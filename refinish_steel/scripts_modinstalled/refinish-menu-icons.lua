--@ module = true
-- refinish-menu-icons.lua
-- ==========================================
-- RM BUILD MENU ICON STAMPER
-- ==========================================
-- DF stores the build menu's icons per button at
--   main_interface.construction.page[P].bb_button[B].texpos
-- and rebuilds those pages when the menu opens or the player
-- navigates categories, which reverts any one-shot write. So this
-- is a poller in the sand button's mold: whenever the structure
-- is populated, every configured building's buttons are checked
-- and restamped if DF's rebuild wiped them.
--
-- ICON SOURCES, two kinds:
--   1. AUTO: every def in world.raws.buildings.all whose code
--      begins with a registered module prefix and whose
--      list_icon_texpos is nonzero gets that same icon in the
--      menu. Injected buildings are covered with zero config:
--      declare icon_image in the module schema and both surfaces
--      follow. Reserved range texpos render fine in the menu
--      (proven live on the retort).
--   2. CONFIG: name -> BUILDING_ICONS cell, for adopting vanilla
--      or raws buildings (soap maker, screw press) whose parse
--      assigned them the generic tile.
--
-- Buttons are matched by name: case insensitive comparison of the
-- configured name against every string field on the button, since
-- the button does not carry the def. All matching buttons across
-- all pages are stamped (a building can appear in more than one
-- category page).
--
-- COMMANDS
--   refinish-menu-icons start | stop | status
--   refinish-menu-icons list      dump every button (open menu first)
--   refinish-menu-icons stamp     one manual pass, printing each write
--
-- ---- COST, AND WHY THE FULL PASS NO LONGER RUNS EVERY FRAME ----
-- MEASURED 2026-09-24: 72.7 ms per second of wall time, 100 calls a
-- second at 0.73 ms each, the largest loop in the session. Every frame
-- the old pass rebuilt the whole target table (every building def, and
-- every texture page with a string made per page) and then, for every
-- button on every page, built a closure, reflected over every field of
-- the DF struct and lowercased each string field into a new table.
--
-- Its only gate was an empty page vector, and that gate never closes:
-- #construction.page reads 1 with the build menu shut (console, same
-- day). So the whole pass ran on every frame of play.
--
-- Now each frame compares the pages against a copy of what they held
-- after the last pass: the page count, each page's button count and
-- each button's texpos, a few dozen integer reads. Only a difference
-- runs the pass. DF rebuilding a page writes its own texpos back, which
-- is a difference, so a restamp still lands the frame after a rebuild,
-- exactly as before. The target table is rebuilt only when one of the
-- things it is built from changes.
-- ==========================================

-- Every frame, because a rebuilt page shows DF's generic tile for as
-- long as the stamper waits, and the check that runs each frame is now
-- a handful of reads.
local POLL_FRAMES = 1


-- ==========================================
-- CONFIG: ADOPTED BUILDINGS
-- ==========================================
-- name  : matched against button strings, case insensitive
-- cell  : {col, row} on the page named by page (8 wide, 16 tall
--         for BUILDING_ICONS, zero indexed)
-- Pick the cells off the png; the two below are PLACEHOLDERS on
-- the generic tile so a wrong guess of mine cannot mislabel
-- anything. Set them and restart the stamper.
-- ==========================================
local ADOPTED = {
    { name = "Soap Maker",  page = "BUILDING_ICONS", cell = { 2, 12 } },
    { name = "Screw Press", page = "BUILDING_ICONS", cell = { 1, 12 } },
}


-- ==========================================
-- SESSION STATE
-- ==========================================
_G.refinish_menu_icons_running = _G.refinish_menu_icons_running or false
-- Session stamp so a stale timeout closure from before a map
-- unload can never fire into a fresh session (house pattern).
_G.refinish_menu_icons_session = (_G.refinish_menu_icons_session or 0)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- RM's own, and peripheral rather than pipeline. Every log line this
-- file writes goes through log(), in the one grammar the log panel
-- reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: STAMP for a restamped button,
-- START and STOP for the poller.
--
-- This replaces a log() that took the subsystem as an argument and
-- let refinish-log guess TYPE from the words (read_type).
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here. The prints in COMMANDS at
-- the bottom answer commands typed at the console, as does the one in
-- stamp_pass, which only prints for the typed stamp command.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MENU_ICONS'
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
-- TARGET TABLE
-- ==========================================
-- name_lower -> texpos. Built from the live defs and pages, so a def
-- injected or cleared mid session is always reflected: TARGET CACHE
-- below decides when a rebuild is due, which is no longer every pass.
-- ==========================================

local function resolve_page_cell(token, c, r)
    for _, p in ipairs(df.global.texture.page) do
        if tostring(p.token) == token then
            if c < p.page_dim_x and r < p.page_dim_y then
                return p.texpos[r * p.page_dim_x + c]
            end
            return nil
        end
    end
    return nil
end

local function build_targets()
    local targets = {}

    -- ---- AUTO: owned defs with a panel icon ----
    local registry = _G.refinish_module_registry or {}
    for _, d in ipairs(df.global.world.raws.buildings.all) do
        if d.list_icon_texpos and d.list_icon_texpos ~= 0 then
            for prefix, _ in pairs(registry) do
                if string.sub(d.code, 1, #prefix) == prefix then
                    targets[string.lower(d.name)] = d.list_icon_texpos
                    break
                end
            end
        end
    end

    -- ---- CONFIG: adopted vanilla and raws buildings ----
    for _, a in ipairs(ADOPTED) do
        local v = resolve_page_cell(a.page, a.cell[1], a.cell[2])
        if v and v ~= 0 then
            targets[string.lower(a.name)] = v
        end
    end

    return targets
end


-- ==========================================
-- TARGET CACHE
-- ==========================================
-- build_targets() above runs only when one of its three inputs changes:
--   * the building defs, which a module inject or clear changes;
--   * the module registry, which the engine replaces with a new table
--     at every data cycle, so each cycle rebuilds exactly once;
--   * the texture pages, which the adopted cells are read from.
-- Two lengths and one table identity, read every frame. Cleared by
-- start_stamper and stop_stamper, so a new session always rebuilds.
-- ==========================================
local targets = nil
local targets_defs, targets_pages, targets_reg = -1, -1, nil

-- The table, and true when it was rebuilt by this call.
local function current_targets()
    local n_defs = #df.global.world.raws.buildings.all
    local n_pages = #df.global.texture.page
    local reg = _G.refinish_module_registry
    if targets and n_defs == targets_defs and n_pages == targets_pages
       and reg == targets_reg then
        return targets, false
    end
    targets = build_targets()
    targets_defs, targets_pages, targets_reg = n_defs, n_pages, reg
    return targets, true
end


-- ==========================================
-- STAMP PASS
-- ==========================================
-- Walks every button on every page. For each, gathers its string
-- fields once and checks them against every target name. Writes
-- only when the stored texpos differs, so a settled menu costs
-- comparisons and no writes.
--
-- Rare now: it runs when the page snapshot below says something
-- changed, or when the targets were rebuilt. The reflection over every
-- field is kept for that reason, because the one field that carries the
-- name has not been identified, and at this rate it costs nothing worth
-- measuring. `refinish-menu-icons list` prints the fields if it is ever
-- wanted.
--
-- Returns how many buttons it wrote and, per target name, how many of
-- them, for the one summary line the caller writes. verbose is the typed
-- `stamp` command, which prints each write as its direct answer.
-- ==========================================

local function stamp_pass(tg, verbose)
    local ok, con = pcall(function()
        return df.global.game.main_interface.construction
    end)
    if not ok or not con or not con.page or #con.page == 0 then
        return 0, {}
    end

    local wrote, names = 0, {}

    for p = 0, #con.page - 1 do
        local pg = con.page[p]
        local n = 0
        pcall(function() n = #pg.bb_button end)

        for b = 0, n - 1 do
            local ok2 = pcall(function()
                local btn = pg.bb_button[b]

                local strs = {}
                for k, v in pairs(btn) do
                    if type(v) == 'string' and v ~= '' then
                        table.insert(strs, string.lower(v))
                    end
                end

                for name, tex in pairs(tg) do
                    for _, s in ipairs(strs) do
                        if s == name or s:find(name, 1, true) then
                            if btn.texpos ~= tex then
                                local before = btn.texpos
                                btn.texpos = tex
                                wrote = wrote + 1
                                names[name] = (names[name] or 0) + 1
                                if verbose then
                                    print(string.format(
                                        "[%s] page %d button %d: %d -> %d.",
                                        name, p, b, before, tex))
                                end
                            end
                            break
                        end
                    end
                end
            end)
            if not ok2 and verbose then
                print(string.format("button [%d][%d] unreadable", p, b))
            end
        end
    end

    return wrote, names
end


-- ==========================================
-- PAGE SNAPSHOT
-- ==========================================
-- What the pages held after the last pass, our stamps included:
-- seen_n[p] is page p's button count and seen_tex[p][b] each button's
-- texpos. The rows are reused rather than rebuilt, so a settled menu
-- allocates nothing here. seen_pages is -1 when there is no snapshot.
--
-- A button that will not read (a null entry) reads as -1 both times,
-- so it neither trips the check nor hides a change beside it.
-- ==========================================
local seen_pages = -1
local seen_n, seen_tex = {}, {}

local function button_texpos(list, b)
    local btn = list[b]
    return btn and btn.texpos or -1
end

local function pages_unchanged(con)
    local np = #con.page
    if np ~= seen_pages then return false end
    for p = 0, np - 1 do
        local list = con.page[p].bb_button
        local n = #list
        if n ~= seen_n[p] then return false end
        local row = seen_tex[p]
        for b = 0, n - 1 do
            if button_texpos(list, b) ~= row[b] then return false end
        end
    end
    return true
end

local function remember_pages(con)
    local np = #con.page
    for p = 0, np - 1 do
        local list = con.page[p].bb_button
        local n = #list
        local row = seen_tex[p]
        if not row then
            row = {}
            seen_tex[p] = row
        end
        for b = 0, n - 1 do row[b] = button_texpos(list, b) end
        seen_n[p] = n
    end
    seen_pages = np
end

local function reset_caches()
    targets, targets_defs, targets_pages, targets_reg = nil, -1, -1, nil
    seen_pages, seen_n, seen_tex = -1, {}, {}
end


-- ==========================================
-- ONLY WHILE THE BUILD MENU CAN SHOW
-- ==========================================
-- MEASURED 2026-09-30 (section probe, 267 s): the pages check below
-- ran 19,733 times with the bottom menu in mode NONE, 2.60 ms/sec, plus
-- 1.02 for the targets, and never once found a change there. All 15
-- restamps came in mode BUILDING. The page list outlives the menu (the
-- engine notes record it reading 1 with the menu closed), so #con.page
-- alone cannot say the menu is open, and the tick now runs only in the
-- build menu's own modes. A page DF rebuilt while the menu was closed
-- still differs from the snapshot on the first tick it shows, and is
-- restamped there.
--
-- nil if the enum cannot be read: the tick then runs in every mode, as
-- it did before.
-- ==========================================
local BUILD_MODES = nil
pcall(function()
    local m = df.main_bottom_mode_type
    BUILD_MODES = {
        [m.BUILDING] = true,
        [m.BUILDING_PLACEMENT] = true,
        [m.BUILDING_PICK_MATERIALS] = true,
    }
end)

-- ==========================================
-- ONE FRAME
-- ==========================================
-- The cheap check, and the pass only when it fails. The snapshot is
-- taken AFTER the pass, so it holds our own stamps and the next frame
-- reads as unchanged until DF rebuilds something.
-- ==========================================
local function tick()
    local con = df.global.game.main_interface.construction
    if #con.page == 0 then return end
    if BUILD_MODES
       and not BUILD_MODES[df.global.game.main_interface.bottom_mode_selected] then
        return
    end
    -- SECTION CLOCK (refinish-section-probe): quiet while the probe is
    -- off. The laps carry the bottom menu's mode; they are how the gate
    -- above was found (ONLY WHILE THE BUILD MENU CAN SHOW).
    local sc = _G.refinish_section_clock
    local t0, mode = nil, 'unknown'
    if sc then
        t0 = sc.now()
        pcall(function()
            mode = tostring(df.main_bottom_mode_type[df.global.game.main_interface.bottom_mode_selected])
        end)
    end
    local tg, rebuilt = current_targets()
    if sc then t0 = sc.lap('menu icons: targets, mode ' .. mode, t0) end
    if not rebuilt and pages_unchanged(con) then
        if sc then sc.lap('menu icons: unchanged check, mode ' .. mode, t0) end
        return
    end
    if sc then t0 = sc.lap('menu icons: check that found a change, mode ' .. mode, t0) end

    local wrote, names = stamp_pass(tg, false)
    remember_pages(con)
    if sc then sc.lap('menu icons: stamp pass, mode ' .. mode, t0) end

    if wrote > 0 then
        local list = {}
        for name, count in pairs(names) do
            list[#list + 1] = count > 1 and (name .. ' x' .. count) or name
        end
        table.sort(list)
        -- DETAIL: DF rebuilds these pages whenever the menu opens or
        -- changes category, so this fires on every visit. One line per
        -- rebuild, where it used to be one line per button.
        log('DETAIL', string.format('%d button(s) restamped after a menu'
            .. ' rebuild: %s.', wrote, table.concat(list, ', ')), 'STAMP')
    end
end


-- ==========================================
-- POLL LOOP
-- ==========================================

local function schedule()
    local my_session = _G.refinish_menu_icons_session
    dfhack.timeout(POLL_FRAMES, 'frames', function()
        -- A closure from a dead session or a stopped stamper does
        -- nothing and does not reschedule.
        if not _G.refinish_menu_icons_running then return end
        if my_session ~= _G.refinish_menu_icons_session then return end
        local t_rec = dfhack.getTickCount()
        pcall(tick)
        -- Named in DFHack's own timers (NAMED FOR DFHACK'S TIMERS, in
        -- refinish-loop-dispatch.lua).
        local rec = dfhack.internal and dfhack.internal.recordRepeatRuntime
        if rec then pcall(rec, 'refinish-menu-icons', t_rec) end
        schedule()
    end)
end


-- ==========================================
-- MODULE EXPORTS
-- ==========================================
-- The core starts and stops the stamper through these; the
-- command dispatch below calls the same functions, so console and
-- lifecycle can never disagree about state.
-- ==========================================

function start_stamper()
    if _G.refinish_menu_icons_running then return false end
    _G.refinish_menu_icons_running = true
    _G.refinish_menu_icons_session = _G.refinish_menu_icons_session + 1
    reset_caches()
    schedule()
    log('DETAIL', "Stamper started.", 'START')
    return true
end

function stop_stamper()
    if _G.refinish_menu_icons_running then
        _G.refinish_menu_icons_running = false
        reset_caches()
        log('DETAIL', "Stamper stopped.", 'STOP')
    end
end

-- Loaded as a module by the core: expose the functions and skip
-- command dispatch silently.
if dfhack_flags and dfhack_flags.module then
    return _ENV
end


-- ==========================================
-- COMMANDS
-- ==========================================

local args = {...}
local cmd = args[1]

if cmd == 'start' then
    if start_stamper() then
        print("Menu icon stamper started.")
    else
        print("Menu icon stamper already running.")
    end

elseif cmd == 'stop' then
    stop_stamper()
    print("Menu icon stamper stopped.")

elseif cmd == 'status' then
    print(string.format("running: %s", tostring(_G.refinish_menu_icons_running)))
    local t = build_targets()
    for name, tex in pairs(t) do
        print(string.format("  target [%s] -> texpos %d", name, tex))
    end

elseif cmd == 'list' then
    local ok, con = pcall(function()
        return df.global.game.main_interface.construction
    end)
    if not ok or not con or #con.page == 0 then
        print("construction.page empty. Open the build menu, then rerun.")
        return
    end
    for p = 0, #con.page - 1 do
        local pg = con.page[p]
        local n = 0
        pcall(function() n = #pg.bb_button end)
        print(string.format("---- page %d: %d button(s) ----", p, n))
        for b = 0, n - 1 do
            pcall(function()
                local btn = pg.bb_button[b]
                local strs = {}
                for k, v in pairs(btn) do
                    if type(v) == 'string' and v ~= '' then
                        table.insert(strs, k .. '=' .. v)
                    end
                end
                print(string.format("  [%d][%2d] texpos=%-8d %s",
                    p, b, btn.texpos, table.concat(strs, '  ')))
            end)
        end
    end

elseif cmd == 'stamp' then
    -- A fresh target table, so a typed stamp never trusts a cache the
    -- running stamper might hold. The next frame then sees our writes
    -- as a change, runs one pass that writes nothing, and settles.
    local n = stamp_pass(build_targets(), true)
    print(string.format("stamped %d button(s).", n))

else
    print("refinish-menu-icons start | stop | status | list | stamp")
end