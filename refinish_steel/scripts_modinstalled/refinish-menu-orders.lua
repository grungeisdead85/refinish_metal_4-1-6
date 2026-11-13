--@ module = true
-- refinish-menu-orders.lua
-- ==========================================
-- THE WORK ORDER CONDITIONS: A TWIN READS WHAT IT IS
-- ==========================================
-- A twin carries its source's own name (refinish-stockpile-windows.lua,
-- the header), so where DF lists a twin beside its source the two read
-- the same. A work order condition's Material list is one such place: it
-- listed 35,559 materials for a condition on a boulder, the twins among
-- them. SEEN in play 2026-10-15: "Clay" twice, the clay and its binder
-- twin, and "Black stoneware clay" three times: a clay that is stone, its
-- binder twin and, by the code, its aggregate twin, since every stone
-- gets one under its own name (refinish-material-aggregate.lua). There a
-- twin is a real entry, since a condition counting binder stacks or
-- gravel has to name the twin those items are made of, so it is labelled
-- rather than edited out, as the stockpile settings got "Granite
-- (aggregate)".
--
-- ---- WHAT A ROW IS DRAWN FROM ----
-- MEASURED 2026-10-15 (refinish-order-label-probe, the same Material list
-- opened three times, 35 binder twins, the game paused):
--   * The list's own string for each row (compare_master, one per row) is
--     its search text only. " (binder)" written on every twin row's
--     string, and never taken off by DF, showed nowhere.
--   * A row is drawn from its material's name (state_name). With the
--     twins' names carrying " (binder)" the rows read "Clay (binder)",
--     and DF built the rows' search text from the names as it built the
--     list, so typing "binder" finds them too.
--   * The adjective (state_adj), labelled in the third opening, did not
--     show: only the second opening showed a label.
-- No row holds a name of its own, so the label can only be on the
-- material's name. Every screen reads that name, so it carries the label
-- only while a work order's conditions are open (THE NAME WINDOW).
--
-- ---- THE NAME WINDOW ----
-- The first frame a work order's conditions are open, every material the
-- stockpile window service knows a menu tag for (its tagged(): every claim
-- or hide that names a menu_tag, such as the aggregate twins' "aggregate",
-- Making Fuel's binder twins' "binder" and its fuel wood twins' "fuel
-- wood") gets " (tag)" on its name, in every state that has one. When they
-- close, each name goes back. DF builds the Material list after the
-- conditions open,
-- from a button, so the names are in place before any build: the probe's
-- second opening was labelled the same way, at the opening.
--
-- OPEN is what DFHack's own focus string calls that screen (Gui.cpp,
-- dwarfmode/Info/WORK_ORDERS/Conditions): the info panel open, on its
-- work orders, with the conditions up. So a conditions flag left set
-- behind a closed panel, should DF ever leave one, labels nothing.
--
-- Only the name changes. Never an id, so the ledger (refinish-ledger.lua,
-- which keys everything by id) and every lookup by token read nothing
-- different; never a flag; and never the adjective.
--
-- ---- WHERE ELSE A LABELLED NAME CAN SHOW ----
-- Only while that screen is up, and only in what is written in that time
-- and names a twin's material: by inference, the condition rows on the
-- same screen ("clay (binder) binder"). Nothing else can be: the game
-- does not run while that screen is up. In play (2026-10-15) it cannot
-- be unpaused with the work orders up, and DFHack counts the game paused
-- while the info panel is open (World::ReadPauseState,
-- main_interface.info.open), which THE NAME WINDOW requires. So no job
-- finishes, nothing is made and DF announces nothing while a twin carries
-- its tag. That same list was wrong about the material picker
-- (refinish-stockpile-windows.lua, HIDING THE TWINS IN THE MENUS), so each
-- closing logs whether the game ran while the conditions were open, as a
-- standing check. No save sees one: the names
-- go back the frame the options screen is up or a save is under way
-- (_G.refinish_menu_locked, set by refinish-save-hook.lua, and
-- _G.refinish_autosave_in_progress, set by refinish-autosave.lua), and at
-- stop(), which RM runs before any clear (refinish_steel.lua, RM'S
-- SERVICES FOLLOW THE DATA), and with it at every map unload. The twins
-- are out of RAM before DF writes a save in any case.
--
-- ---- PUT BACK ONLY WHAT IS STILL OURS ----
-- Each change is recorded with its material's token, the state, the text
-- before and the text after. A name goes back only where the same token
-- still sits at that address and the name still reads the labelled text,
-- so a twin rebuilt or removed in between is never written to. RM stops
-- this service before a data cycle and starts it after (RM'S SERVICES
-- FOLLOW THE DATA), so the twins under an open window do not change: a
-- name that could not go back is counted in the closing line.
-- ==========================================

local repeatUtil = require('repeat-util')
local REPEAT_KEY  = 'refinish-menu-orders'
local POLL_FRAMES = 1      -- the opening is caught on its first frame

-- Every state a material can name: matter_state Solid 0 to Pressed 5
-- (df-structures), read off the enum, with that value standing in.
local LAST_STATE = 5
pcall(function() LAST_STATE = df.matter_state._last_item end)

-- The info panel's work orders mode (df-structures,
-- info_interface_mode_type: NONE -1, CREATURES, JOBS, BUILDINGS, LABOR,
-- WORK_ORDERS 4), read off the enum, with that value standing in.
local WORK_ORDERS = 4
pcall(function() WORK_ORDERS = df.info_interface_mode_type.WORK_ORDERS end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. SUBJECT: OPEN and CLOSE for the window, START and STOP.
-- DETAIL for the routine opening and closing, WARNING when the window
-- service cannot say what is tagged, ERROR for a fault, once each.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MENU_ORDERS'
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
-- STATE (reset by start)
-- ==========================================
local record   = nil    -- the open window's changes, or nil: { token, mt, mi, st, old, new }
local open_was = false  -- the window as the last poll left it
local tick_at  = nil    -- cur_year_tick when it opened: did the game run underneath?
local said     = {}     -- messages already logged, once each

local function once(typ, msg, subject)
    if said[msg] then return end
    said[msg] = true
    log(typ, msg, subject)
end

-- ==========================================
-- LABELLING
-- ==========================================
-- One material: " (tag)" on its name in every state that has one and does
-- not carry it already. Returns how many names it changed.
local function label_one(mt, mi, tag)
    local info = dfhack.matinfo.decode(mt, mi)
    if not (info and info.material) then return 0 end
    local token = info:getToken()
    local names = info.material.state_name
    local suffix = ' (' .. tag .. ')'
    local n = 0
    for st = 0, LAST_STATE do
        local s = names[st]
        if s ~= '' and s:sub(-#suffix) ~= suffix then
            names[st] = s .. suffix
            record[#record + 1] = { token = token, mt = mt, mi = mi, st = st,
                old = s, new = s .. suffix }
            n = n + 1
        end
    end
    return n
end

-- Every tagged material, asked of the window service at the opening (THE
-- NAME WINDOW). A material that cannot be labelled costs only itself.
local function label_all()
    local wapi = _G.refinish_window_api
    if not (wapi and wapi.tagged) then
        -- WARNING: twins read as their sources in the work order conditions.
        once('WARNING', "RM's stockpile window service has no tagged(), so no twin is"
            .. ' labelled in the work order conditions this session.', 'OPEN')
        return
    end
    local t0 = os.clock()
    local ok, list = pcall(wapi.tagged)
    if not ok or type(list) ~= 'table' then
        once('ERROR', 'the window service could not say what is tagged: ' .. tostring(list), 'OPEN')
        return
    end
    record = {}
    local mats, faults = 0, 0
    for _, e in ipairs(list) do
        local okl, n = pcall(label_one, e[1], e[2], e[3])
        if not okl then
            faults = faults + 1
            once('ERROR', ('material %s:%s could not be labelled: %s'):format(tostring(e[1]),
                tostring(e[2]), tostring(n)), 'OPEN')
        elseif n > 0 then
            mats = mats + 1
        end
    end
    tick_at = df.global.cur_year_tick
    log('DETAIL', ('work order conditions opened: %d tagged material(s), %d of them labelled'
        .. ' (%d name(s)), in %.1f ms%s.'):format(#list, mats, #record, (os.clock() - t0) * 1000,
        faults > 0 and (', %d could not be'):format(faults) or ''), 'OPEN')
end

-- Every recorded name back, last first, where it is still ours (PUT BACK
-- ONLY WHAT IS STILL OURS). why names the moment for the log.
local function put_back(why)
    if not record then return end
    local n, total = 0, #record
    for i = total, 1, -1 do
        local r = record[i]
        pcall(function()
            local info = dfhack.matinfo.decode(r.mt, r.mi)
            if info and info.material and info:getToken() == r.token
               and info.material.state_name[r.st] == r.new then
                info.material.state_name[r.st] = r.old
                n = n + 1
            end
        end)
    end
    record = nil
    local ran = '?'
    pcall(function()
        if tick_at then ran = (df.global.cur_year_tick ~= tick_at) and 'ran' or 'did not run' end
    end)
    tick_at = nil
    log('DETAIL', ('%s: %d of %d labelled name(s) put back%s; the game %s while they were'
        .. ' open.'):format(why, n, total, n < total
        and (', %d no longer ours'):format(total - n) or '', ran), 'CLOSE')
end

-- ==========================================
-- THE POLL
-- ==========================================
-- Every frame, paused included: the work orders are used paused. The
-- window is open while the conditions are, as THE NAME WINDOW defines
-- open, unless the options screen is up or a save is under way (WHERE
-- ELSE A LABELLED NAME CAN SHOW). Every term is a boolean, so open is
-- one too. It acts only on a change, so a frame with nothing changing
-- costs a few reads.
local function poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end
    local info = df.global.game.main_interface.info
    local open = info.open and info.current_mode == WORK_ORDERS
        and info.work_orders.conditions.open
        and not _G.refinish_menu_locked and not _G.refinish_autosave_in_progress
    if open == open_was then return end
    open_was = open
    if open then
        label_all()
    elseif _G.refinish_menu_locked or _G.refinish_autosave_in_progress then
        put_back('the options screen or a save came up')
    else
        put_back('work order conditions closed')
    end
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- An RM service: it follows the data (refinish_steel.lua, RM'S SERVICES
-- FOLLOW THE DATA). On the dispatcher, paused included; its own timer only
-- if the dispatcher is missing. poll is handed over bare: the dispatcher
-- calls every subscriber inside its own pcall and logs a fault once per
-- session by name. The fallback timer does the same itself.
local fallback_fault_logged = false
local function guarded_poll()
    local ok, err = pcall(poll)
    if not ok and not fallback_fault_logged then
        fallback_fault_logged = true
        log('ERROR', 'poll fault: ' .. tostring(err), 'POLL')
    end
end

function start()
    -- A record left by a run that never stopped goes back first.
    pcall(put_back, 'started with names still labelled')
    record, open_was, tick_at, said = nil, false, nil, {}
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

-- Every name back before anything else: RM stops its services before any
-- clear, while the twins still exist.
function stop()
    pcall(put_back, 'stopped')
    open_was = false
    repeatUtil.cancel(REPEAT_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(REPEAT_KEY) end
    log('DETAIL', 'stopped.', 'STOP')
end
