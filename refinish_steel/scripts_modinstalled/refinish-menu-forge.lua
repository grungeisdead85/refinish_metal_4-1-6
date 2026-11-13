--@ module = true
-- refinish-menu-forge.lua
-- ==========================================
-- THE FORGE'S TASK MENU: RM'S FINISHES IN ONE FOLDER
-- ==========================================
-- The forge lists every metal inside every item category. With every
-- base metal on, one such list held 61,442 rows (making-fuel-menu-
-- shaper.lua, 2026-09-30), nearly all RM finishes, and vanilla metals
-- were impossible to find, even by searching. This service gives each
-- category list one folder for all of them:
--
--   weapons and ammunition > refinished metals > steel > colour-based
--     > amber steel > its job list
--
-- The base and kind levels are always there, so the path is the same
-- however many base metals are selected. The kinds, colour-based and
-- material-based, split a base's finishes the way the smelter's folders
-- do (refinish-scan.lua, THE FORGE'S FOLDERS). Until 2026-10-03 a base
-- folder listed all of them together, sorted by name, and nothing in the
-- list showed which kind a finish was.
--
-- ---- WHAT THE PROBE RUNS MEASURED (refinish-forge-menu-probe, 2026-10-02) ----
--   * df.global.game.main_interface.building holds the open task menu:
--     `button` (every row, plus DF's Back), filtered_button (the rows a
--     search leaves) and press_button (every row, not narrowed by a
--     search), with category, material/matgloss and
--     current_custom_category_token for the view.
--   * DF rebuilds the list on a press, never on its own and never while
--     typing a search (a search only narrows filtered_button).
--   * A folder (custom category selector) draws its caption from its
--     reaction CATEGORY. DF builds a folder's rows from the reactions at
--     the building filed under that category; a folder with none dumps
--     the task panel and Add new task stays dead until the workshop is
--     reopened. Every folder here therefore has a placeholder reaction
--     (refinish-index-reaction.lua, THE FORGE'S FOLDER PLACEHOLDERS).
--   * DF checks the folder token BEFORE the metal: a metal pressed with
--     a folder token set rebuilds the folder. With the token cleared, the
--     same press opens the metal's own job list, row for row the same as
--     its base metal's, and the jobs queued from it were right in play.
--   * DF's Back presses the last entry of `button` that is not a row
--     (button only). A category list's is a category button for NONE, a
--     metal's job list's a material button with no material; a reaction
--     folder gets none, and there Back reads Cancel and shuts the panel.
--     An entry this service puts there is pressed the same way. The
--     probe's entry, which read Back, carried the fields of DF's own
--     (leave_button, flag and search text); this service's first entries,
--     built with those zeroed, read Cancel in play (2026-10-02). Every
--     Back entry here is therefore built from DF's own (new_back).
--   * Putting a folder's token back once a job list is open makes DF's
--     Back from the jobs return to the folder.
--   * Queueing a job closes the panel and resets the menu to the top.
--   * IN PLAY with every base on (2026-10-02, 61,392 finishes): DF's own
--     category list cannot carry a material number above 32,767. Those
--     rows come out as "rock" (the long rock list seen before any of this
--     existed), so only 31,424 finishes were filed in Weapons, and steel's
--     635 material finishes (numbered high, after the colours and the
--     bases before it) never reached its folder. MEASURED off the rows
--     (2026-10-02, 62,606 inorganics): the unnumbered rows carry -32,768
--     to -2,931, which is inorganics 32,768 to the last wrapped through
--     16 bits, 29,838 rows, exactly that many; with the 31,554 filed,
--     every one of the 61,392 finishes is accounted for.
--
-- ---- THE VIEWS, AND WHAT THIS SERVICE DOES IN EACH ----
--   top level        DF lists "refinished metals" here too (its category
--                    has reactions at the forge); taken out, because a
--                    metal opened from the top has no item category.
--   category list    every RM finish whose base has a folder leaves the
--                    list, and so does every row DF could not number (a
--                    material number outside the inorganics); the
--                    "refinished metals" folder goes on top.
--   refinished metals
--                    DF builds a folder per base metal. Bases with no
--                    finish in this category go; a Back entry that
--                    returns to the category list is put last.
--   a base folder    DF builds a folder per kind of finish the base has,
--                    since the placeholders are filed under those; a
--                    Back entry that returns to refinished metals is put
--                    last.
--   a kind folder    DF builds its placeholder row; it is replaced by
--                    EVERY finish of that kind of the base, taken from
--                    the blueprint rather than from DF's list, which
--                    loses the high numbers; the folder token is cleared
--                    so a press opens a metal's jobs, and a Back entry
--                    that returns to the base folder is put last.
--   a job list       opened from a kind folder: the kind's token is put
--                    back, so Back returns to the kind folder. A job row
--                    that does not name the metal opened is taken out and
--                    logged, so a broken number can never become a job.
--   new work order   the placeholders are taken out of the manager's list.
--
-- ---- OWNERSHIP: THE RULE THAT PREVENTS A CRASH ----
-- DF deletes what is in `button` when it rebuilds, so every button is
-- deleted exactly once, by exactly one party: a button taken out of the
-- vectors is deleted here, after it is out of all three; a button made
-- here and left in `button` is DF's to delete. filtered_button holds
-- stale pointers while the panel is closed (measured: 61,500 of them
-- with `button` empty), so no list is touched unless DF built it:
-- `button` not empty and belonging to the forge in view. The buttons a
-- filed category list leaves behind are deleted over the frames after it
-- opens (DEFERRED DELETION), out of every vector the whole time.
-- ==========================================

local repeatUtil = require('repeat-util')
local REPEAT_KEY  = 'refinish-menu-forge'
local POLL_FRAMES = 1      -- rides the menu: a rebuild is answered next frame

local FOLDER_RXN_PREFIX = 'REFINISH_STEEL_RXN_FORGE_FOLDER_'
local COLOUR_PREFIX     = 'REFINISH_STEEL_MAT_COLOUR_'
local SPECIFIC_PREFIX   = 'REFINISH_STEEL_MAT_SPECIFIC_'
local OPENS_MENU        = ' (opens menu)'   -- DF's search text suffix on folders and metals

local MATSEL  = df.interface_button_building_material_selectorst
local CUSTCAT = df.interface_button_building_custom_category_selectorst
local CATSEL  = df.interface_button_building_category_selectorst

local FORGE = {
    [df.workshop_type.MetalsmithsForge] = true,
    [df.workshop_type.MagmaForge] = true,
}

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. SUBJECT is the view a line is about: TOP, CATEGORY,
-- FOLDER, BASE, KIND, JOBS, MANAGER, or START and STOP. Every line
-- reaches the log on disk; the panel's Log Detail setting decides what
-- shows.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MENU_FORGE'
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

-- ==========================================
-- STATE (reset by start)
-- ==========================================
local defs, defs_key          -- the folders: see load_defs
local base_of, map_key        -- inorganic index -> base metal id, RM finishes only
local kind_at                -- inorganic index -> its finish's kind, COLOUR or MATERIAL
local members_of             -- base metal id -> kind -> its finishes' inorganic indices
local rec                     -- the category list last filed (FILING)
local tmpl_by_cat             -- DF's own metal button fields, per category
local list_stamp, view_stamp  -- the menu as this service last left it
local last_view              -- the view on screen
local restore_token           -- the kind folder a job list was opened from
local cwo_stamp               -- the manager's list as last pruned
local back_tmpl               -- DF's own Back fields, off a category list (new_back)
local prev_tick               -- dfhack.getTickCount() at the last poll
local frame_ms, frame_ms_before   -- the last two gaps between polls (the filing line)

local function reset()
    defs, defs_key, base_of, map_key, members_of, kind_at = nil, nil, nil, nil, nil, nil
    rec, tmpl_by_cat = nil, {}
    list_stamp, view_stamp, last_view = nil, nil, nil
    restore_token, cwo_stamp = nil, nil
    back_tmpl, prev_tick, frame_ms, frame_ms_before = nil, nil, nil, nil
end
reset()

-- ==========================================
-- SMALL HELPERS
-- ==========================================
local function ms_since(t0) return (os.clock() - t0) * 1000 end

-- Identity by address: refs compare equal only when type AND pointer
-- match (Lua_API), and a building read off a button need not carry the
-- same type as the one df.building.find returns.
local function addr(ref)
    if ref == nil then return nil end
    local ok, _, a = pcall(df.sizeof, ref)
    if ok then return a end
    return nil
end

local function same_bld(btn, bld)
    local ok, bd = pcall(function() return btn.bd end)
    if not ok or bd == nil then return false end
    return addr(bd) == addr(bld)
end

local function is_forge(bld)
    return bld:getType() == df.building_type.Workshop
        and FORGE[bld:getSubtype()] == true
end

local function solid_name(mg)
    local all = df.global.world.raws.inorganics.all
    if mg < 0 or mg >= #all then return '?' end
    local s = all[mg].material.state_name[0]
    return string.lower((s and s ~= '') and s or all[mg].id)
end

-- resize(0) drops pointers without deleting what they point at, and
-- appending one at a time never leaves a null slot if a write fails.
local function set_vec(vec, list)
    vec:resize(0)
    for i = 1, #list do vec:insert('#', list[i]) end
end

local function delete_all(list)
    local failed = 0
    for i = 1, #list do
        if not pcall(df.delete, list[i]) then failed = failed + 1 end
    end
    return failed
end

-- A highlight past the end of a shorter list is a crash waiting on a
-- keypress (making-fuel-menu-shaper.lua).
local function clamp(bi)
    local nf = #bi.filtered_button
    if bi.selected >= nf then bi.selected = math.max(0, nf - 1) end
end

-- ==========================================
-- DEFERRED DELETION
-- ==========================================
-- Filing a category list takes some 60,000 of DF's buttons out of every
-- vector (FILING). They are this service's to delete (OWNERSHIP, in the
-- header), but nothing requires that on the frame the list opens, the
-- one the player waits on. They wait here instead, out of every vector,
-- and go a few milliseconds' worth per frame. Each finish's search text
-- and sort value is read just before its button goes, for the kind
-- folders, while its list is still the one on file; a kind folder opened
-- before the drain is through finishes it first (fill_kind). start and
-- stop finish it too, so nothing outlives a stop. reset leaves it alone:
-- dropping the list would leak every button in it.
-- ==========================================
local DRAIN_BUDGET_MS = 4      -- deleting per frame, in ms of work
local DRAIN_STRIDE    = 256    -- deletes between clock checks

local pending = nil            -- batches waiting, oldest first

local function defer_delete(btns, mgs, r)
    pending = pending or {}
    pending[#pending + 1] = { btn = btns, mg = mgs, rec = r, pos = 1,
        failed = 0, frames = 0, ms = 0, worst = 0 }
end

-- budget_ms: how much of this frame to spend; math.huge finishes it all.
-- no_names: delete without reading (start and stop: nothing will use them).
local function drain(budget_ms, no_names)
    if not pending then return end
    local t0 = os.clock()
    local done = 0
    while #pending > 0 do
        if done > 0 and ms_since(t0) >= budget_ms then break end
        local q = pending[1]
        local tq = os.clock()
        -- Names only for the list on file: a batch from an older list is
        -- deleted without reading.
        local into = (not no_names and q.rec == rec) and q.rec or nil
        local i, last = q.pos, #q.btn
        while i <= last do
            local b, mg = q.btn[i], q.mg[i]
            if into and mg >= 0 then
                into.name[mg], into.alpha[mg] = b.filter_str, b.alpha_order
            end
            if not pcall(df.delete, b) then q.failed = q.failed + 1 end
            i = i + 1
            done = done + 1
            if done % DRAIN_STRIDE == 0 and ms_since(t0) >= budget_ms then break end
        end
        q.pos = i
        local spent = ms_since(tq)
        q.frames, q.ms = q.frames + 1, q.ms + spent
        if spent > q.worst then q.worst = spent end
        if i <= last then break end          -- this frame's share is spent
        table.remove(pending, 1)
        log('DETAIL', ('%s: the %d buttons its filing took out deleted over %d frame(s),'
            .. ' %.1f ms in all, %.1f ms at most in one (%d delete fault(s)).'):format(
            df.interface_category_building[q.rec.category] or q.rec.category,
            last, q.frames, q.ms, q.worst, q.failed), 'CATEGORY')
    end
    if #pending == 0 then pending = nil end
end

-- ==========================================
-- THE FOLDERS (load_defs)
-- ==========================================
-- refinish-scan.lua names them in the blueprint (THE FORGE'S FOLDERS):
-- the refinished metals category, per base metal a category, and inside
-- it per kind of finish a category and the code of its placeholder
-- reaction. A kind folder is READY only when its placeholder is in the
-- reaction array AND permitted to the fort's civ:
-- DF shows a folder only for reactions the civ may do, and a folder
-- pressed with nothing DF can build dumps the panel. So no finish leaves
-- a list unless its kind folder is ready; a base folder is ready when one
-- of its kind folders is, and refinished metals goes in only when one is.
--
-- Read once per data cycle, and again whenever the reaction array grows:
-- the placeholders are built last, after the grinders, so the walk back
-- from the end is a few rows when every kind of every base has a folder.
-- A kind has one only once a finish of it is minted
-- (refinish-mint-finish.lua), so with fewer folders than that the walk
-- reads the whole array, which then
-- holds only the finishes the fort can make. The civ's permitted list is
-- read once.
-- ==========================================
local function load_defs()
    local bp = _G.refinish_blueprint
    local forge = bp and bp.forge
    local reactions = df.global.world.raws.reactions.reactions
    local key = tostring(bp) .. '|' .. #reactions .. '|' .. tostring(_G.refinish_reactions_loaded)
    if key == defs_key then return defs end
    defs_key, defs = key, nil
    if not (forge and _G.refinish_reactions_loaded) then return nil end

    -- d.bases: per base its folder's token and name, and its kinds; each
    -- kind (kd) its folder's token, name and placeholder code. ready_n
    -- counts the bases with a kind folder ready.
    local d = { root = forge.root, bases = {}, base_of_token = {}, kind_of_token = {},
        ready_n = 0 }
    local want, need, n_bases = {}, 0, 0
    for base_id, f in pairs(forge.bases) do
        local base = { id = base_id, token = f.token, name = f.name, kinds = {} }
        d.bases[base_id] = base
        d.base_of_token[f.token] = base_id
        n_bases = n_bases + 1
        for kind, k in pairs(f.kinds or {}) do
            local kd = { base = base_id, kind = kind, token = k.token, name = k.name, rxn = k.rxn }
            base.kinds[kind] = kd
            d.kind_of_token[k.token] = kd
            want[k.rxn] = kd
            need = need + 1
        end
    end
    local index_to_kind, has_folder = {}, {}
    local found, bases_found = 0, 0
    for i = #reactions - 1, 0, -1 do
        local kd = want[reactions[i].code]
        if kd then
            index_to_kind[i] = kd
            found = found + 1
            if not has_folder[kd.base] then
                has_folder[kd.base] = true
                bases_found = bases_found + 1
            end
            if found == need then break end
        end
    end
    -- A kind folder ready makes its base folder ready, counted once.
    local kinds_ready = 0
    local function ready(kd)
        kd.ready = true
        kinds_ready = kinds_ready + 1
        local base = d.bases[kd.base]
        if not base.ready then
            base.ready = true
            d.ready_n = d.ready_n + 1
        end
    end
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    local granted = 0
    if civ then
        local permitted = civ.entity_raw.workshops.permitted_reaction_id
        for k = 0, #permitted - 1 do
            local kd = index_to_kind[permitted[k]]
            if kd and not kd.ready then ready(kd) end
        end
        -- ---- EVERY FOLDER OPENS ----
        -- The entity stage grants a base's finishes, and so its folder's
        -- placeholder, only to civs that know the base metal, while DF's
        -- forge lists every finish of every base. MEASURED: 80 of 81
        -- ready, and the 81st base's finishes stayed in the lists. The
        -- rest are granted here to the fort's civ. RM's clear takes every
        -- REFINISH_STEEL_ permission off by code before a save
        -- (refinish-clear-entity.lua), and this runs again on the next
        -- data cycle, so the grant never reaches a save.
        for i, kd in pairs(index_to_kind) do
            if not kd.ready then
                permitted:insert('#', i)
                ready(kd)
                granted = granted + 1
            end
        end
    end
    -- Measured against the placeholders found, not every kind of every
    -- base: a kind with no finish minted yet has no placeholder by design,
    -- and no finishes to keep in the lists either.
    if kinds_ready < found then
        -- WARNING: a kind folder that is not ready keeps its finishes in
        -- the category lists, as before this service.
        log('WARNING', ('%d of %d colour and material folders ready (placeholder built'
            .. ' and permitted); the others keep their finishes in the category lists.')
            :format(kinds_ready, found), 'START')
    else
        log('DETAIL', ('%d base metal folder(s) ready, holding %d colour and material'
            .. ' folder(s), %d of them granted here; %d base(s) with no finish minted'
            .. ' yet, so no folder.'):format(d.ready_n, kinds_ready, granted,
            n_bases - bases_found), 'START')
    end
    defs = d
    return d
end

-- ==========================================
-- WHICH INORGANIC IS WHICH BASE'S FINISH, AND OF WHICH KIND
-- ==========================================
-- From the blueprint, by inorganic index, because a menu button carries
-- the index. Indices move when RAM is rebuilt, so this is rebuilt
-- whenever the inorganic array or the blueprint changes, and a filed
-- list from before goes with it. The kind is the id's prefix: colour
-- finishes and material finishes each have a folder inside the base's
-- (refinish-scan.lua, THE FORGE'S FOLDERS, THE KINDS).
-- ==========================================
local function load_map()
    local all = df.global.world.raws.inorganics.all
    local n = #all
    local bp = _G.refinish_blueprint
    local key = table.concat({ n, n > 0 and all[n - 1].id or '-', tostring(bp) }, '|')
    if key == map_key then return base_of end
    map_key, base_of, members_of, kind_at, rec = key, {}, {}, {}, nil
    if not (bp and bp.materials) then return base_of end
    local t0 = os.clock()
    local count = 0
    for i = 0, n - 1 do
        local id = all[i].id
        local data = bp.materials[id]
        if data and data.base_metal_id then
            local kind = (id:find(COLOUR_PREFIX, 1, true) == 1 and 'COLOUR')
                or (id:find(SPECIFIC_PREFIX, 1, true) == 1 and 'MATERIAL') or nil
            if kind then
                local b = data.base_metal_id
                base_of[i] = b
                kind_at[i] = kind
                local by_kind = members_of[b]
                if not by_kind then
                    by_kind = {}
                    members_of[b] = by_kind
                end
                local m = by_kind[kind]
                if not m then
                    m = {}
                    by_kind[kind] = m
                end
                m[#m + 1] = i
                count = count + 1
            end
        end
    end
    log('DETAIL', ('%d finishes mapped to their base metals in %.0f ms.')
        :format(count, ms_since(t0)), 'START')
    return base_of
end

-- ==========================================
-- BUTTONS
-- ==========================================
-- Made buttons copy DF-made ones field by field. hotkey is never copied:
-- a copied hotkey would give two rows one key.
local function capture_metal(b)
    return {
        leave_button = b.leave_button, flag = b.flag.whole,
        alpha_order = b.alpha_order, job_item_flag = b.job_item_flag.whole,
        prepare_interface = b.prepare_interface,
    }
end

local function new_metal(bld, t, mg, name, alpha)
    local b = MATSEL:new()
    b.bd = bld
    b.hotkey = 0
    b.leave_button = t.leave_button
    b.flag.whole = t.flag
    b.filter_str = name
    b.alpha_order = alpha or t.alpha_order
    b.material = 0
    b.matgloss = mg
    b.job_item_flag.whole = t.job_item_flag
    b.prepare_interface = t.prepare_interface
    return b
end

-- A folder row, or, put in `button` only, a Back entry: pressing either
-- sets the folder token, and DF builds that view.
local function new_folder(bld, token, filter)
    local b = CUSTCAT:new()
    b.bd = bld
    b.custom_category_token = token
    b.filter_str = filter
    b.hotkey = 0
    b.leave_button = false
    b.alpha_order = 0
    b.flag.whole = 0
    return b
end

-- A Back entry: put in `button` only and last, where DF's Back control
-- presses it (header, WHAT THE PROBE RUNS MEASURED). It carries the
-- fields of DF's own Back, read off a category list (file_category): an
-- entry with them read Back, entries without them read Cancel. It stays
-- a folder button, because a folder button's press is what sets the
-- token a Back here has to land on.
local function new_back(bld, token, subject)
    local b = new_folder(bld, token, '')
    local t = back_tmpl
    if t then
        b.leave_button = t.leave_button
        b.flag.whole = t.flag
        b.filter_str = t.filter_str
    else
        -- WARNING: a folder reached with no category list read this
        -- session, which the menu's paths should not allow.
        log('WARNING', "Back entry built before DF's own Back was read; it may read Cancel.", subject)
    end
    return b
end

-- ==========================================
-- THE TOP LEVEL
-- ==========================================
-- DF lists refinished metals among the forge's own folders, since its
-- category holds reactions here. Opened from the top, a metal would have
-- no item category to list jobs for, so it is taken out.
-- ==========================================
local function prune_top(bi, d)
    local doomed = {}
    local function keep(b)
        if b._type == CUSTCAT and b.custom_category_token == d.root then
            doomed[tostring(b)] = b
            return false
        end
        return true
    end
    for _, name in ipairs({ 'button', 'filtered_button', 'press_button' }) do
        local vec = bi[name]
        for i = #vec - 1, 0, -1 do
            if not keep(vec[i]) then vec:erase(i) end
        end
    end
    local list = {}
    for _, b in pairs(doomed) do list[#list + 1] = b end
    if #list > 0 then
        delete_all(list)
        clamp(bi)
    end
end

-- ==========================================
-- FILING A CATEGORY LIST
-- ==========================================
-- Every RM finish whose kind folder is ready leaves the list. The
-- category's record (rec) keeps which bases had a finish here, and DF's
-- own search text and sort value for each finish, read as its button is
-- deleted (DEFERRED DELETION), so a kind folder shows exactly what DF
-- listed for this category. DF's Back (the last entry, button only)
-- stays where it is, and its fields are the pattern for this service's
-- Back entries (new_back).
--
-- ---- THE FRAME THE LIST OPENS ON ----
-- This runs over every row DF built, some 60,000 with every base on,
-- while the player waits: each row's fields are read once (kind), the
-- other two vectors are not walked again when they hold `button`'s rows,
-- and the deleting waits for the frames after. The filing line logs the
-- parts: rows read, lists set, and the frame DF built the list in beside
-- the frame before it, which sets DF's share against this service's.
-- ==========================================
local function file_category(bi, bld, d, map)
    local btns = bi.button
    local n = #btns
    local t0 = os.clock()
    -- DF's own Back, last in `button`: a category button for NONE. Its
    -- fields are logged once a session, so the log shows what Back
    -- entries here carry.
    local last = btns[n - 1]
    if last._type == CATSEL and last.category == -1 then
        local first = (back_tmpl == nil)
        back_tmpl = { leave_button = last.leave_button, flag = last.flag.whole,
            filter_str = last.filter_str }
        if first then
            log('DETAIL', ("DF's Back on a category list: leave_button %s, flag %s,"
                .. " search text '%s'. Back entries here carry the same."):format(
                tostring(back_tmpl.leave_button), tostring(back_tmpl.flag),
                back_tmpl.filter_str), 'CATEGORY')
        end
    end
    -- present: the bases with a finish DF listed here. name and alpha, DF's
    -- own search text and sort value per finish, are filled by the drain.
    local r = { category = bi.category, present = {}, name = {}, alpha = {} }
    local bases = d.bases
    local n_inorg = #df.global.world.raws.inorganics.all
    -- What a row is, each field read once. A finish whose kind folder is
    -- ready: its base id and material number. A row DF could not
    -- number, an inorganic metal whose number is not an inorganic's (IN
    -- PLAY, in the header): never a real metal, and pressing one would
    -- open jobs for no material: false and the number. Anything else: nil.
    local function kind(b)
        if b._type ~= MATSEL or b.material ~= 0 then return nil end
        local mg = b.matgloss
        if mg < 0 or mg >= n_inorg then return false, mg end
        local base = map[mg]
        local f = base and bases[base]
        local kd = f and f.kinds[kind_at[mg]]
        if kd and kd.ready then return base, mg end
        return nil
    end
    -- doomed and dmg run in step: each button leaving, and its material
    -- number (-1 for an unnumbered row, which has no name worth keeping).
    local keep, doomed, dmg, nd = {}, {}, {}, 0
    local tmpl = nil
    local broken, lo, hi = 0, nil, nil
    for i = 0, n - 1 do
        local b = btns[i]
        local k, mg = kind(b)
        if k then
            nd = nd + 1
            doomed[nd], dmg[nd] = b, mg
            r.present[k] = true
            if not tmpl then tmpl = capture_metal(b) end
        elseif k == false then
            nd = nd + 1
            doomed[nd], dmg[nd] = b, -1
            broken = broken + 1
            if not lo or mg < lo then lo = mg end
            if not hi or mg > hi then hi = mg end
        else
            keep[#keep + 1] = b
        end
    end
    if nd == 0 then return end
    local t_rows = os.clock()
    -- ---- THE OTHER TWO VECTORS ----
    -- press_button holds every row and filtered_button the rows a search
    -- leaves (header). With no search narrowing the list, both hold
    -- `button`'s rows, everything but DF's Back at its end, so the rows
    -- kept here serve both without another walk. Checked by the counts,
    -- the first and last rows by identity (refs compare by type and
    -- pointer, Lua_API), and DF's Back kept. Either way only buttons kept
    -- in `button` go into them, so ownership holds even were the order to
    -- differ.
    local rows_n = n - 1
    local function mirrors(vec)
        return #vec == rows_n and vec[0] == btns[0] and vec[rows_n - 1] == btns[rows_n - 1]
    end
    local fast = keep[#keep] == last and mirrors(bi.press_button) and mirrors(bi.filtered_button)
    local folder = new_folder(bld, d.root, 'refinished metals' .. OPENS_MENU)
    local fkeep, pkeep
    if fast then
        local rows = { folder }
        for i = 1, #keep - 1 do rows[#rows + 1] = keep[i] end
        fkeep, pkeep = rows, rows
    else
        -- Read before anything is set: whatever a search left in
        -- filtered_button, and every row in press_button.
        local function others(vec)
            local out = { folder }
            for i = 0, #vec - 1 do
                local b = vec[i]
                if kind(b) == nil then out[#out + 1] = b end
            end
            return out
        end
        fkeep, pkeep = others(bi.filtered_button), others(bi.press_button)
    end
    table.insert(keep, 1, folder)
    set_vec(btns, keep)
    set_vec(bi.filtered_button, fkeep)
    set_vec(bi.press_button, pkeep)
    clamp(bi)
    defer_delete(doomed, dmg, r)
    rec = r
    tmpl_by_cat[bi.category] = tmpl
    log('DETAIL', ('%s: %d finishes filed into refinished metals and %d unnumbered'
        .. ' row(s) taken out (material numbers %s to %s, inorganics %d) in %.1f ms:'
        .. ' rows read %.1f ms, lists set %.1f ms (other two lists %s). The frame DF'
        .. ' built the list in took %s ms, the frame before %s ms. The %d buttons'
        .. ' taken out are deleted over the next frames.'):format(
        df.interface_category_building[bi.category] or bi.category,
        nd - broken, broken, tostring(lo), tostring(hi), n_inorg, ms_since(t0),
        (t_rows - t0) * 1000, ms_since(t_rows), fast and 'mirrored' or 'walked',
        tostring(frame_ms or '?'), tostring(frame_ms_before or '?'), nd), 'CATEGORY')
end

-- ==========================================
-- REFINISHED METALS, OPEN
-- ==========================================
-- DF built a folder per base metal. A base with no finish in this
-- category (or none ready) goes, and the Back entry goes last (new_back):
-- a folder button with an empty token, which reopens the category list.
-- ==========================================
local function fill_root(bi, bld, d)
    local doomed = {}
    local here = (rec and rec.category == bi.category) and rec.present or nil
    local function keep(b)
        if b._type ~= CUSTCAT then return true end
        local base = d.base_of_token[b.custom_category_token]
        if not base then return true end
        local ok = d.bases[base].ready and (here == nil or here[base] ~= nil)
        if not ok then doomed[tostring(b)] = b end
        return ok
    end
    for _, name in ipairs({ 'button', 'filtered_button', 'press_button' }) do
        local vec = bi[name]
        for i = #vec - 1, 0, -1 do
            if not keep(vec[i]) then vec:erase(i) end
        end
    end
    local list = {}
    for _, b in pairs(doomed) do list[#list + 1] = b end
    delete_all(list)
    bi.button:insert('#', new_back(bld, '', 'FOLDER'))     -- Back, button only
    clamp(bi)
end

-- ==========================================
-- A BASE FOLDER, OPEN
-- ==========================================
-- DF built a folder per kind of finish the base has (THE FOLDERS), and
-- they stay as DF made them: DF lists only the kinds whose placeholder
-- the civ may do, and a finish is its base cloned, item flags and all, so
-- a base listed in this category has its kinds here too. The Back entry
-- goes last (new_back), a folder button for refinished metals: DF gives a
-- reaction folder no Back of its own.
-- ==========================================
local function fill_base(bi, bld, d, base)
    bi.button:insert('#', new_back(bld, d.root, 'BASE'))     -- Back, button only
    clamp(bi)
    log('DETAIL', ('%s: %d kind folder(s) listed.'):format(d.bases[base].name,
        #bi.filtered_button), 'BASE')
end

-- ==========================================
-- A KIND FOLDER, OPEN
-- ==========================================
-- DF built the placeholder row. The kind's finishes replace it, sorted
-- by name, made from the category's own DF-made metal button; the token
-- is cleared so a press opens the metal's jobs; the Back entry (new_back),
-- last and button only, reopens the base folder.
-- ==========================================
local function fill_kind(bi, bld, d, kd, map)
    -- DF's names for the filed list's finishes are read as their buttons
    -- are deleted, so any still waiting go now (DEFERRED DELETION).
    drain(math.huge)
    local t0 = os.clock()
    local t = tmpl_by_cat[bi.category]
    if not t then
        for _, any in pairs(tmpl_by_cat) do t = any break end
    end
    if not t then
        -- WARNING: reached without a category list filed this session;
        -- the placeholder row stays (it reads red and cannot be done).
        log('WARNING', 'kind folder opened before any category list was filed;'
            .. ' left as DF built it.', 'KIND')
        return
    end
    -- Every finish of this kind of the base, from the blueprint (load_map),
    -- not only the ones DF listed: DF's list loses every number above
    -- 32,767. A finish is its base cloned, item flags and all, so where one
    -- is listed all belong.
    local by_kind = members_of and members_of[kd.base]
    local members = (by_kind and by_kind[kd.kind]) or {}
    local listed = 0
    local names = {}
    for _, mg in ipairs(members) do
        local own = rec and rec.name[mg]
        if own then listed = listed + 1 end
        names[mg] = own or (solid_name(mg) .. OPENS_MENU)
    end
    local sorted = {}
    for i, mg in ipairs(members) do sorted[i] = mg end
    table.sort(sorted, function(a, c) return names[a] < names[c] end)
    local rows = {}
    for _, mg in ipairs(sorted) do
        rows[#rows + 1] = new_metal(bld, t, mg, names[mg], rec and rec.alpha[mg] or nil)
    end
    -- Everything DF built here goes: the placeholder row.
    local doomed = {}
    local btns = bi.button
    for i = 0, #btns - 1 do doomed[#doomed + 1] = btns[i] end
    local all = {}
    for i, b in ipairs(rows) do all[i] = b end
    all[#all + 1] = new_back(bld, d.bases[kd.base].token, 'KIND')   -- Back, button only
    set_vec(btns, all)
    set_vec(bi.filtered_button, rows)
    set_vec(bi.press_button, rows)
    local failed = delete_all(doomed)
    clamp(bi)
    restore_token = bi.current_custom_category_token
    bi.current_custom_category_token = ''
    log('DETAIL', ('%s, %s: %d finishes listed (%d of them in DF\'s own list) in %.1f ms'
        .. ' (%d delete fault(s)).'):format(d.bases[kd.base].name, kd.name, #rows,
        listed, ms_since(t0), failed), 'KIND')
end

-- ==========================================
-- THE MANAGER'S NEW WORK ORDER LIST
-- ==========================================
-- The placeholders are reactions at the forge, so the list of new work
-- orders would offer them. Pruned the way making-fuel-menu-shaper.lua
-- prunes its hardcoded jobs: the master list and each building's slice,
-- each template deleted once, the walk run only when the list is rebuilt.
-- ==========================================
local function prune_manager()
    local cwo = df.global.game.main_interface.create_work_order
    if not cwo.open then
        cwo_stamp = nil
        return
    end
    local master = cwo.jminfo_master
    local stamp = #master .. '/' .. (#master > 0 and tostring(master[0]) or '-')
    if stamp == cwo_stamp then return end
    cwo_stamp = stamp
    local t0 = os.clock()
    local CUSTOM = df.job_type.CustomReaction
    local doomed, hits = {}, 0
    local function prune(vec)
        for i = #vec - 1, 0, -1 do
            local t = vec[i]
            if t.job_type == CUSTOM
                    and t.reaction_name:find(FOLDER_RXN_PREFIX, 1, true) == 1 then
                doomed[tostring(t)] = t
                vec:erase(i)
                hits = hits + 1
            end
        end
    end
    prune(master)
    for b = 0, #cwo.building - 1 do prune(cwo.building[b].jminfo) end
    local list = {}
    for _, t in pairs(doomed) do list[#list + 1] = t end
    delete_all(list)
    cwo_stamp = #master .. '/' .. (#master > 0 and tostring(master[0]) or '-')
    if hits > 0 then
        log('DETAIL', ('%d placeholder template(s) taken out of the new work order'
            .. ' list in %.1f ms.'):format(hits, ms_since(t0)), 'MANAGER')
    end
end

-- ==========================================
-- ONE FRAME
-- ==========================================
local function view_of(bi, tok, d)
    if bi.material ~= -1 then return 'jobs' end
    if bi.category == -1 then return 'top' end
    if tok == '' then return 'category' end
    if tok == d.root then return 'root' end
    if d.base_of_token[tok] then return 'base' end
    if d.kind_of_token[tok] then return 'kind' end
    return 'other'
end

local function stamps(bi, vs)
    local btns = bi.button
    local n = #btns
    local list = table.concat({ bi.category, bi.material, bi.matgloss,
        bi.current_custom_category_token, n,
        n > 0 and tostring(btns[0]) or '-',
        n > 0 and tostring(btns[n - 1]) or '-' }, '|')
    local view = table.concat({ #bi.filtered_button, vs.building_job_filter_str }, '|')
    return list, view, n
end

local function on_list_change(bi, bld, d, map, n)
    local tok = bi.current_custom_category_token
    local view = view_of(bi, tok, d)
    if n == 0 then
        last_view = 'closed'
        return
    end
    if not same_bld(bi.button[0], bld) then return end     -- a switch, not rebuilt yet
    if view == 'top' then
        prune_top(bi, d)
    elseif view == 'category' then
        if d.ready_n > 0 then file_category(bi, bld, d, map) end
    elseif view == 'root' then
        fill_root(bi, bld, d)
    elseif view == 'base' then
        fill_base(bi, bld, d, d.base_of_token[tok])
    elseif view == 'kind' then
        fill_kind(bi, bld, d, d.kind_of_token[tok], map)
    elseif view == 'jobs' then
        if last_view == 'kind' then
            -- Opened from a kind folder. A job row must name the metal
            -- opened; one that does not (a number DF lost, IN PLAY in the
            -- header) is taken out before it can become a job.
            local NEWJOB = df.interface_button_building_new_jobst
            local wrong, total = {}, 0
            local btns = bi.button
            for i = 0, #btns - 1 do
                local b = btns[i]
                if b._type == NEWJOB then
                    total = total + 1
                    if b.material ~= bi.material or b.matgloss ~= bi.matgloss then
                        wrong[tostring(b)] = b
                    end
                end
            end
            local list = {}
            for _, b in pairs(wrong) do list[#list + 1] = b end
            if #list > 0 then
                for _, name in ipairs({ 'button', 'filtered_button', 'press_button' }) do
                    local vec = bi[name]
                    for i = #vec - 1, 0, -1 do
                        if wrong[tostring(vec[i])] then vec:erase(i) end
                    end
                end
                delete_all(list)
                clamp(bi)
                -- WARNING: those jobs cannot be queued from here.
                log('WARNING', ('%d of %d job rows for material %d named another'
                    .. ' material and were taken out.'):format(#list, total, bi.matgloss), 'JOBS')
            else
                log('DETAIL', ('%d job rows, all on material %d.'):format(total, bi.matgloss), 'JOBS')
            end
            -- The kind's token back, so DF's Back (material to none) returns
            -- to the kind folder.
            if restore_token then bi.current_custom_category_token = restore_token end
        end
    end
    last_view = view
end

local function poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end
    -- The gap since the last poll. On the poll that files a category list
    -- it is the frame DF built the list in; the gap before it is a plain
    -- frame to set it against (the filing line).
    local now = dfhack.getTickCount()
    frame_ms_before, frame_ms = frame_ms, prev_tick and (now - prev_tick) or nil
    prev_tick = now
    drain(DRAIN_BUDGET_MS)
    local d = load_defs()
    if not d then return end
    prune_manager()
    local mi = df.global.game.main_interface
    local vs, bi = mi.view_sheets, mi.building
    if not vs.open then return end
    local bld = df.building.find(vs.viewing_bldid)
    if not bld or not is_forge(bld) then
        list_stamp, view_stamp = nil, nil
        return
    end
    local list, view, n = stamps(bi, vs)
    if list == list_stamp and view == view_stamp then return end
    if list ~= list_stamp then
        local token_was = bi.current_custom_category_token
        on_list_change(bi, bld, d, load_map(), n)
        -- A token written here (cleared in a kind folder, put back on a
        -- job list) is not a list DF built: the view on screen stays the
        -- one this service named.
        if token_was ~= bi.current_custom_category_token and view_of(bi, token_was, d) == 'kind' then
            last_view = 'kind'
        end
    end
    list_stamp, view_stamp = stamps(bi, vs)
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- An RM service: it follows the data (refinish_steel.lua, RM'S SERVICES
-- FOLLOW THE DATA), started once RM's data is in RAM and stopped before
-- it leaves. On the dispatcher, paused included, because the task menu
-- is used while paused; its own timer only if the dispatcher is missing.
-- Nothing here outlives a stop: the lists are DF's to rebuild.
-- ==========================================
-- poll is handed over bare: the dispatcher calls every subscriber inside
-- its own pcall and logs a fault once per session by name, so a fault is
-- seen rather than swallowed. The fallback timer does the same itself.
local fallback_fault_logged = false
local function guarded_poll()
    local ok, err = pcall(poll)
    if not ok and not fallback_fault_logged then
        fallback_fault_logged = true
        log('ERROR', 'poll fault: ' .. tostring(err), 'POLL')
    end
end

function start()
    drain(math.huge, true)
    reset()
    fallback_fault_logged = false
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(REPEAT_KEY, {
            every = POLL_FRAMES, fn = poll, paused = true }) then
        repeatUtil.cancel(REPEAT_KEY)
    else
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', guarded_poll)
    end
    log('DETAIL', 'active.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(REPEAT_KEY) end
    drain(math.huge, true)    -- every button this service still holds goes before a stop
    reset()
    log('DETAIL', 'stopped.', 'STOP')
end