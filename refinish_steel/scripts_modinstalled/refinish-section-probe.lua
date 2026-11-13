-- refinish-section-probe.lua
-- ==========================================
-- SECTION PROBE: WHERE INSIDE A LOOP THE TIME GOES
-- ==========================================
-- READ ONLY. Console only, with a fort loaded and RM running.
--
--     refinish-section-probe on       start timing (a running window is
--                                     reported first, then restarted)
--     refinish-section-probe report   what each section cost so far
--     refinish-section-probe off      report, then stop timing
--
-- ---- REPORT FIRST ----
-- Nothing this probe has timed is ever thrown away unreported. off
-- reports the window before it stops, on reports a running window
-- before it starts a new one, and a map unload, which nobody types,
-- writes the report to the log before the window ends. A fifteen minute
-- window was lost on 2026-10-01 when off, which then stopped without a
-- word, was typed in place of report.
--
-- ---- WHY ----
-- The profiler times whole loops. Three of them grew in a busy fort and
-- cannot be fixed without knowing which part grew (2026-09-30):
--   d:refinish-reaction-adaptive   2.08 to 2.51 ms a call (about 1 before)
--   d:making_fuel_fuel_access      0.62 to 0.75 ms a call (0.04 to 0.14)
--   t:refinish-menu-icons.lua:380  0.07 to 0.09 ms a frame (0.02)
-- Each has timing points between its sections. They call the clock this
-- probe installs as _G.refinish_section_clock, and do nothing at all
-- while it is not installed: one global read per poll.
--
-- ---- THE CLOCK ----
-- os.clock() in milliseconds: 1 ms steps on Windows, against the 15.6 ms
-- of dfhack.getTickCount(). A section shorter than a step reads as 0 or
-- 1 ms on any one call, so only the totals over many calls mean
-- anything, the same rule as the profiler's averages. Run the fort
-- unpaused for a few minutes with the jobs that made it busy.
--
-- ---- THE REPORT ----
-- Per section: calls, total ms, ms a call, the longest single call, and
-- ms per second of the window, largest first. The longest call is the
-- one to read for a hitch: a section that is cheap on average can still
-- hold one frame for a quarter second. A loop's sections are listed under its name
-- with a 'whole poll' line, so the gap between the parts and the whole
-- is the loop's own overhead. The menu icon sections carry the build
-- menu's mode in their names, which says whether the per frame check
-- runs while the menu is closed.
-- ==========================================

local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SECTION_PROBE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
    else
        line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
            tostring(subject or '-'), tostring(typ or 'UNTYPED'), tostring(msg))
    end
    _G.refinish_log_event(line)
end

-- The answer to a typed command: printed, and logged. quiet is for the
-- report a map unload writes, which nobody typed: logged only.
local function say(msg, subject, quiet)
    if not quiet then print(('SECTION PROBE %s: %s'):format(subject, msg)) end
    log('INFO', msg, subject)
end

-- ==========================================
-- THE CLOCK THE TIMING POINTS CALL
-- ==========================================
-- now() starts a section; lap(name, t0) closes it under name and
-- returns the time, so the next section starts where this one ended.
local function new_clock()
    local c = { t = {}, n = {}, max = {}, since = os.clock() }
    function c.now() return os.clock() * 1000 end
    function c.lap(name, t0)
        local t = os.clock() * 1000
        if t0 then
            local d = t - t0
            c.t[name] = (c.t[name] or 0) + d
            c.n[name] = (c.n[name] or 0) + 1
            if d > (c.max[name] or 0) then c.max[name] = d end
        end
        return t
    end
    return c
end

-- ==========================================
-- THE REPORT
-- ==========================================
-- Defined before on and off, which both call it (REPORT FIRST).
local function report(quiet)
    local c = _G.refinish_section_clock
    if not c then
        say('not on.', 'REPORT', quiet)
        return
    end
    local secs = os.clock() - c.since
    local rows = {}
    for name, t in pairs(c.t) do
        rows[#rows + 1] = { name = name, t = t, n = c.n[name] or 0, max = c.max[name] or 0 }
    end
    table.sort(rows, function(a, b) return a.t > b.t end)
    say(('%.1f s of clock since on, %d section(s).'):format(secs, #rows), 'REPORT', quiet)
    for _, r in ipairs(rows) do
        say(('%-56s %8d calls %10.1f ms %8.3f ms a call %6.0f ms max %7.2f ms/sec'):format(r.name, r.n,
            r.t, r.n > 0 and r.t / r.n or 0, r.max, secs > 0 and r.t / secs or 0), 'REPORT', quiet)
    end
end

local function on()
    if _G.refinish_section_clock then
        report()
        say('restarting: the report above closes the old window.', 'ON')
    end
    _G.refinish_section_clock = new_clock()
    say('timing. Run the fort unpaused a few minutes, then: refinish-section-probe report', 'ON')
end

local function off()
    if not _G.refinish_section_clock then
        say('not on.', 'OFF')
        return
    end
    report()
    _G.refinish_section_clock = nil
    say('stopped after the report above; the timing points are quiet again.', 'OFF')
end

-- ==========================================
-- A MAP UNLOAD ENDS THE WINDOW, REPORTED
-- ==========================================
-- The timing points live in RM's files, so a window left on across an
-- unload would go on to mix two forts' numbers. The unload writes the
-- report to the log, then stops. Keyed, so running this script again
-- replaces the handler rather than adding a second one.
dfhack.onStateChange.refinish_section_probe = function(code)
    if code ~= SC_MAP_UNLOADED then return end
    if not _G.refinish_section_clock then return end
    report(true)
    _G.refinish_section_clock = nil
    say('stopped by the map unload, after the report above.', 'OFF', true)
end

local args = { ... }
if not dfhack.isMapLoaded() then
    print('refinish-section-probe: load a fort first.')
    return
end
local MODES = { on = on, off = off, report = report }
local fn = MODES[args[1] or '']
if not fn then
    print('refinish-section-probe: on | report | off')
    return
end
fn()