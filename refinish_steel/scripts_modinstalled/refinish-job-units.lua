--@ module = true
-- refinish-job-units.lua
-- ==========================================
-- RM JOB UNITS
-- ==========================================
-- Every unit a work order's job finishes, reported on the tick it
-- finishes to every service and module that waits for job completions.
--
-- ---- WHY IT EXISTS ----
-- A work order does not post a job per unit. DF keeps one job at each
-- workshop the order runs in and resets it in place after every unit,
-- the way it resets a repeating job, until the order is done. MEASURED
-- 2026-10-09: jobs 7654 and 7655, ConstructBlocks at two carpenter's
-- workshops from one order, kept their ids through three units each,
-- flagged by_manager and not repeat.
--
-- DFHack's completion event reports a job that is still in the job list
-- only if its repeat flag is set: a unit is done when the job's
-- completion timer was 0 on the last tick and is -1 now (EventManager.cpp,
-- manageJobCompletedEvent, read 2026-10-09). A work order's job is never
-- put to that test, so DFHack reports one completion for a whole order:
-- its last unit, when the job leaves the list. Every file that waited for
-- completions saw a whole order as one job. MEASURED 2026-10-09: bins and
-- blocks made by work orders paid no byproducts at all, and a bin job
-- read 6000 out against one 5000 log, the volume of two bins.
--
-- ---- HOW ----
-- 1. FINDING THEM. A work order's job (flags.by_manager, and not
--    flags.repeat, whose units DFHack reports itself) is noted when
--    DFHack reports it posted, by a slow backstop over the whole job
--    list, and by a scan at start for the jobs a save brought back. It is
--    noted with its workshop; a job with none is left to the backstop.
-- 2. WATCHING THEM. Every frame, paused included, each noted job is found
--    again through its workshop's own job list, ten at most, never through
--    a kept reference: a job DF finishes or cancels between two frames is
--    freed memory (JOBS ARE ONLY GOOD FOR THE TICK, refinish-loop-dispatch).
--    A job no longer there has left the list, and DFHack reports the
--    order's last unit itself, so the note just goes.
-- 3. THE TEST. DFHack's own for a repeating job's unit, applied to a work
--    order's, exactly: the completion timer was 0 at the last look and is
--    -1 now, with the job still in its workshop. The timer counts down
--    while a dwarf works (32, 82 and 36 on live jobs in df_data_reference)
--    and reads -1 before work starts, and DFHack's test rests on a
--    repeating job reading -1 again once DF has reset it for its next
--    unit. A work order's job is taken to reset the same way, which play
--    confirms or refutes in the log: a job that leaves its workshop says
--    how many units were reported here, and 0 after a long order would
--    mean the timer does something else. A unit cancelled on exactly that
--    tick reads as done, which DFHack accepts for repeating jobs too
--    ("experiments show this doesn't happen", EventManager.cpp).
-- 4. THE REPORT. Each subscriber's handler is called with the job, lowest
--    order first and name order within one, each inside pcall. A handler
--    that throws is named once a session and keeps being called.
--
-- ---- THE JOB A HANDLER IS HANDED ----
-- The LIVE job, on the tick its unit finished. The unit's products are
-- in the workshop and what it was fed is consumed, and DF has already
-- reset the job for its next unit, so job.items no longer lists them.
-- DFHack hands its handlers a copy taken while the job worked, which can.
-- A handler reads what it noted while the job worked (its memo or
-- witness), as every handler subscribed when this was written does, and
-- keeps nothing: the job is good for the call only.
--
-- ---- FIRST IN THE TICK ----
-- The watch rides the dispatcher's every frame tier, and the dispatcher
-- runs the shortest cadence first, so a unit is reported before any
-- slower subscriber's poll on the same tick, paused ones included. That
-- is load bearing: the byproduct service, reaction outputs and the binder
-- watcher find a job's output by an item number read at each poll, and a
-- poll between the unit and its report would move that number past the
-- unit's products. DFHack's own reports need no such care: its events run
-- before every Lua loop in an update (Core.cpp, Core::onUpdate calls
-- EventManager::manageEvents, then the plugins, then the Lua timers, read
-- 2026-10-09). Without the dispatcher this file runs its own loops, and
-- its order among the other loops is not guaranteed.
--
-- ---- WHAT IT DOES NOT DO ----
-- Ordinary and repeating jobs are DFHack's to report, and so is a work
-- order's last unit. Nothing here changes a job or an item. A subscriber
-- keeps its own onJobCompleted registration beside this one, so an RM
-- without this file, or with it stopped, reports exactly what DFHack
-- reports, as before.
--
-- ---- COST ----
-- A frame with no work order job noted is one table check. With some,
-- per job: a building lookup, at most ten job ids, a flag and a timer.
--
-- ---- SUBSCRIBING, from a start() ----
--   local units = _G.refinish_job_units_api
--   if units and units.subscribe then units.subscribe(KEY, on_completed) end
-- and from stop():
--   if units and units.unsubscribe then units.unsubscribe(KEY) end
-- KEY is the subscriber's own, and subscribing again under it replaces
-- the handler. The handler is the one given to eventful.onJobCompleted.
-- An optional third argument is the order, a number, 50 when omitted:
-- lower is called first.
--
-- ---- LIFECYCLE ----
-- refinish_steel loads this file at its own load, so the handle exists
-- before any module starts, and starts and stops it with RM's services,
-- right after the dispatcher (RM'S SERVICES FOLLOW THE DATA). Stopping
-- drops every subscription and every noted job: each service and module
-- subscribes again in its own start, and the start scan notes the jobs
-- again. Subscribing works while it is stopped, which is when the
-- modules do it, inside the pipeline.
--
-- COMMANDS (console)
--   refinish-job-units status    subscribers, and the work order jobs watched
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local KEY         = 'refinish-job-units'        -- the watch, every frame
local SCAN_KEY    = 'refinish-job-units-scan'   -- the backstop
local SCAN_FRAMES = 100
local ORDER       = 50                          -- a subscriber's order when it gives none

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. SUBJECT is WATCH for a job noted or gone, UNIT for a unit
-- reported, SUBSCRIBE, SUBSCRIBER for a handler's fault, START and STOP.
-- Every line reaches the log on disk; filtering is the panel's job alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'JOB_UNITS'
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
-- STATE, ON _G
-- ==========================================
-- On _G rather than in this file's locals, so a reload of this file
-- (development only) finds the subscriptions and the noted jobs where it
-- left them, the same reason the dispatcher keeps its own there.
--   subs     name -> { fn, order }
--   order    the subscriptions, lowest order first, name order within one;
--            rebuilt on change
--   watched  job id -> { bid = workshop id, timer = completion timer at
--            the last look, units = units reported here, label }
--   errored  name -> true, a handler's throw already logged this session
--   running  is the service started
--   via      what the watch runs on, for the log and the status command
--   next_id  df.global.item_next_id at the last look: every item made
--            since is numbered at or above it
-- ==========================================
_G.refinish_job_units = _G.refinish_job_units or {}
local U = _G.refinish_job_units
U.subs    = U.subs    or {}
U.order   = U.order   or {}
U.watched = U.watched or {}
U.errored = U.errored or {}
U.running = U.running or false

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Lowest order first and name order within one, so the order handlers
-- are called in never depends on how a table happened to hash. DFHack's
-- own event calls its handlers in its table's order (Lua_API, Event
-- type: "loops through the table with next"), which is no order at all.
local function rebuild()
    local list = {}
    for name, s in pairs(U.subs) do
        list[#list + 1] = { name = name, fn = s.fn, order = s.order }
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    U.order = list
end

-- ==========================================
-- SUBSCRIBING
-- ==========================================
function subscribe(name, fn, order)
    if type(name) ~= 'string' or name == '' then
        return false, 'a subscription needs a name'
    end
    if type(fn) ~= 'function' then
        return false, 'a subscription needs a handler'
    end
    if order ~= nil and type(order) ~= 'number' then
        return false, 'order must be a number'
    end
    U.subs[name] = { fn = fn, order = order or ORDER }
    U.errored[name] = nil
    rebuild()
    -- DETAIL: every service and module subscribes again on every data cycle.
    log('DETAIL', ('%s subscribed, order %s.'):format(name, tostring(order or ORDER)),
        'SUBSCRIBE')
    return true
end

function unsubscribe(name)
    if U.subs[name] then
        U.subs[name] = nil
        rebuild()
    end
end

-- ==========================================
-- NAMING A JOB IN THE LOG
-- ==========================================
-- df.job_type answers "CustomReaction" for every raws reaction, so a
-- reaction job is named by its reaction's code, and a hardcoded job by
-- its type's name, never by its number. Falls back to the number, then to
-- '?', so it can never be the thing that throws inside a log call.
local function label(job)
    local name = nil
    pcall(function()
        if job.job_type == df.job_type.CustomReaction then
            name = tostring(job.reaction_name)
        end
    end)
    if name and name ~= '' and name ~= 'nil' then return name end
    pcall(function() name = tostring(df.job_type[job.job_type] or job.job_type) end)
    return name or '?'
end

-- ==========================================
-- FINDING THEM
-- ==========================================
-- A work order's job whose units DFHack does not report: by_manager, and
-- not repeat. A repeating one is DFHack's (THE TEST, header).
local function is_order_job(job)
    local f = job.flags
    return f.by_manager and not f['repeat']
end

-- Noted with its workshop and its timer as it stands. A job with no
-- workshop yet is passed over and found again by the backstop.
local function note(job, how)
    local id = job.id
    if U.watched[id] then return end
    local bid = nil
    pcall(function()
        local b = dfhack.job.getHolder(job)
        if b then bid = b.id end
    end)
    if not bid then return end
    local t = -1
    pcall(function() t = job.completion_timer end)
    local w = { bid = bid, timer = t, units = 0, label = label(job) }
    U.watched[id] = w
    log('DETAIL', ('job %d (%s) at building %d runs a work order: each unit it finishes'
        .. ' is reported here. Found %s.'):format(id, w.label, bid, how), 'WATCH')
end

-- DFHack reports a job posted (onJobInitiated). Inside pcall: an error
-- escaping into eventful breaks every other listener in the process.
local function on_posted(job)
    pcall(function()
        if U.running and is_order_job(job) then note(job, 'at posting') end
    end)
end

-- The backstop and the start scan: every job in a list. The flags are
-- read only for a job not noted already.
local function scan(jobs, how)
    for _, j in ipairs(jobs) do
        if j and not U.watched[j.id] and is_order_job(j) then note(j, how) end
    end
end

local function scan_dispatch(jobs)
    if not U.running or not dfhack.isMapLoaded() or not jobs then return end
    scan(jobs, 'by the backstop')
end

-- This file's own walk of the job list, for the start scan and for an RM
-- without the dispatcher.
local function walk(how)
    local jobs = {}
    local link = df.global.world.jobs.list.next
    while link do
        if link.item then jobs[#jobs + 1] = link.item end
        link = link.next
    end
    scan(jobs, how)
end

local function scan_own()
    if not U.running or not dfhack.isMapLoaded() then return end
    pcall(walk, 'by the backstop')
end

-- ==========================================
-- WATCHING THEM
-- ==========================================
-- The job, found through its workshop's own list; nil when it has left.
local function find(bid, id)
    local b = df.building.find(bid)
    if not b then return nil, nil end
    for _, j in ipairs(b.jobs) do
        if j.id == id then return j, b end
    end
    return nil, b
end

-- THE REPORT (header, 4). The new items are counted before any handler
-- runs, so a handler's own spawns are never in the count: the line says
-- what DF made, which is what shows the report came on the unit's tick.
local function report(d, since)
    local made = 0
    pcall(function()
        for _, ci in ipairs(d.b.contained_items) do
            if ci.item and ci.item.id >= since then made = made + 1 end
        end
    end)
    for _, s in ipairs(U.order) do
        local ok, err = pcall(s.fn, d.job)
        if not ok and not U.errored[s.name] then
            U.errored[s.name] = true
            -- ERROR: that subscriber misses this work, named once a session.
            log('ERROR', ('%s threw on job %d: %s'):format(s.name, d.id, tostring(err)),
                'SUBSCRIBER')
        end
    end
    log('DETAIL', ('job %d (%s) at building %d finished a unit (%d reported here): %d new'
        .. ' item(s) in the workshop, handed to %d subscriber(s).'):format(d.id, d.w.label,
        d.w.bid, d.w.units, made, #U.order), 'UNIT')
end

-- Every frame. The units are gathered first and reported after the walk,
-- so no handler runs while the noted jobs are being walked, and every job
-- reported is still this tick's.
local function watch_step()
    if next(U.watched) == nil then
        U.next_id = nil
        return
    end
    if not U.running or not dfhack.isMapLoaded() then return end
    -- ---- NO TICK, NO UNIT (2026-10-31) ----
    -- A unit finishes only when the game advances: the test below is a
    -- completion timer stepping from 0 to -1, and the timer moves with
    -- the game tick. So a frame on which cur_year_tick has not moved,
    -- which is every paused frame, cannot hold a unit, and the watch is
    -- skipped. MEASURED before this: 19.9 ms/sec while paused, 65 jobs
    -- watched every frame for nothing. The tick and not the pause flag:
    -- whatever the pause flag reads during a single step, the tick moves
    -- on one, so a step's unit is never skipped. The subscription stays
    -- paused = true for FIRST IN THE TICK. While skipped, U.next_id is not
    -- moved on, so the first unit after a pause may count items a script
    -- made during it in its log line; no handler depends on that count.
    local tick = df.global.cur_year_tick
    if tick == U.last_tick then return end
    U.last_tick = tick
    local now_next = df.global.item_next_id
    local since = U.next_id or now_next
    U.next_id = now_next
    local done = nil
    for id, w in pairs(U.watched) do
        local ok, job, b = pcall(find, w.bid, id)
        if not ok or not job then
            -- Gone from its workshop: the order is done or the job was
            -- cancelled. DFHack reports a last unit itself.
            U.watched[id] = nil
            log('DETAIL', ('job %d (%s) left building %d after %d unit(s) reported here;'
                .. ' DFHack reports an order\'s last unit itself.'):format(id, w.label,
                w.bid, w.units), 'WATCH')
        elseif job.flags['repeat'] then
            -- Set to repeat since it was noted: DFHack reports its units now,
            -- and reporting them here too would pay every one twice.
            U.watched[id] = nil
            log('DETAIL', ('job %d (%s) is repeating now; DFHack reports its units from'
                .. ' here.'):format(id, w.label), 'WATCH')
        else
            local t = job.completion_timer
            if w.timer == 0 and t == -1 then
                w.units = w.units + 1
                done = done or {}
                done[#done + 1] = { job = job, b = b, id = id, w = w }
            end
            w.timer = t
        end
    end
    if done then
        for _, d in ipairs(done) do report(d, since) end
    end
end

-- The same step on this file's own loop, for an RM without the dispatcher.
local function watch_own()
    local ok, err = pcall(watch_step)
    if not ok and not U.errored[KEY] then
        U.errored[KEY] = true
        log('ERROR', 'WATCH ERROR: ' .. tostring(err), 'WATCH')
    end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- Subscriptions are kept: the modules make theirs inside the pipeline,
-- before this starts. Only the noted jobs start afresh, from the scan.
function start()
    U.running = true
    U.watched, U.next_id, U.last_tick = {}, nil, nil
    -- Posting. Enabled here rather than trusting another file to have
    -- done it: a hook on an event nobody enabled is never called, and
    -- fails without a word.
    eventful.onJobInitiated[KEY] = on_posted
    pcall(function() eventful.enableEvent(eventful.eventType.JOB_INITIATED, 0) end)
    -- The watch every frame with no job walk, and the backstop on the
    -- slow tier with every job; both paused included (FIRST IN THE TICK).
    local api = _G.refinish_dispatch_api
    if api and api.subscribe
            and api.subscribe(KEY, { every = 1, fn = watch_step, paused = true })
            and api.subscribe(SCAN_KEY, { every = SCAN_FRAMES, jobs = true,
                                          fn = scan_dispatch, paused = true }) then
        repeatUtil.cancel(KEY)
        repeatUtil.cancel(SCAN_KEY)
        U.via = 'the dispatcher'
    else
        -- Whichever runs, the other is cleared, so a start after a start
        -- never leaves both serving the same jobs.
        if api and api.unsubscribe then
            api.unsubscribe(KEY)
            api.unsubscribe(SCAN_KEY)
        end
        repeatUtil.scheduleEvery(KEY, 1, 'frames', watch_own)
        repeatUtil.scheduleEvery(SCAN_KEY, SCAN_FRAMES, 'frames', scan_own)
        U.via = 'its own loops'
    end
    -- The jobs a save brought back, mid order.
    pcall(walk, 'at start')
    log('DETAIL', ('started on %s: %d subscriber(s), %d work order job(s) watched.'):format(
        U.via, count(U.subs), count(U.watched)), 'START')
    return true
end

function stop()
    U.running = false
    eventful.onJobInitiated[KEY] = nil
    repeatUtil.cancel(KEY)
    repeatUtil.cancel(SCAN_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then
        api.unsubscribe(KEY)
        api.unsubscribe(SCAN_KEY)
    end
    U.subs, U.order, U.watched, U.errored, U.next_id = {}, {}, {}, {}, nil
    log('DETAIL', 'stopped; every subscription and noted job dropped.', 'STOP')
end

-- ---- THE HANDLE ----
-- Published at load, not at start, because modules subscribe during the
-- pipeline, before start() runs. See LIFECYCLE.
_G.refinish_job_units_api = { subscribe = subscribe, unsubscribe = unsubscribe }

if dfhack_flags and dfhack_flags.module then return end

-- ==========================================
-- COMMANDS
-- ==========================================
-- Prints only here, as the direct answer to a typed command.
local args = {...}
if args[1] == 'status' then
    print(('job units %s on %s, %d subscriber(s), %d work order job(s) watched.'):format(
        U.running and 'running' or 'stopped', tostring(U.via or '-'), count(U.subs),
        count(U.watched)))
    for _, s in ipairs(U.order) do
        print(('  subscriber %-32s order %s'):format(s.name, tostring(s.order)))
    end
    for id, w in pairs(U.watched) do
        print(('  job %-8d %-28s building %-6d timer %-5s %d unit(s) reported'):format(
            id, w.label, w.bid, tostring(w.timer), w.units))
    end
else
    print('refinish-job-units status')
end
