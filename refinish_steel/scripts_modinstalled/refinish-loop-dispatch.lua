--@ module = true
-- refinish-loop-dispatch.lua
-- ==========================================
-- RM LOOP DISPATCHER
-- ==========================================
-- One loop that runs other loops. A watcher that used to schedule its
-- own timer subscribes here instead, and the dispatcher calls it on the
-- tier it asked for.
--
-- WHY IT EXISTS
-- Every watcher scheduled its own loop, and every watcher that served
-- jobs walked the whole job list itself. Two watchers polling every
-- frame for their own reactions walked it twice a frame, reading every
-- job's reaction name twice. Here the list is walked ONCE per tick for
-- every subscriber that asked, each job's reaction name is read once,
-- and each subscriber is handed only the jobs it wants.
--
-- CADENCE
-- A subscriber runs every N frames, its own N, so a loop ported here
-- keeps exactly the cadence it had. The common ones have names:
--   frame   1    things that race a hauler or ride the UI
--   fast    5    job servicing that can wait a moment
--   steady  10   job servicing that can wait a little longer
--   slow    100  invariants, keys, memos
-- Every cadence shares one timer, and a frame where several are due
-- walks the jobs once for all of them.
--
-- PAUSE
-- A subscriber runs only while the game is unpaused, unless it asks for
-- paused = true. A paused tick with nobody to run costs a counter and a
-- flag read, and walks nothing.
--
-- SUBSCRIBING, from a module's start()
--   local api = _G.refinish_dispatch_api
--   api.subscribe(name, { tier = 'frame', jobs = pred, fn = callback })
--     name    unique. Subscribing again under the same name replaces the
--             old subscription, which is what a module that restarts on
--             every data cycle needs. The profiler row is 'd:' .. name.
--     every   frames between calls, a whole number from 1. Or
--     tier    one of the names above. Default: every frame.
--     jobs    optional. A function(reaction_name, job_type) -> true or
--             false, and fn is handed the list of this tick's jobs that
--             match; a job that is not a reaction is offered as ''. Or
--             true, and fn is handed every job in the list.
--             The list is READ ONLY and good for this tick only. Most
--             ticks a filtered list is EMPTY, one shared table, and
--             the every-job list is the dispatcher's own buffer.
--     fn      function(jobs), called inside pcall.
--     paused  true to run while the game is paused. Default false.
--   api.unsubscribe(name)
-- subscribe returns true, or false and a reason. A module that gets
-- false, or finds no handle at all (an RM without this file), keeps
-- its own loop, so nothing here is a hard dependency.
--
-- Through the _G handle, never reqscript on a hot path: resolving a
-- script by name costs about 2 ms a call (engine notes).
--
-- JOBS ARE ONLY GOOD FOR THE TICK THEY ARE HANDED OUT IN. Never keep
-- one: a job can be finished or cancelled by DF between any two ticks,
-- and a kept reference then points at freed memory. And a subscriber
-- that REMOVES a job ends it for every subscriber after it in the same
-- tick, so two subscribers that remove jobs must never have
-- overlapping predicates. The rot and cremate watchers match disjoint
-- reaction prefixes, which is the pattern.
--
-- TIMING, FOR THE PROFILER
-- Every subscriber is timed here and written into the profiler's own
-- rows as 'd:<name>', so the LOOP COST panel shows each one exactly as
-- it showed its old loop. The dispatcher's own share, the walk and the
-- bookkeeping, is the row 'd:refinish-loop-dispatch'. The tick itself is
-- registered with the profiler as SELF TIMED, so its interception does
-- not time the tick a second time and the panel's total adds up.
-- Timing runs only while the profiler does (live or armed), exactly
-- like the profiler's own wrappers, so an unprofiled session pays
-- nothing for it.
--
-- ERRORS
-- A subscriber that throws is logged once per session, by name, and
-- keeps being called: one broken watcher never stops the others and
-- never stops the tick.
--
-- LIFECYCLE
-- refinish_steel loads this file at its own load, so the subscribe
-- handle exists before any module starts (modules start inside the
-- pipeline, which runs before refinish_steel starts its loops). It
-- starts the tick once the pipeline is up, next to the menu icon
-- stamper, and stops it at map unload. Stopping drops every
-- subscription: the next world's modules subscribe again in their own
-- start(). The tick keeps running through data cycles, like every
-- other RM loop; the modules re-subscribe under the same names.
--
-- The timer is 'frames', which DF does NOT cancel on a world unload
-- (Lua_API), so stop() cancels it by id with timeout_active(id, nil).
--
-- COMMANDS (console)
--   refinish-loop-dispatch status    subscribers, tiers, and whether it runs
-- ==========================================

local TIER_FRAMES = { frame = 1, fast = 5, steady = 10, slow = 100 }

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. SUBJECT is SUBSCRIBE for the roster, SUBSCRIBER for a
-- subscriber's fault, START and STOP. Every line reaches the log on
-- disk; filtering is the panel's job alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'DISPATCH'
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
-- STATE, ON _G
-- ==========================================
-- On _G rather than in this file's locals, so a reload of this file
-- (development only) finds the subscriptions and the running timer
-- where it left them instead of starting a second copy beside them.
--   subs     name -> subscription
--   groups   one entry per cadence in use, shortest first, each
--            holding its subscriptions in name order; rebuilt on change
--   running  is the tick live
--   timer    the pending timer's id, for stop() to cancel
--   frame    ticks since start, which is what the tiers divide
--   errored  name -> true, a fault already logged this session
-- ==========================================
_G.refinish_dispatch = _G.refinish_dispatch or {}
local D = _G.refinish_dispatch
D.subs    = D.subs    or {}
D.groups  = D.groups  or {}
D.running = D.running or false
D.frame   = D.frame   or 0
D.errored = D.errored or {}

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Shortest cadence first and name order within one, so the order
-- subscribers run in never depends on how a table happened to hash.
local function rebuild()
    local names = {}
    for name in pairs(D.subs) do names[#names + 1] = name end
    table.sort(names)
    local by_every, groups = {}, {}
    for _, name in ipairs(names) do
        local s = D.subs[name]
        local g = by_every[s.every]
        if not g then
            g = { every = s.every, subs = {} }
            by_every[s.every] = g
            groups[#groups + 1] = g
        end
        g.subs[#g.subs + 1] = s
    end
    table.sort(groups, function(a, b) return a.every < b.every end)
    D.groups = groups
end

-- ==========================================
-- SUBSCRIBING
-- ==========================================
function subscribe(name, spec)
    if type(name) ~= 'string' or name == '' then
        return false, 'a subscription needs a name'
    end
    if type(spec) ~= 'table' or type(spec.fn) ~= 'function' then
        return false, 'a subscription needs fn'
    end
    local every = spec.every
    if every == nil then
        every = TIER_FRAMES[spec.tier or 'frame']
        if not every then return false, 'unknown tier ' .. tostring(spec.tier) end
    end
    if type(every) ~= 'number' or every < 1 or every % 1 ~= 0 then
        return false, 'every must be a whole number of frames from 1'
    end
    if spec.jobs ~= nil and spec.jobs ~= true and type(spec.jobs) ~= 'function' then
        return false, 'jobs must be true or a function of the reaction name'
    end
    D.subs[name] = {
        name   = name,
        every  = every,
        jobs   = spec.jobs,
        fn     = spec.fn,
        paused = spec.paused == true,
        key    = 'd:' .. name,
    }
    D.errored[name] = nil
    rebuild()
    -- DETAIL: every module re-subscribes on every data cycle.
    log('DETAIL', ('%s every %d frame(s)%s.'):format(name, every,
        spec.jobs == true and ', with every job'
        or spec.jobs and ', with its jobs' or ''), 'SUBSCRIBE')
    return true
end

function unsubscribe(name)
    if D.subs[name] then
        D.subs[name] = nil
        rebuild()
    end
end

-- ==========================================
-- THE JOB WALK, ONCE PER TICK
-- ==========================================
-- Two buffers reused from tick to tick, so a busy fort does not build
-- two fresh tables every frame. n says how much of each is this tick's;
-- anything past it is last tick's and is cleared, so no stale job is
-- ever left where a later walk could read it.
local job_buf, name_buf, type_buf, job_n = {}, {}, {}, 0

-- ONLY A REACTION JOB'S NAME IS READ. Reading a string field builds a
-- Lua string, and most of a fort's job list is hauling, digging and
-- building, whose reaction name is empty. Those are handed to the
-- predicates as '' after one integer read of the job type, which no
-- predicate asking for a reaction name can match.
local CUSTOM = df.job_type.CustomReaction

local function walk_jobs()
    local n = 0
    local link = df.global.world.jobs.list.next
    while link do
        local j = link.item
        if j then
            n = n + 1
            local jt = j.job_type
            job_buf[n] = j
            type_buf[n] = jt
            name_buf[n] = (jt == CUSTOM) and j.reaction_name or ''
        end
        link = link.next
    end
    for i = n + 1, job_n do
        job_buf[i], name_buf[i], type_buf[i] = nil, nil, nil
    end
    job_n = n
end

-- The one shared empty list. Read only, see the header.
local EMPTY = {}

-- One subscriber, called as pcall(run, s, walked). Its predicate runs
-- in here too, so a predicate that throws is that subscriber's fault
-- and is timed as that subscriber's cost.
local function run(s, walked)
    local mine = nil
    if s.jobs == true then
        -- Every job: the buffer itself, exactly job_n long, since the
        -- walk clears whatever last tick left past the end.
        mine = walked and job_buf or EMPTY
    elseif s.jobs then
        mine = EMPTY
        if walked then
            local pred = s.jobs
            for i = 1, job_n do
                if pred(name_buf[i], type_buf[i]) then
                    if mine == EMPTY then mine = {} end
                    mine[#mine + 1] = job_buf[i]
                end
            end
        end
    end
    s.fn(mine)
end

-- ==========================================
-- TIMING
-- ==========================================
-- The profiler's state block, when it is timing anything, else nil.
local function profiler()
    local P = _G.refinish_perf_probe
    if P and P.stats and (P.live or P.armed) then return P end
    return nil
end

-- The profiler's row shape, backfilled the way its own slot() does, and
-- looked up by name every time so a reset of its counters can never
-- leave this writing into a table nobody reads.
local function record(P, key, dt)
    local s = P.stats[key]
    if not s then
        s = {}
        P.stats[key] = s
    end
    s.calls  = (s.calls or 0) + 1
    s.ms     = (s.ms or 0) + dt
    s.max_ms = math.max(s.max_ms or 0, dt)
    s.adopts = s.adopts or 0
end

-- ==========================================
-- THE TICK
-- ==========================================
-- ---- NAMED FOR DFHACK'S TIMERS ----
-- DFHack's own timers (print_timers, under Lua timer details) name a
-- loop only when it reports each run's time, which repeat-util does
-- for its jobs (dfhack.internal.recordRepeatRuntime, repeat-util.lua).
-- This dispatcher runs on a raw dfhack.timeout, so everything it runs
-- landed in the report's unnamed "framework" row. MEASURED 2026-10-02:
-- 18,399 ms of one session's 24,421 ms of Lua timers were unnamed. Each
-- subscriber now reports its run under its own key, and the dispatcher
-- its own share under d:refinish-loop-dispatch, the names RM's profiler
-- uses. RM's other raw loops do the same: refinish_steel.lua (its three
-- loops), refinish-menu-icons.lua and refinish-module-inject-building.lua.
-- Without the internal function (another DFHack build), nothing is
-- recorded.
local record_runtime = dfhack.internal and dfhack.internal.recordRepeatRuntime

local tick   -- defined below; schedule() hands it to the timer

local function schedule()
    -- Registered as self timed on every schedule, not once, so a
    -- profiler that starts after this is still told before the timer
    -- call it would otherwise wrap.
    local P = _G.refinish_perf_probe
    if P and P.self_timed then P.self_timed[tick] = true end
    D.timer = dfhack.timeout(1, 'frames', tick)
end

tick = function()
    D.timer = nil
    if not D.running then return end
    D.frame = D.frame + 1

    local P = profiler()
    local t_all = P and dfhack.getTickCount() or 0
    local t_subs = 0
    -- NAMED FOR DFHACK'S TIMERS: the tick's start, and what its
    -- subscribers took, so the dispatcher's own share is what is left.
    local t_tick = record_runtime and dfhack.getTickCount() or 0
    local t_named = 0
    local paused = dfhack.world.ReadPauseState()
    local walked = false

    for _, g in ipairs(D.groups) do
        if D.frame % g.every == 0 then
            for _, s in ipairs(g.subs) do
                if s.paused or not paused then
                    -- The walk happens on the first subscriber that
                    -- wants jobs, and never on a tick where none does.
                    if s.jobs and not walked then
                        walked = pcall(walk_jobs)
                    end
                    local t0 = (P or record_runtime) and dfhack.getTickCount() or 0
                    local ok, err = pcall(run, s, walked)
                    if record_runtime then
                        pcall(record_runtime, s.key, t0)
                        t_named = t_named + (dfhack.getTickCount() - t0)
                    end
                    if P then
                        local dt = dfhack.getTickCount() - t0
                        record(P, s.key, dt)
                        t_subs = t_subs + dt
                    end
                    if not ok and not D.errored[s.name] then
                        D.errored[s.name] = true
                        -- ERROR: a watcher that throws every tick does
                        -- none of its work; named once, still called.
                        log('ERROR', ('%s threw: %s'):format(s.name,
                            tostring(err)), 'SUBSCRIBER')
                    end
                end
            end
        end
    end

    if P then
        record(P, 'd:refinish-loop-dispatch', (dfhack.getTickCount() - t_all) - t_subs)
    end
    if record_runtime then
        -- The dispatcher's own share, the tick less its subscribers,
        -- passed as a span that ends now. Never below zero: the counter
        -- is unsigned, and millisecond reads can round past each other.
        local now = dfhack.getTickCount()
        local own = math.max(0, (now - t_tick) - t_named)
        pcall(record_runtime, 'd:refinish-loop-dispatch', now - own)
    end
    schedule()
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start()
    -- A timer left by a copy of this file loaded before a reload would
    -- make two chains. Cancelled first, so there is only ever one.
    if D.timer then pcall(dfhack.timeout_active, D.timer, nil) end
    D.running = true
    D.frame = 0
    D.errored = {}
    schedule()
    log('DETAIL', ('started, %d subscriber(s).'):format(count(D.subs)), 'START')
    return true
end

function stop()
    if D.timer then pcall(dfhack.timeout_active, D.timer, nil) end
    D.timer = nil
    D.running = false
    D.subs = {}
    rebuild()
    log('DETAIL', 'stopped; every subscription dropped.', 'STOP')
end

-- ---- THE HANDLE ----
-- Published at load, not at start, because modules subscribe during the
-- pipeline, before start() runs. See LIFECYCLE.
_G.refinish_dispatch_api = { subscribe = subscribe, unsubscribe = unsubscribe }

if dfhack_flags and dfhack_flags.module then return end

-- ==========================================
-- COMMANDS
-- ==========================================
-- Prints only here, as the direct answer to a typed command.
local args = {...}
if args[1] == 'status' then
    print(('dispatcher %s, frame %d, %d subscriber(s).'):format(
        D.running and 'running' or 'stopped', D.frame, count(D.subs)))
    for _, g in ipairs(D.groups) do
        for _, s in ipairs(g.subs) do
            print(('  every %-4d %-40s %s%s'):format(g.every, s.name,
                s.jobs == true and 'all jobs ' or s.jobs and 'jobs ' or '',
                s.paused and 'paused' or ''))
        end
    end
else
    print('refinish-loop-dispatch status')
end