--@ module = true
-- refinish_steel.lua
-- ==========================================
-- REFINISH METAL: MASTER COORDINATION SCRIPT
-- ==========================================
-- This is the top-level entry point. It handles:
--   - Application boot (logging, session rotation)
--   - Map load (evaluators, boot scan, state detection)
--   - Delayed startup (triggers the pipeline)
--   - Runtime monitors (reaction watcher, UI tripwire, autosave)
--   - Map unload (shutdown, cleanup)
--
-- _G KEY REGISTRY:
-- Every _G.refinish_ key used across the mod is listed here.
-- All per-map keys are nil'd in the shutdown block (PRIORITY 4).
--
-- SESSION STATE (per-map lifecycle)
--   active                  - bool: is the mod running on this map?
--   menu_locked             - bool: options screen open, or a game save
--                             between its unload and reload (set every
--                             frame by refinish-save-hook.lua)
--   save_hook_mode          - string: refinish-save-hook.lua's state
--   silent_load             - bool: suppress prompts on next startup?
--   autosave_in_progress    - bool: is an autosave cycle running?
--   version                 - string: mod version (e.g. "v3.2")
--
-- PIPELINE STATE (what's been injected into RAM)
--   ram_loaded              - bool: are RM materials in the inorganics array?
--   reactions_loaded        - bool: are RM reactions in the reactions array?
--   entity_loaded           - bool: are RM permissions in civ entity_raws?
--   data_loaded             - bool: do any items carry RM material indexes?
--
-- BOOT CACHES (derived from static raws, computed once on map load)
--   valid_bases             - array: all physically valid metals (from boot Pass 2)
--   known_metals_cache      - set: metals the player civ can access (boot Pass 3)
--   reaction_traits         - dict: scored traits per reaction index (boot Pass 1)
--   evaluated_reactions     - dict: all scored metal-making reactions (evaluator)
--   best_metal_template     - table: highest-scoring metal reaction + indexes
--   best_dust_template      - table: highest-scoring powder reaction + indexes
--   civ_tech                - dict: per-civ mood/tech/known_metals (boot Pass 4)
--
-- BLUEPRINT (scan output, rebuilt each data cycle)
--   blueprint               - table: materials, reactions, categories, civ_tech,
--                              ui_dict (original_names went with the powder rename)
--
-- MONITOR TIMESTAMPS (polled by runtime loops)
--   last_ui_ping            - string: last UI tripwire check time
--   last_cal_ping           - string: last calendar check time
--   last_watch_ping         - string: last reaction watcher check time
--   last_real_save          - number: os.time() of last real-time save
--   last_jobs_canceled      - number: count for panel display
--
-- ERROR THROTTLES (prevent log spam from polling loops)
--   err_spam_watcher        - bool: suppress repeated watcher errors
--   err_spam_ui             - bool: suppress repeated UI errors
--   err_spam_cal            - bool: suppress repeated calendar errors
--
-- HUD STATE
--   hud_view                - string: current panel name
--   hud_restore_left        - string: panel to restore on left nav
--   hud_restore_right       - string: panel to restore on right nav
--
-- HOTKEYS
--   hk_cache                - table: keybinding strings by function name
--
-- TELEMETRY (persistent for the full map session)
--   telemetry               - table: structured timing data with sub-tables:
--                              .boot     - map-load boot timings
--                              .startup  - pipeline rebuild timings
--                              .last_save; most recent autosave cycle timings
--                              .counts   - asset counts from latest pipeline run
--
-- AUTOSAVE CONFIG
--   original_autosave       - int: vanilla autosave setting, restored on unload
--
-- LOGGING (persists across full DF session, NOT per-map)
--   log                     - array: in-memory log lines (capped at 5000)
--   log_event               - function: the logging function itself
--   app_boot_rotation_done  - bool: has the session log been rotated?
--
-- MODULE ENGINE (manages its own lifecycle, NOT cleaned per-map)
--   module_registry         - dict: registered module payloads by prefix
--   module_listeners        - dict: listener callbacks by module name
--   modules_injected        - bool: has the module pipeline run this cycle?
--   module_clone_cache      - dict: best clone donor per material class (from evaluator)
-- ==========================================

local scriptmanager = require('script-manager')
local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local utils = require('utils')
local eval_bases = reqscript('refinish-bases')
local eval_metal = reqscript('refinish-evaluate-metal-making')
local eval_dust = reqscript('refinish-evaluate-dust-making')

-- ---- THE LOOP DISPATCHER, LOADED NOW ----
-- Loaded at this file's load so its subscribe handle exists before any
-- module starts: modules start inside the pipeline, which runs before
-- the loops below are started. Its tick starts beside the menu icon
-- stamper. Guarded: without it, every module keeps its own loop.
local dispatch = nil
pcall(function() dispatch = reqscript('refinish-loop-dispatch') end)

-- ---- WORK ORDER UNITS, LOADED NOW ----
-- Reports every unit a work order's job finishes to whatever waits for
-- job completions, which DFHack reports once per order. Loaded at this
-- file's load, beside the dispatcher it rides, so its subscribe handle
-- exists before any module starts; started and stopped with the services
-- below. Guarded: without it, completions are DFHack's alone, as before.
-- See refinish-job-units.lua.
local job_units = nil
pcall(function() job_units = reqscript('refinish-job-units') end)

-- ---- RM'S OWN PAYLOAD, REGISTERED NOW ----
-- The dust tool and whatever else RM injects through the module engine.
-- Loading the file registers its listener, so it has to happen before
-- the first token call, which is why it is here. See
-- refinish-core-payload.lua. Guarded: without it RM has no dust tool.
pcall(function() reqscript('refinish-core-payload') end)

-- The char maps for RM's catalog forms (gravel), registered at load so
-- they exist before any tool asks for them. See refinish-sprite-art-forms.
pcall(function() reqscript('refinish-sprite-art-forms') end)

-- ---- THE BYPRODUCT SERVICE, LOADED NOW ----
-- Measures what jobs destroy and pays it back: RM's own dust, and every
-- module's declared streams. Loaded here so its handle exists before any
-- module registers (modules start inside the pipeline); started and
-- stopped beside the dispatcher. See refinish-job-byproducts.lua.
local byproducts = nil
pcall(function() byproducts = reqscript('refinish-job-byproducts') end)

-- ---- THE TOOL TINT ----
-- Any module's tool that declares "tint" in its tools JSON wears that
-- art in its own material's colour. Started and stopped beside the
-- byproduct service. See refinish-sprite-tool-tint.lua.
local tool_tint = nil
pcall(function() tool_tint = reqscript('refinish-sprite-tool-tint') end)

-- ---- THE AGGREGATE TWINS' RUNTIME ----
-- The engine pushes the twins itself (STEP 2.5); this is the hop and the
-- sprite sync, started beside the tool tint. See refinish-material-aggregate.lua.
local aggregate = nil
pcall(function() aggregate = reqscript('refinish-material-aggregate') end)

-- ---- ORGANIC CATEGORIES ----
-- Gives module materials a position in DF's organic storage categories
-- (hide globs, dyes). Loaded here so its handle exists before modules
-- claim during the pipeline. See refinish-stockpile-organic.lua.
local organic = nil
pcall(function() organic = reqscript('refinish-stockpile-organic') end)

-- ---- STOCKPILE WINDOWS ----
-- Lends the twins their sources' flags while their items are loose, so
-- DF's own dwarves stockpile them. Loaded here so its handle
-- (_G.refinish_window_api) exists before the aggregate and the modules
-- claim their twins. See refinish-stockpile-windows.lua.
local windows = nil
pcall(function() windows = reqscript('refinish-stockpile-windows') end)

-- ---- THE FORGE'S TASK MENU ----
-- Files RM's finishes out of the forge's category lists into one folder,
-- refinished metals > base metal > finishes, with Back working at every
-- level. It needs the finishes and their folders' placeholder reactions,
-- so it follows the data like the services above. See
-- refinish-menu-forge.lua.
local forge_menu = nil
pcall(function() forge_menu = reqscript('refinish-menu-forge') end)

-- ---- BACK IN EVERY REACTION FOLDER ----
-- DF gives a reaction folder no Back entry, so its Back control reads
-- Cancel and shuts the task panel. This puts one in every folder DF
-- builds, at any building, the smelter's finishing folders among them.
-- Started and stopped with the services above. See
-- refinish-menu-back.lua.
local menu_back = nil
pcall(function() menu_back = reqscript('refinish-menu-back') end)

-- ---- THE WORK ORDER CONDITIONS ----
-- A work order condition's Material list draws each row from the
-- material's name and lists a twin beside its source, so the two read the
-- same there. While a work order's conditions are open, every twin a
-- claim or hide gave a menu tag carries it on its name: "clay (binder)".
-- Started and stopped with the services below. See
-- refinish-menu-orders.lua.
local menu_orders = nil
pcall(function() menu_orders = reqscript('refinish-menu-orders') end)

-- ---- FINISHES MINTED IN PLAY ----
-- A base metal's first bars, or a material's first dust, mints the
-- finishes they make the moment it exists, instead of at the next load
-- (refinish-mint-finish.lua mints at load). See
-- refinish-mint-finish-watch.lua.
local mint_watch = nil
pcall(function() mint_watch = reqscript('refinish-mint-finish-watch') end)

-- ---- REACTION OUTPUTS ----
-- A product that takes its material from a reagent is shared out over
-- the materials that reagent actually held, and a stacked tool's new
-- items merge per material. Started and stopped with the services
-- below. See refinish-reaction-outputs.lua.
local outputs = nil
pcall(function() outputs = reqscript('refinish-reaction-outputs') end)

-- ---- MATERIAL CLASSES ----
-- Reaction classes a module asks for on existing materials (Making
-- Concrete's POZZOLAN on volcanic stone), given from the module's start
-- hook and every one taken back by stop(). Loaded now so its handle
-- exists before any module starts. See refinish-material-classes.lua.
local mat_classes = nil
pcall(function() mat_classes = reqscript('refinish-material-classes') end)

-- ---- MELTING ----
-- Metal melts through DF's own melt job. Every melt is measured: it returns
-- nine tenths of what is in what it melted, and each smelter keeps its
-- part bars exactly, per metal.
-- Started and stopped with the services below. See refinish-melt.lua.
local melt = nil
pcall(function() melt = reqscript('refinish-melt') end)

-- ---- BRICKS ----
-- Brick jobs at the kiln, vanilla's make clay bricks and RM's with dust
-- grog, are paid by the volume of their clay and temper, and since
-- 2026-10-28 so is a brick reaction a module registers with a temper of
-- its own (Making Fuel's make clay bricks with dried dung). Loaded here, at RM's
-- load, so its handle (_G.refinish_bricks_api) is there before any module
-- registers in the pipeline. Started and stopped with the services below.
-- See refinish-bricks.lua.
local bricks = nil
pcall(function() bricks = reqscript('refinish-bricks') end)

-- ---- FERTILIZER ----
-- DF's fertilize job opened to every fertilizer, potash keeping its share
-- and stacks trimmed to what a plot needs. Started and stopped with the
-- services below. See refinish-fertilize.lua.
local fertilize = nil
pcall(function() fertilize = reqscript('refinish-fertilize') end)

-- ---- THE ADAPTIVE REACTION ENGINE ----
-- Loaded here so its handle (_G.refinish_adaptive_api) exists before any
-- module registers as its provider during the pipeline. The engine
-- starts and stops with the module it serves. See
-- refinish-reaction-adaptive.lua.
pcall(function() reqscript('refinish-reaction-adaptive') end)

-- ==========================================
-- RM'S SERVICES FOLLOW THE DATA
-- ==========================================
-- The dispatcher and the services loaded above run only while
-- RM's data is in RAM. Started at the end of refinish-startup (map
-- load, the save hook's reload, a manual start) and of the hotsave's
-- restore; stopped first thing in refinish-shutdown (the save hook's
-- unload, a manual or hard shutdown), at the hotsave's clear and at map
-- unload. Published on _G.refinish_services for those scripts.
--
-- Until 2026-09-30 they started at map load and stopped at map unload
-- and nowhere else, so they ran on through every save while the data
-- was out of RAM: the tool tint walked binder items whose twin
-- materials were gone, and the aggregate read past the end of the
-- shrunken inorganics. The modules' scripts follow the same rule
-- through the module engine (MODULE LIFECYCLE).
--
-- One flag makes both safe to repeat: a second start or stop does
-- nothing. The dispatcher's stop drops every subscription, and every
-- service and module subscribes again in its own start.
-- ==========================================
local services_running = false

local function start_services()
    if services_running then return end
    services_running = true
    -- The loop dispatcher's tick. Modules subscribed in the pipeline,
    -- which ran before this; this starts serving them. Guarded like
    -- every call below: a service that fails costs itself, never the
    -- session or the others. See refinish-loop-dispatch.
    pcall(function() if dispatch then dispatch.start() end end)
    -- Work order units, right after the dispatcher it rides: its watch is
    -- an every frame subscriber, so it reports a unit before any slower
    -- poll on the same tick. Subscriptions made in the pipeline, before
    -- this, are kept. See refinish-job-units.lua.
    pcall(function() if job_units then job_units.start() end end)
    -- The byproduct service, after the dispatcher it rides.
    pcall(function() if byproducts then byproducts.start() end end)
    -- The tool tint, on the dispatcher as well.
    pcall(function() if tool_tint then tool_tint.start() end end)
    -- The gravel hop and the twin sprite sync. With no twins (no module
    -- asked for gravel) both find nothing to do.
    pcall(function() if aggregate then aggregate.start() end end)
    -- Organic categories: the claims the modules made as they started
    -- register now.
    pcall(function() if organic then organic.start() end end)
    -- Stockpile windows: after the aggregate, which claims its stone
    -- twins in its own start, so the first scan already sees them.
    pcall(function() if windows then windows.start() end end)
    -- The forge's task menu, on the dispatcher, paused included.
    pcall(function() if forge_menu then forge_menu.start() end end)
    -- Back in every reaction folder, the same way.
    pcall(function() if menu_back then menu_back.start() end end)
    -- The work order conditions, on the dispatcher, paused included.
    pcall(function() if menu_orders then menu_orders.start() end end)
    -- Finishes minted in play: the created event, and a poll on the
    -- dispatcher, unpaused.
    pcall(function() if mint_watch then mint_watch.start() end end)
    -- Reaction outputs: on the dispatcher, paused included, and the
    -- completion event.
    pcall(function() if outputs then outputs.start() end end)
    -- Material classes: nothing to start, the modules gave theirs in the
    -- pipeline; this only logs what is in place.
    pcall(function() if mat_classes then mat_classes.start() end end)
    -- Melting: on the dispatcher, paused included, and the completion
    -- event.
    pcall(function() if melt then melt.start() end end)
    -- Bricks: on the dispatcher, paused included, and the completion event.
    pcall(function() if bricks then bricks.start() end end)
    -- Fertilizer: on the dispatcher, paused included, and the job event.
    -- After the material classes, so its grant joins the cycle's record.
    pcall(function() if fertilize then fertilize.start() end end)
end

local function stop_services()
    -- Given classes come off first, and whether or not the services were
    -- started: a module gives its classes in the pipeline, before the
    -- services start, so a startup that failed between the two still
    -- has classes to take back before a save.
    pcall(function() if mat_classes then mat_classes.stop() end end)
    if not services_running then return end
    services_running = false
    -- The dispatcher first. Its timer is 'frames', which DF does not
    -- cancel on an unload, so stop() cancels it, and it drops every
    -- subscription for the services and modules to make afresh.
    pcall(function() if dispatch then dispatch.stop() end end)
    -- Work order units beside it: every subscription and noted job goes,
    -- for the services and modules to make afresh.
    pcall(function() if job_units then job_units.stop() end end)
    -- The byproduct service beside it: module registrations go, and the
    -- modules make them again as they start; core's stay.
    pcall(function() if byproducts then byproducts.stop() end end)
    pcall(function() if tool_tint then tool_tint.stop() end end)
    pcall(function() if aggregate then aggregate.stop() end end)
    pcall(function() if organic then organic.stop() end end)
    -- Before any clear: an open window's flags go back while the twins
    -- still exist.
    pcall(function() if windows then windows.stop() end end)
    pcall(function() if forge_menu then forge_menu.stop() end end)
    pcall(function() if menu_back then menu_back.stop() end end)
    -- Before any clear: names labelled for the work order conditions go
    -- back while the twins still carry them.
    pcall(function() if menu_orders then menu_orders.stop() end end)
    pcall(function() if mint_watch then mint_watch.stop() end end)
    pcall(function() if outputs then outputs.stop() end end)
    pcall(function() if melt then melt.stop() end end)
    pcall(function() if bricks then bricks.stop() end end)
    pcall(function() if fertilize then fertilize.stop() end end)
end

_G.refinish_services = { start = start_services, stop = stop_services }

-- ---- NAMED FOR DFHACK'S TIMERS ----
-- This file's three self-scheduling loops, the JIT watcher, the save
-- hook monitor and the calendar, report each run to DFHack's own timers
-- under a name of their own (NAMED FOR DFHACK'S TIMERS, in
-- refinish-loop-dispatch.lua). Without the internal function, nothing
-- is recorded.
local record_runtime = dfhack.internal and dfhack.internal.recordRepeatRuntime
local function named_run(name, t0)
    if record_runtime then pcall(record_runtime, name, t0) end
end

-- ==========================================
-- APPLICATION BOOT: UNIVERSAL LOGGING ENGINE
-- ==========================================
_G.refinish_log = _G.refinish_log or {}

_G.refinish_log_event = function(msg)
    local timestamp = os.date("%H:%M:%S")
    local formatted_msg = string.format("[%s] %s", timestamp, msg)
    
    -- RAM Array (Capped at 5000 lines)
    table.insert(_G.refinish_log, 1, formatted_msg)
    -- ---- THREE ROWS PER ENTRY NOW ----
    -- A tagged entry renders as two header lines plus its body, so
    -- 5000 stored lines is closer to 1700 readable entries than it
    -- used to be. The table costs nothing until the log is opened.
    --
    -- Trim this if the HUD hangs on open: the cost is in building the
    -- rendered list, not in holding the strings.
    if #_G.refinish_log > 15000 then table.remove(_G.refinish_log) end
    
    -- Hard Drive Live Append
    pcall(function()
        local log_file = io.open("refinish_session.log", "a")
        if log_file then
            log_file:write(formatted_msg .. "\n")
            log_file:close()
        end
    end)
end

-- ==========================================
-- LOG FUNNELS
-- ==========================================
-- Every line this file writes goes through one of these, in the one
-- grammar the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
-- The panel filters on TYPE and nothing else, so each call site
-- states its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- This file coordinates several subsystems, so it keeps one funnel
-- per subsystem rather than naming one at every call site. Each has
-- the same (typ, msg, subject) shape as every other file's log().
-- SUBJECT is the correlation slot: a map event, a job id, a step.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, and
-- nothing in this file answers a typed command: it runs on game
-- events and its own loops. Anything it needs to say lives in the
-- log alone.
-- ==========================================
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function make_log(sub)
    return function(typ, msg, subject)
        if not _G.refinish_log_event then return end
        local line
        if rlog then
            line = rlog.compose('REFINISH_METAL', sub, subject, typ, msg)
        else
            -- The composer failed to load. Same grammar, unsanitised.
            line = string.format('REFINISH_METAL %s %s %s | %s', sub,
                tostring(subject or '-'), tostring(typ or 'UNTYPED'),
                tostring(msg))
        end
        _G.refinish_log_event(line)
    end
end

local log_session = make_log('SESSION')     -- the executable and the map
local log_boot    = make_log('BOOT')        -- map load state check
local log_system  = make_log('SYSTEM')      -- first run, hotkeys, monitors
local log_watcher = make_log('WATCHER')     -- grinder reaction watcher
local log_ui      = make_log('UI_MONITOR')  -- the save hook's driver loop
local log_cal     = make_log('CALENDAR')    -- autosave timer

-- ---- VERSION, AT LOAD ----
-- Was assigned inside the SC_MAP_LOADED handler, which meant it was
-- nil for the whole span between launch and a map being loaded. The
-- launch banner below reads it, so the banner threw the moment it
-- stopped being a hardcoded string.
--
-- It is a constant. It belongs where the file loads, not where a
-- world event fires. Every consumer still guards with `or "?"`, which
-- was the existing signal that nil was reachable.
_G.refinish_version = "v4.0.0"

-- The Session Rotator: Cycle the logs ONLY ONCE per Dwarf Fortress launch
if not _G.refinish_app_boot_rotation_done then
    pcall(function()
        os.remove("refinish_last_session.log")
        os.rename("refinish_session.log", "refinish_last_session.log")
    end)
    _G.refinish_app_boot_rotation_done = true
    
    -- Immediately log the application boot. SESSION is the subsystem
    -- because these two belong to the executable rather than to the
    -- mod.
    log_session('SYSTEM', 'Dwarf Fortress executable launched.', 'LAUNCH')
    log_session('SYSTEM', string.format(
        'Core module %s loaded into system memory.',
        tostring(_G.refinish_version or '?')), 'BOOT')
end
-- ==========================================

-- ==========================================
-- WHAT THE UNLOAD LEFT IN RAM
-- ==========================================
-- MEASURED 2026-10-01: a save & quit wrote a save that would not load,
-- carrying REFINISH_CORE_AGG_PLASTER. Two seconds before it, the options
-- screen's refresh had failed with "Could not find script
-- refinish-tool-wash" and "... refinish-ledger": DFHack could no longer
-- find RM's scripts. The map unload failsafe then ran every scrubber
-- inside a pcall that dropped its error, none of them could be found,
-- nothing was cleared, and it logged "Memory successfully terminated."
-- before DF wrote the save with RM's data in it.
--
-- So the failsafe now keeps each step's failure and logs it, and then
-- counts what of RM's is still in the raws: the test the autosave makes
-- before it lets DF save (is_memory_physically_clear in
-- refinish-autosave.lua), counted rather than stopped at the first hit.
-- It is written here, not called from there, because at this moment no
-- other RM script may be reachable. The success line is written only
-- when nothing is left.
local function ram_left()
    local function owned(s)
        if type(s) ~= 'string' then return false end
        if string.sub(s, 1, 15) == 'REFINISH_STEEL_' then return true end
        for prefix in pairs(_G.refinish_module_registry or {}) do
            if string.sub(s, 1, #prefix) == prefix then return true end
        end
        return false
    end
    local n, first = { mat = 0, rxn = 0, cat = 0, tool = 0, plant = 0, bld = 0 }, nil
    local function count(kind, vec, field)
        pcall(function()
            for _, v in ipairs(vec) do
                local ok, s = pcall(function() return v[field] end)
                if ok and owned(s) then
                    n[kind] = n[kind] + 1
                    first = first or s
                end
            end
        end)
    end
    local raws = df.global.world.raws
    count('mat', raws.inorganics.all, 'id')
    count('rxn', raws.reactions.reactions, 'code')
    count('cat', raws.reactions.reaction_categories, 'id')
    count('tool', raws.itemdefs.tools, 'id')
    -- The plants and building defs the module sweep removes, which the
    -- autosave's test does not look at. MEASURED 2026-10-01, second test:
    -- the sweep's plant and building clears failed beside its tool clear,
    -- and this count, without these two, reported only the tools.
    count('plant', raws.plants.all, 'id')
    count('bld', raws.buildings.all, 'code')
    return n, first
end

-- ==========================================
-- KNOWN PATHS, CHECKED WITHOUT A SEARCH
-- ==========================================
-- MEASURED 2026-10-01, refinish-section-probe, 115 s on a busy fort with
-- a save & continue: a lookup by name searches DFHack's script folders
-- in order, 24 here with RM's the 18th. The script check's 12 lookups
-- cost 86 ms a run (110 max) and refreshing the kept copies another 49
-- ms (70 max): about 135 ms every 5 seconds, all session long, the
-- costliest line in the report at 15 ms/sec. Checking at a save request
-- cost 180 ms, part of the hang around a save.
--
-- So each file is found by name once, and after that only its known
-- path is asked about, with one mtime call that says both whether the
-- file is there (-1 when it is not) and whether it changed. A file not
-- found by its first search is not searched for again: its known path
-- stays false until the next map load forgets the paths, since DFHack
-- builds its script folders afresh for each world. A file put back
-- where it was is seen again by its known path.
-- ==========================================
local known_path = {}

local function forget_paths()
    for name in pairs(known_path) do known_path[name] = nil end
end

local function mtime_at(path)
    local ok, t = pcall(dfhack.filesystem.mtime, path)
    if ok and type(t) == 'number' then return t end
    return -1
end

-- A file's modification time, or nil when it is not there. memo, when
-- given, answers a name asked about twice in one check.
local function stamp_of(name, memo)
    if memo and memo[name] ~= nil then return memo[name] or nil end
    local path = known_path[name]
    if path == nil then
        local ok, found = pcall(dfhack.findScript, name)
        path = ok and found or false
        known_path[name] = path
    end
    local mt = path and mtime_at(path) or -1
    local out = mt ~= -1 and mt or nil
    if memo then memo[name] = out or false end
    return out
end

-- ==========================================
-- THE UNLOAD, KEPT IN MEMORY
-- ==========================================
-- The map unload must clear RAM even when RM's files are gone: they had
-- been deleted while the game ran on 2026-10-01 (WHAT THE UNLOAD LEFT
-- IN RAM). So the code it runs is kept here while they are there: the
-- text of the three clear scripts, and the environments of the module
-- engine and of the three injectors its sweep looks up by name. The
-- failsafe still runs each step from its file first, as before; only a
-- step that cannot be reached runs from its kept copy. The copies are
-- taken at each map load and refreshed whenever the script check finds
-- a file changed (KNOWN PATHS, CHECKED WITHOUT A SEARCH), so a copy is
-- the code the file itself would run.
--
-- MEASURED 2026-10-01, second test, a save & quit with the files
-- deleted: the three clear scripts ran from their copies (61392
-- materials, 99579 reactions, 892 categories, 220003 permissions
-- cleared) and the module engine ran from its kept environment, but
-- every tool, building and plant clear inside it failed: the sweep looks
-- its injectors up by name, and those files were gone too. 29 tool defs
-- stayed in RAM and the save would not load. So while the sweep runs, a
-- lookup by name whose file cannot be found is answered from the kept
-- environments (WITH THE KEPT ENVIRONMENTS, below). That covers every
-- lookup the sweep makes, in any file, with nothing changed in them.
local KEPT_SCRIPTS = { 'refinish-clear-entity', 'refinish-clear-reaction', 'refinish-clear' }
local KEPT_ENVS = {
    'refinish-module-engine', 'refinish-module-inject-tool',
    'refinish-module-inject-building', 'refinish-module-inject-plant',
}
local kept_text, kept_mtime, kept_envs, kept_env_mtime = {}, {}, {}, {}

-- memo, when given, carries the file times the script check has just
-- read, so no file is asked about twice in one check.
local function keep_unload(memo)
    for _, name in ipairs(KEPT_SCRIPTS) do
        pcall(function()
            local mt = stamp_of(name, memo)
            if not mt then return end
            if kept_text[name] and kept_mtime[name] == mt then return end
            local fh = io.open(known_path[name], 'rb')
            if not fh then return end
            local text = fh:read('*a')
            fh:close()
            -- Kept only if it compiles: a copy that cannot run is no copy.
            if text and #text > 0 and load(text, '=' .. name) then
                kept_text[name], kept_mtime[name] = text, mt
            end
        end)
    end
    -- An environment is asked for again only when its file has changed,
    -- which is when DFHack would build it afresh.
    for _, name in ipairs(KEPT_ENVS) do
        pcall(function()
            local mt = stamp_of(name, memo)
            if not mt then return end
            if kept_envs[name] and kept_env_mtime[name] == mt then return end
            local env = dfhack.script_environment(name)
            if env then kept_envs[name], kept_env_mtime[name] = env, mt end
        end)
    end
end

-- A kept clear script, run as DFHack runs a script: a fresh environment
-- over _G, no arguments.
local function run_kept(name)
    local text = kept_text[name]
    if not text then error('no copy of ' .. name .. ' was kept') end
    local chunk, err = load(text, '=' .. name, 't', setmetatable({}, { __index = _G }))
    if not chunk then error(err) end
    chunk()
end

-- ---- WITH THE KEPT ENVIRONMENTS ----
-- Runs fn with dfhack.script_environment answering from kept_envs any
-- name whose file cannot be found. A name that can be found is answered
-- from its file exactly as before, so with the files in place nothing
-- changes. The original is put back whatever fn does. Returns the names
-- answered from a kept environment, each with the error its file gave.
local function with_kept_envs(fn)
    local orig = dfhack.script_environment
    local served, seen = {}, {}
    dfhack.script_environment = function(name, ...)
        local ok, env = pcall(orig, name, ...)
        if ok and env then return env end
        local kept = kept_envs[name]
        if not kept then error(env, 0) end
        if not seen[name] then
            seen[name] = true
            served[#served + 1] = { name = name, err = tostring(env) }
        end
        return kept
    end
    local ok, err = pcall(fn)
    dfhack.script_environment = orig
    if not ok then error(err, 0) end
    return served
end

-- ==========================================
-- THE PLAYER IS TOLD, IN THE COLOUR OF THE RISK
-- ==========================================
-- Each guard here tells the player through RM's prompt system, in the
-- theme colour the configuration panel gives its severity: RISK_H
-- (Danger) for a save that would not load, RISK_M (Warning) for a
-- safety notice, RISK_L (Caution) for an all clear. The prompt class
-- and the theme are held from this file's load, so a prompt can still
-- be drawn when RM's files cannot be found. If the prompt cannot be
-- drawn at all, DFHack's own message box carries the same text.
local theme_mod = nil
pcall(function() theme_mod = reqscript('refinish-theme') end)
local RISK_FALLBACK = { RISK_H = COLOR_RED, RISK_M = COLOR_LIGHTRED, RISK_L = COLOR_YELLOW }

local function rm_alert(text, role, frame_h)
    local pen = RISK_FALLBACK[role] or COLOR_LIGHTRED
    pcall(function()
        local theme = theme_mod and theme_mod.get_current_theme()
        if theme and theme[role] then pen = theme[role] end
    end)
    local ok = pcall(function()
        RefinishPrompt{ frame_h = frame_h or 16, text = text, text_pen = pen }:show()
    end)
    if not ok then
        pcall(function()
            require('gui.dialogs').showMessage('REFINISH METAL', text, pen)
        end)
    end
end
-- For the save hook and any other file that must warn the player.
_G.refinish_alert = rm_alert

-- After a map unload the prompt waits for a screen that is settled: the
-- title screen with the world gone, or a fort with a map loaded again.
-- MEASURED 2026-10-01: waiting only for the world to be gone was not
-- enough. Prompts were drawn over DF's save screen during a save & quit,
-- stacked and garbled. After SETTLE_MAX_FRAMES it is shown regardless.
local SETTLE_MAX_FRAMES = 12000

local function settled_screen()
    local focus = ''
    pcall(function()
        local f = dfhack.gui.getCurFocus()
        if type(f) == 'table' then f = f[1] end
        focus = tostring(f or '')
    end)
    if not dfhack.isWorldLoaded() then return focus:find('^title') ~= nil end
    return dfhack.isMapLoaded() and focus:find('^dwarfmode') ~= nil
end

local function alert_after_unload(text, role)
    local waited = 0
    local function try_show()
        if waited < SETTLE_MAX_FRAMES and not settled_screen() then
            waited = waited + 30
            dfhack.timeout(30, 'frames', try_show)
            return
        end
        rm_alert(text, role, 18)
    end
    dfhack.timeout(30, 'frames', try_show)
end

-- ==========================================
-- RM'S OWN FILES, STILL THERE
-- ==========================================
-- The scripts every save path calls by name. While any is missing, a
-- save may go out with RM's data in it: the alarm says so at once, in
-- Danger colours, and says again in Caution colours once they are back.
-- Checked every SCRIPT_CHECK_MS from the UI monitor, by known path
-- (KNOWN PATHS, CHECKED WITHOUT A SEARCH), except while a save is under
-- way (NOT DURING A SAVE); a passing check also refreshes THE UNLOAD,
-- KEPT IN MEMORY.
local SCRIPTS_NEEDED = {
    'refinish-clear-entity', 'refinish-clear-reaction', 'refinish-clear',
    'refinish-module-engine', 'refinish-shutdown', 'refinish-startup',
    'refinish-autosave', 'refinish-tool-wash', 'refinish-ledger',
    'refinish-module-inject-tool', 'refinish-module-inject-building',
    'refinish-module-inject-plant',
}
local SCRIPT_CHECK_MS = 5000
local next_script_check = 0

local function scripts_missing(memo)
    local out = {}
    for _, name in ipairs(SCRIPTS_NEEDED) do
        if not stamp_of(name, memo) then out[#out + 1] = name end
    end
    return out
end

local function check_scripts(now_please)
    local now = dfhack.getTickCount()
    if not now_please and now < next_script_check then return end
    -- ---- NOT DURING A SAVE ----
    -- The check that decides a save is made when the save is asked for
    -- (A SAVE RM CANNOT UNLOAD FOR IS HELD BACK, refinish-save-hook.lua,
    -- which calls this with now_please). Once the options screen is up or
    -- a save is under way, a timed check can change nothing, so it waits:
    -- refinish_menu_locked is set by the save hook while the screen is up
    -- and from a save's unload to its reload, refinish_autosave_in_progress
    -- through RM's own hotsave. The deadline is left as it was, so the
    -- check runs on the first frame after.
    if not now_please and (_G.refinish_menu_locked or _G.refinish_autosave_in_progress) then
        return
    end
    next_script_check = now + SCRIPT_CHECK_MS
    -- SECTION CLOCK (refinish-section-probe): the lookups and the kept
    -- copies, timed apart. Known paths only, after each file's first
    -- search (KNOWN PATHS, CHECKED WITHOUT A SEARCH).
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    local memo = {}
    local missing = scripts_missing(memo)
    if sc then t0 = sc.lap('scripts: files looked up', t0) end
    if #missing == 0 then
        keep_unload(memo)
        if sc then sc.lap('scripts: kept copies refreshed', t0) end
        if _G.refinish_scripts_missing then
            _G.refinish_scripts_missing = nil
            log_system('INFO', 'script files found again.', 'SCRIPTS')
            rm_alert("Refinish Metal's script files can be found again. If any of them changed while"
                .. " the game was running, restart Dwarf Fortress before saving.", 'RISK_L', 12)
        end
        return
    end
    if _G.refinish_scripts_missing then return end
    _G.refinish_scripts_missing = missing
    log_system('ERROR', ('%d script file(s) can no longer be found (%s). A save now may carry'
        .. ' RM data and not load.'):format(#missing, table.concat(missing, ', ')), 'SCRIPTS')
    rm_alert(("Refinish Metal's script files can no longer be found (%d missing, such as %s)."
        .. " They were moved or deleted while the game was running. Do not save: RM may not be able"
        .. " to take its data out of memory first, and a save written with it still in will not"
        .. " load. Put the files back and restart Dwarf Fortress, or quit without saving."):format(
        #missing, missing[1]), 'RISK_H', 18)
end
-- For the save hook: a refresh that could not find a script asks at once.
_G.refinish_check_scripts = function() check_scripts(true) end

dfhack.onStateChange['refinish_steel_system'] = function(sc)
    
    if sc == SC_MAP_LOADED then
        if not dfhack.isMapLoaded() then return end

        if df.global.gamemode ~= df.game_mode.DWARF then return end

        local mod_is_active = false
        for _, mod in ipairs(scriptmanager.get_active_mods()) do
            if mod.id == 'refinish_steel' then mod_is_active = true break end
        end

        if not mod_is_active then return end
        if _G.refinish_active then return end
        
        local current_save = dfhack.getSavePath() or "Unknown_Save_Dir"
        
        log_session('SYSTEM', 'Map loaded from ' .. current_save
            .. '. Initializing session.', 'MAP_LOADED')

        _G.refinish_active = true
        _G.refinish_menu_locked = false
        _G.refinish_original_autosave = _G.refinish_original_autosave or df.global.d_init.feature.autosave

        -- ==========================================
        -- PERSISTENT TELEMETRY TABLE
        -- ==========================================
        -- Created once at session start and kept alive for the entire
        -- map session. Unlike the old approach (created per-autosave,
        -- nil'd at the end), this table persists so the status panel,
        -- log, debug prompts, and dump can all read historical timing
        -- data at any time.
        --
        -- Structure:
        --   boot.*       - Map-load boot timings (set here, never overwritten)
        --   startup.*    - Pipeline rebuild timings (set by refinish-startup)
        --   last_save.*  - Most recent autosave cycle timings (set by refinish-autosave)
        --   counts.*     - Asset counts from the most recent pipeline run
        -- ==========================================
        _G.refinish_telemetry = {
            -- Boot timings: populated immediately below
            boot = {
                t_modules   = 0,  -- Module pipeline
                t_eval      = 0,  -- Reaction evaluators (metal + dust templates)
                t_boot_scan = 0,  -- Unified boot scanner (all passes)
                t_state     = 0,  -- State detection (existing RM assets in RAM)
                t_total     = 0,  -- Total boot wall time
            },
            -- Startup timings: populated by refinish-startup.lua
            startup = {
                t_sweep     = 0,  -- Ghost job sweep
                t_modules   = 0,  -- Module pipeline (rebuild)
                t_scan      = 0,  -- Blueprint scan
                t_idx_mat   = 0,  -- Material injection
                t_idx_rxn   = 0,  -- Reaction injection
                t_mod_perms = 0,  -- Module permission evaluation (Step 5.5)
                t_idx_ent   = 0,  -- Entity permission injection
                t_load      = 0,  -- Legacy payload migration (a save the retired wash wrote)
                t_total     = 0,  -- Total startup wall time
            },
            -- Last save cycle timings: populated by refinish-autosave.lua
            last_save = {
                timestamp   = "N/A",  -- Human-readable time of last save
                t_clr_ent   = 0,      -- Entity permission clear
                t_clr_rxn   = 0,      -- Reaction clear
                t_clr_mat   = 0,      -- Material clear
                t_engine    = 0,      -- DF quicksave execution
                t_restore   = 0,      -- Full pipeline restore (sweep+scan+index)
                t_active    = 0,      -- Total active processing (excludes wait time)
                -- protocol, t_save and the payload's item, building and
                -- construction counts went with the save wash (2026-09-29).
            },
            -- Asset counts: populated by boot + startup, refreshed each cycle
            counts = {
                -- Boot cache (set during boot, static for session)
                valid_metals    = 0,
                known_metals    = 0,
                reaction_traits = 0,
                civ_techs       = 0,
                -- Baseline game state (set during boot, before injection)
                base_inorganics = 0,  -- Total inorganics in the world BEFORE RM injection
                base_reactions  = 0,  -- Total reactions in the world BEFORE RM injection
                -- Blueprint (set by startup after scan)
                bp_materials    = 0,
                bp_reactions    = 0,
                bp_categories   = 0,
                active_bases    = 0,
                -- Injected (set by startup after index scripts run)
                inj_materials   = 0,  -- RM inorganics added to RAM
                inj_reactions   = 0,  -- RM reactions added to RAM
                inj_categories  = 0,  -- RM categories added to RAM
                inj_permissions = 0,  -- RM civ permission entries added
                civs_unlocked   = 0,  -- Number of civs that received permissions
            },
        }

        -- ==========================================
        -- MASTER CACHE BUILDER (Runs ONCE per save)
        -- ==========================================
        -- Every step is timed and logged. The os.clock() timer
        -- measures CPU time, not wall time; it won't include
        -- time spent waiting for user input or DF rendering.
        -- ==========================================
        local boot_clock = os.clock()
        local t = boot_clock

        -- Steps 1, 2 and 3 (module pipeline, reaction evaluators,
        -- unified boot scan) now run in refinish-startup, as Step 2
        -- and Step 2.5.
        --
        -- WHY THEY LEFT: the module pipeline WRITES to the inorganics
        -- array. Running it here put the module band into RAM at
        -- SC_MAP_LOADED, before the pause protocol and before
        -- refinish-index sets _G.refinish_ram_loaded. Every check in
        -- RM that answers "is it safe to write to disk" reads that
        -- flag or tests only the REFINISH_STEEL_ prefix, so all of
        -- them reported clean while module materials were live. The
        -- autosave baseline check then wrote saves with injected data
        -- still in the array.
        --
        -- The evaluators and the boot scan followed it because both
        -- read the array it writes, so all three moved together. In
        -- startup they are guarded to build once per loaded world,
        -- while the module pipeline keeps its own per-cycle guard.
        --
        -- Counts formerly snapshotted here (valid_metals,
        -- known_metals, reaction_traits, civ_techs) moved with them,
        -- since they describe caches that no longer exist at boot.
        --
        -- boot_clock and t above are deliberately kept: t_state and
        -- t_total below still measure against them. t is reset here so
        -- t_state covers only the state check, as before.
        t = os.clock()

        -- Snapshot baseline game state BEFORE any RM injection happens.
        -- These numbers are the vanilla totals (plus any other mods).
        -- After startup injects RM assets, the live arrays will be larger.
        _G.refinish_telemetry.counts.base_inorganics = #df.global.world.raws.inorganics.all
        _G.refinish_telemetry.counts.base_reactions = #df.global.world.raws.reactions.reactions

        _G.refinish_last_ui_ping = "Initializing..."
        _G.refinish_last_cal_ping = "Initializing..."
        _G.refinish_last_watch_ping = "Initializing..."
        _G.refinish_last_real_save = os.time()

        -- FIRST TIME INSTALL CHECK
        local first_run = dfhack.persistent.getSiteData('refinish_installed')
        if not first_run or first_run == "" then
            dfhack.persistent.saveSiteData('refinish_installed', 'TRUE')
            log_system('SYSTEM', 'First time install detected. Guided prompt'
                .. ' triggered.', 'FIRST_RUN')
            local THEME = reqscript('refinish-theme').get_current_theme()
            -- The config panel opens from this prompt's OK button.
            --
            -- It was deferred to execute_startup for a while, because
            -- the panel reaches refinish-panel-metals, which calls
            -- get_valid_bases and would run the unified scan before
            -- the module pipeline had injected anything, caching a
            -- base metal list with no module content for the whole
            -- session.
            --
            -- That hazard is gone. on_ok does not fire until the
            -- player presses OK, which is many frames after this
            -- handler returns, and the pipeline now completes inside
            -- this same handler. The scan cannot run early.
            --
            -- It also fixes the stacking. The panel used to be pushed
            -- onto the viewscreen while this prompt was still on it,
            -- so the player met the panel first and found the prompt
            -- buried underneath.
            RefinishPrompt{
                frame_h = 14,
                text = "Refinish Metal is online. Press OK to review your configuration settings.",
                text_pen = THEME.PRI,
                on_ok = function()
                    log_system('INFO', 'First run; opening the configuration'
                        .. ' panel.', 'FIRST_RUN')
                    dfhack.run_script('refinish-hud', 'show', 'config')
                end,
                }:show()
        elseif #scripts_missing() == 0 then
            -- RM'S OWN FILES, STILL THERE: with any of them missing RM
            -- cannot start, so it does not say it is online; the alarm
            -- says why instead.
            local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
            if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end
            
            if msg_setting == 'DEBUG' then
                -- DEBUG prompt: show actual boot telemetry
                local bt = _G.refinish_telemetry.boot
                local ct = _G.refinish_telemetry.counts
                local debug_txt = string.format(
                    "Refinish Metal is online.\n\n" ..
                    "--- BOOT TELEMETRY ---\n" ..
                    "Modules: %.3fs  |  Evaluators: %.3fs\n" ..
                    "Boot Scan: %.3fs  |  State Check: %.3fs\n" ..
                    "Total Boot: %.3fs\n\n" ..
                    "--- BOOT CACHE ---\n" ..
                    "Valid Metals: %d  |  Known Metals: %d\n" ..
                    "Reaction Traits: %d  |  Civ Techs: %d",
                    bt.t_modules, bt.t_eval, bt.t_boot_scan, bt.t_state, bt.t_total,
                    ct.valid_metals, ct.known_metals, ct.reaction_traits, ct.civ_techs
                )
                RefinishPrompt{
                    frame_h = 20,
                    frame_w = 60,
                    text = debug_txt,
                    on_ok = function() end
                }:show()
            elseif msg_setting == 'GUIDED' then
                RefinishPrompt{
                    frame_h = 10,
                    text = "Refinish Metal is online.",
                    on_ok = function() end
                }:show()
            end
        end

        -- ==========================================
        -- UNIVERSAL STATE MANAGER
        -- ==========================================
        -- Detect whether RM assets already exist in RAM from a
        -- previous session (e.g. hotsave left items with mat_index
        -- pointing at RM inorganics). This runs ONCE at boot.
        -- ==========================================
        _G.refinish_ram_loaded = false
        _G.refinish_reactions_loaded = false
        _G.refinish_entity_loaded = false
        _G.refinish_data_loaded = false

        local inorganics = df.global.world.raws.inorganics.all
        for _, mat in ipairs(inorganics) do
            if string.find(mat.id, "REFINISH_STEEL_MAT_") then
                _G.refinish_ram_loaded = true
                break
            end
        end

        local custom_rxn_indexes = {}
        local reactions = df.global.world.raws.reactions.reactions
        for _, rxn in ipairs(reactions) do
            if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
                _G.refinish_reactions_loaded = true
                custom_rxn_indexes[rxn.index] = true
            end
        end

        if _G.refinish_reactions_loaded then
            local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
            if player_civ and player_civ.entity_raw then
                for _, pid in ipairs(player_civ.entity_raw.workshops.permitted_reaction_id) do
                    if custom_rxn_indexes[pid] then
                        _G.refinish_entity_loaded = true
                        break
                    end
                end
            end
        end

        if _G.refinish_ram_loaded then
            for _, item in ipairs(df.global.world.items.all) do
                local ok, m_idx = pcall(function() return item.mat_index end)
                if ok and type(m_idx) == 'number' and m_idx >= 0 and m_idx < #inorganics then
                    if string.find(inorganics[m_idx].id, "REFINISH_STEEL_MAT_") then
                        _G.refinish_data_loaded = true
                        break
                    end
                end
            end
        end

        -- Finalize state check timing
        _G.refinish_telemetry.boot.t_state = os.clock() - t
        _G.refinish_telemetry.boot.t_total = os.clock() - boot_clock

        -- Both boot lines are DETAIL. What a player reads at map load
        -- is the startup summary and the ONLINE line after it.
        log_boot('DETAIL', string.format(
            'State check complete (%.3fs); MATS:%s | RXNS:%s | UI:%s | ITEMS:%s',
            _G.refinish_telemetry.boot.t_state,
            tostring(_G.refinish_ram_loaded), tostring(_G.refinish_reactions_loaded),
            tostring(_G.refinish_entity_loaded), tostring(_G.refinish_data_loaded)
        ), 'STATE_CHECK')
        log_boot('DETAIL', string.format('Boot complete (%.3fs).',
            _G.refinish_telemetry.boot.t_total), 'TOTAL')

        -- ==========================================
        -- DELAYED STARTUP LOGIC
        -- ==========================================
        -- Default is NONE. The pipeline runs synchronously, right
        -- here, before DF's first tick. The delay branches below are
        -- kept for diagnosis but every one of them is unsafe on a save
        -- that contains module material items.
        --
        -- WHY (measured 2026-08-26)
        --
        -- Items store mat_index, never material names. Module items go
        -- to disk holding an index that only exists while RM is
        -- injected, and core RM items do the same under HOTSAVE. On
        -- load, before injection, those indices sit past the end of
        -- raws.inorganics.all, and what DF does with them depends
        -- entirely on the item class:
        --
        --   solids (BAR, BLOCKS, BOULDER, TOOL)
        --       resolve to a generic rock. Inert. These have ridden
        --       through this window on every reload since the module
        --       engine existed, which is why the delay looked safe.
        --
        --   LIQUID_MISC
        --       resolves to MAGMA. An inorganic liquid with no
        --       material IS magma by DF's definition. It is sitting in
        --       a wooden bucket, being carried by a dwarf.
        --
        -- On a test save with 24 out of range items, 21 solids read as
        -- "rock bars", "rock blocks", "rock jug", "rock", and the 3
        -- liquids read as "magma". The fort burned down on unpause.
        --
        -- Running the pipeline while still paused repaired all 24, so
        -- DF settles item material at first service rather than at
        -- load. This handler runs before any tick, which makes it the
        -- last safe moment.
        --
        -- The old reason for delaying was a save safety check that
        -- read _G.refinish_ram_loaded, a flag that knew about core RM
        -- but not modules. That check is now ram_is_at_baseline() in
        -- refinish-autosave.lua, which walks the arrays directly
        -- through rm_owned(). The reason retired; the delay outlived
        -- it.
        --
        -- If this default is ever changed back, change it in
        -- refinish-panel-config.lua as well, in BOTH the widget
        -- default and the restore-defaults list.
        -- ==========================================
        -- The config option was removed from the panel, so the site
        -- data read is commented out rather than deleted. It must not
        -- run while there is no UI to set it: a save that stored TICK
        -- before removal would keep it permanently and silently.
        --
        -- To re-enable, uncomment these two lines and the blocks marked
        -- LOAD DELAY OPTION: four in refinish-panel-config.lua, the dump
        -- line in refinish-dump.lua, and the help section in
        -- refinish-panel-help.lua (removed, so its text is to write
        -- again). The dispatch chain below is untouched and all four
        -- branches still work.
        -- local delay_setting = dfhack.persistent.getSiteData('refinish_config_delay')
        -- if not delay_setting or delay_setting == "" then delay_setting = 'NONE' end
        local delay_setting = 'NONE'

        local function execute_startup()
            if _G.refinish_active then
                log_system('DETAIL', 'Executing refinish-startup (delay: '
                    .. tostring(delay_setting) .. ').', 'STARTUP')
                dfhack.run_script('refinish-startup', 'SILENT')

                -- The first run config panel used to open here, gated
                -- by _G.refinish_first_run_pending. It now opens from
                -- the on_ok of the first time install prompt above, so
                -- the player sees the prompt first and the panel
                -- second. The flag is no longer set or read anywhere.
            end
        end

        if delay_setting == 'TICK' then
            dfhack.timeout(1, 'ticks', execute_startup)
        elseif delay_setting == 'FRAMES_20' then
            dfhack.timeout(20, 'frames', execute_startup)
        elseif delay_setting == 'FRAMES_100' then
            dfhack.timeout(100, 'frames', execute_startup)
        elseif delay_setting == 'NONE' then
            execute_startup()
        end
        
        -- HOTKEYS (DYNAMIC FETCH & CACHE)
        local function get_hk(id, default)
            local hk = dfhack.persistent.getSiteData(id)
            return (hk and hk ~= "") and hk or default
        end
        
        -- THE FIX: Removed '@dwarfmode' to enforce global UI routing
        _G.refinish_hk_cache = {
            autosave = get_hk('refinish_hk_autosave', 'Ctrl-Shift-S'),
            wipe = get_hk('refinish_hk_wipe', 'Ctrl-Shift-X'),
            startup = get_hk('refinish_hk_startup', 'Ctrl-Alt-X'),
            hardwipe = get_hk('refinish_hk_hardwipe', 'Ctrl-Shift-Q'),
            
            config   = get_hk('refinish_hk_config',  'Ctrl-Shift-C'),
            metals   = get_hk('refinish_hk_metals',  'Ctrl-Shift-M'),
            civs     = get_hk('refinish_hk_civs',    'Ctrl-Shift-V'),
            status   = get_hk('refinish_hk_status',  'Ctrl-Shift-I'),
            log      = get_hk('refinish_hk_log',     'Ctrl-Shift-L'),
            inspect  = get_hk('refinish_hk_inspect', 'Ctrl-Shift-E'),
            help     = get_hk('refinish_hk_help',    'Ctrl-Shift-H')
        }
        
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.autosave, 'refinish-autosave')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.wipe, 'refinish-shutdown')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.startup, 'refinish-startup')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.hardwipe, 'refinish-hard-shutdown')
        
        -- THE BYPASS: We pass 'show' FIRST so DFHack doesn't intercept the reserved engine strings
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.config,  'refinish-hud show config')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.metals,  'refinish-hud show metals')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.civs,    'refinish-hud show civs')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.status,  'refinish-hud show status')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.log,     'refinish-hud show log')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.inspect, 'refinish-hud show inspect')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.help,    'refinish-hud show help')

        df.global.d_init.feature.autosave = -1
        log_system('DETAIL', 'Hotkeys bound and vanilla autosave suspended.',
            'HOTKEYS')

        -- ==========================================
        -- POLLING RATE HELPER
        -- ==========================================
        -- Reads the config once per loop iteration to pick up live
        -- changes from the config panel without needing a restart.
        -- Returns the frame count for dfhack.timeout().
        -- ==========================================
        local POLL_RATES = { FAST = 10, NORMAL = 25, RELAXED = 50 }

        local function get_poll_frames()
            local setting = dfhack.persistent.getSiteData('refinish_config_poll_rate')
            return POLL_RATES[setting] or POLL_RATES.FAST
        end

        -- ==========================================
        -- 1.5. THE JIT REACTION WATCHER (Bait-and-Switch)
        -- ==========================================
        local JIT_CONFIG = {
            ["REFINISH_STEEL_RXN_LUA_GRIND_GEMS"] =   { qty = 3,   prod = 1, worthless = false, itype = df.item_type.ROUGH },
            ["REFINISH_STEEL_RXN_LUA_GRIND_COMMON"] = { qty = 1,   prod = 4, worthless = true,  itype = df.item_type.BOULDER },
            ["REFINISH_STEEL_RXN_LUA_GRIND_ANY"] =    { qty = 1,   prod = 4, worthless = false, itype = df.item_type.BOULDER },
            ["REFINISH_STEEL_RXN_LUA_GRIND_METAL"] =  { qty = 150, prod = 1, worthless = false, itype = df.item_type.BAR },
            -- The finished-metal grinders, one per base metal
            -- (refinish-mint-finish.lua, THE FINISHED-METAL GRINDERS),
            -- share this entry: the [%a]+ below stops at the underscore
            -- after FIN.
            ["REFINISH_STEEL_RXN_LUA_GRIND_FIN"] =    { qty = 150, prod = 1, worthless = false, itype = df.item_type.BAR }
        }
        local FIN_GRIND = "REFINISH_STEEL_RXN_LUA_GRIND_FIN"

        -- ---- THE CLONE IS A COPY OF RM'S OWN GRINDER ----
        -- It used to clone MAKE_PLASTER_POWDER, found by name, and
        -- rebuild a powder product into a bag. The grinders make RM's dust
        -- tool now, and the base grinder the job came from already
        -- carries every part the clone needs, so the clone copies it,
        -- pins the input to the material the dwarf grabbed, and takes
        -- that material's name. No vanilla reaction is named anywhere.
        --
        -- The vectors hold pointers, and assign copies the pointers, so
        -- reagents and products are copied one by one before the input
        -- is pinned; pinning a shared reagent would pin the base grinder.
        -- ---- ONE LOOKUP, NOT ONE WALK ----
        -- MEASURED 2026-09-30: a walk of the reactions array for one code
        -- cost 38 ms with 103,543 reactions (walk probe), and a new grind
        -- ghost made two: ghost_known's miss, which walks the whole array,
        -- then the base here. This loop peaked at 140 ms (profiler). RM's
        -- reaction index (refinish-resolve.lua, REACTIONS) answers by code
        -- with the position, checked on every use; the injector loads it
        -- every cycle. The walk stays as the fallback.
        local function rx_lookup(code)
            local f = _G.refinish_find_reaction
            if f then
                local ok, r, at = pcall(f, code)
                if ok then return r, at end
            end
            for i, r in ipairs(df.global.world.raws.reactions.reactions) do
                if r.code == code then return r, i end
            end
            return nil
        end

        local function build_ghost_grinder_jit(ghost_code, base_code, mat_index, mat_name, config)
            local reactions_array = df.global.world.raws.reactions.reactions
            local base = rx_lookup(base_code)   -- ONE LOOKUP, NOT ONE WALK
            if not base then return false end

            local rxn = df.reaction:new()
            rxn:assign(base)

            rxn.code = ghost_code
            rxn.name = "grind " .. string.lower(mat_name) .. " into dust"
            rxn.skill = df.job_skill.NONE
            rxn.category = ""
            pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)

            rxn.building.type:resize(0)
            rxn.building.subtype:resize(0)
            rxn.building.custom:resize(0)

            rxn.reagents:resize(0)
            for _, orig in ipairs(base.reagents) do
                local r = orig._type:new()
                r:assign(orig)
                rxn.reagents:insert('#', r)
            end
            rxn.products:resize(0)
            for _, orig in ipairs(base.products) do
                local p = orig._type:new()
                p:assign(orig)
                rxn.products:insert('#', p)
            end
            rxn.reagents[0].mat_type = 0
            rxn.reagents[0].mat_index = mat_index

            rxn.index = #reactions_array
            reactions_array:insert('#', rxn)
            reactions_array[#reactions_array - 1].reagents[0].flags2.non_economic = config.worthless

            return true
        end

        -- ==========================================
        -- PROTECTED BASES, CACHED
        -- ==========================================
        -- The base metal selection is saved as a JSON string handed to
        -- saveSiteData, which json-encodes it a second time, so
        -- getSiteData reads it back through DFHack's JSON.lua string
        -- reader, whose cost grows with the square of the string's
        -- length. This loop read it every poll. MEASURED 2026-09-29 with
        -- DFHack's own library: 0.95 ms a read at 81 bases, 9.5 ms a
        -- second at 10 polls. In play the profiler had this loop at 2.46
        -- ms a call with every base on, 0.69 with about 24.
        --
        -- The raw stored text is fetched without decoding (the String
        -- variant, one C++ read), and the set is rebuilt only when that
        -- text changes, which is when the metals panel saves a new
        -- selection. false, not nil, marks "never built": nil is what a
        -- save with no selection returns.
        local bases_raw_seen, bases_set = false, {}
        local function protected_base_set()
            local raw = dfhack.persistent.getSiteDataString('refinish_config_bases')
            if raw == bases_raw_seen then return bases_set end
            bases_raw_seen = raw
            local set = {}
            local bases_str = dfhack.persistent.getSiteData('refinish_config_bases')
            if bases_str and bases_str ~= "" then
                local json = require('json')
                pcall(function() set = json.decode(bases_str) end)
            else
                -- Nothing saved: every base with a refinishing path
                -- (refinish-bases.lua, THE DEFAULT SELECTION). With no
                -- valid metal list yet nothing is kept, so the next poll
                -- asks again.
                local d = dfhack.script_environment('refinish-bases').default_bases()
                if not d then
                    bases_raw_seen = false
                    return {}
                end
                set = d
            end
            bases_set = set
            return set
        end

        -- ==========================================
        -- GHOST LOOKUP, REMEMBERED
        -- ==========================================
        -- Whether a ghost grinder exists used to be checked by walking
        -- the whole reactions array for every generic grind job needing a
        -- swap: 100,138 reactions with every base on in the big test
        -- world (2026-09-29). Where a ghost was found or built is now
        -- remembered, and a remembered slot is VERIFIED on every use (the
        -- reaction at that index still carries that code), so a data
        -- cycle that rebuilt the array can never leave a stale answer: a
        -- failed check is a miss, and a miss walks the array. Backwards,
        -- because build_ghost_grinder_jit appends every ghost at the end.
        local ghost_at = {}
        local function ghost_known(code)
            local reactions = df.global.world.raws.reactions.reactions
            local idx = ghost_at[code]
            if idx and idx < #reactions and reactions[idx].code == code then
                return true
            end
            ghost_at[code] = nil
            local r, at = rx_lookup(code)   -- ONE LOOKUP, NOT ONE WALK
            if r then
                ghost_at[code] = at
                return true
            end
            return false
        end

        local function reaction_watcher_loop()
            if not dfhack.isMapLoaded() or not _G.refinish_active then return end
            local t_rec = dfhack.getTickCount()

            local ok, err = pcall(function()
                _G.refinish_last_watch_ping = os.date("%H:%M:%S")
                local protect_bases = dfhack.persistent.getSiteData('refinish_config_protect')
                -- Off unless set (refinish-index-reaction.lua, protected_bases).
                if not protect_bases or protect_bases == "" then protect_bases = 'NO' end

                -- The active base metals for the protect check, from the
                -- cache (PROTECTED BASES, above this loop).
                local protected_bases = {}
                if protect_bases == 'YES' then
                    protected_bases = protected_base_set()
                end

                for _, job in utils.listpairs(df.global.world.jobs.list) do
                    if job.job_type == df.job_type.CustomReaction then
                        local r_name = tostring(job.reaction_name) 
                        
                        if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                            local base_r_name = string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                            local config = JIT_CONFIG[base_r_name]
                            
                            if config then
                                for _, job_item_ref in ipairs(job.items) do
                                    local actual_item = job_item_ref.item
                                    if actual_item then
                                        local itype = tonumber(actual_item:getType())
                                        if itype == tonumber(config.itype) then
                                            local mat_info = dfhack.matinfo.decode(actual_item)
                                            if mat_info and mat_info.inorganic then
                                                local specific_mat_id = mat_info.inorganic.id
                                                
                                                -- TRAP DOOR: respect Protect Bases. Finished
                                                -- bars may be ground since 2026-10-03: their
                                                -- dust melts back into bars of the finish, and
                                                -- no finishing reaction takes it (refinish-scan
                                                -- never makes a finish a reagent).
                                                local is_protected_base = protected_bases[specific_mat_id]

                                                if is_protected_base then
                                                    -- Human-readable name for the announcement.
                                                    -- Prefer the material's real solid-state display
                                                    -- name (e.g. "specific steel cinnabar"); fall back
                                                    -- to a de-underscored raw ID only if that name is
                                                    -- somehow missing.
                                                    local mat_name = mat_info.inorganic.material.state_name[0]
                                                    if not mat_name or mat_name == "" then
                                                        mat_name = string.lower(specific_mat_id):gsub("_", " ")
                                                    end

                                                    -- Refusing a protected base's bar (e.g. plain steel)
                                                    local msg = "A dwarf realized they were about to grind unfinished " .. mat_name .. " and canceled the job."
                                                    local THEME = reqscript('refinish-theme').get_current_theme()
                                                    dfhack.gui.showAnnouncement(msg, THEME.RISK_L, true)
                                                    -- WARNING, matching the yellow announcement:
                                                    -- the player queued a grind the watcher had
                                                    -- to refuse.
                                                    log_watcher('WARNING', msg, 'JOB_' .. tostring(job.id))
                                                    dfhack.job.removeJob(job)
                                                    break 
                                                end

                                                -- The grinder a ghost is copied from: the family's
                                                -- own code, but a finished-metal grinder is one per
                                                -- base, and a ghost of one is its code with the
                                                -- finish's id on the end, so it is cut at the
                                                -- finish's id (every finish id starts
                                                -- REFINISH_STEEL_MAT_). The startup and autosave
                                                -- ghost sweeps cut it the same way.
                                                local grinder_code = base_r_name
                                                if base_r_name == FIN_GRIND then
                                                    grinder_code = string.match(r_name, "^(.-)_REFINISH_STEEL_MAT_") or r_name
                                                end
                                                local expected_ghost_id = grinder_code .. "_" .. specific_mat_id
                                                
                                                if r_name ~= expected_ghost_id then
                                                    local ghost_exists = ghost_known(expected_ghost_id)
                                                    
                                                    if not ghost_exists then
                                                        local solid_name = mat_info.inorganic.material.state_name[0]
                                                        local built = build_ghost_grinder_jit(expected_ghost_id, grinder_code, actual_item:getMaterialIndex(), solid_name, config)
                                                        if built then
                                                            -- Appended at the end: remember the slot.
                                                            ghost_at[expected_ghost_id] =
                                                                #df.global.world.raws.reactions.reactions - 1
                                                            log_watcher('DETAIL', 'JIT compiled ' .. expected_ghost_id .. '.',
                                                                'JOB_' .. tostring(job.id))
                                                        end
                                                    end
                                                    
                                                    job.reaction_name = expected_ghost_id
                                                    -- DETAIL: one per grinding job, chatter in
                                                    -- ordinary play.
                                                    log_watcher('DETAIL', 'Ghost swap to ' .. specific_mat_id .. '.',
                                                        'JOB_' .. tostring(job.id))
                                                end
                                                break 
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end)

            if not ok then 
                if not _G.refinish_err_spam_watcher then
                    log_watcher('ERROR', 'Watcher loop error: ' .. tostring(err))
                    _G.refinish_err_spam_watcher = true
                end
            else
                _G.refinish_err_spam_watcher = false
            end
            named_run('refinish-jit-watcher', t_rec)
            dfhack.timeout(get_poll_frames(), 'frames', reaction_watcher_loop) 
        end

        -- ==========================================
        -- 1. THE SAVE HOOK (every frame)
        -- ==========================================
        -- Unloads RM before the game's own saves and reloads after
        -- them; refinish-save-hook.lua records what was measured and
        -- why. Every frame rather than the poll rate, because save &
        -- continue leaves five frames between the request and the
        -- write. Resolved once per map, never per frame: reqscript
        -- costs about 2 ms a call.
        --
        -- What stood here was the ESC-menu data cycle: it unloaded RM
        -- whenever the options screen opened (AUTO) and reloaded it when
        -- the screen closed, beside a warning overlay telling a MANUAL
        -- player not to save. The hook unloads only for an actual save,
        -- so both are gone. The loop keeps its name and the ping the
        -- status panel reads.
        local save_hook = nil
        pcall(function() save_hook = dfhack.reqscript('refinish-save-hook') end)
        if save_hook then
            pcall(save_hook.reset)
        else
            log_ui('ERROR', 'refinish-save-hook did not load: the game\'s own'
                .. ' saves are NOT protected this session.', 'SAVE_HOOK')
        end

        -- RM'S OWN FILES, STILL THERE: a new map starts with no alarm
        -- raised, and THE UNLOAD, KEPT IN MEMORY taken from the files.
        -- KNOWN PATHS, CHECKED WITHOUT A SEARCH: DFHack builds its script
        -- folders afresh for each world, so each file is found by name
        -- again here, once.
        forget_paths()
        _G.refinish_scripts_missing = nil
        keep_unload()

        -- SCRIPT SEARCH: how many folders DFHack searches, in order, for
        -- each script looked up by name, and where RM's own sits. The
        -- check pays that search once per file per map, as above.
        pcall(function()
            local paths = dfhack.internal.getScriptPaths()
            local at = nil
            for i, p in ipairs(paths) do
                if tostring(p):lower():find('refinish', 1, true) then at = i; break end
            end
            log_system('DETAIL', ("script search: %d folder(s); RM's is number %s."):format(
                #paths, tostring(at)), 'SCRIPTS')
        end)

        local function ui_monitor_loop()
            if not dfhack.isMapLoaded() or not _G.refinish_active then return end
            local t_rec = dfhack.getTickCount()

            local ok, err = pcall(function()
                _G.refinish_last_ui_ping = os.date("%H:%M:%S")
                save_hook.step()
            end)
            -- RM'S OWN FILES, STILL THERE, every SCRIPT_CHECK_MS, under a
            -- guard of its own.
            pcall(check_scripts)

            if not ok then
                if not _G.refinish_err_spam_ui then
                    log_ui('ERROR', 'Save hook error: ' .. tostring(err))
                    _G.refinish_err_spam_ui = true
                end
            else
                _G.refinish_err_spam_ui = false
            end
            named_run('refinish-save-hook-monitor', t_rec)
            dfhack.timeout(1, 'frames', ui_monitor_loop)
        end

        -- ==========================================
        -- 2. SEASONAL AUTOSAVE LOGIC (Slow Polling)
        -- ==========================================
        local last_season = -1
        local last_year = -1

        local function calendar_loop()
            if not dfhack.isMapLoaded() or not _G.refinish_active then return end
            local t_rec = dfhack.getTickCount()

            local ok, err = pcall(function()
                _G.refinish_last_cal_ping = os.date("%H:%M:%S")
                
                if not _G.refinish_menu_locked and not _G.refinish_autosave_in_progress then
                    df.global.d_init.feature.autosave = -1
                    local cur_year = df.global.cur_year
                    local cur_tick = df.global.cur_year_tick
                    local cur_season = math.floor(cur_tick / 100800) 
                    local now = os.time()

                    if last_season == -1 then last_season = cur_season last_year = cur_year end

                    local interval = dfhack.persistent.getSiteData('refinish_config_interval')
                    if not interval or interval == "" then interval = 'SEASONAL' end
                    local trigger = false

                    if cur_season ~= last_season or cur_year ~= last_year then
                        if interval == 'SEASONAL' then trigger = true
                        elseif interval == 'SEMIANNUAL' then if cur_season == 0 or cur_season == 2 then trigger = true end
                        elseif interval == 'YEARLY' then if cur_year ~= last_year then trigger = true end
                        end
                        last_season = cur_season
                        last_year = cur_year
                    end

                    if interval == 'REAL_15' and (now - _G.refinish_last_real_save) >= 900 then trigger = true
                    elseif interval == 'REAL_30' and (now - _G.refinish_last_real_save) >= 1800 then trigger = true
                    elseif interval == 'REAL_60' and (now - _G.refinish_last_real_save) >= 3600 then trigger = true
                    end

                    if trigger and interval ~= 'NONE' then
                        log_cal('INFO', 'Autosave timer triggered (' .. interval .. ').',
                            'AUTOSAVE_TIMER')
                        _G.refinish_last_real_save = now
                        dfhack.run_script('refinish-autosave')
                    end
                end
            end)

            if not ok then 
                if not _G.refinish_err_spam_cal then
                    log_cal('ERROR', 'Calendar loop error: ' .. tostring(err))
                    _G.refinish_err_spam_cal = true
                end
            else
                _G.refinish_err_spam_cal = false
            end
            named_run('refinish-calendar', t_rec)
            dfhack.timeout(1000, 'frames', calendar_loop)
        end
        
        reaction_watcher_loop()
        ui_monitor_loop()
        calendar_loop()

        -- Build menu icon stamper. Poll gated like the loops
        -- above; restamps owned and adopted building icons
        -- whenever DF rebuilds the construction menu pages.
        pcall(function()
            dfhack.reqscript('refinish-menu-icons').start_stamper()
        end)

        -- RM's services (the dispatcher, byproducts, tool tint,
        -- aggregate, organic categories, stockpile windows) are started
        -- by refinish-startup at the end of its pipeline, above, and only
        -- when RM's data is loaded (RM'S SERVICES FOLLOW THE DATA).

        -- Live loop timing for the telemetry panel's LOOP COST section.
        -- Every scheduled loop in the session, ours and other mods', so
        -- a slow game shows whose loop it is; see LIVE MODE in
        -- refinish-tool-profiler. The profiler stops itself on map
        -- unload. Guarded like the stamper: timing that fails should
        -- cost the telemetry, never the session.
        pcall(function()
            dfhack.reqscript('refinish-tool-profiler').live_start()
        end)

        log_system('ONLINE', 'Monitors and loops successfully started.',
            'STARTUP')

-- ==========================================
    -- SHUTDOWN SEQUENCE
    -- ==========================================
    elseif sc == SC_MAP_UNLOADED then
        if _G.refinish_active then
            -- PRIORITY 1: THE KILLSWITCH
            pcall(function()
                log_session('SYSTEM', 'Map unloaded. Executing memory wipe.',
                    'MAP_UNLOADED')
                _G.refinish_active = false
            end)

            -- Menu icon stamper down before the scrubbers run.
            -- Clearing the running flag here is what lets the next
            -- map's start_stamper succeed; the session stamp
            -- already kills any in flight timeout closure.
            pcall(function()
                dfhack.reqscript('refinish-menu-icons').stop_stamper()
            end)

            -- RM's services down beside it, before the scrubbers: an open
            -- stockpile window's flags go back while the twins still exist
            -- (RM'S SERVICES FOLLOW THE DATA). Nothing to do if a shutdown
            -- already stopped them.
            stop_services()
            
            -- PRIORITY 2: THE SCRUBBERS (Absolute highest priority)
            -- THE FIX: Check state managers BEFORE calling dfhack.run_script.
            -- This perfectly guarantees the failsafe runs if needed, but prevents 
            -- the engine from redundantly loading/compiling scripts, which stops queue bleed.
            -- WHAT THE UNLOAD LEFT IN RAM: every step's failure is kept,
            -- where the pcalls used to drop it. THE UNLOAD, KEPT IN
            -- MEMORY: a step whose file cannot be reached runs from its
            -- kept copy, and says so.
            local failed, from_copy = {}, {}
            local function scrub(name, fn, kept)
                local ok, err = pcall(fn)
                if ok then return end
                if kept then
                    local ok2, err2 = pcall(kept)
                    if ok2 then
                        from_copy[#from_copy + 1] = name
                        log_system('ERROR', name .. ' could not run from its file (' .. tostring(err)
                            .. '); it ran from the copy kept in memory.', 'SHUTDOWN')
                        return
                    end
                    err = tostring(err) .. '; the kept copy failed too: ' .. tostring(err2)
                end
                failed[#failed + 1] = name .. ': ' .. tostring(err)
            end
            scrub('refinish-clear-entity', function()
                if _G.refinish_entity_loaded then dfhack.run_script('refinish-clear-entity') end
            end, function()
                if _G.refinish_entity_loaded then run_kept('refinish-clear-entity') end
            end)
            scrub('refinish-clear-reaction', function()
                if _G.refinish_reactions_loaded then dfhack.run_script('refinish-clear-reaction') end
            end, function()
                if _G.refinish_reactions_loaded then run_kept('refinish-clear-reaction') end
            end)
            scrub('refinish-clear', function()
                if _G.refinish_ram_loaded then dfhack.run_script('refinish-clear') end
            end, function()
                if _G.refinish_ram_loaded then run_kept('refinish-clear') end
            end)

            -- No tool wash here. Site data can no longer be written at
            -- the map unload, so a wash could keep no record: measured
            -- 2026-09-29, every tool came back a jug with nothing to put
            -- it back. A save & quit's records are written when the
            -- options screen opens (refinish-save-hook.lua,
            -- refresh_records), before this runs, and a quit without
            -- saving needs no record. For a save & quit this IS the
            -- unload: DF unloads the map before it writes the save
            -- (refinish-save-hook.lua, SAVE & QUIT).
            -- WITH THE KEPT ENVIRONMENTS: the engine, and every injector
            -- it looks up by name, answer from their kept copies when
            -- their files cannot be found.
            scrub('clear_module_assets', function()
                local served = with_kept_envs(function()
                    local mod_engine = dfhack.script_environment('refinish-module-engine')
                    if mod_engine and mod_engine.clear_module_assets then
                        mod_engine.clear_module_assets({ no_wash = true })
                    end
                end)
                for _, s in ipairs(served) do
                    from_copy[#from_copy + 1] = s.name
                    log_system('ERROR', s.name .. ' could not be found (' .. s.err .. '); its'
                        .. ' environment kept in memory was used.', 'SHUTDOWN')
                end
            end)

            -- WHAT THE UNLOAD LEFT IN RAM, counted before anything below
            -- can change it, and reported at the end in place of the old
            -- unconditional success line.
            local left, first_left = ram_left()
            
            -- PRIORITY 3: SECONDARY TEARDOWN (Hotkeys & Config Restores)
            pcall(function()
                if _G.refinish_original_autosave then df.global.d_init.feature.autosave = _G.refinish_original_autosave end
            end)

            pcall(function()
                -- We use the RAM cache here instead of getSiteData to prevent the database crash!
                if _G.refinish_hk_cache then
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.autosave)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.wipe)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.startup)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.hardwipe)
                    
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.config)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.metals)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.civs)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.status)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.log)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.inspect)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.help)
                end
            end)
            
            -- PRIORITY 4: GARBAGE COLLECTION
            -- Every _G.refinish_ key set during the session must be
            -- nil'd here to prevent stale data leaking across map loads.
            -- Module engine keys (module_registry, module_listeners,
            -- modules_injected) are NOT cleaned here; they manage
            -- their own lifecycle across data cycles.
            -- Logging keys (log, log_event) persist across the full
            -- DF session, not just per-map.

            -- Pipeline state
            _G.refinish_blueprint = nil
            _G.refinish_ram_loaded = nil
            _G.refinish_reactions_loaded = nil
            _G.refinish_entity_loaded = nil
            _G.refinish_data_loaded = nil

            -- Session state
            _G.refinish_active = nil
            _G.refinish_menu_locked = nil
            _G.refinish_save_hook_mode = nil
            _G.refinish_silent_load = nil
            _G.refinish_autosave_in_progress = nil
            -- refinish_version is NOT cleared: it is set once, where this
            -- file loads, so clearing it here left the status panel on
            -- "?" after any save & quit and reload until DF restarted.
            -- Nor is refinish_services, for the same reason: without it
            -- no later startup could start the services again.

            -- Boot caches
            _G.refinish_valid_bases = nil
            _G.refinish_known_metals_cache = nil
            _G.refinish_reaction_traits = nil
            _G.refinish_evaluated_reactions = nil
            _G.refinish_best_metal_template = nil
            _G.refinish_best_dust_template = nil
            _G.refinish_civ_tech = nil

            -- Hotkeys
            _G.refinish_hk_cache = nil

            -- HUD state
            _G.refinish_hud_view = nil
            _G.refinish_hud_restore_left = nil
            _G.refinish_hud_restore_right = nil

            -- Monitor timestamps
            _G.refinish_last_ui_ping = nil
            _G.refinish_last_cal_ping = nil
            _G.refinish_last_watch_ping = nil
            _G.refinish_last_real_save = nil
            _G.refinish_last_jobs_canceled = nil

            -- Telemetry
            _G.refinish_telemetry = nil

            -- Module Dependency
            _G.refinish_dependency_cache = nil
            
            pcall(function()
                for _, f in ipairs(failed) do
                    log_system('ERROR', 'clear step failed: ' .. f, 'SHUTDOWN')
                end
                local n_left = left.mat + left.rxn + left.cat + left.tool + left.plant + left.bld
                if n_left > 0 then
                    log_system('ERROR', ('RAM NOT CLEARED: %d material(s), %d reaction(s), %d reaction'
                        .. ' categor(ies), %d tool def(s), %d plant(s) and %d building def(s) from RM and'
                        .. ' its modules are still loaded (first: %s). A save written now carries them'
                        .. ' and will not load.'):format(left.mat, left.rxn, left.cat, left.tool,
                        left.plant, left.bld, tostring(first_left)), 'SHUTDOWN')
                    alert_after_unload(("Refinish Metal could not take its data out of memory when the"
                        .. " map unloaded: %d of its definitions were still loaded (first: %s). If you"
                        .. " saved on the way out, that save carries them and will not load: load an"
                        .. " earlier one. A quit without saving lost nothing. Put RM's script files back"
                        .. " and restart Dwarf Fortress before loading anything."):format(n_left,
                        tostring(first_left)), 'RISK_H')
                elseif #from_copy > 0 then
                    log_system('OFFLINE', 'Memory terminated from the kept copies; RAM read clear.',
                        'SHUTDOWN')
                    alert_after_unload("Refinish Metal's script files could not be found when the map"
                        .. " unloaded. RM took its data out of memory with the copies it keeps, and"
                        .. " memory read clear, so a save made on the way out should load. Put RM's"
                        .. " files back and restart Dwarf Fortress before loading it.", 'RISK_M')
                elseif #failed > 0 then
                    log_system('OFFLINE', 'Memory terminated: RAM read clear despite the failed step(s)'
                        .. ' above.', 'SHUTDOWN')
                else
                    log_system('OFFLINE', 'Memory successfully terminated.', 'SHUTDOWN')
                end
            end)
            
            _G.refinish_err_spam_watcher = nil
            _G.refinish_err_spam_ui = nil
            _G.refinish_err_spam_cal = nil
        end
    end
end