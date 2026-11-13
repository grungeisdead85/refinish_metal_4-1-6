--@ module = true
-- refinish-menu-back.lua
-- ==========================================
-- BACK IN EVERY REACTION FOLDER
-- ==========================================
-- DF's Back control presses the last entry of the task menu's `button`
-- that is not a row (button only). A category list gets one from DF (a
-- category button for NONE), and so does a metal's job list; a reaction
-- folder (a custom category: the CATEGORY a reaction is filed under)
-- gets none, and there the control reads Cancel and shuts the whole
-- panel. MEASURED 2026-10-02 (refinish-forge-menu-probe, the run is in
-- refinish-menu-forge.lua's header). A mistake in a folder then costs
-- the way out and the whole way back in, and RM's finishing reactions at
-- the smelter sit four folders deep:
--   refinish metal bars > refinish steel bars > colour-based > gem finish
--
-- This service puts a Back entry last in every reaction folder DF builds,
-- at any building: a folder button for the folder's parent category, or
-- for none when the folder sits at the top (or straight inside a forge's
-- item category). Pressing it sets that token and DF builds the parent's
-- view, the way refinish-menu-forge.lua's Back entries already work at
-- the forge. It is general on purpose: any reaction folder, RM's, a
-- module's or another mod's, gets Back, and nothing else in a list is
-- touched.
--
-- LEFT ALONE
--   * a job list (a material is open) and the top level (no folder).
--   * a list that already has an entry after its rows: `button` longer
--     than press_button, which holds the rows alone. DF's own Back, or
--     another service's, is there already.
--   * refinish-menu-forge.lua's own folders (REFINISH_STEEL_CAT_FORGE_),
--     which that service fills and gives their Back.
--   * a folder whose category is not in the reaction categories: its
--     parent is unknown, and a Back to the wrong place is worse than none.
--
-- OWNERSHIP. The entry is made here and left in `button`, so it is DF's
-- to delete when it rebuilds or closes the list (refinish-menu-forge.lua,
-- OWNERSHIP: THE RULE THAT PREVENTS A CRASH). This file deletes nothing,
-- and touches a list only when DF built it for the building in view:
-- `button` not empty and its first entry on that building.
--
-- THE ENTRY'S FIELDS. At the forge an entry read Back only when it
-- carried DF's own Back fields (leave_button, flag, search text); with
-- them zeroed it read Cancel (refinish-menu-forge.lua, new_back). DF's
-- own, read off the forge's category list in play (2026-10-02, the
-- forge service's CATEGORY line): leave_button true, flag 0, search text
-- ' (opens menu)'. Those are the defaults here, since a building with no
-- item categories (the smelter) never shows a category list to read them
-- from. DF's own are read again off any category list this service sees,
-- and used from then on.
-- ==========================================

local repeatUtil = require('repeat-util')
local REPEAT_KEY  = 'refinish-menu-back'
local POLL_FRAMES = 1      -- rides the menu: a rebuild is answered next frame

-- refinish-menu-forge.lua's folders: refinished metals and a folder per
-- base metal. That service gives them their Back.
local FORGE_FOLDER_PREFIX = 'REFINISH_STEEL_CAT_FORGE_'

local CUSTCAT = df.interface_button_building_custom_category_selectorst
local CATSEL  = df.interface_button_building_category_selectorst

-- DF's own Back fields, measured (THE ENTRY'S FIELDS).
local DEFAULT_BACK = { leave_button = true, flag = 0, filter_str = ' (opens menu)' }

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. Every line reaches the log on disk; the panel's Log
-- Detail setting decides what shows. No console prints.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MENU_BACK'
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
            tostring(subject or '-'), tostring(typ or 'UNTYPED'), tostring(msg))
    end
    _G.refinish_log_event(line)
end

-- ==========================================
-- STATE
-- ==========================================
local stamp            -- the list as this service last left it
local back_tmpl        -- DF's own Back fields, read off a category list
local parents, parents_n  -- category id -> parent id, and the array length read
local logged           -- folder token -> its Back was logged this session

local function reset()
    stamp, back_tmpl = nil, nil
    parents, parents_n = {}, -1
    logged = {}
end
reset()

-- ==========================================
-- SMALL HELPERS
-- ==========================================
-- Identity by address: refs compare equal only when type AND pointer
-- match (Lua_API), and a building read off a button need not carry the
-- same type as the one df.building.find returns. As refinish-menu-forge.
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

-- The list's stamp: the building, the view, its length and its two ends.
-- DF rebuilds the list on a press, never on its own and never while a
-- search is typed (refinish-menu-forge.lua's header), so an unchanged
-- stamp is an unchanged list.
local function stamp_of(vs, bi)
    local btns = bi.button
    local n = #btns
    return table.concat({ vs.viewing_bldid, bi.category, bi.material,
        bi.current_custom_category_token, n,
        n > 0 and tostring(btns[0]) or '-',
        n > 0 and tostring(btns[n - 1]) or '-' }, '|')
end

-- ==========================================
-- WHERE A FOLDER'S BACK GOES
-- ==========================================
-- The folder's parent category, from the reaction categories (each with
-- its id, name and parent, the parent "" at the top). Read again whenever
-- the array's length changes (modules add theirs at Step 2, RM at Step
-- 5). A parent that is not itself a category is drawn at the top, as
-- refinish-index-reaction.lua's own tree treats it, so its Back goes to
-- the top. nil for a folder whose category is not there at all.
-- ==========================================
local function parent_of(tok)
    local cats = df.global.world.raws.reactions.reaction_categories
    local n = #cats
    if n ~= parents_n then
        local t = {}
        for i = 0, n - 1 do
            local c = cats[i]
            t[c.id] = c.parent
        end
        parents, parents_n = t, n
    end
    local p = parents[tok]
    if p == nil then return nil end
    if p ~= '' and parents[p] == nil then return '' end
    return p
end

-- ==========================================
-- THE ENTRY
-- ==========================================
-- A folder button for the parent's token, put in `button` only and last,
-- where DF's Back control presses it. hotkey is never set: a copied
-- hotkey would give two entries one key.
local function new_back(bld, token)
    local t = back_tmpl or DEFAULT_BACK
    local b = CUSTCAT:new()
    b.bd = bld
    b.custom_category_token = token
    b.filter_str = t.filter_str
    b.hotkey = 0
    b.leave_button = t.leave_button
    b.alpha_order = 0
    b.flag.whole = t.flag
    return b
end

-- DF's own Back, when the list in view is a category list: the last entry
-- of `button`, after the rows, a category button for NONE.
local function read_back(bi, n)
    if n <= #bi.press_button then return end
    local last = bi.button[n - 1]
    if last._type ~= CATSEL or last.category ~= -1 then return end
    local t = { leave_button = last.leave_button, flag = last.flag.whole,
        filter_str = last.filter_str }
    local was = back_tmpl or DEFAULT_BACK
    back_tmpl = t
    if t.leave_button ~= was.leave_button or t.flag ~= was.flag or t.filter_str ~= was.filter_str then
        log('DETAIL', ("DF's Back on a category list: leave_button %s, flag %s, search text"
            .. " '%s'. Back entries here carry the same."):format(tostring(t.leave_button),
            tostring(t.flag), t.filter_str), 'TEMPLATE')
    end
end

-- ==========================================
-- ONE FRAME
-- ==========================================
local function poll()
    if not dfhack.isMapLoaded() then return end
    local mi = df.global.game.main_interface
    local vs, bi = mi.view_sheets, mi.building
    if not vs.open then
        stamp = nil
        return
    end
    local now = stamp_of(vs, bi)
    if now == stamp then return end
    stamp = now
    local n = #bi.button
    if n == 0 then return end
    local bld = df.building.find(vs.viewing_bldid)
    if not bld or not same_bld(bi.button[0], bld) then return end   -- not rebuilt for it yet
    read_back(bi, n)

    local tok = bi.current_custom_category_token
    if tok == '' or bi.material ~= -1 then return end
    if tok:find(FORGE_FOLDER_PREFIX, 1, true) == 1 then return end
    if n > #bi.press_button then return end
    local parent = parent_of(tok)
    if parent == nil then
        if not logged[tok] then
            logged[tok] = true
            -- WARNING: this folder keeps DF's Cancel.
            log('WARNING', ("folder %s is not among the reaction categories, so it has"
                .. " no Back."):format(tok), 'FOLDER')
        end
        return
    end

    bi.button:insert('#', new_back(bld, parent))     -- Back, button only
    stamp = stamp_of(vs, bi)
    if not logged[tok] then
        logged[tok] = true
        log('DETAIL', ('Back put in folder %s, to %s.'):format(tok,
            parent ~= '' and parent or 'the top'), 'FOLDER')
    end
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- An RM service, started and stopped with the others (refinish_steel.lua,
-- RM'S SERVICES FOLLOW THE DATA). On the dispatcher, paused included,
-- because the task menu is used while paused; its own timer only if the
-- dispatcher is missing. Nothing here outlives a stop: an entry already
-- in a list is DF's to delete.
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
    reset()
    log('DETAIL', 'stopped.', 'STOP')
end
