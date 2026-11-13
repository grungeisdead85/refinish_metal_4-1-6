--@ module = true
-- refinish-save-hook.lua
-- ==========================================
-- UNLOAD BEFORE EVERY GAME SAVE
-- ==========================================
-- WHY
--
-- A save written with RM's or a module's additions in the raws arrays
-- is corrupt: save & continue with data loaded corrupted saves in
-- the early save tests. RM's own save cycles (refinish-autosave.lua)
-- unload first. The game's save & continue is unloaded here, from the
-- moment the player asks for it. A save & quit is not unloaded here:
-- DF unloads the map before it writes one, and the unload failsafe in
-- refinish_steel.lua clears RAM there (SAVE & QUIT, below).
--
-- What both saves need from this file is the records, written while
-- site data can still be written. The tool wash's record
-- (refinish-tool-wash.lua) has to reach site data before the game
-- writes, or every owned tool comes back a cauldron: 288 of 288 with
-- the wash switched off, 2026-09-29. At the map unload site data can
-- no longer be written, which is why the unload failsafe cannot do
-- this job for tools. See WHEN DFHACK WRITES ITS DATA.
--
-- Since 2026-10-27 the tool record no longer waits for this file to see
-- the options screen: it is kept written from about a second after each
-- load (THE RECORD NO LONGER WAITS FOR THE OPTIONS SCREEN, below). The
-- ledger is still refreshed as the screen opens.
--
-- This replaces the ESC-menu data cycle, which unloaded RM whenever
-- the options screen opened (in AUTO), and its warning overlay.
--
-- MEASURED, refinish-save-probe.lua, 2026-09-29
--
--   Save & continue raises options.do_manual_save with
--   manual_save_timer at 5, counting down one per frame; the game
--   writes after it reaches 0 (51 frames in 13 seconds, that run). The
--   flag stays true after the save until the options screen opens
--   again, and the screen had closed after the save.
--
--   Save & quit never raises it. The options context becomes
--   MAIN_DWARF_SAVE_AND_EXIT_CHOICES, and in that run nothing else
--   changed until the map unloaded 87 frames later.
--
-- HOW
--
-- step() runs every frame, driven by refinish_steel.lua's monitor.
--
--   Save & continue: on the frame do_manual_save rises, unload
--   (refinish-shutdown SILENT). RM's Lua runs on the game's own thread,
--   so the countdown waits until the unload returns. Once the timer
--   has reached 0 and the options screen has closed, reload
--   (refinish-startup SILENT NOPROMPT), as the ESC cycle did.
--
--   Save & quit: nothing is unloaded here. See SAVE & QUIT.
--
-- Only what this file unloaded is reloaded: a player who shut RM down
-- by hand keeps it down until they start it again.
--
-- SAVE & QUIT, 2026-09-30. Until then this file unloaded RM on the
-- frame the context became the save and exit choices, since no field
-- marks the final choice, and reloaded when the player backed out.
-- That put a whole data cycle into a back-out, about 2 s to unload and
-- 12 s to reload in region4, for a save that never happened, and the
-- back-out was read off fields that outlive the screen, which once kept
-- RM unloaded and, with the pause held, the game locked paused. The
-- unload was never needed there: the records are refreshed when the
-- options screen opens, DF unloads the map before it writes a save &
-- quit, and the failsafe clears everything refinish-shutdown clears
-- (entity permissions, reactions, materials and every module's assets,
-- with the modules and RM's services stopped) before that write.
-- Measured 2026-09-29: a save & quit taken with RM's data loaded loaded
-- cleanly; its tools came back as jugs only because nothing recorded
-- them before the menu refresh existed.
--
-- WHEN DFHACK WRITES ITS DATA, read from DFHack's Core.cpp, 2026-09-29.
-- Every frame, Core's update writes DFHack's persistent data (site data
-- included, into save/current, which DF copies to the save's folder)
-- on the frame do_manual_save or autosave_request rises, or the save
-- screen appears, and only THEN runs the per-frame handlers, this file
-- among them. So on a save & continue, anything the unload writes to
-- site data misses that save. MEASURED the same day: test2, saved that
-- way, carried a census written 24 seconds before the request but not
-- the tool record the unload wrote, and all 288 tools came back
-- cauldrons. Save & quit escapes it: its data is written when the save
-- screen appears, after the map unload (region2 restored all 288).
--
-- Hence the records a save must carry, the tool record and the
-- material ledger, are refreshed when the options screen opens, which
-- every save from it passes through and which pauses the game: a read
-- and two writes, nothing unloaded. The unload writes nothing the save
-- depends on. Items keep their materials through every save since the
-- save wash was retired (2026-09-29), and the ledger moves them by name
-- on the next load. Until then a save & continue had to skip the wash
-- (a NOPAYLOAD argument), because its payload would have missed the
-- save while the washed items went into it.
--
-- THE RECORDS FOLLOW THE DATA CYCLE, NOT THE OPENING, 2026-10-25. Every
-- load and every reload, the hotsave's among them, consumes the stored
-- tool record (refinish-tool-wash.lua, settle), so from then until this
-- file's next refresh a save & quit carries no record and every owned
-- tool comes back a cauldron. Until this date the refresh ran only on
-- the frame the options screen opened, and the code left two ways for
-- that one frame to be lost:
--   * the screen opened while RM's own save cycle ran: step() records
--     the opening before its early return for that cycle, so the
--     opening was spent, and the cycle's reload then consumed the
--     record with nothing left to refresh it;
--   * a data cycle ran while the screen stayed up: the hotsave's hotkey
--     is bound with no context, so DFHack runs it with the options
--     screen up, and refinish-autosave.lua does not wait for the menu
--     the way the calendar does. Its reload consumed the record, and no
--     new opening came to refresh it.
-- Seen in play: a hotsave and a save & quit taken side by side, the
-- hotsave sound (it writes its own full record before its quicksave)
-- and the save & quit back with cauldrons; and a player reported their
-- dust coming back as cauldrons (2026-10-25). Which of the two ways
-- either save took is not confirmed by a log.
-- So the records are refreshed whenever the screen is up and they have
-- not yet been refreshed for the data cycle in RAM: st.records_for
-- against the module registry, which every load and reload replaces.
-- That is the first frame the screen is up, as before, and again after
-- any data cycle that runs while it stays up.
--
-- THE RECORD NO LONGER WAITS FOR THE OPTIONS SCREEN, 2026-10-27. SEEN in
-- play: a save & quit came back with every owned tool a cauldron, the
-- load after it logging "No washed items on record". The session that
-- wrote it logged no refresh at all from its load (18:54) to its map
-- unload (19:28), neither the tool record's line nor the ledger's, though
-- a save & quit can only be chosen from this screen. options_shown()
-- read only the first of DFHack's focus strings, and DFHack lists the
-- options screen after the strings of any other panel still flagged open:
-- a designation in progress, the announcement stack, an info panel, a
-- sheet, and more (DFHack Gui.cpp, add_main_interface_focus_strings).
-- With one of those present this file never saw the screen, refreshed
-- nothing and said nothing. Which one it was is not in the log: nothing
-- on that path wrote a line. The fix of 2026-10-25 had widened when the
-- refresh runs and left the record waiting on this file seeing the
-- screen, which was the fault itself. Since this date:
--   * the tool record is kept written from the load on, by the writer
--     this file drives every frame (THE MENU'S RECORD, BUILT AHEAD, AND
--     KEPT WRITTEN; refinish-tool-wash.lua, THE RECORD, KEPT WRITTEN), so
--     no save waits on anything being seen;
--   * the screen is looked for among every focus string of DF's own top
--     screen (EVERY FOCUS STRING), and options.open set while the fort's
--     screen shows no options screen is said once, a WARNING;
--   * every save says what record it carries: a save & continue as it is
--     asked for (WHAT A SAVE & CONTINUE CARRIES), a save & quit at the
--     map unload (refinish-tool-wash.lua, WHAT A SAVE CARRIES).
--
-- PRIMED, 2026-09-29. The options screen's fields belong to the game,
-- not the fort, and outlive a map: region2 loaded with the context
-- still on the save and exit choices from the quit that wrote it, which
-- read as a new request and unloaded RM a second after the load. The
-- first frame after reset() only takes the current flags as the
-- starting point, so nothing left over can act.
--
-- MEASURED WORKING, 2026-09-29, after all three fixes. From autosave 3
-- (288 owned tools, 17 refinished objects, AUTOSAVE protocol): a save &
-- continue (test3) and a save & quit (region2), each reloaded after a
-- full recycle. Both restored all 288 tools and all 17 finishes, needed
-- no remap, logged no error, and matched the census taken before the
-- saves in every count. region2 raised no unload after its load.
--
-- STILL UNHANDLED: a save through DF's autosave request (plotinfo.main
-- do_auto_save, which DFHack's quicksave sets) that RM did not start
-- itself. RM keeps vanilla autosave off, and its own cycles unload
-- first; a console quicksave with data loaded is not caught. The probe
-- logs those fields, so one run measures it.
-- ==========================================

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The one grammar the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE |
-- body. DETAIL for the routine unload and reload, since the shutdown
-- and startup summarise themselves; ERROR when one fails, because the
-- save then goes ahead with data loaded, or RM stays down.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SAVE_HOOK'
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
-- STATE
-- ==========================================
--   mode       'idle', 'continue' (unloaded for a save & continue), or
--              'refused' (a save & continue held back: A SAVE RM CANNOT
--              UNLOAD FOR IS HELD BACK)
--   prev_*     last frame's flags, so only a rising edge acts: the
--              manual save flag stays true after its save
--   saw_zero   the save & continue countdown has reached 0
--   primed     false until the first frame after reset() has taken
--              the current flags as its starting point (PRIMED)
--   prev_shown last frame's answer to "is the options screen up"
--   prev_open  last frame's options.open, whose rise writes the tool record
--              at once, whatever the focus says (THE MENU'S RECORD, BUILT
--              AHEAD, AND KEPT WRITTEN)
--   hold       true from this file's unload to its reload: the game is
--              held paused so no tick runs while RM's data is out of RAM
--              (THE PAUSE, HELD FROM UNLOAD TO RELOAD)
--   was_running the game was running when the hold began, so the reload
--              hands it back running
--   records_for the data cycle the records were last refreshed for while
--              the options screen has been up (the module registry, or
--              false when there is none), nil while the screen is down
--              (THE RECORDS FOLLOW THE DATA CYCLE, NOT THE OPENING)
local st

local function fresh()
    return { mode = 'idle', prev_manual = false, saw_zero = false,
             primed = false, prev_shown = false, prev_open = false, hold = false,
             was_running = false }
end
st = fresh()

-- A new map starts idle. Called when refinish_steel.lua starts its
-- monitors, since a module keeps its state across map loads.
function reset()
    st = fresh()
    _G.refinish_save_hook_mode = st.mode
end

-- ==========================================
-- IS ANYTHING LOADED
-- ==========================================
-- The same question refinish-autosave.lua's BASELINE CHECK asks before
-- its plain quicksave, inverted. Kept as a copy rather than shared,
-- as the two ledgers keep theirs: change the two together.
local function rm_owned(str)
    if string.sub(str, 1, 15) == "REFINISH_STEEL_" then return true end
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        if string.sub(str, 1, #prefix) == prefix then return true end
    end
    return false
end

local function loaded()
    if _G.refinish_ram_loaded then return true end
    if _G.refinish_modules_injected then return true end
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if rm_owned(mat.id) then return true end
    end
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if rm_owned(rxn.code) then return true end
    end
    return false
end

-- ==========================================
-- THE PAUSE, HELD FROM UNLOAD TO RELOAD
-- ==========================================
-- MEASURED 2026-09-30, refinish-save-probe, a save & continue with the
-- game running: the options screen halts the simulation without
-- touching pause_state (paused false throughout, the tick frozen at +310
-- from the screen opening to the save's end), and when DF closed the
-- screen after the save, one tick ran (+311) before this file's reload
-- in the same update. One tick with RM's data out of RAM: the magma
-- window the hotsave closed on its own path.
--
-- So the unload takes the pause, step() reasserts it every frame while
-- it is held (an unpause meanwhile cannot run a tick), and the reload
-- hands back what the player had. The options screen never sets
-- pause_state, so nothing hands the game back running before then.
local function take_pause()
    st.hold, st.was_running = true, not df.global.pause_state
    df.global.pause_state = true
end

local function give_pause()
    if st.hold and st.was_running then df.global.pause_state = false end
    st.hold, st.was_running = false, false
end

-- ==========================================
-- UNLOAD AND RELOAD
-- ==========================================
-- The same two calls the ESC cycle made, proven from a frame callback.
-- The pause is taken before the unload and handed back after the
-- reload, whether or not either one succeeded: a failed reload leaves
-- RM shut down, as a failed manual start does, and holding the game
-- paused over it would help nothing.
local function unload(why)
    take_pause()
    local ok, err = pcall(function()
        dfhack.run_script('refinish-shutdown', 'SILENT')
    end)
    if ok then
        log('DETAIL', why .. ': unloaded before the game writes.', 'UNLOAD')
    else
        log('ERROR', why .. ': the unload FAILED, so this save goes ahead'
            .. ' with data loaded: ' .. tostring(err), 'UNLOAD')
        -- Told in Danger colours, through RM's prompt system (THE PLAYER IS
        -- TOLD, IN THE COLOUR OF THE RISK, refinish_steel.lua). The game
        -- itself is unchanged: RM's data was never taken out of it.
        if _G.refinish_alert then
            pcall(_G.refinish_alert, "Refinish Metal could not take its data out of memory before"
                .. " this save & continue (" .. tostring(err) .. "). The save being written carries"
                .. " it and will not load. Your game is unchanged and can go on, but do not rely on"
                .. " this save: keep an earlier one, and restart Dwarf Fortress with RM's files in"
                .. " place before saving again.", 'RISK_H', 18)
        end
    end
end

local function reload(why)
    _G.refinish_silent_load = true
    local ok, err = pcall(function()
        dfhack.run_script('refinish-startup', 'SILENT', 'NOPROMPT')
    end)
    if ok then
        log('DETAIL', why .. ': reloaded.', 'RELOAD')
    else
        log('ERROR', why .. ': the reload FAILED; Refinish Metal stays'
            .. ' unloaded until it is started by hand: ' .. tostring(err),
            'RELOAD')
    end
    give_pause()
end

-- The records a save must carry, written before any request (WHEN
-- DFHACK WRITES ITS DATA). Reads the fort and writes two keys; nothing
-- is unloaded, so opening the menu stays quick. Resolved by name here
-- only, once per opening, never per frame.
-- ---- THE TWO SCRIPTS THE REFRESH CALLS, FOUND ONCE A DATA CYCLE ----
-- MEASURED 2026-10-02 (section probe, 101 s, five openings of the options
-- screen): the refresh cost 20.4 ms an opening, 12.4 of it "tool record"
-- and 8.0 "ledger checked", while the ledger logged its own check at 0
-- ms. Most of it was finding the two scripts: a lookup by name searches
-- DFHack's 24 script folders, RM's the 18th, about 7 ms a lookup (KNOWN
-- PATHS, CHECKED WITHOUT A SEARCH, refinish_steel.lua; 6.5 ms each at the
-- module engine's ONE LOOKUP PER SCRIPT A RUN). The refresh made two at
-- every opening, and the build ahead one every frame it ran. So each is
-- found once a data cycle and kept until the module registry is
-- replaced, which every load and reload does: no handle outlives the load
-- that found it, the rule the engine's own lookups keep. It is the
-- environment DFHack hands the pipeline too, so the tool wash's kept
-- record is the same table either way.
local envs_for, wash_env, ledger_env = nil, nil, nil

local function envs()
    local reg = _G.refinish_module_registry
    if envs_for ~= reg or not wash_env or not ledger_env then
        wash_env, ledger_env = nil, nil
        pcall(function() wash_env = dfhack.script_environment('refinish-tool-wash') end)
        pcall(function() ledger_env = dfhack.script_environment('refinish-ledger') end)
        envs_for = reg
    end
    return wash_env, ledger_env
end

local function refresh_records()
    local prefixes = {}
    for prefix in pairs(_G.refinish_module_registry or {}) do
        prefixes[#prefixes + 1] = prefix
    end
    -- SECTION CLOCK (refinish-section-probe): the refresh's two parts,
    -- inside the whole the caller times.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    -- The menu's wash: the record kept in memory, topped up and written
    -- only if that changed it (refinish-tool-wash.lua, THE RECORD, KEPT
    -- BETWEEN OPENINGS OF THE MENU), where every opening used to walk
    -- every item in the fort.
    local ok_w, err_w = pcall(function()
        local w = envs()
        w.menu_wash(prefixes)
    end)
    if sc then t0 = sc.lap('save hook: tool record (menu opened)', t0) end
    if not ok_w then
        -- ERROR: the opening's top up failed. Until 2026-10-27 this refresh
        -- was the only record either save from this menu carried (SAVE &
        -- QUIT); now the writer keeps it written as the fort changes (THE
        -- MENU'S RECORD, BUILT AHEAD, AND KEPT WRITTEN), and a save carries
        -- its last write.
        log('ERROR', 'tool record not topped up as the options screen opened; a'
            .. ' save from this menu carries the record last written as the fort'
            .. ' changed: ' .. tostring(err_w), 'REFRESH')
    end
    -- Kept when nothing has moved since the last write (refinish-ledger,
    -- UNCHANGED SINCE THE LAST WRITE): opening the menu no longer costs a
    -- rewrite of an identical ledger.
    local ok_l, err_l = pcall(function()
        local _, l = envs()
        l.write({ if_changed = true })
    end)
    if sc then sc.lap('save hook: ledger checked (menu opened)', t0) end
    if not ok_l then
        log('ERROR', 'material ledger not refreshed: ' .. tostring(err_l),
            'REFRESH')
    end
    -- RM'S OWN FILES, STILL THERE (refinish_steel.lua), asked at every
    -- opening, with the options screen, and a save, a click away. Until
    -- 2026-10-02 it was asked only when the refresh failed, which a lookup
    -- of a deleted script made it do; with both scripts kept in memory
    -- (THE TWO SCRIPTS THE REFRESH CALLS, above) the refresh no longer
    -- fails that way, so the opening asks itself. The check reads each
    -- file at its known path: 0.47 ms a call (section probe, scripts:
    -- files looked up).
    if _G.refinish_check_scripts then pcall(_G.refinish_check_scripts) end
end

-- ---- WHAT A SAVE & CONTINUE CARRIES ----
-- DFHack wrote this save's site data at the start of the frame its
-- request rose (WHEN DFHACK WRITES ITS DATA), so the tool record it
-- carries is the last one written before that frame, whatever the unload
-- writes after it. Said as the request is seen, from the tool wash's own
-- account (refinish-tool-wash.lua, WHAT A SAVE CARRIES). A save & quit is
-- said at the map unload, there.
local function say_carried(why)
    pcall(function()
        local n, at, known = envs().stored_record()
        if n then
            -- DETAIL: at every save & continue.
            log('DETAIL', ('%s: this save carries the tool record written at %s,'
                .. ' %d tool item(s).'):format(why, at, n), 'RECORD')
        elseif known > 0 then
            -- WARNING: this save brings the owned tools back as cauldrons.
            log('WARNING', ('%s: this save carries no tool record while this session'
                .. ' counted %d owned tool item(s); they come back from it as'
                .. ' cauldrons.'):format(why, known), 'RECORD')
        end
    end)
end

-- ==========================================
-- A SAVE RM CANNOT UNLOAD FOR IS HELD BACK
-- ==========================================
-- MEASURED 2026-10-01, refinish-save-cancel-probe, RM shut down, on a
-- copy of the fort:
--   Clearing options.do_manual_save ONCE, on the frame it rose, did not
--   hold: the flag came back, the countdown ran out and the save was
--   written (seen in play; the probe's own file check read nothing).
--   HOLDING it down on every frame did: across 3000 frames it was raised
--   again 18 times, each time with manual_save_timer still at 5, and was
--   cleared each time. The timer never moved, the menu stayed open, and
--   no save happened until the hold ended, when the next press saved at
--   once. To the player, the save name screen simply did not take the
--   save.
--
-- So when RM's script files cannot be found (RM'S OWN FILES, STILL
-- THERE, refinish_steel.lua), a save & continue is held back instead of
-- unloaded for: nothing is unloaded, the request is cleared on the frame
-- it rises and on every frame it rises again while the options screen
-- is up, and the player is told why in Danger colours, through RM's
-- prompt system, at most once every REFUSE_NOTICE_MS. The game is
-- unchanged, and a save goes through again once the files are back. A
-- save & quit is not held: the map unload clears RAM from its kept
-- copies (THE UNLOAD, KEPT IN MEMORY, refinish_steel.lua).
--
-- Only missing files hold a save back. An unload that is reached and
-- then fails part way is not undone here, so that case keeps the path
-- above: the save goes ahead, logged and told (UNLOAD AND RELOAD).
local REFUSE_NOTICE_MS = 5000
local last_refuse_notice = nil

local function refuse_notice()
    local now = dfhack.getTickCount()
    if last_refuse_notice and now - last_refuse_notice < REFUSE_NOTICE_MS then return end
    last_refuse_notice = now
    local missing = _G.refinish_scripts_missing or {}
    if _G.refinish_alert then
        pcall(_G.refinish_alert, ("Refinish Metal is holding this save back. Its script files can"
            .. " no longer be found (%d missing, such as %s), so it cannot take its data out of"
            .. " memory first, and a save written now would not load. Your game is unchanged. Put"
            .. " the files back and restart Dwarf Fortress before saving, or quit without saving.")
            :format(#missing, tostring(missing[1])), 'RISK_H', 18)
    end
end

-- True when the save must be held back. The script check is asked at
-- once; when that check is what first finds the files gone, its own alarm
-- has just told the player, so this does not tell them twice.
local function refuse_save()
    local known_before = _G.refinish_scripts_missing ~= nil
    if _G.refinish_check_scripts then pcall(_G.refinish_check_scripts) end
    local missing = _G.refinish_scripts_missing
    if not missing or #missing == 0 then return false end
    log('ERROR', ('save & continue held back: %d script file(s) cannot be found (%s), so RM'
        .. ' cannot unload first and the save would not load.'):format(#missing,
        table.concat(missing, ', ')), 'REFUSED')
    if known_before then
        refuse_notice()
    else
        last_refuse_notice = dfhack.getTickCount()
    end
    return true
end

-- Is the options screen up, from the live focus rather than the options
-- struct, whose fields can be left over from before a load (PRIMED).
--
-- EVERY FOCUS STRING, 2026-10-27. This read only the first focus string,
-- and DFHack puts the options screen's after those of any other panel
-- still flagged open (THE RECORD NO LONGER WAITS FOR THE OPTIONS SCREEN,
-- in the header): with any of those up, the screen read as down. So the
-- options screen is looked for among every focus string, by DFHack's own
-- matchFocusString, of DF's own top screen (getDFViewscreen) rather than
-- of any DFHack screen sitting over it, as screen_waits asks in
-- refinish-stockpile-windows.lua.
local function options_shown()
    local shown = false
    pcall(function()
        local vs = dfhack.gui.getDFViewscreen(true)
        shown = dfhack.gui.matchFocusString('dwarfmode/Options', vs) == true
    end)
    return shown
end

-- ---- options.open SET, NO OPTIONS SCREEN IN THE FOCUS ----
-- The other mismatch from the tripwire's (THE TRIPWIRE, below). DFHack
-- builds the options screen's focus string from options.open itself
-- (Gui.cpp), so with the fort's screen on top the two cannot disagree. If
-- they ever do, DFHack has changed how it names the screen, and every
-- reader of that name is blind again: said once, a WARNING, with the
-- focus strings it saw. Asked only while the fort's screen is DF's top
-- screen, whose focus strings are the ones that name the options screen.
local unseen_said = false

local function open_unseen()
    if unseen_said then return end
    pcall(function()
        local vs = dfhack.gui.getDFViewscreen(true)
        if not df.viewscreen_dwarfmodest:is_instance(vs) then return end
        unseen_said = true
        local list = {}
        for _, s in ipairs(dfhack.gui.getFocusStrings(vs) or {}) do
            list[#list + 1] = tostring(s)
        end
        -- WARNING: this file cannot see the options screen.
        log('WARNING', 'options.open is set but no options screen is among the'
            .. ' focus strings (' .. table.concat(list, ', ') .. '); the screen reads'
            .. ' as down here. The tool record does not wait on it.', 'FOCUS')
    end)
end

-- ---- THE FOCUS, ASKED ONLY WHILE options.open IS SET ----
-- MEASURED 2026-10-02 (DFHack's own counters, refinish-save-hook-monitor):
-- 470 to 706 ms in sessions of three to six minutes, about 2 ms/sec,
-- nearly all of it options_shown() asking DF for the focus string every
-- frame. options.open is one read.
--
-- MEASURED 2026-10-02, a probe that counted every frame (368 s, the
-- options screen opened four times, one of them a save & continue): with
-- the screen up for 2,145 frames, options.open was clear on none of
-- them, and set with the screen down on none. So the focus is asked only
-- while open is set, and still decides there: open left set from before
-- a load (PRIMED) is not the screen being up.
--
-- THE TRIPWIRE. Every TRIPWIRE_FRAMES frames with open clear the focus is
-- asked anyway, about one frame in a hundred of the old cost. The screen
-- up there is a path the probe never saw: it is logged once as a
-- WARNING, and from then until the screen closes the focus is asked every
-- frame, so its rising edge still writes the records a save & quit relies
-- on (SAVE & QUIT), late rather than never.
local TRIPWIRE_FRAMES = 100
local trip_count, tripped, trip_said = 0, false, false

local function screen_up(o)
    if o.open == true or tripped then
        local up = options_shown()
        if tripped and not up then tripped = false end
        if o.open == true and not up then open_unseen() end
        return up
    end
    trip_count = trip_count + 1
    if trip_count < TRIPWIRE_FRAMES then return false end
    trip_count = 0
    if not options_shown() then return false end
    tripped = true
    if not trip_said then
        trip_said = true
        -- WARNING: the gate on options.open missed this screen's opening.
        log('WARNING', 'the options screen is up while options.open is clear;'
            .. ' the tripwire found it late, and the focus is asked every'
            .. ' frame until it closes.', 'TRIPWIRE')
    end
    return true
end

-- ---- THE MENU'S RECORD, BUILT AHEAD, AND KEPT WRITTEN ----
-- refinish-tool-wash.lua keeps the tool record a save from the options
-- screen carries, built in the background after a load (THE RECORD, KEPT
-- BETWEEN OPENINGS OF THE MENU, there), so that an opening only tops it
-- up. This drives that build, a slice a frame while nothing else is
-- under way, until it is built for this data cycle. A new data cycle
-- brings a new module registry, and the build starts again.
--
-- And since 2026-10-27 it keeps the record WRITTEN (THE RECORD NO LONGER
-- WAITS FOR THE OPTIONS SCREEN, in the header; THE RECORD, KEPT WRITTEN,
-- in the tool wash): on the frame the build is done, then every
-- KEEP_WRITE_FRAMES frames, the record is brought up to date and written
-- if that changed it, and at once on the frame options.open rises (now),
-- whatever the focus says, finishing a build still under way. Between
-- those frames, one countdown a frame. Not on the frame a save & continue
-- is asked for (step, below), and not while RM's own save cycle runs,
-- since step() returns before this then.
local KEEP_WRITE_FRAMES = 100
local keep_built_for = nil
local keep_wait = 0
local keep_said = {}     -- faults already logged, once each

-- A fault in the build or the writer, said once per message. Site data
-- keeps the record last written, which is what a save then carries.
local function keep_fault(what, err)
    local msg = tostring(err)
    if keep_said[msg] then return end
    keep_said[msg] = true
    -- ERROR: the record stops following the fort until this is fixed.
    log('ERROR', ('the tool record could not be %s (%s); site data keeps the'
        .. ' record last written, and a save carries that.'):format(what, msg), 'RECORD')
end

-- The writer, on its countdown, or at once when now is set.
local function keep_written(now)
    if now then keep_wait = 0 end
    keep_wait = keep_wait - 1
    if keep_wait > 0 then return end
    keep_wait = KEEP_WRITE_FRAMES
    -- SECTION CLOCK (refinish-section-probe): one look, a write when due.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    local ok, err = pcall(function()
        local w = envs()
        w.keep_write(nil, now)
    end)
    if sc then sc.lap('save hook: tool record kept written', t0) end
    if not ok then keep_fault('written', err) end
end

local function keep_frame(now)
    local reg = _G.refinish_module_registry
    if reg == nil then return end
    if keep_built_for == reg then return keep_written(now) end
    -- SECTION CLOCK (refinish-section-probe): one slice of the build.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    local ok, done = pcall(function()
        local w = envs()
        return w.keep_step()
    end)
    if ok and done then keep_built_for = reg end
    if not ok then keep_fault('built', done) end
    if sc then sc.lap('save hook: tool record built ahead, a slice', t0) end
    -- Written on the frame the build is done, and on the frame the
    -- options screen's flag rises, which finishes the build if it must.
    if keep_built_for == reg or now then keep_written(true) end
end

-- ==========================================
-- ONE FRAME
-- ==========================================
function step()
    local o = df.global.game.main_interface.options
    local manual  = o.do_manual_save == true
    local open    = o.open == true
    -- THE FOCUS, ASKED ONLY WHILE options.open IS SET (above).
    local shown   = screen_up(o)

    -- The calendar's autosave waits while this is set, and the status
    -- panel and the dump show it: the options screen is up, or a save is
    -- between its unload and its reload.
    _G.refinish_menu_locked = shown or st.mode ~= 'idle'
    _G.refinish_save_hook_mode = st.mode

    -- PRIMED: the first frame after a load only takes the flags as they
    -- stand.
    if not st.primed then
        st.prev_manual, st.prev_shown, st.prev_open = manual, shown, open
        st.primed = true
        return
    end

    -- Only a rising edge acts on a save request. Recorded before anything
    -- else so a request during RM's own save cycle is not replayed after
    -- it. The records are not edge driven (THE RECORDS FOLLOW THE DATA
    -- CYCLE, NOT THE OPENING): shown_rose only names why a refresh ran.
    local manual_rose = manual and not st.prev_manual
    local shown_rose  = shown and not st.prev_shown
    local open_rose   = open and not st.prev_open
    st.prev_manual, st.prev_shown, st.prev_open = manual, shown, open

    -- RM's own save cycle owns the state while it runs.
    if _G.refinish_autosave_in_progress then return end

    if st.mode == 'idle' then
        -- THE MENU'S RECORD, BUILT AHEAD, AND KEPT WRITTEN (above): a slice
        -- a frame until built, then written as it changes, and at once as
        -- the options screen's own flag rises. Not on the frame a save is
        -- asked for: DFHack wrote that save's site data at the start of the
        -- frame (WHEN DFHACK WRITES ITS DATA), so a write now would miss it
        -- while WHAT A SAVE & CONTINUE CARRIES reported it as carried.
        if not manual_rose then keep_frame(open_rose) end
        -- The screen opening, before any save can be asked for from it.
        -- SECTION CLOCK (refinish-section-probe): the work done as the
        -- options screen opens, and as a save is asked for.
        local sc = _G.refinish_section_clock
        -- THE RECORDS FOLLOW THE DATA CYCLE, NOT THE OPENING (header).
        -- Refreshed on the first frame the screen is up, and again after
        -- any data cycle that runs while it stays up. records_for goes
        -- back to nil whenever the screen is down, so every opening
        -- refreshes, as it always did. false stands in for no registry,
        -- so nil keeps meaning "not refreshed while this screen is up".
        local cycle = _G.refinish_module_registry or false
        if not shown then
            st.records_for = nil
        elseif st.records_for ~= cycle and not manual_rose then
            -- Marked before the check, so a fort with nothing loaded is
            -- asked once a data cycle rather than every frame: loaded()
            -- walks the arrays when RM's flags are down.
            st.records_for = cycle
            if loaded() then
                local why = shown_rose and 'menu opened' or 'data cycle, menu up'
                local t0 = sc and sc.now()
                refresh_records()
                if sc then sc.lap('save hook: records refreshed (' .. why .. ')', t0) end
                if not shown_rose then
                    -- DETAIL: the refresh this file used to lose (header).
                    log('DETAIL', 'records refreshed again: a data cycle ran'
                        .. ' while the options screen was up.', 'REFRESH')
                end
            end
        end
        if manual_rose then
            if loaded() then
                local t0 = sc and sc.now()
                local refused = refuse_save()
                if sc then sc.lap('save hook: save request checked', t0) end
                if refused then
                    -- A SAVE RM CANNOT UNLOAD FOR IS HELD BACK.
                    o.do_manual_save = false
                    st.mode = 'refused'
                else
                    -- WHAT A SAVE & CONTINUE CARRIES (above), before the
                    -- unload writes anything of its own.
                    say_carried('save & continue')
                    unload('save & continue')
                    st.mode, st.saw_zero = 'continue', o.manual_save_timer <= 0
                end
            end
        end
        -- A save & quit is left to the map unload failsafe. Its tool record
        -- is the one kept written as the fort changed, topped up as the
        -- screen opened; its ledger was refreshed as the screen opened
        -- (SAVE & QUIT).
        _G.refinish_save_hook_mode = st.mode
        return
    end

    -- 'refused': every request raised while the options screen stays up
    -- is cleared, each new one told; the screen closing ends it (A SAVE
    -- RM CANNOT UNLOAD FOR IS HELD BACK).
    if st.mode == 'refused' then
        if o.do_manual_save == true then
            o.do_manual_save = false
            if manual_rose then refuse_notice() end
        end
        if not shown then st.mode = 'idle' end
        _G.refinish_save_hook_mode = st.mode
        return
    end

    -- The pause, held from the unload to the reload (THE PAUSE, HELD
    -- FROM UNLOAD TO RELOAD): reasserted every frame, so an unpause
    -- meanwhile cannot run a tick while RM's data is out of RAM.
    if st.hold and not df.global.pause_state then
        df.global.pause_state = true
    end

    -- 'continue': reload once the save has happened and the options
    -- screen has closed.
    if o.manual_save_timer <= 0 then st.saw_zero = true end
    if st.saw_zero and o.open ~= true then
        reload('save & continue done')
        st.mode = 'idle'
    end
    _G.refinish_save_hook_mode = st.mode
end