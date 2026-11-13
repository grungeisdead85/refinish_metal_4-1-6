-- refinish-startup.lua
-- ==========================================
-- REFINISH METAL: PIPELINE STARTUP
-- ==========================================
-- Rebuilds the full asset pipeline: sweep -> modules -> scan ->
-- index -> index-reaction -> index-entity -> load (autosave only).
--
-- PROMPT RULES (simple, no flag combinations):
--   No args  = manual invocation (hotkey/console).
--              Show prompts based on msg_setting (DEBUG/GUIDED/PASSIVE).
--   'SILENT' = automatic invocation (boot, autosave, tripwire, config).
--              No prompts ever. Pipeline runs, telemetry is written,
--              caller owns the user-facing output.
--
-- Every step is timed and written to _G.refinish_telemetry.startup
-- regardless of prompt mode. The data is always available for the
-- status panel, log, and debug dump.
-- ==========================================

local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local THEME = reqscript('refinish-theme').get_current_theme()
local utils = require('utils')

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body. The
-- panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot, here the step a line belongs to.
-- Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'STARTUP'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
    else
        -- The composer failed to load. Same grammar, unsanitised.
        line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
            tostring(subject or '-'), tostring(typ or 'UNTYPED'),
            tostring(msg))
    end
    _G.refinish_log_event(line)
end

-- ---- WHICH LINES POP ----
-- Quiet is for faults and the few confirmations a player wants at a
-- glance, not every subsystem finishing. The pipeline summary is the
-- only line here that can reach it, and only when a player ran this
-- by hand (see summary_type). Every step's own line is DETAIL:
-- debugging material the summary already carries in its timings.

local args = {...}
local silent = (args[1] == 'SILENT')

-- ---- HOW LOUD THE SUMMARY IS ----
-- COMPLETE when a player ran this by hand. DETAIL inside a save
-- cycle, where the cycle's own summary is the one that pops. INFO for
-- the automatic runs (map load, the ESC menu, a panel rebuild), which
-- Info still shows.
local function summary_type()
    if not silent then return 'COMPLETE' end
    if _G.refinish_autosave_in_progress then return 'DETAIL' end
    return 'INFO'
end

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- TELEMETRY HELPER
-- ==========================================
-- Writes to _G.refinish_telemetry.startup if the table exists.
-- If it doesn't (e.g. manual console invocation before boot),
-- timing still works locally; just isn't persisted.
-- ==========================================
local function tset(key, value)
    if _G.refinish_telemetry and _G.refinish_telemetry.startup then
        _G.refinish_telemetry.startup[key] = value
    end
end

-- ==========================================
-- THE LOAD CLOCK
-- ==========================================
-- Times the parts of one pipeline run and reports them, costliest
-- first, when the run ends: DETAIL lines under LOAD_CLOCK. The files on
-- the load path (refinish-module-engine, refinish-module-react,
-- refinish-index, refinish-index-reaction, refinish-index-entity) read
-- _G.refinish_load_clock fresh at each run and time their own parts
-- through it. Outside a run it is nil, and they time nothing.
--
-- os.clock() reads whole milliseconds here. A part timed once is exact
-- to the millisecond. A part timed per item (an assign, an insert) is a
-- sum of 0 and 1 ms readings: right on average, and within about a
-- tenth of a second over 60,000 items.
--
-- Script lookups by name are counted at dfhack.findScript, which
-- reqscript, script_environment and run_script all call first. DFHack's
-- Core::findScript canonicalizes a path in each script folder until one
-- holds the file (Core.cpp), about 7 ms a lookup in region4 (KNOWN
-- PATHS, CHECKED WITHOUT A SEARCH, refinish_steel.lua). The counter
-- calls the real function and hands back its answer unchanged, and it
-- is taken off again before the report.
-- ==========================================
local function new_load_clock()
    local clock = os.clock
    local lc = { now = clock, laps = {}, lookups = {} }
    -- Adds s seconds over n calls under name. label names the module or
    -- civ of the largest single addition, the report's "largest".
    function lc.add(name, s, n, label)
        local e = lc.laps[name]
        if not e then
            e = { n = 0, s = 0, max = -1 }
            lc.laps[name] = e
        end
        e.n = e.n + (n or 1)
        e.s = e.s + s
        if s > e.max then e.max, e.at = s, label end
    end
    -- One part: the time since t0. Returns now, the next part's t0.
    function lc.lap(name, t0, label)
        local now = clock()
        lc.add(name, now - t0, 1, label)
        return now
    end
    return lc
end

-- Puts the lookup counter on dfhack.findScript. The real function is
-- kept in _G across runs, so a run that died before its report, and left
-- the counter on, is never counted through twice.
local function count_lookups(lc)
    local real = _G.refinish_real_find_script or dfhack.findScript
    _G.refinish_real_find_script = real
    lc.real_find = real
    -- Who asked, for the report: the first frame outside DFHack's own
    -- dfhack.lua, where reqscript, script_environment and run_script
    -- live, and outside C (a pcall). File name and line.
    local getinfo = debug and debug.getinfo
    local DIRS = '.*[/' .. string.char(92) .. ']'     -- up to the last / or backslash
    local function caller()
        if not getinfo then return '?' end
        -- Level 1 is this function and 2 the counter below. getinfo is
        -- called directly: through a pcall it would count one level more.
        for level = 3, 12 do
            local info = getinfo(level, 'Sl')
            if not info then return '?' end
            local src = info.short_src or '?'
            if src ~= '[C]' and not src:find('dfhack.lua', 1, true) then
                return (src:gsub(DIRS, '')) .. ':' .. tostring(info.currentline)
            end
        end
        return '?'
    end
    -- ---- EACH NAME'S PATH, FOUND ONCE A RUN ----
    -- A lookup searches every script folder for the name, about 5 ms
    -- each (MEASURED 2026-10-01, the load clock, region4: 60 lookups,
    -- 295 ms). The folders and the files in them do not change during a
    -- run, so the path found for a name, or that there is none, is kept
    -- for the rest of the run and a second ask is answered from it.
    -- Counted apart from the real lookups, in kept.
    local found = {}
    dfhack.findScript = function(name)
        local e = lc.lookups[name]
        if not e then
            e = { n = 0, s = 0, sites = {}, kept = 0 }
            lc.lookups[name] = e
        end
        local was = found[name]
        if was ~= nil then
            e.kept = (e.kept or 0) + 1
            if was == false then return nil end
            return was
        end
        local t1 = os.clock()
        local path = real(name)
        found[name] = path or false
        e.n = e.n + 1
        e.s = e.s + (os.clock() - t1)
        local site = caller()
        e.sites[site] = (e.sites[site] or 0) + 1
        return path
    end
end

-- ---- ONE LOOKUP PER SCRIPT A RUN, FOR EVERY FILE ----
-- During a pipeline run _G.refinish_run_require(name) answers what
-- reqscript(name) answers, and finds each script once a run. A file
-- that asks for the same script over and over during a load calls
-- (_G.refinish_run_require or reqscript)(name): outside a run the global
-- is nil and it asks reqscript as before. Made fresh at every run and
-- cleared at its end, so no handle outlives the load that found it
-- (dfhack/scripts.md, a handle captured at a script's first load).
-- MEASURED 2026-10-01, the load clock, region4: the same few scripts
-- were still found 39 times in a load, at 5.5 ms a lookup: the sprite
-- art module once per tinted slot and edit, the sprite engine for the
-- ash sprite's every call, the material injector per plant and drain.
local function open_run_require()
    local found = {}
    -- A scratch table for this run only, for work every module's call
    -- would otherwise repeat on unchanged arrays (the reaction builder's
    -- template signatures). Cleared with the lookups.
    _G.refinish_run_cache = {}
    _G.refinish_run_require = function(name)
        local e = found[name]
        if e == nil then
            e = reqscript(name)
            found[name] = e
        end
        return e
    end
end

-- Times every script DFHack runs, or loads for the first time, during
-- the run (dfhack.run_script_with_env, under every run_script and every
-- first script_environment), by name, inclusive of the scripts each
-- loads in turn. The real function's answers pass through unchanged,
-- and it is put back in the report.
local function time_script_runs(lc)
    local real = _G.refinish_real_run_script_with_env or dfhack.run_script_with_env
    _G.refinish_real_run_script_with_env = real
    lc.real_run = real
    lc.scripts = {}
    dfhack.run_script_with_env = function(envVars, name, flags, ...)
        local t1 = os.clock()
        local r = table.pack(real(envVars, name, flags, ...))
        local e = lc.scripts[name]
        if not e then
            e = { n = 0, s = 0 }
            lc.scripts[name] = e
        end
        e.n = e.n + 1
        e.s = e.s + (os.clock() - t1)
        return table.unpack(r, 1, r.n)
    end
end

-- Takes the counter off, clears the clock, and logs every part,
-- costliest first. Parts under a millisecond are summed into one line.
-- Parts overlap: a module's whole holds its steps, and the lookups sit
-- inside everything else.
local function report_load_clock(lc)
    if not lc then return end
    if lc.real_find then dfhack.findScript = lc.real_find end
    if lc.real_run then dfhack.run_script_with_env = lc.real_run end
    _G.refinish_run_require = nil
    _G.refinish_run_cache = nil
    if _G.refinish_load_clock == lc then _G.refinish_load_clock = nil end
    local names, n_look, s_look = {}, 0, 0
    for name, e in pairs(lc.lookups) do
        n_look, s_look = n_look + e.n, s_look + e.s
        names[#names + 1] = { name = name, n = e.n, s = e.s }
    end
    if n_look > 0 then
        lc.add('script lookups by name (findScript), all of them', s_look, n_look)
    end
    local n_kept = 0
    for _, e in pairs(lc.lookups) do n_kept = n_kept + (e.kept or 0) end
    if n_kept > 0 then
        log('DETAIL', string.format('%d more lookup(s) answered from paths'
            .. ' found earlier in the run.', n_kept), 'LOAD_CLOCK')
    end
    local rows = {}
    for name, e in pairs(lc.laps) do rows[#rows + 1] = { name = name, e = e } end
    table.sort(rows, function(a, b) return a.e.s > b.e.s end)
    log('DETAIL', string.format('Load clock: %d part(s), costliest first. Parts'
        .. ' overlap: a whole holds its steps, and lookups sit inside both.',
        #rows), 'LOAD_CLOCK')
    local small_n, small_s = 0, 0
    for _, r in ipairs(rows) do
        local e = r.e
        if e.s < 0.001 then
            small_n, small_s = small_n + 1, small_s + e.s
        else
            log('DETAIL', string.format(
                '%-62s %6d call(s) %9.1f ms %9.3f ms a call, largest %.1f ms%s',
                r.name, e.n, e.s * 1000, e.s * 1000 / math.max(e.n, 1),
                e.max * 1000, e.at and (' (' .. tostring(e.at) .. ')') or ''),
                'LOAD_CLOCK')
        end
    end
    if small_n > 0 then
        log('DETAIL', string.format('%d smaller part(s), %.1f ms together.',
            small_n, small_s * 1000), 'LOAD_CLOCK')
    end
    table.sort(names, function(a, b) return a.s > b.s end)
    local top = {}
    for i = 1, math.min(10, #names) do
        top[#top + 1] = string.format('%s x%d, %.0f ms', names[i].name,
            names[i].n, names[i].s * 1000)
    end
    if #top > 0 then
        log('DETAIL', 'Script lookups, costliest names: '
            .. table.concat(top, '; ') .. '.', 'LOAD_CLOCK')
    end
    -- Who asked for the six costliest, callers by count.
    for i = 1, math.min(6, #names) do
        local e = lc.lookups[names[i].name]
        local sites = {}
        for site, n in pairs(e.sites or {}) do
            sites[#sites + 1] = { site = site, n = n }
        end
        table.sort(sites, function(a, b) return a.n > b.n end)
        local parts = {}
        for j = 1, math.min(6, #sites) do
            parts[#parts + 1] = string.format('%s x%d', sites[j].site, sites[j].n)
        end
        log('DETAIL', string.format('%s asked for by: %s.', names[i].name,
            table.concat(parts, ', ')), 'LOAD_CLOCK')
    end
    -- The scripts run or first loaded, costliest first, inclusive.
    local runs = {}
    for name, e in pairs(lc.scripts or {}) do
        runs[#runs + 1] = { name = name, n = e.n, s = e.s }
    end
    table.sort(runs, function(a, b) return a.s > b.s end)
    local shown = {}
    for i = 1, math.min(16, #runs) do
        shown[#shown + 1] = string.format('%s x%d, %.0f ms', tostring(runs[i].name),
            runs[i].n, runs[i].s * 1000)
    end
    if #shown > 0 then
        log('DETAIL', 'Scripts run or first loaded, costliest, each holding'
            .. ' the scripts it loads: ' .. table.concat(shown, '; ') .. '.', 'LOAD_CLOCK')
    end
end


-- ==========================================
-- THE INJECTED COUNTS (the status panel's INJECTED rows)
-- ==========================================
-- What RM has in the arrays now, against the baseline boot captured
-- before any injection. Counted at the end of every pipeline, and
-- published as _G.refinish_count_injected so a finish minted in play
-- (refinish-mint-finish.lua, notice) brings the numbers up to date; the
-- status panel only reads them. Until 2026-10-03 they were counted here
-- alone, so a finish minted in play showed only after the next load.
-- ==========================================
local function count_injected(c)
    -- Injection counts: compare live array sizes to baseline.
    -- Baseline was captured during boot (before any RM injection).
    local live_inorganics = #df.global.world.raws.inorganics.all
    local live_reactions = #df.global.world.raws.reactions.reactions
    c.inj_materials = live_inorganics - (c.base_inorganics or live_inorganics)
    c.inj_reactions = live_reactions - (c.base_reactions or live_reactions)

    -- Category count: walk the live array (small, fast)
    local cat_count = 0
    for _, cat in ipairs(df.global.world.raws.reactions.reaction_categories) do
        if string.find(cat.id, "REFINISH_STEEL_CAT_") then cat_count = cat_count + 1 end
    end
    c.inj_categories = cat_count

    -- Permission count: walk the player civ's permitted reactions
    -- to count RM entries. Also count total civs that received perms.
    local perm_count = 0
    local civs_unlocked = 0
    local rm_rxn_indexes = {}
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if string.find(rxn.code, "REFINISH_STEEL_") then
            rm_rxn_indexes[rxn.index] = true
        end
    end
    for _, civ in ipairs(df.global.world.entities.all) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            local civ_has_rm = false
            for _, pid in ipairs(civ.entity_raw.workshops.permitted_reaction_id) do
                if rm_rxn_indexes[pid] then
                    perm_count = perm_count + 1
                    civ_has_rm = true
                end
            end
            if civ_has_rm then civs_unlocked = civs_unlocked + 1 end
        end
    end
    c.inj_permissions = perm_count
    c.civs_unlocked = civs_unlocked
end
_G.refinish_count_injected = function()
    local c = _G.refinish_telemetry and _G.refinish_telemetry.counts
    if c then count_injected(c) end
end


-- ==========================================
-- PIPELINE EXECUTION
-- ==========================================
-- This is the actual work. Always runs the same way regardless
-- of prompt mode. Returns a table of timing results so the
-- prompt section can read them without touching _G.
-- ==========================================
local function run_pipeline()
    log('DETAIL', 'Pipeline initiated (silent: ' .. tostring(silent) .. ').',
        'PIPELINE')

    -- THE LOAD CLOCK: on for this run, reported and cleared at its end
    -- (report_load_clock, after the summary).
    local LC = new_load_clock()
    _G.refinish_load_clock = LC
    count_lookups(LC)
    time_script_runs(LC)
    open_run_require()

    local startup_clock = os.clock()
    local t = startup_clock

    -- ---- WHAT THIS RUN MAKES, MARKED ----
    -- The ids DF will give the next item, building, job, work order and
    -- history event, read before Step 2 starts any module. Anything
    -- numbered from here on is made by this run, on this load's
    -- material indices, and the remap at Step 6.5 leaves it as it is
    -- (refinish-ledger.lua, MADE THIS LOAD). Added 2026-10-12: Making
    -- Fuel's pooper drops dung as it starts, and the remap read that
    -- dung's index through the save's layout.
    local made_from = nil
    pcall(function()
        made_from = dfhack.script_environment('refinish-ledger').next_ids()
    end)

    -- ==========================================
    -- STEP 1: ORPHANED GHOST SWEEPER
    -- ==========================================
    -- After a save/reload, JIT-compiled ghost grinder reactions
    -- may have stale suffixes on their job names. This sweep
    -- strips them back to the base reaction code so the watcher
    -- can re-resolve them cleanly.
    -- ==========================================
    local orphaned_jobs_fixed = 0
    local ok, err = pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local r_name = tostring(job.reaction_name)
                if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                    -- A finished-metal grinder is one per base metal
                    -- (refinish-mint-finish.lua, THE FINISHED-METAL
                    -- GRINDERS), and a ghost of one is its code with the
                    -- finish's id on the end, so that ghost is cut at the
                    -- finish's id (REFINISH_STEEL_MAT_...). The other
                    -- grinders end at their family name.
                    local base_name = string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_FIN_")
                        and (string.match(r_name, "^(.-)_REFINISH_STEEL_MAT_") or r_name)
                        or string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                    if base_name and r_name ~= base_name then
                        job.reaction_name = base_name
                        orphaned_jobs_fixed = orphaned_jobs_fixed + 1
                    end
                end
            end
        end
    end)
    if not ok then
        log('WARNING', 'Ghost sweep failed: ' .. tostring(err), 'GHOST_SWEEP')
    end

    local t_sweep = os.clock() - t
    tset('t_sweep', t_sweep)
    log('DETAIL', string.format('Ghost sweep complete (%.3fs); %d orphans fixed.',
        t_sweep, orphaned_jobs_fixed), 'GHOST_SWEEP')
    t = os.clock()

    -- ==========================================
    -- STEP 2: MODULE PIPELINE
    -- ==========================================
    dfhack.script_environment('refinish-module-engine').run_module_pipeline()
    local t_modules = os.clock() - t
    tset('t_modules', t_modules)
    log('DETAIL', string.format('Module pipeline complete (%.3fs).', t_modules),
        'MODULE_PIPELINE')
    t = os.clock()

    -- ==========================================
    -- STEP 2.5: BOOT CACHE BUILDER
    -- ==========================================
    -- Evaluators plus the unified boot scan. Builds the _G caches
    -- that later steps consume:
    --
    --   evaluators -> refinish_evaluated_reactions
    --                 refinish_best_metal_template   (Steps 5 and 6)
    --                 refinish_best_dust_template    (Steps 5 and 6)
    --   boot scan  -> refinish_valid_bases, refinish_known_metals_cache
    --                 refinish_reaction_traits
    --                 refinish_civ_tech              (Step 3 and Step 5.5)
    --
    -- ORDER IS LOAD BEARING IN THREE PLACES:
    --
    --   1. AFTER Step 2. The evaluators read
    --      _G.refinish_module_registry to exclude module reactions
    --      from scoring (evaluate-metal-making:195-211,
    --      evaluate-dust-making:164-177). With an empty registry a
    --      module reaction could win, and the cached .reaction is a
    --      live df.reaction pointer that clear_module_assets frees on
    --      the next wash. This ordering is memory safety, not taste.
    --
    --   2. Evaluators BEFORE the scan. Pass 3 Source B2 consumes
    --      refinish_evaluated_reactions (refinish_steel:245-248).
    --
    --   3. BEFORE Step 3. refinish-scan reads refinish_civ_tech at
    --      :395 with a silent "or {}" fallback, and calls
    --      get_valid_bases(true, true) at :107, which would trigger
    --      the scan itself with different allow_divine/allow_mythical
    --      arguments than boot uses. Populating first keeps that
    --      fallback dead.
    --
    -- GUARD LIFETIME: once per loaded world, NOT once per data cycle.
    -- These caches are nil'd only in the teardown block
    -- (refinish_steel:866-873) and never by a wash, so every later
    -- startup invocation skips this. That matters because
    -- refinish-startup runs on every ESC menu exit, every autosave
    -- restore and every config change.
    --
    -- Contrast Step 2 above: guarded by _G.refinish_modules_injected,
    -- which clear_module_assets resets, so modules DO rebuild every
    -- data cycle. Two adjacent blocks, two different lifetimes.
    -- ==========================================
    if not _G.refinish_civ_tech
       or not _G.refinish_best_metal_template
       or not _G.refinish_best_dust_template then

        local eval_metal = reqscript('refinish-evaluate-metal-making')
        local eval_dust  = reqscript('refinish-evaluate-dust-making')

        -- ---- ONE EVALUATION OF THE METAL REACTIONS ----
        -- get_best_metal_template(true) evaluates every reaction itself,
        -- through get_metal_making_reactions(true), and keeps the result,
        -- so the list is taken from that same evaluation (false: the
        -- result kept a moment ago, in this run). Asked the other way
        -- round, as until 2026-10-01, each call forced a full evaluation
        -- of its own, back to back on an unchanged array. Only the boot
        -- scan reads the list, and only reads it.
        local t_ev = os.clock()
        _G.refinish_best_metal_template = eval_metal.get_best_metal_template(true)
        _G.refinish_evaluated_reactions = eval_metal.get_metal_making_reactions(false)
        t_ev = LC.lap('boot cache: metal reactions evaluated', t_ev)
        _G.refinish_best_dust_template  = eval_dust.get_best_dust_template(true)
        t_ev = LC.lap('boot cache: dust reactions evaluated', t_ev)

        local metal_code = _G.refinish_best_metal_template and _G.refinish_best_metal_template.code or "NONE"
        local dust_code  = _G.refinish_best_dust_template and _G.refinish_best_dust_template.code or "NONE"
        log('DETAIL', string.format('Evaluators complete; Metal: [%s], Dust: [%s].',
            metal_code, dust_code), 'EVALUATORS')

        reqscript('refinish-boot').run_unified_scan()
        LC.lap('boot cache: unified scan', t_ev)

        -- Cache counts move with the work that produces them. These
        -- were snapshotted at boot (refinish_steel:269-272); once the
        -- boot call site is removed they would read zero there.
        if _G.refinish_telemetry and _G.refinish_telemetry.counts then
            local function tcount(tbl)
                if not tbl then return 0 end
                local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n
            end
            local c = _G.refinish_telemetry.counts
            c.valid_metals    = _G.refinish_valid_bases and #_G.refinish_valid_bases or 0
            c.known_metals    = tcount(_G.refinish_known_metals_cache)
            c.reaction_traits = tcount(_G.refinish_reaction_traits)
            c.civ_techs       = tcount(_G.refinish_civ_tech)
        end

        local t_boot_cache = os.clock() - t
        tset('t_boot_cache', t_boot_cache)
        log('DETAIL', string.format('Boot cache built (%.3fs).', t_boot_cache),
            'BOOT_CACHE')
        t = os.clock()
    end

    -- ==========================================
    -- STEP 3: BLUEPRINT SCAN
    -- ==========================================
    dfhack.run_script('refinish-scan')
    local t_scan = os.clock() - t
    tset('t_scan', t_scan)
    log('DETAIL', string.format('Blueprint scan complete (%.3fs).', t_scan),
        'BLUEPRINT_SCAN')
    t = os.clock()

    -- ==========================================
    -- STEP 4: MATERIAL INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index')
    local t_idx_mat = os.clock() - t
    tset('t_idx_mat', t_idx_mat)
    log('DETAIL', string.format('Material injection complete (%.3fs).', t_idx_mat),
        'MATERIAL_INJECTION')
    t = os.clock()

    -- ==========================================
    -- STEP 5: REACTION INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index-reaction')
    local t_idx_rxn = os.clock() - t
    tset('t_idx_rxn', t_idx_rxn)
    log('DETAIL', string.format('Reaction injection complete (%.3fs).', t_idx_rxn),
        'REACTION_INJECTION')
    t = os.clock()

    -- ==========================================
    -- STEP 5.5: MODULE PERMISSION EVALUATION
    -- ==========================================
    -- Runs AFTER boot (civ_tech exists) and AFTER reaction
    -- injection (module reaction indexes are resolved). Evaluates
    -- each module reaction against each civ's capabilities and
    -- metal knowledge, injecting permissions only where both
    -- gates pass. Also registers product metals as known, so
    -- core RM's index-entity (Step 6) can see module metals
    -- when gating Refinish permissions.
    -- ==========================================
    local t_mod_perms = 0
    if _G.refinish_module_registry and next(_G.refinish_module_registry) then
        local mod_perm_eval = dfhack.script_environment('refinish-module-evaluate-permissions')
        local mod_perms = mod_perm_eval.evaluate_and_inject()
        t_mod_perms = os.clock() - t
        tset('t_mod_perms', t_mod_perms)
        log('DETAIL', string.format(
            'Module permission evaluation complete (%.3fs); %d permissions.',
            t_mod_perms, mod_perms), 'MODULE_PERMISSIONS')
        t = os.clock()
        -- Refresh the metals panel if the HUD is open, so module
        -- product metals appear with correct availability colors.
        if _G.refinish_hud_view then
            local metals_panel = _G.refinish_hud_view.router_left.subviews[2]
            if metals_panel and metals_panel.refresh_list then
                metals_panel:refresh_list()
            end
        end
    end

    -- ==========================================
    -- STEP 6: ENTITY PERMISSION INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index-entity')
    local t_idx_ent = os.clock() - t
    tset('t_idx_ent', t_idx_ent)
    log('DETAIL', string.format('Entity injection complete (%.3fs).', t_idx_ent),
        'ENTITY_INJECTION')
    t = os.clock()

    -- ==========================================
    -- STEP 6.5: MATERIAL INDEX REMAP
    -- ==========================================
    -- Indices are final as of Step 4. Before anything reads a
    -- stored index, translate every object through last session's
    -- ledger: stored index -> material name -> current index.
    --
    -- Every save keeps objects on their materials now (the save wash
    -- was retired 2026-09-29), so this is the only recovery there is.
    --
    -- Must run BEFORE the legacy migration below. That restore sets
    -- mat_index from names; remapping afterwards would take freshly
    -- correct indices and rewrite them against a stale ledger.
    -- ==========================================
    local ledger = dfhack.script_environment('refinish-ledger')
    -- remap's third value is true when THE FINGERPRINT (refinish-ledger)
    -- showed nothing to move and nothing new for Step 8 to store.
    -- made_from (WHAT THIS RUN MAKES, MARKED, at the top of the run):
    -- what this run made is left as it is.
    local ok_rm, rm_err, _, rm_unchanged = pcall(function()
        return ledger.remap({ since = made_from })
    end)
    -- ERROR, not WARNING: a failed remap leaves saved objects pointing
    -- at whatever material now sits at their old index.
    if not ok_rm then
        log('ERROR', 'Ledger remap failed: ' .. tostring(rm_err), 'LEDGER')
    end
    local t_remap = os.clock() - t
    tset('t_remap', t_remap)
    log('DETAIL', string.format('Ledger remap complete (%.3fs).', t_remap),
        'LEDGER')
    t = os.clock()

    -- ==========================================
    -- STEP 6.7: FINISHES THE FORT CAN MAKE
    -- ==========================================
    -- A finish is minted only once the fort has had both its base metal's
    -- bars and its dust (refinish-mint-finish.lua). Steps 4 and 5 rebuilt
    -- what the finish roster already held; this reads the bars and dusts
    -- in the fort now, by their materials, which is why it runs after the
    -- remap has put every stored index right. A base metal or dust new to
    -- the roster mints its pairs, appended to the arrays and the roster,
    -- and grants their permissions itself, since Step 6 has run.
    -- minted_late counts the finish materials it appended: Step 8 must
    -- write the ledger when it is not 0.
    -- ==========================================
    local minted_late = 0
    local ok_rc, rc_n = pcall(function()
        return reqscript('refinish-mint-finish').reconcile()
    end)
    if not ok_rc then
        -- ERROR: the arrays stand as Steps 4 and 5 left them, and the next
        -- load reads the fort again.
        log('ERROR', 'Finish reconcile failed: ' .. tostring(rc_n), 'MINT_FINISH')
    else
        minted_late = rc_n or 0
    end
    local t_mint = os.clock() - t
    tset('t_mint', t_mint)
    log('DETAIL', string.format('Finish reconcile complete (%.3fs).', t_mint),
        'MINT_FINISH')
    t = os.clock()

    -- ==========================================
    -- STEP 7: LEGACY PAYLOAD MIGRATION
    -- ==========================================
    -- A save last written by the retired save wash still has its
    -- finished objects on their base metals, their finishes held in
    -- the JSON payload in site data. refinish-load.lua restores them
    -- once, by name, and deletes the payload, so this runs once per
    -- save: the next save written carries no payload.
    --
    -- It carries the old v3.x migration too. That gate only forced
    -- this same restore when the payload's ids looked old, and ids that
    -- no longer exist restore nothing either way. Every payload is
    -- migrated now, because every save the old line wrote needs it,
    -- whatever its ids.
    -- ==========================================
    local t_load = 0
    local legacy_payload = dfhack.persistent.getSiteData("REFINISH_STEEL_PAYLOAD")
    if legacy_payload and legacy_payload ~= "" then
        dfhack.run_script('refinish-load')
        t_load = os.clock() - t
        log('DETAIL', string.format('Legacy payload migration complete (%.3fs).',
            t_load), 'PAYLOAD_MIGRATION')
    end
    -- Written every run, so the panel never shows a previous run's time.
    tset('t_load', t_load)

    -- ==========================================
    -- STEP 7.5: PILE SETTINGS FOLLOW THEIR MATERIALS
    -- ==========================================
    -- After a remap that read the stored ledger, each pile's entries move
    -- with their materials, by name (refinish-ledger.lua, PILE SETTINGS
    -- FOLLOW THEIR MATERIALS). Here, after Steps 6.7 and 7, so the
    -- finishes those mint keep their choices too.
    -- ==========================================
    local ok_rp, rp_err = pcall(function() return ledger.remap_piles() end)
    if not ok_rp then
        -- ERROR: the piles keep their entries where the save left them.
        log('ERROR', 'Pile settings not moved: ' .. tostring(rp_err), 'LEDGER')
    end

    -- ==========================================
    -- STEP 8: LEDGER WRITE
    -- ==========================================
    -- Snapshot id -> index for this session's injected materials.
    -- Runs after the restore so the remap above always reads the
    -- previous session's record, never one written this run.
    -- ==========================================
    -- ---- NOT WHEN STARTUP IS THE TAIL OF A SAVE ----
    -- The AUTOSAVE cycle, retired 2026-09-29, ended by running this
    -- whole script, so step 8 fired with the array freshly rebuilt.
    -- The hotsave cycle rebuilds inline and never comes here, so the
    -- flag test below is now only a safeguard; the reasoning stands for
    -- any startup run inside a save cycle. The quicksave it just took
    -- holds the PRE rebuild indices, and the shutdown wrote a ledger
    -- describing exactly those. Writing again here replaces that with
    -- the rebuilt layout, the file and the ledger stop agreeing, and
    -- the next cold load remaps every object against a map of an array
    -- that was never saved.
    --
    -- MEASURED in the session log: Step 0 recorded 441, this line then
    -- recorded 442 in the same second. Two different layouts, one
    -- ledger, and the save file matched the one that got thrown away.
    --
    -- On a real load the flag is false and this runs as it always did.
    if _G.refinish_autosave_in_progress then
        log('DETAIL', 'Save cycle in progress; ledger left describing the'
            .. ' save just written.', 'LEDGER')
    else
        -- After an unchanged fingerprint there is nothing to store: remap
        -- compared every record a write would make, and seeded the layout
        -- the save hook's later checks compare against, and nothing from
        -- Step 6.5 to here moves a material. So no write is made. Until
        -- 2026-10-01 the write was asked to keep the ledger, and walked
        -- the layout again (31 to 63 ms) only to find it unchanged.
        -- Otherwise it writes in full, as before.
        -- A finish minted at Step 6.7 changes the layout after the remap
        -- compared it, so that write is never skipped.
        local keep = ok_rm and rm_unchanged == true and minted_late == 0
        local ok_lw, lw_err = true, nil
        if not keep then
            ok_lw, lw_err = pcall(function() return ledger.write() end)
        end
        -- ERROR for the same reason as the remap: the next load has no
        -- correct layout to move objects from.
        if not ok_lw then
            log('ERROR', 'Ledger write failed: ' .. tostring(lw_err), 'LEDGER')
        end
    end

    -- ==========================================
    -- FINALIZE TELEMETRY
    -- ==========================================
    local t_total = os.clock() - startup_clock
    tset('t_total', t_total)

    -- Update all asset counts from the freshly built pipeline
    if _G.refinish_telemetry and _G.refinish_telemetry.counts then
        local c = _G.refinish_telemetry.counts
        local function tcount(tbl) if not tbl then return 0 end; local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n end

        -- Blueprint counts
        if _G.refinish_blueprint then
            c.bp_materials = tcount(_G.refinish_blueprint.materials)
            c.bp_reactions = tcount(_G.refinish_blueprint.reactions)
            c.bp_categories = tcount(_G.refinish_blueprint.categories)
        end

        -- Active base metals from config
        local json = require('json')
        local bases_raw = dfhack.persistent.getSiteData('refinish_config_bases')
        if bases_raw and bases_raw ~= "" then
            local ok, bases = pcall(json.decode, bases_raw)
            if ok and bases then c.active_bases = tcount(bases) end
        else
            -- Nothing saved: the default selection (refinish-bases.lua,
            -- THE DEFAULT SELECTION).
            c.active_bases = tcount(dfhack.script_environment('refinish-bases').default_bases())
        end

        count_injected(c)
    end

    -- ---- RM'S SERVICES START ----
    -- The dispatcher and the services riding it, now that every asset is
    -- in RAM, the boot cache is built and the modules have started
    -- (refinish_steel.lua, RM'S SERVICES FOLLOW THE DATA). Map load, the
    -- save hook's reload and a manual start all end here; the hotsave's
    -- restore starts them itself.
    pcall(function()
        local svc = _G.refinish_services
        if svc and svc.start then svc.start() end
    end)

    -- Log the full summary
    log(summary_type(), string.format(
        'Pipeline complete (%.3fs); mod is active. Sweep:%.3f | Mod:%.3f | Scan:%.3f | Mat:%.3f | Rxn:%.3f | ModPerm:%.3f | Ent:%.3f | Migrate:%.3f',
        t_total, t_sweep, t_modules, t_scan, t_idx_mat, t_idx_rxn, t_mod_perms,
        t_idx_ent, t_load), 'PIPELINE')

    -- ---- THE LOAD CLOCK, REPORTED ----
    -- After the summary, so the stage totals above read first.
    report_load_clock(LC)

    -- Return timing results for the prompt section to use
    return {
        t_total = t_total, t_sweep = t_sweep, t_modules = t_modules,
        t_scan = t_scan, t_idx_mat = t_idx_mat, t_idx_rxn = t_idx_rxn,
        t_mod_perms = t_mod_perms, t_idx_ent = t_idx_ent, t_load = t_load,
        orphaned_jobs_fixed = orphaned_jobs_fixed
    }
end


-- ==========================================
-- ENTRY POINT
-- ==========================================
-- SILENT: Run pipeline, no prompts, return immediately.
-- Manual: Run pipeline, then show result prompt.
--
-- For manual invocations, run_pipeline() is called directly
-- at the top level of the script; NOT inside a ZScreen
-- callback. This guarantees there is no parent modal on the
-- screen stack when the result prompt fires.
-- ==========================================
if silent then
    -- Automatic invocation: just run, caller owns the output.
    run_pipeline()
    return
end

-- Manual invocation: confirm before running. The pipeline and
-- its result prompt run on the next frame so the confirmation
-- dialog is fully off the screen stack first.
RefinishPrompt{
    text = "Initiate startup?\n\nThis will rebuild all materials, reactions, and entity permissions.",
    text_pen = THEME.PRI,
    on_yes = function()
        -- Deferred: let the confirmation prompt fully dismiss before
        -- the pipeline runs and potentially shows its own result prompt.
        dfhack.timeout(1, 'frames', function()
            local timing = run_pipeline()

            if msg_setting == 'DEBUG' then
                local bp_mats = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_materials or 0
                local bp_rxns = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_reactions or 0
                local bp_cats = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_categories or 0

                local report = string.format(
                    "Startup Pipeline Complete (%.3fs)\n\n" ..
                    "--- PIPELINE TIMING ---\n" ..
                    "Ghost Sweep:      %.3fs\n" ..
                    "Module Pipeline:  %.3fs\n" ..
                    "Blueprint Scan:   %.3fs\n" ..
                    "Index Materials:  %.3fs\n" ..
                    "Index Reactions:  %.3fs\n" ..
                    "Module Perms:     %.3fs\n" ..
                    "Index Entities:   %.3fs\n" ..
                    "Migration:        %.3fs\n\n" ..
                    "--- BLUEPRINT ---\n" ..
                    "Materials: %d  |  Reactions: %d  |  Categories: %d\n" ..
                    "Orphans Fixed: %d",
                    timing.t_total, timing.t_sweep, timing.t_modules, timing.t_scan,
                    timing.t_idx_mat, timing.t_idx_rxn, timing.t_mod_perms,
                    timing.t_idx_ent, timing.t_load,
                    bp_mats, bp_rxns, bp_cats,
                    timing.orphaned_jobs_fixed
                )
                RefinishPrompt{
                    frame_h = 24,
                    frame_w = 60,
                    text = report,
                    on_ok = function() end
                }:show()

            elseif msg_setting == 'GUIDED' then
                RefinishPrompt{
                    frame_h = 10,
                    text = string.format("Refinish Metal is live. Startup completed in %.2fs.", timing.t_total),
                    on_ok = function() end
                }:show()

            elseif msg_setting == 'PASSIVE' then
                dfhack.gui.showAnnouncement(
                    string.format('Refinish Metal: Startup complete (%.2fs).', timing.t_total),
                    THEME.PRI, true
                )
            end
        end)
    end
}:show()