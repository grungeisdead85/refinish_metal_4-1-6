--@ module = true
-- refinish-reaction-adaptive-vessels.lua
-- ==========================================
-- RM ADAPTIVE REACTIONS: VESSELS
-- ==========================================
-- The liquid half of RM's adaptive reaction engine: how many containers
-- a liquid payout needs and how many a job may grab (VESSEL EXPANSION),
-- how much the grabbed container holds and writing the liquid into the
-- ghost's products (HOW MUCH THE GRABBED CONTAINER HOLDS), which banks a
-- drain pours (DRAIN), and cleaning up liquid left at nothing in a jug
-- (NULL LIQUID REAPER). Split out of refinish-reaction-adaptive.lua,
-- section for section and unchanged, so the engine file holds the
-- engine and this one holds the containers.
--
-- WHOSE STATE. Every call here runs for the module the engine is
-- serving at that moment. The engine calls use(P) whenever it switches
-- module, which binds this file's V (the module's provider), bank,
-- liquid material prefix and drain material cache to that module's.
-- The cache is built lazily and saved back into the module's record
-- when the engine switches away.
--
-- reset() at each data cycle, tick() once per poll: both called by the
-- engine, which owns the loop.
-- ==========================================

local V, yield_bank = {}, {}
local MAT_PREFIX, drain_mat_cache = '', nil
local P_now = nil

local surgery = nil
pcall(function() surgery = reqscript('refinish-job-surgery') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- This file's own subsystem, so a vessel line says where it came from.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'REACTION_ADAPTIVE_VESSELS'
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

local CRUMBS_ON = false
local function crumb(where, extra)
    if not CRUMBS_ON then return end
    log('DETAIL', 'CRUMB ' .. tostring(where)
        .. (extra and (' ' .. tostring(extra)) or ''), 'CRUMB')
end

local seen = {}
local function log_once(key, typ, msg, subject)
    if seen[key] then return end
    seen[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- THE ENGINE'S HANDLES
-- ==========================================
-- use(P): bind this file to module P (the engine's PROVIDERS record).
function use(P)
    if P == P_now then return end
    if P_now then P_now.drain_cache = drain_mat_cache end
    P_now = P
    V          = P and P.V or {}
    yield_bank = P and P.bank or {}
    MAT_PREFIX = P and P.mat_prefix or ''
    drain_mat_cache = P and P.drain_cache or nil
end

-- reset(): a new data cycle. The engine's reset_engine calls this.
function reset()
    seen = {}
    drain_mat_cache = nil
    if P_now then P_now.drain_cache = nil end
    expand_state    = {}
    vessel_poll     = 0
    pool_room_cache = { poll = -1, cap = nil }
    -- A data cycle can rebuild the tool defs: see THE POOL TEST.
    liquid_room     = {}
    -- ...and the containers with them: THE KNOWN CONTAINERS.
    known_cont, known_cont_poll, known_cont_floor = nil, -1, nil
end

-- tick(): once per engine poll.
function tick()
    vessel_poll = vessel_poll + 1
end

-- ==========================================
-- VESSEL EXPANSION
-- ==========================================
-- A stack burns whole, so a big stack can earn several packages of a
-- liquid in one run. A reaction declares ONE output container per
-- liquid slot, so without this it pays one and banks the rest.
-- Measured: a 200 rye stack earns 6.400 tar_plant, pays 1, strands
-- 5.400 every single run. That is not a rare bound, it is ordinary
-- farm output, and the surplus never drains.
--
-- THE FIX IS MORE CONTAINERS, EACH FILLED IN WHOLE PACKAGES. This
-- first read "never fuller ones: one package per container, always",
-- because a reaction takes the FIRST item meeting its requirements, so
-- a container holding anything but whole packages breaks every
-- consumer that meets it. That is the partial bug, and it is still
-- never allowed. What changed is the writer: write_liquid (FILL WHAT
-- WAS GRABBED) fills each grabbed container with as many WHOLE
-- packages as its capacity takes (slot_room: a jug takes sixteen
-- one-unit packages), and containers_wanted asks for
-- ceil(packages / room) containers, not one per package. Count is
-- still never the lever, and no container ever holds part of a
-- package. Go by the functions if this note and they ever disagree: it
-- went on saying one package per container after the writer changed,
-- and a design was built on it (2026-09-29).
--
-- SO: append a whole triple per extra container, and take them off
-- again when the cycle ends.
--   a vessel REAGENT, cloned from the reaction's own vessel so it
--   inherits has_tool_use, empty and preserve, with a unique code
--   a job_item FILTER pointing at that reagent by index
--   a PRODUCT slot for the same liquid, whose product_to_container
--   names the new reagent's code
--
-- WHY ALL THREE. The reagent drives completion, the filter drives
-- collection, and product_to_container is a STRING naming a reagent
-- code, so a second package needs its own product slot. Appending
-- only some of them produces a job that cannot be satisfied.
--
-- WHY REAGENT AND FILTER MUST MOVE TOGETHER. repair_filters shrinks
-- the filter vector every poll to a target counted from
-- ghost.reagents. Append a filter alone and it is erased within a
-- poll; append both and the target grows in step. This is also why
-- the slot surgery round trip passed with that repair running live.
--
-- APPEND AT THE END, ERASE FROM THE END. Nothing before the last
-- entry shifts, so every existing job_item_idx and reagent_index
-- stays valid and no fixup is needed.
--
-- REMOVE ONLY BETWEEN CYCLES, in the poll, when job.items is empty
-- AND the cycle actually held items. An empty item list also occurs
-- before the first haul, and removing there would strip slots off a
-- job that has not run.
--
-- NEVER ASK FOR A JUG THAT IS NOT THERE. The count below is exact on
-- everything but reachability: a container must be a LIQUID_CONTAINER
-- tool, empty, unforbidden and unclaimed. Reachability uses
-- canWalkBetween, which is a walkability cache lookup and cannot see
-- burrows or invaders, so it is a FILTER and never a guarantee. Both
-- failure directions are bounded: a wrong accept costs one over ask
-- ending in a DF cancellation that recovers cleanly, a wrong reject
-- costs one package banked that drains later.
--
-- THE SWITCH. Off appends no extra containers: each liquid slot pays
-- into the reaction's own container alone, filled as write_liquid
-- fills any. It can be disabled live without a recycle. vessels_on
-- reads this name; the note once gave refinish_fuel_vessels, which
-- nothing reads:
--   :lua refinish_adaptive_vessels = false
-- ==========================================
VESSEL_EXPANSION = true

-- Hard ceiling on extra jugs PER CURRENCY, regardless of what the
-- arithmetic asks for. A backstop against a runaway, not a balance
-- number: an earlier build had no memory of what it had appended and
-- grew the vectors on every poll, reaching 684 appends in eighteen
-- seconds. This file has been here before, with filters reaching 26
-- on dung and 65 on branches.
--
-- PER CURRENCY, not per job. Counted per job it was a shared budget,
-- so whichever currency the stream loop reached first spent all of
-- it. Measured on a giant sperm whale corpse: oil_bone took all four
-- extras and ammonia, which had earned 11 packages, got none at all.
-- The JUGS are still shared and counted once per poll, which is
-- correct, because every currency draws from the same pile.
--
-- IT MUST NOT BIND IN NORMAL PLAY. A cap below what a run earns makes
-- the bank grow forever, because the remainder carries into the next
-- run and pushes the demand higher still. Measured on repeating 200
-- rye earning 6.4: a cap of 4 grows the bank 1.4 a run without limit,
-- a cap of 5 still creeps, and a cap of 6 oscillates and drains to
-- zero. Headroom above the earning is what lets it drain, so the
-- fort's jug supply should be the throttle, not this.
-- Sized to take a giant sperm whale in one run. A fresh whale earns
-- 35 oil bone and 11 ammonia, so 34 and 10 extras, and it was
-- measured collecting about 46 containers and emptying the banks
-- completely in a single run.
VESSEL_MAX_EXTRA = 40

-- A SECOND bound, on the whole job rather than one currency, and it
-- exists for a different reason. Measured: 44 filters completes, and
-- a run that wanted about 67 took the corpse, took one container, and
-- then dropped the corpse. Whatever that boundary is, it is between
-- those two numbers, and a job that FAILS is worse than a job that
-- banks. So the total stays inside proven territory and a compounded
-- input banks the difference instead of asking for a shape that has
-- been seen to fail.
--
-- This is not the per job budget that starved ammonia. That was the
-- per currency ceiling being shared; this sits above both and only
-- binds when their sum is large enough to be dangerous.
-- ---- DF WILL NOT GATHER FOR A JOB PAST THIS MANY FILTERS ----
-- Measured, on whales at one furnace:
--
--   47 filters, 44 extras   gathered and BURNED
--   49 filters, 46 extras   two containers claimed in twenty seconds
--                           against fifty two free, then the job died
--                           without consuming anything
--   about 67 filters        same shape, took the corpse and dropped it
--
-- So the ceiling is 48 and 47 is proven. It is a limit on the JOB,
-- not on our extras, which is why it must be counted in FILTERS: a
-- reaction with four base reagents reaches it sooner than one with
-- three.
--
-- WHAT MADE IT LOOK RANDOM. The variable is the carried bank, not the
-- feedstock. The first whale earns 35 oil and 11 ammonia and needs 47
-- filters. Its remainder carries, so the SECOND whale at the same
-- furnace earns 36 and 12, needs 49, and cannot run at all. It looked
-- like cancelling a job broke the next one; what actually happened is
-- that the next one asked for two more containers.
--
-- Set to the proven number, not the boundary. One short costs a
-- package that banks and is paid next run; one over costs the whole
-- burn.
VESSEL_MAX_FILTERS = 47

-- Containers never offered to a job, so it can never ask for the last
-- one in the fort. See the margin note in count_free_vessels: asking
-- for exactly everything gets the job refused outright, and a refused
-- job loses its whole burn while an unasked container only delays a
-- package.
VESSEL_RESERVE = 4

-- Live override, same shape as the on/off switch, so the ceiling can
-- be lifted for a test and dialled back without editing this file or
-- recycling:
--     :lua refinish_adaptive_vessel_max = 999   run it bare
--     :lua refinish_adaptive_vessel_max = nil   back to the default
-- The material's OWN name, not the id lowercased. The materials file
-- already names these properly: OIL_BONE is "bone oil", TAR_COAL is
-- "coal tar", VINEGAR_WOOD is "wood vinegar". Lowercasing the id
-- gives "oil bone", which is not what anything else in the game calls
-- it, and reordering the words by hand only moves the guesswork.
--
-- Falls back to the flattened id ONLY if the material cannot be read,
-- so a missing material shows something rather than nothing.
function currency_name(currency)
    local nm = nil
    pcall(function()
        local mi = dfhack.matinfo.find('INORGANIC:'
            .. tostring(V.CURRENCY_MATERIAL_PREFIX or '') .. tostring(currency))
        if mi and mi.material then
            local s = mi.material.state_name.Liquid
            s = s and tostring(s) or nil
            if s and #s > 0 then nm = s end
        end
    end)
    if nm then return nm end
    local flat = string.lower(tostring(currency)):gsub('_', ' ')
    return flat
end

function vessel_max()
    local g = _G.refinish_adaptive_vessel_max
    if type(g) == 'number' and g >= 0 then return math.floor(g) end
    return VESSEL_MAX_EXTRA
end

function vessels_on()
    local g = _G.refinish_adaptive_vessels
    if g == nil then return VESSEL_EXPANSION end
    return g and true or false
end

-- ---- FAIR SHARE OF THE CONTAINERS ----
-- count_free_vessels reads the world, and the world does not know
-- what another job appended a moment ago. flags.in_job only excludes
-- a container once a dwarf has claimed it, and every append happens
-- before hauling starts, so two furnaces starting together each
-- counted the whole pile and each promised itself all of it.
-- Measured: two whales at once, jobs 10 and 11, appended 44 apiece
-- against one pile. 88 demanded, neither aware of the other.
--
-- The pile is divided by the number of jobs that WANT extras, not by
-- the number running. Nine furnaces burning single logs beside one
-- whale should not cut the whale to a tenth; they would never have
-- taken an extra container.
--
-- Nothing here can make a run worse than it was before expansion
-- existed. A job always has its own base vessels, which are the
-- reaction's own reagents and are never touched, so the floor is one
-- package per currency. Extras are upside, and this only decides how
-- the upside is split.
--
-- vessel_poll is a counter of this file's own. audit_tick is declared
-- far below and reading it here would resolve to a global, silently
-- nil, which is a trap this file has been caught by before.
vessel_poll = 0

-- [job.id] = {
--   n     = triples appended this cycle
--   wants = extras this job would take if the pile allowed
--   tick  = the poll it last asked on, so a dead job stops counting
--   held  = true once the job was seen holding items
--   slots = { [currency] = { product indices appended for it } }
-- }
--
-- `slots` is the part that was missing and it is the whole bug. The
-- stream loop runs six times a second, and without a record of what
-- was already appended, every poll rebuilt the list from the base
-- slot and appended the difference AGAIN.
expand_state = {}

function expand_for(job)
    local st = expand_state[job.id]
    if not st then
        st = { n = 0, held = false, slots = {} }
        expand_state[job.id] = st
    end
    return st
end

-- ---- IS THIS JOB STILL COLLECTING? ----
-- Extra slots appended to a job whose base filters are ALL already
-- filled are never hauled for. DF closes a job's collection phase
-- once its own reagents are covered, and appending after that does
-- not re-open it.
--
-- MEASURED, two whale corpse runs in one session:
--   job 10 expanded holding 1 of its 3 base filters. DF fetched
--          every extra, reached attached=47 filters=47, and BURNED.
--   job 14 expanded holding 3 of 3. It claimed not one further
--          container out of 52 free in the fort, and died with 44
--          filters unfilled.
-- Availability was never the difference. Timing was.
--
-- This is why the defect needs a CANCEL to reproduce. A cancelled
-- job leaves its feed and its jugs standing at the workshop, so the
-- next job fills every base filter inside a single frame and is
-- already closed by the time the swap fires.
--
-- MEASURED BY FILTER COVERAGE, NOT BY ITEM COUNT. DF attaches spare
-- items to filters that are already satisfied (register K1, the
-- unforbidden corpse swept onto a full q1 slot) and sometimes
-- attaches at job_item_idx -1. Either inflates #job.items and would
-- refuse a job that genuinely still had a slot open. Asking which
-- base indices are covered is immune to both.
--
-- The base filters are the ones this cycle was born with, so they
-- are everything below the extras this cycle has appended: st.n.
function collection_open(job, st)
    local n_base = 0
    local ok_n = pcall(function()
        n_base = #job.job_items.elements - (st and st.n or 0)
    end)

    local covered = {}
    local ok_c = pcall(function()
        for _, iref in ipairs(job.items) do
            local i = iref.job_item_idx
            if i and i >= 0 and i < n_base then covered[i] = true end
        end
    end)

    -- ---- UNREADABLE MEANS CLOSED ----
    -- The two errors are not symmetric. Wrongly answering OPEN
    -- appends filters nothing will ever haul and kills the whole
    -- burn, which is the defect this exists to stop. Wrongly
    -- answering CLOSED banks the surplus and the next run pays it
    -- out. So a failed read takes the cheap error, and announces
    -- itself rather than going quiet about it.
    if not ok_n or not ok_c or n_base < 1 then
        log_once('collect_read:' .. tostring(job.id), 'WARNING', string.format('VESSEL: job %s filter coverage unreadable,'
                .. ' so no extra containers are asked for and the'
                .. ' surplus banks.', tostring(job.id)), 'VESSEL')
        return false
    end

    for i = 0, n_base - 1 do
        if not covered[i] then return true end
    end
    return false
end

-- The workshop tile. job.pos first, then any attached item, which is
-- standing at the workshop by definition. Verified in play: job.pos
-- read 96,92,130 on a live retort.
function job_tile(job)
    local p = nil
    pcall(function()
        if job.pos and job.pos.x and job.pos.x >= 0 then
            p = xyz2pos(job.pos.x, job.pos.y, job.pos.z)
        end
    end)
    if p then return p end
    pcall(function()
        for _, iref in ipairs(job.items) do
            local x, y, z = dfhack.items.getPosition(iref.item)
            if x then p = xyz2pos(x, y, z) return end
        end
    end)
    return p
end

-- ==========================================
-- THE POOL TEST, ONE TOOL, SHARED BY BOTH WALKS
-- ==========================================
-- MEASURED 2026-09-30 (section probe, 606 s, busy fort): the vessel
-- plan and product writes in the engine cost 1.24 ms a call, 29.3
-- ms/sec. count_free_vessels, timed on its own inside that, was 2.9 of
-- it at 6.07 ms a call; the only other item walk on the path is
-- pool_min_capacity, cached per poll, so at most one a poll. Both walk
-- every tool in the fort with, per tool, a closure, a pcall, and a
-- read of the subtype's whole tool_use vector.
--
-- Whether a tool is a liquid container, and how much it holds, belongs
-- to its SUBTYPE, and a fort has far fewer tool subtypes than tools.
-- So it is read once per subtype and kept:
--   liquid_room[subtype] = container capacity (a number), or false for
--   a tool that is not a liquid container
-- Every later tool costs one call and one lookup, and only liquid
-- containers go on to the flag and contents tests. Hoisted, so a walk
-- builds no closure per tool.
--
-- SAME ANSWERS. The same tests in the same order as the old per tool
-- closures, with the tool_use answer asked of the subtype instead of
-- each item. A tool whose test throws is skipped, as before, and its
-- subtype is not recorded, so the next one asks again.
--
-- A module global, like pool_room_cache: reset() above clears it, and
-- a local declared here would be out of its reach.
-- ==========================================
liquid_room = {}

-- The capacity of `it`'s subtype if that is a liquid container, else
-- nil: THE POOL TEST's per subtype half on its own, which is all the walk
-- of THE KNOWN CONTAINERS asks. check_type is for the items.all
-- fallback, which holds more than tools; the TOOL vector holds nothing
-- else.
local function liquid_cap_of(it, check_type)
    if check_type and it:getType() ~= df.item_type.TOOL then return nil end
    local st = it:getSubtype()
    local room = liquid_room[st]
    if room == nil then
        room = false
        for _, u in ipairs(it.subtype.tool_use) do
            if u == df.tool_uses.LIQUID_CONTAINER then
                room = tonumber(it.subtype.container_capacity) or 0
                break
            end
        end
        liquid_room[st] = room
    end
    if not room then return nil end
    return room
end

-- The capacity if `it` is an empty, unforbidden, unclaimed liquid
-- container, else nil.
local function free_container_room(it, check_type)
    local room = liquid_cap_of(it, check_type)
    if not room then return nil end
    if it.flags.forbid or it.flags.in_job then return nil end
    if #(dfhack.items.getContainedItems(it) or {}) > 0 then return nil end
    return room
end

-- True if a dwarf at wpos can walk to the tool.
local function reachable_from(wpos, it)
    local x, y, z = dfhack.items.getPosition(it)
    if not x then return false end
    return dfhack.maps.canWalkBetween(wpos, xyz2pos(x, y, z)) and true
end

-- ==========================================
-- THE KNOWN CONTAINERS
-- ==========================================
-- MEASURED 2026-10-01 (section probe, 700 s, 4,884 twin items): the pool
-- walk cost 8.1 ms and ran 289 times, 3.35 ms/sec, and its cost had risen
-- with the twin count over three runs (2.1, 5.5, 8.1 ms a walk): it reads
-- every tool in the fort, and gravel and kindling are tools.
-- count_free_vessels walks the same tools (2.84 ms a call over 762 calls
-- in an earlier run).
--
-- Only a liquid container can answer either question, and a tool's
-- subtype never changes. So a walk now records the liquid containers
-- (known_cont, by item id), and both questions read that list, testing
-- every container on it fresh each time, as the walk did (THE POOL TEST,
-- then reachability). A container that is gone is not found and leaves
-- the list.
--
-- THE WALK STAYS, AT LEAST EVERY CONT_FULL_POLLS, for containers made or
-- brought in since. Until then a new container is not counted, which
-- errs low, the safe side for both questions: count_free_vessels asks for
-- fewer containers (LEAVE A MARGIN: an unasked container is a package
-- banked, an over ask a cancelled job), and the pool minimum can only
-- come out higher, which asks for fewer too. No container the walk would
-- refuse is ever counted.
--
-- Module globals, like pool_room_cache: reset() clears them for a data
-- cycle, which can rebuild the tool defs.
-- ==========================================
CONT_FULL_POLLS  = 200
known_cont       = nil   -- item id -> true, every liquid container tool known
known_cont_poll  = -1    -- vessel_poll of the walk that built it
known_cont_floor = nil   -- the smallest capacity above zero among them

local function id_of(it) return it.id end

-- The list, rebuilt by a walk of every tool when there is none, when
-- CONT_FULL_POLLS have passed since the last walk, or when the poll count
-- has gone back (reset() starts it from 0 for a data cycle). nil if no
-- item vector can be read.
local function known_containers()
    if known_cont and vessel_poll >= known_cont_poll
       and vessel_poll - known_cont_poll < CONT_FULL_POLLS then
        return known_cont
    end
    local vec, check_type = nil, false
    pcall(function() vec = df.global.world.items.other.TOOL end)
    if not vec then
        check_type = true
        pcall(function() vec = df.global.world.items.all end)
    end
    if not vec then return nil end
    -- SECTION CLOCK (refinish-section-probe): one lap per walk.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    local nvec = -1
    pcall(function() nvec = #vec end)
    crumb('P container walk in', string.format('%d item(s)', nvec))
    local found, floor, n, walked = {}, nil, 0, 0
    for _, it in ipairs(vec) do
        walked = walked + 1
        -- Every 25, so a crash inside the walk is bounded to a 25 item
        -- window instead of the whole vector, without one line per item.
        if walked % 25 == 0 then crumb('P..', walked .. '/' .. nvec) end
        local ok, room = pcall(liquid_cap_of, it, check_type)
        if ok and room then
            local okid, id = pcall(id_of, it)
            if okid then
                found[id] = true
                n = n + 1
                if room > 0 and (floor == nil or room < floor) then floor = room end
            end
        end
    end
    known_cont, known_cont_poll, known_cont_floor = found, vessel_poll, floor
    crumb('Q container walk out', tostring(n))
    log_once('known_cont', 'DETAIL', ('container list: %d liquid container(s) among %d tool(s),'
        .. ' walked again at least every %d polls.'):format(n, nvec, CONT_FULL_POLLS), 'CONTAINERS')
    if sc then sc.lap('vessels: container list walk (backstop)', t0) end
    return found
end

-- Empty, unforbidden, unclaimed, reachable liquid containers.
-- getPosition returns THREE values; capturing it into one takes only
-- x and every later call throws. That mistake counted two jugs
-- sealed inside a walled structure.
--
-- RESERVES THE BASE VESSELS. A jug is excluded once it is claimed,
-- but the reaction's OWN vessels are often not claimed yet at the
-- moment of counting, so they were counted as spare and then promised
-- to the extras as well. Measured: a job wanting 7 jugs was sized
-- against a count that had double counted 2 of them, and it took
-- every jug in the fort and then failed for want of a liquid
-- container. Subtracting the base count always is conservative: when
-- the base jugs ARE already claimed it under counts, which only banks
-- a package for later.
function count_free_vessels(job, ghost)
    local wpos = job_tile(job)
    if not wpos then return 0 end   -- cannot verify, so ask for nothing

    -- THE KNOWN CONTAINERS, each through THE POOL TEST, fresh; only a
    -- free one is then placed and walked to. One that is gone leaves the
    -- list.
    local list = known_containers()
    if not list then return 0 end
    local n = 0
    for id in pairs(list) do
        local it = df.item.find(id)
        if not it then
            list[id] = nil
        else
            local okr, room = pcall(free_container_room, it, false)
            if okr and room then
                local okw, near = pcall(reachable_from, wpos, it)
                if okw and near then n = n + 1 end
            end
        end
    end

    -- Hold back one for each vessel the reaction already declares.
    -- The ghost is PASSED IN rather than fetched from ghost_cache,
    -- because this function is defined above that upvalue. Reading it
    -- here would resolve to a global, silently be nil, and skip the
    -- reservation while compiling perfectly.
    local base = 0
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            if ghost.reagents[i].flags.PRESERVE_REAGENT then
                base = base + 1
            end
        end
    end)
    n = n - base

    -- ---- LEAVE A MARGIN ----
    -- A job that asks for every container in the fort is refused
    -- outright. Measured: 48 free with 46 asked completed; 18 free,
    -- 20 with the base, with 20 asked was cancelled inside one
    -- second, before a single container had been hauled, announcing
    -- "Needs corpse". The filter count was not it, 47 filters worked
    -- and 21 did not. The difference was two spare containers against
    -- none.
    --
    -- Erring low costs nothing. An unasked container is one package
    -- waiting in the bank that the next run pays out; an over ask is
    -- a cancelled job that loses the whole burn.
    n = n - VESSEL_RESERVE

    if n < 0 then n = 0 end
    return n
end

-- Appends one triple for `cur`, cloning the reaction's own vessel
-- reagent and the product at `at`. Returns the new product index, or
-- nil if anything could not be built.
-- ---- DEFINED HERE, ABOVE EVERY CALLER, DELIBERATELY ----
-- This block first sat immediately above write_liquid, which is below
-- slots_for_liquid. slots_for_liquid calls slot_room, so the reference
-- resolved to a GLOBAL at call time and came back nil:
--
--   ERROR in poll: attempt to call a nil value (global 'slot_room')
--
-- It only fired on a job that actually expanded, because a job wanting
-- one container returns from slots_for_liquid before reaching the
-- call. So a buffalo worked and a whale produced nothing at all.
--
-- Same family as the scope trap already in the register. The rule is
-- the same: define above every caller, and check the ordering rather
-- than trusting that it compiled.
-- ==========================================
-- HOW MUCH THE GRABBED CONTAINER HOLDS
-- ==========================================
-- MEASURED, not assumed, and confirmed three separate ways:
--
--   1 A bone oil package in a jug reads dimension 150 and volume 60,
--     so one package costs 60 of the currency capacity is spent in.
--   2 The wiki states a tool needs 600 capacity per unit of liquid at
--     RAWS scale, and DF divides raws by ten on load. 600/10 is 60.
--   3 A test reaction writing dimension 2400 into a jug of capacity
--     1000 landed as "tallow oil (1600%)", exactly 16 packages, which
--     is 960 of 1000. Seventeen would have been 1020 and over.
--
-- Three routes to the same number, one of them a live run, so it is a
-- constant rather than a guess. It is a DF constant, not a tuning
-- knob, which is why it lives here and not in the tuning file.
LIQUID_VOLUME_PER_UNIT = 60

-- ---- SLOT -> THE CONTAINER ACTUALLY ATTACHED TO IT ----
-- A product names its vessel by REAGENT CODE in product_to_container,
-- the same string the JSON writes, for example "vessel_1". So the walk
-- is code -> reagent index -> the job item filling that reagent.
--
-- Every step is pcall wrapped and any failure returns nil, which the
-- caller reads as "fall back to one package", today's behaviour. A
-- container we cannot measure must never be assumed roomy.
-- ---- EVERY INDEX BOUNDED BEFORE IT IS USED ----
-- Both reads below are into VECTORS OF POINTERS, and an index past the
-- end of one of those is not a Lua error that pcall can catch. DFHack
-- hands the raw slot to lua_item_read, the pointer is garbage, and the
-- process dies. The DF crash log named exactly that:
--
--   dfhack!DFHack::ptr_container_identity::lua_item_read+0x56
--
-- and the poll's own error handler printed nothing, which is the tell:
-- a Lua error would have been caught and logged, so it was not one.
--
-- `idx` comes straight off iref.job_item_idx and was only checked for
-- being non negative. Nothing checked it against the number of
-- elements that actually exist, and the two can disagree: DF attaches
-- items at -1, and collapse_vessels erases elements from the END of
-- the vector while attached items keep pointing at where they used to
-- be.
--
-- Out of range is REPORTED rather than silently skipped. If this fires
-- it is the answer, and a silent skip would have hidden it.
function slot_container(job, ghost, at)
    local n_prod = -1
    pcall(function() n_prod = #ghost.products end)
    if type(at) ~= 'number' or at < 0 or at >= n_prod then
        crumb('X product slot out of range', string.format(
            'at=%s of %d', tostring(at), n_prod))
        return nil
    end

    local code = nil
    pcall(function()
        code = tostring(ghost.products[at].product_to_container)
    end)
    if not code or code == '' then return nil end

    local ri = nil
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            if tostring(ghost.reagents[i].code) == code then
                ri = i
                break
            end
        end
    end)
    if not ri then return nil end

    local n_el = -1
    pcall(function() n_el = #job.job_items.elements end)

    local found = nil
    pcall(function()
        for _, iref in ipairs(job.items) do
            local idx = iref.job_item_idx
            if type(idx) == 'number' and idx >= 0 then
                if idx >= n_el then
                    -- THE CANDIDATE. An attached item pointing past
                    -- the end of the filter vector.
                    crumb('X filter index out of range', string.format(
                        'idx=%d of %d, job %s, item %s',
                        idx, n_el, tostring(job and job.id),
                        tostring(iref.item and iref.item.id)))
                else
                    local r2 = job.job_items.elements[idx].reagent_index
                    if r2 == ri then
                        found = iref.item
                        break
                    end
                end
            end
        end
    end)
    return found
end

-- Whole packages the container on this slot can take, or nil if it
-- cannot be read. `pack` is the package size in LIQUID_UNITs, so a
-- currency packaged in twos gets half as many packages in the same
-- container.
-- ---- ROOM ESTIMATED FROM THE POOL, NOT FROM THE ATTACHED VESSEL ----
-- Vessel expansion has to decide how many containers to ask for while
-- collection is still OPEN, which is precisely before any vessel has
-- arrived. Measured: job 17 expanded holding one item, the corpse, so
-- the attached container could not be read and the estimate fell
-- through to the package count. It asked for three containers to hold
-- three packages, which is the behaviour this was meant to replace.
--
-- So the estimate reads the POOL instead: the smallest capacity among
-- the containers that could actually be grabbed. Smallest rather than
-- average or largest, because under-estimating room means asking for
-- one container too many, which banks, while over-estimating means
-- asking for too few and stranding the surplus.
--
-- Cached per poll. This walks the item vector and the stream loop
-- calls it once per currency, so without the cache a two liquid
-- reaction would scan the fort twice a poll for the same answer.
--
-- ---- HELD FOR POOL_HOLD_POLLS, NOT JUST ONE POLL ----
-- MEASURED 2026-09-30 (section probe, 539 s): even after THE POOL TEST
-- the walk cost 2.10 ms and ran on 1,336 of 4,726 polls, 5.2 ms/sec,
-- the largest single cost left in the engine.
--
-- The answer is only ever an ESTIMATE: slot_room asks for it only for
-- a slot with no container attached. A job that completes has held
-- every item, vessels included, through its working stretch (BURN TEST
-- in the engine: about twelve seconds), and every write in that
-- stretch reads the attached container's own capacity. So the estimate
-- only sizes how many extra containers a collecting job asks for, and
-- a stale answer either way costs a banked package, not a bad write
-- (the two notes above). Held for 10 polls, about a second at the
-- engine's rate, the walk runs a tenth as often.
--
-- A single value: 1 restores the old once a poll behaviour exactly.
POOL_HOLD_POLLS = 10
pool_room_cache = { poll = -1, cap = nil }

function pool_min_capacity()
    -- The last walk's answer while it is inside the hold. poll -1 (never
    -- walked, or reset() for a new data cycle) always walks.
    if pool_room_cache.poll >= 0
       and vessel_poll >= pool_room_cache.poll
       and vessel_poll - pool_room_cache.poll < POOL_HOLD_POLLS then
        return pool_room_cache.cap
    end
    pool_room_cache.poll = vessel_poll
    pool_room_cache.cap  = nil
    -- SECTION CLOCK (refinish-section-probe): one lap per real walk,
    -- quiet while the probe is off.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()

    -- THE KNOWN CONTAINERS, each through THE POOL TEST, then the smallest
    -- room above zero. Nothing on the list holds less than its smallest
    -- capacity (known_cont_floor), so finding that ends the search.
    local list = known_containers()
    if not list then return nil end
    crumb('P pool search in', 'known containers')
    local lo = nil
    for id in pairs(list) do
        local it = df.item.find(id)
        if not it then
            list[id] = nil
        else
            local ok, c = pcall(free_container_room, it, false)
            if ok and c and c > 0 and (lo == nil or c < lo) then
                lo = c
                if known_cont_floor and lo <= known_cont_floor then break end
            end
        end
    end
    pool_room_cache.cap = lo
    crumb('Q pool walk out', tostring(lo))
    if sc then sc.lap('vessels: pool search, known containers', t0) end
    return lo
end

function slot_room(job, ghost, at, pack)
    -- The attached container is the accurate answer and is preferred
    -- whenever it exists, because that is the vessel this slot will
    -- actually fill. The pool minimum is the ESTIMATE used before the
    -- vessels arrive.
    local it = job and slot_container(job, ghost, at) or nil
    if not it then
        local cap = pool_min_capacity()
        if not cap or cap <= 0 then return nil end
        local n = math.floor(cap / (LIQUID_VOLUME_PER_UNIT * pack))
        if n < 1 then return 0 end
        return n
    end

    local cap = nil
    pcall(function() cap = it.subtype.container_capacity end)
    if not cap or cap <= 0 then return nil end

    local n = math.floor(cap / (LIQUID_VOLUME_PER_UNIT * pack))
    if n < 1 then
        -- A container too small for even one package. Nothing in
        -- vanilla is, so this is a mod authoring fault and it says so
        -- rather than quietly writing zero.
        log_once('tiny_vessel:' .. tostring(cap), 'WARNING', string.format(
            'VESSEL: a container of capacity %d cannot hold even one'
            .. ' package of %d volume. Nothing will be bottled into'
            .. ' it.', cap, LIQUID_VOLUME_PER_UNIT * pack), 'VESSEL')
        return 0
    end
    return n
end

-- ---- HOW MANY CONTAINERS, NOT HOW MANY PACKAGES ----
-- packages_wanted returns PACKAGES. Vessel expansion has always used
-- that number as a CONTAINER count, which was correct only while every
-- container took exactly one package. Now that a jug takes sixteen, a
-- whale asking for 46 would append 45 slots to fill three.
--
-- The base container is the estimate, because it is the one already
-- attached and readable. If the extras turn out smaller, write_liquid
-- fills each to its own capacity and banks the remainder, so an
-- optimistic estimate costs a banked package rather than a bad write.
--
-- Unreadable falls back to the package count, which is exactly the old
-- behaviour: it over-asks, and over-asking was survivable before.
function containers_wanted(job, ghost, at, packages, pack)
    if packages < 1 then return packages end
    local room = slot_room(job, ghost, at, pack)
    if not room or room < 1 then return packages end
    return math.ceil(packages / room)
end

function append_vessel_triple(job, ghost, at, seq)
    -- ---- CLONE A VESSEL, NOT MERELY A PRESERVED REAGENT ----
    -- This took the LAST preserved reagent, on the unstated assumption
    -- that preserved means liquid container. That held only because
    -- every preserved reagent in the module was one.
    --
    -- The drain key breaks it. It is preserved and it is NOT a vessel,
    -- so expansion would clone the KEY: a filter demanding a second
    -- drain key, and a liquid product pointed at it. The drain does
    -- expand, so this would fire on its first run.
    --
    -- The test is now LIQUID_CONTAINER tool use, which is what actually
    -- makes a reagent a vessel, rather than a property vessels happen
    -- to share with other things. Ordering the key first in the JSON
    -- would also have worked, and would have been an accident passing
    -- for a rule.
    local vi = nil
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            local rg = ghost.reagents[i]
            if rg.flags.PRESERVE_REAGENT
               and rg.has_tool_use == df.tool_uses.LIQUID_CONTAINER then
                vi = i
            end
        end
    end)
    if not vi then
        -- Nothing to clone. Said out loud rather than returning
        -- quietly, because a reaction that expands but declares no
        -- vessel is an authoring fault, not a runtime condition.
        log_once('novessel:' .. tostring(ghost.code), 'WARNING', string.format(
            'VESSEL: %s has no preserved LIQUID_CONTAINER reagent to'
            .. ' clone, so no extra containers can be added.',
            tostring(ghost.code)), 'VESSEL')
        return nil
    end

    local new_at = nil
    local ok = pcall(function()
        local code = 'vessel_x' .. tostring(seq)

        local rproto = ghost.reagents[vi]
        local nr = rproto._type:new()
        nr:assign(rproto)
        nr.code = code
        ghost.reagents:insert('#', nr)
        local new_ri = #ghost.reagents - 1

        -- The filter to clone is the one belonging to THAT reagent,
        -- found by reagent_index, not whatever happens to sit last in
        -- the vector. Same fault as above, one level down: with a key
        -- declared after the vessels, the last element is the key's.
        local els    = job.job_items.elements
        local eproto = nil
        for k = 0, #els - 1 do
            if els[k].reagent_index == vi then eproto = els[k] end
        end
        -- The fallback picks by owner too: the last filter that names
        -- ANY reagent. Taking the last filter outright could take one
        -- of the fuel access layer's bulk copies, which owns no
        -- reagent, and clone a jug slot that demands fuel.
        if not eproto then
            for k = #els - 1, 0, -1 do
                local ri = -1
                pcall(function() ri = els[k].reagent_index end)
                if ri >= 0 then eproto = els[k] break end
            end
        end
        local ne = eproto._type:new()
        ne:assign(eproto)
        ne.reagent_index = new_ri
        els:insert('#', ne)

        local pproto = ghost.products[at]
        local np = pproto._type:new()
        np:assign(pproto)
        np.product_to_container = code
        np.count = 0
        ghost.products:insert('#', np)
        new_at = #ghost.products - 1
    end)
    if not ok then return nil end
    return new_at
end

-- ---- THE GHOST MUST DESCRIBE THE JOB IT SERVES ----
--
-- A job expanded to N vessel slots carries N filters, and its ghost
-- carried N reagents to match. Destroy that ghost, which a data cycle
-- does, and the job is reverted to its base and a fresh ghost is cut
-- from it. The base declares only the slots its author wrote, so the
-- job now has more filters than the reaction has reagents.
--
-- DF CANNOT COMPLETE A JOB IN THAT STATE. Every job_item carries a
-- reagent_index and completion looks each one up on the reaction to
-- decide consume or preserve. An index past the end is an out of
-- bounds read inside DF, and it happens at the moment the job
-- finishes rather than while it runs.
--
-- MEASURED. Job 10, five filters against a three reagent ghost:
--
--   FILTER REPAIR: job 10 has 5 filters against 3 reagent(s), but 5
--                  of them are occupied. NOT shrinking; ...
--   SLOT DESYNC: job 10 filters=5 expected=3 (reagents=3, 0 folded).
--
-- repeating for eleven seconds, then a crash as the job completed.
--
-- THE JOB IS THE GROUND TRUTH, not the reaction. DF has already
-- fetched the items, the filters are already written, and a dwarf is
-- already standing at the furnace. So the reaction is grown to match.
-- No filter is added: they exist, that is the whole problem.
--
-- WHY GROWING RATHER THAN RE-POINTING. Pointing the surplus filters at
-- an existing vessel reagent is a smaller write, but it produces a
-- shape DF has never been asked to complete, two filters claiming one
-- reagent. Growing produces 5 reagents against 5 filters, which is
-- exactly what a normal expansion produces and what this fort
-- completes successfully every day. The low risk option is the one
-- that reproduces a proven shape.
--
-- REAGENT AND PRODUCT TOGETHER, and registered with expand_state.
-- collapse_vessels erases a TRIPLE off the end, filter, reagent and
-- product, st.n times. Growing reagents alone would leave it removing
-- a product that expansion never added. Adding both and setting st.n
-- makes the reconstruction indistinguishable from the expansion it
-- replaces, so the job collapses back to base shape between cycles
-- exactly as it would have.
--
-- The rebuilt products carry count 0, so they mint nothing. The
-- surplus jugs are held, released empty at completion, and their
-- liquid banks. That is the honest outcome: the allocation those
-- slots once had died with the ghost and is not recoverable, and
-- inventing one would be worse than banking.
function reconcile_reagents(job, ghost)
    local n_f, n_r = 0, 0
    pcall(function()
        -- ---- DF'S FUEL FILTER DOES NOT COUNT ----
        -- A fuel:true reaction carries one job_item DF wrote for
        -- itself, at reagent_index -1. Counting it makes the filter
        -- total permanently exceed the reagent total by one, so this
        -- reads a well formed job as a job that expanded, and grows
        -- the reaction by a bogus vessel reagent EVERY cycle.
        -- Measured on job 13: "kept 4 filter(s) ... declares 3" on a
        -- three reagent retort holding exactly its three items plus
        -- fuel.
        for i = 0, #job.job_items.elements - 1 do
            local ri = job.job_items.elements[i].reagent_index
            if not ri or ri >= 0 then n_f = n_f + 1 end
        end
        n_r = #ghost.reagents
    end)
    if n_f <= n_r then return 0 end

    -- Preserved AND a liquid container, the same test
    -- append_vessel_triple uses and for the same reason: the drain key
    -- is preserved and is not a vessel.
    local vi = nil
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            local rg = ghost.reagents[i]
            if rg.flags.PRESERVE_REAGENT
               and rg.has_tool_use == df.tool_uses.LIQUID_CONTAINER then
                vi = i
            end
        end
    end)

    -- A product already bound to a container, which is what makes it a
    -- vessel slot rather than a solid rung of the ladder.
    local pi = nil
    pcall(function()
        for i = 0, #ghost.products - 1 do
            local pc = tostring(ghost.products[i].product_to_container or '')
            if pc ~= '' then pi = i end
        end
    end)

    if not vi or not pi then
        log_once('noreconcile:' .. tostring(job.id), 'ERROR', string.format(
            'Job %d has %d filters against %d reagent(s), and %s has no'
            .. ' vessel slot to rebuild from. It cannot be reconciled'
            .. ' and DF cannot complete it. Report this line.',
            job.id, n_f, n_r, tostring(ghost.code)), 'VESSEL')
        return 0
    end

    local added = 0
    pcall(function()
        while #ghost.reagents < n_f do
            local code = 'vessel_r' .. tostring(#ghost.reagents)

            local rproto = ghost.reagents[vi]
            local nr = rproto._type:new()
            nr:assign(rproto)
            nr.code = code
            ghost.reagents:insert('#', nr)

            local pproto = ghost.products[pi]
            local np = pproto._type:new()
            np:assign(pproto)
            np.product_to_container = code
            np.count = 0
            ghost.products:insert('#', np)

            added = added + 1
        end
    end)

    if added > 0 then
        local st = expand_for(job)
        st.n = (st.n or 0) + added
        log_once('reconcile:' .. tostring(job.id) .. ':' .. tostring(n_f), 'INFO', string.format(
                'VESSEL: job %d kept %d filter(s) across a data cycle'
                .. ' but its rebuilt reaction declares %d. Rebuilt %d'
                .. ' vessel slot(s) so the job can finish; they hold'
                .. ' their jugs and pay nothing, and collapse with the'
                .. ' rest between cycles.',
                job.id, n_f, n_r, added), 'VESSEL')
    end
    return added
end

-- Every product slot this currency can pay into, base first.
-- Appends up to `want - 1` extras, capped by free vessels.
-- How many whole packages this currency has earned. Used by the
-- pre pass AND by the stream loop, so the two can never disagree
-- about what a currency wants. Two copies of this arithmetic is
-- exactly how a currency ends up allocated for one number and asking
-- for another.
function packages_wanted(projected, currency)
    local pk = (V.setting('LIQUID_STANDARD') or {})[currency]
               or V.setting('LIQUID_STANDARD_DEFAULT') or 1
    if pk < 1 then pk = 1 end
    return math.floor((projected + V.setting('EPSILON')) / pk)
end

-- `want` counts CONTAINERS. `packages` is carried alongside purely so
-- the shortfall message can tell the player what they earned in the
-- unit they think in, rather than in vessels.
function slots_for_liquid(job, ghost, at, want, free, currency, packages)
    local slots = { at }
    if not vessels_on() or not at then return slots, free end

    local st = expand_for(job)
    st.tick  = vessel_poll
    st.wants = (want and want > 1) and (want - 1) or 0

    -- ---- REUSE BEFORE APPENDING ----
    -- The slots this currency already owns from an earlier poll of
    -- the SAME cycle. Rebuilding the list without them is what made
    -- the first build append the difference again every poll.
    local mine = st.slots[currency]
    if not mine then mine = {} st.slots[currency] = mine end
    for _, s in ipairs(mine) do
        if s < #ghost.products then table.insert(slots, s) end
    end

    if want < 2 then return slots, free end

    -- ---- ONLY WHILE DF IS STILL COLLECTING ----
    -- Past that point an appended filter is never hauled for, so
    -- asking for one converts a working job into a job that waits
    -- forever on a slot nothing will fill. Zeroing the pile rather
    -- than returning early is deliberate: the shortfall log and the
    -- player announcement below are already the right words for this
    -- ("earned N but can only bottle M, the rest banks"), so the
    -- refusal reports itself through the path that already exists.
    if not collection_open(job, st) then
        free = 0
        -- Said ONCE, and only for a cycle that never got to append.
        -- A cycle that DID expand goes on answering "closed" on every
        -- later poll, correctly and harmlessly, and announcing that
        -- would be a false report on a run that worked.
        if st.n < 1 then
            log_once('vessel_closed:' .. job.id, 'DETAIL', string.format(
                    'VESSEL: job %d was already holding every base'
                    .. ' item when it started, so DF has closed its'
                    .. ' collection phase and extra containers would'
                    .. ' never be fetched. Asking for none; the'
                    .. ' surplus banks and the next run pays it.',
                    job.id), 'VESSEL')
        end
    end

    -- One claimant per job that wants extras and asked on this poll
    -- or the last one. Self is included, since st.wants was set above.
    -- A job that has already taken its share still counts: it is
    -- still holding those containers.
    local claimants = 0
    for _, o in pairs(expand_state) do
        if (o.wants or 0) > 0 and (o.tick or -1) >= vessel_poll - 1 then
            claimants = claimants + 1
        end
    end
    if claimants < 1 then claimants = 1 end
    local allowed = math.floor(free / claimants)
    if claimants > 1 and free > 0 then
        log_once('vessel_share:' .. job.id .. ':' .. tostring(currency), 'DETAIL', string.format(
                'VESSEL: job %d shares %d container(s) with %d other'
                .. ' furnace(s), taking up to %d.',
                job.id, free, claimants - 1, allowed), 'VESSEL')
    end

    -- ---- ALL AT ONCE, ON PURPOSE ----
    -- An earlier build pipelined these against arrivals, on the theory
    -- that unfilled filters kept the job hunting and let an unforbidden
    -- corpse be swept in. The theory was wrong: the corpse was still
    -- taken with the throttle in place, and the throttle cost real
    -- output. Appends came at hauling speed, roughly one a second, and
    -- a whale correctly allotted 34 containers finished having asked
    -- for 19 and bottled 17.
    --
    -- Issuing them together is the point: DF dispatches haulers in
    -- parallel. The appends are already bounded by the container
    -- count, the per currency allotment, vessel_max and
    -- VESSEL_MAX_FILTERS. A throttle on top of those bought nothing and
    -- cost half the output of the largest input in the game.
    -- Tracked rather than re-read, since the loop adds exactly one
    -- filter per pass.
    local n_filters = 0
    pcall(function() n_filters = #job.job_items.elements end)

    while #slots < want and free > 0
          and #mine < allowed
          and #mine < vessel_max()
          and n_filters < VESSEL_MAX_FILTERS do
        local new_at = append_vessel_triple(job, ghost, at, st.n + 1)
        if not new_at then break end
        st.n = st.n + 1
        free = free - 1
        table.insert(mine, new_at)
        table.insert(slots, new_at)
        n_filters = n_filters + 1
        log('DETAIL', string.format(
            'VESSEL: job %d asks container %d of %d for %s',
            job.id, #slots, want, string.lower(tostring(currency))), 'VESSEL')
    end

    if want > #slots and n_filters >= VESSEL_MAX_FILTERS then
        log_once('vessel_filtercap:' .. job.id, 'DETAIL', string.format(
                'VESSEL: job %d stopped at %d filters, the limit past'
                .. ' which DF will not gather for a job. The rest banks'
                .. ' and the next run pays it.', job.id, n_filters), 'VESSEL')
    end

    -- What one container on this reaction actually holds, for the
    -- message below. Same reader the writer uses, so the two cannot
    -- disagree about how roomy a jug is.
    -- Sizes, not just position. A vector reporting a size that includes
    -- a dead pointer is the shape of this crash, so the size is the
    -- number worth having on the line before the read.
    local nsz = {}
    pcall(function() nsz[1] = #ghost.products end)
    pcall(function() nsz[2] = #ghost.reagents end)
    pcall(function() nsz[3] = #job.items end)
    pcall(function() nsz[4] = #job.job_items.elements end)
    crumb('A slot_room in', string.format(
        'job %s at %s | products %s reagents %s items %s filters %s',
        tostring(job and job.id), tostring(at),
        tostring(nsz[1]), tostring(nsz[2]), tostring(nsz[3]),
        tostring(nsz[4])))
    local room_each = slot_room(job, ghost, at, 1) or 1
    crumb('B slot_room out', room_each)

    if want > #slots then
        crumb('C currency_name in', tostring(currency))
        local pretty = currency_name(currency)
        crumb('D currency_name out', tostring(pretty))
        -- The fuel log is not where a player looks. A run that earned
        -- more than it could bottle looks identical to one that did
        -- not, and the difference is sitting in a bank nobody can see,
        -- so it goes in front of them. log_once keys on the job and
        -- the currency, so this says its piece once per run rather
        -- than six times a second.
        -- INFO: the player can act on this: more containers, or a higher
        -- ceiling.
        log_once('vessel_short:' .. job.id .. ':' .. tostring(currency), 'INFO', string.format(
                'VESSEL: job %d earned %d package(s) of %s but has'
                .. ' only %d container(s), holding %d. The rest banks.'
                .. ' Make more containers, or lift the ceiling with'
                .. ' refinish_adaptive_vessel_max.',
                job.id, packages or want,
                string.lower(tostring(currency)), #slots,
                #slots * room_each), 'VESSEL')
        -- ---- ONCE, AND INDEPENDENT OF THE LOG LEVEL ----
        -- This fired every poll. log_once guards only the LOG line
        -- and returns early when the level is below its threshold,
        -- so the announcement sat outside the guard entirely and DF
        -- collapsed the repeats into 'x259' and 'x435'. An
        -- announcement is for the player, not the log, so it carries
        -- its own key and does not consult the level at all.
        local akey = 'vessel_ann:' .. job.id .. ':' .. tostring(currency)
        if not seen[akey] then
            seen[akey] = true
            -- 'kept' rather than 'held back': the value is banked and
            -- the next smaller input pays it out, so the number is a
            -- queue and not a loss. Saying it needs N more containers
            -- reads as a demand for 45 jugs right now, which is what
            -- made this look alarming.
            crumb('E announce in', string.format('%d %s',
                  want - #slots, tostring(pretty)))
            pcall(function()
                dfhack.gui.showAnnouncement(string.format(
                    'The retort kept %d %s for lack of accessible containers.',
                    want - #slots, pretty),
                    COLOR_BROWN, false)
            end)
            crumb('F announce out')
        end
    end
    return slots, free
end

-- Takes every appended triple back off. Called from the poll between
-- cycles, where nothing is attached.
--
-- ---- THE FILTERS BY OWNER, THE REACTION BY POSITION ----
-- job_items is shared with the fuel access layer, which appends its
-- bulk copies to the same end, so a filter is claimed by the reagent it
-- names, never by where it sits. ghost.reagents and ghost.products are
-- this file's alone, so there the last st.n are ours. See WHAT LEAVING
-- FUEL ALONE DOES NOT COVER, and register R31.
function collapse_vessels(job, ghost)
    local st = expand_state[job.id]
    if not st or st.n < 1 then return 0 end
    -- ---- BY OWNER, NOT BY POSITION ----
    -- job_items is shared: making-fuel-access.lua appends its bulk fuel
    -- copies to the same end, and restore_fuel puts a tanked job's slot
    -- back there too. Taking the last st.n filters took whatever
    -- happened to be last, so on a job carrying both it would erase
    -- fuel copies while deleting the reagents the jug filters name,
    -- which is the R22 crash.
    --
    -- Every filter this file appends names its own reagent
    -- (append_vessel_triple writes reagent_index), and so do the slots
    -- R22's reconcile rebuilds. So the expansion's filters are exactly
    -- those owned by a reagent at or past the base count. A fuel slot
    -- owns no reagent, reads -1, and is passed over.
    --
    -- Only ever called between cycles, with nothing attached, so
    -- erasing from the middle moves no live job_item_idx.
    --
    -- Through RM's job surgery, which enforces all of the above: owned
    -- filters only, downward, at most st.n, and never under an attached
    -- item.
    local removed = 0
    local keep = #ghost.reagents - st.n
    if keep < 0 then keep = 0 end
    if surgery then
        removed = surgery.erase(job, function(e)
            return e.reagent_index >= keep
        end, { limit = st.n })
    end

    -- The reaction's own vectors are this file's alone: nothing else
    -- appends to them, so the last st.n there really are the
    -- expansion's, and they come off whether or not their filters were
    -- still present.
    local dropped = 0
    for _ = 1, st.n do
        local ok = pcall(function()
            local lr = #ghost.reagents - 1
            ghost.reagents[lr]:delete()
            ghost.reagents:erase(lr)

            local lp = #ghost.products - 1
            ghost.products[lp]:delete()
            ghost.products:erase(lp)
        end)
        if not ok then break end
        dropped = dropped + 1
    end

    if removed > 0 or dropped > 0 then
        log('DETAIL', string.format('VESSEL: job %d released %d extra jug slot(s):'
            .. ' %d filter(s), %d reagent(s) and product(s)',
            job.id, st.n, removed, dropped), 'VESSEL')
    end
    if removed < st.n then
        log_once('jugfilter:' .. tostring(job.id), 'DETAIL', string.format(
            'VESSEL: job %d recorded %d extra jug slot(s) but only %d'
            .. ' filter(s) were still owned by them. The rest were gone'
            .. ' already, and the reaction was trimmed to match.',
            job.id, st.n, removed), 'VESSEL')
    end
    expand_state[job.id] = nil
    return removed
end

-- A liquid into its container. Count is 0 or 1 PER SLOT, never more:
-- the size goes into product_dimension, so one container holds one
-- liquid item. More liquid than a container takes means more slots;
-- inside one, the writer puts as many whole packages as it holds (FILL
-- WHAT WAS GRABBED, below).
--
-- PAYS WHOLE PACKAGES OR NOTHING.
--
-- Never part of one. The package size for a currency is
-- LIQUID_STANDARD in making-fuel-tuning.lua, and every consumer of that
-- currency asks for exactly that much, so a container of whole
-- packages meets the ask and what a consumer leaves is whole packages
-- too. This once said "never a multiple", from when every slot took one
-- package.
--
-- The old behaviour paid at every whole unit, which produced buckets
-- of whatever the bank happened to hold. That cannot work, because DF
-- fills a reagent slot from ONE container and picks without regard to
-- size. A short bucket fails the ask outright. An oversized one
-- either fails too, or gets partially drained and leaves a non
-- standard remainder that fails every job it is handed to afterwards.
-- One size per currency is the only arrangement that matches every
-- time.
--
-- Holding back costs nothing. settle() carries sum minus paid, so an
-- unaffordable package leaves the whole credit banked for a later
-- job.
--
-- ONE CONTAINER PER SLOT is structural: the reaction declares one
-- output container for each liquid slot, which is why vessel expansion
-- appends whole triples for more. This read "ONE PACKAGE PER JOB" and
-- prescribed raising LIQUID_STANDARD for a currency banking faster
-- than it drained; filling containers and adding them answers that
-- now, and the count is still never raised.
--
-- A stream whose reaction has no slot for it (at == nil) is banked
-- and not written.
function write_liquid(job, ghost, slots, projected, name, currency)
    -- `slots` is the list of product slots this currency may pay
    -- into: the base slot, plus any appended by vessel expansion.
    -- A bare number is still accepted so nothing else has to change.
    if type(slots) == 'number' then slots = { slots } end
    if not slots or #slots < 1 then return 0, {} end

    -- Missing table is an error rather than a default. Silently
    -- falling back to one unit would mint containers nothing can
    -- consume, which is the exact failure this replaced.
    local std = V.setting('LIQUID_STANDARD')
    if type(std) ~= 'table' then
        error('the provider\'s settings are missing LIQUID_STANDARD')
    end
    local pack = std[currency] or V.setting('LIQUID_STANDARD_DEFAULT') or 1
    pack = math.floor(pack)
    if pack < 1 then pack = 1 end

    -- One whole package per slot, in order, while the projection
    -- affords it. Every slot writes exactly `pack`, so every minted
    -- item is exactly one package and no consumer can ever meet a
    -- part filled container.
    local left, paid = projected, 0
    for _, at in ipairs(slots) do
        if not at or at >= #ghost.products then break end

        -- ---- FILL WHAT WAS GRABBED, NOT ONE PACKAGE ----
        -- The old rule wrote exactly one package into every slot,
        -- which is why a whale needed 46 containers to bottle 46
        -- packages. A jug holds 16. The container was never the
        -- constraint; the writer was.
        --
        -- COUNT IS NOT THE LEVER. A test reaction with count 50
        -- produced a stack 0 null. Every vanilla LIQUID_MISC product
        -- is count 1 with the amount in the dimension, and that is
        -- what already works here, so raising the dimension is the
        -- whole change.
        --
        -- SAFE WHETHER OR NOT DF ENFORCES ITS OWN CEILING. If DF
        -- checks capacity we match it; if it does not, we have chosen
        -- a sane limit rather than overflowing a container.
        --
        -- Unreadable container falls back to `pack`, which is exactly
        -- today's behaviour, so nothing regresses when the read fails.
        local room = slot_room(job, ghost, at, pack) or pack

        -- Whole packages only, on both sides. A part filled container
        -- is the partial bug and the packaging law forbids it.
        local afford = math.floor((left + V.setting('EPSILON')) / pack) * pack
        local take   = math.min(room * pack, afford)

        pcall(function()
            local p = ghost.products[at]
            if take < pack then
                p.count = 0
            else
                p.count = 1
                p.product_dimension = take * V.dial('LIQUID_UNIT')
            end
        end)
        -- ---- ZERO THE REST, DO NOT BREAK ----
        -- Breaking here left every later slot holding whatever an
        -- EARLIER POLL wrote into it. write_liquid runs on every poll,
        -- and a poll before the vessels arrived wrote one package into
        -- each slot, so a later poll that could afford only the first
        -- slot left stale ones behind it.
        --
        -- Harmless while every slot took exactly one package, because
        -- the slot count and the package count always matched. With a
        -- container holding sixteen they diverge, and the stale writes
        -- surface as liquid split oddly across containers.
        --
        -- A zeroed slot mints a null that the reaper clears, which is
        -- the same thing an unused slot has always done.
        if take >= pack then
            left = left - take
            paid = paid + take
        end
    end
    return paid, { { n = paid, name = name } }
end

-- ==========================================
-- DRAIN: PICKING WHAT TO POUR
-- ==========================================

-- The prefix module MATERIALS carry. Deliberately not MODULE_PREFIX,
-- which is MAKING_FUEL_RXN_ and names reactions.
-- MAT_PREFIX is this file's provider binding, declared at the top.

-- Currency to inorganic index, built once. The drain writes this into
-- a product's mat_index, so it has to be the same index DF uses to
-- look the material up.
-- drain_mat_cache is this file's provider binding, declared at the top.

function build_drain_mat_cache()
    drain_mat_cache = {}
    pcall(function()
        for i, m in ipairs(df.global.world.raws.inorganics.all) do
            -- MAT_PREFIX, not MODULE_PREFIX. The latter is
            -- MAKING_FUEL_RXN_ and names reactions; materials
            -- carry MAKING_FUEL_ with no RXN_. Using the wrong one
            -- matches nothing and the drain silently pours nothing,
            -- which is the worst shape a bug can take here.
            local c = tostring(m.id):match('^' .. MAT_PREFIX .. '(.+)$')
            if c then drain_mat_cache[c] = i end
        end
    end)
end

-- ---- CHECKED ON READ, THE SAME AS base_reaction ----
--
-- This holds INDICES, not pointers, so a stale entry cannot be caught
-- by comparing an object's own code. It is checked the only way an
-- index can be: read the material back and see whether it is still the
-- one this currency names.
--
-- UNMEASURED, and included anyway. A data cycle rebuilds the whole
-- inorganics array, and these indices survive it. They happen to land
-- in the same places while the material count does not change, which
-- is why this has never bitten. Install or remove a module and it
-- would, and the symptom would be a drain quietly pouring the wrong
-- liquid into a jug, which is the hardest kind of fault to notice.
-- The check is one array read per drain slot.
function currency_mat_index(cur)
    if not drain_mat_cache then build_drain_mat_cache() end

    local idx = drain_mat_cache[cur]
    if idx == nil then return nil end

    local live = nil
    pcall(function()
        live = tostring(df.global.world.raws.inorganics.all[idx].id)
    end)
    if live == MAT_PREFIX .. cur then return idx end

    log_once('stale_drainmat:' .. tostring(cur), 'WARNING', string.format(
        'Currency %s was cached at inorganic %s, which now holds %s.'
        .. ' Rebuilding the index.',
        tostring(cur), tostring(idx), tostring(live)), 'CACHE')
    build_drain_mat_cache()
    return drain_mat_cache[cur]
end

-- Every bank at THIS furnace holding at least one whole package of an
-- actual liquid, richest first.
--
-- The key shape is derived from bank_key rather than assumed, by
-- asking it for a sentinel currency and splitting on it. BANK_SCOPE
-- can be building or reaction scoped and the two produce completely
-- different keys; hardcoding either would work until someone changed
-- it, and then fail silently by finding nothing.
--
-- LIQUID_STANDARD is the whitelist. Banks also hold charcoal, ash and
-- pitch, and pouring a boulder into a jug is not a thing.
function drain_candidates(base_code, job)
    local out = {}
    local pre, suf = nil, nil
    pcall(function()
        local mark   = '\1CURRENCY\1'
        local sample = V.bank_key(base_code, mark, job)
        local a, b = sample:find(mark, 1, true)
        if a then
            pre = sample:sub(1, a - 1)
            suf = sample:sub(b + 1)
        end
    end)
    if not pre then return out end

    local liq = V.setting('LIQUID_STANDARD') or {}
    for k, v in pairs(yield_bank or {}) do
        if type(v) == 'number' and k:sub(1, #pre) == pre
           and (#suf == 0 or k:sub(- #suf) == suf) then
            local cur = k:sub(#pre + 1, #k - #suf)
            local pk  = liq[cur]
            if pk and pk > 0 and v + V.setting('EPSILON') >= pk then
                table.insert(out, { cur = cur, bal = v, pack = pk })
            end
        end
    end
    table.sort(out, function(a, b) return a.bal > b.bal end)
    return out
end

-- ==========================================
-- NULL LIQUID REAPER
-- ==========================================
-- DF mints a to_container liquid product even when its count is
-- zero. The item arrives with the authored dimension and
-- stack_size 0, and nothing in the game can consume it. It is not a
-- malformed item, it is how DF marks a product that did not fire.
--
-- Two measurements make this safe, and it is safe ONLY because of
-- them:
--
--   THE DISCRIMINATOR. Job 22 held OIL_BONE at count 1 and AMMONIA
--   at count 0 on adjacent slots in the same poll, and produced
--   #1162 at stack 1 and #1163 at stack 0. Across ten further mints
--   the pairing never broke. stack_size mirrors the product count,
--   so stack 0 means unpaid and nothing else.
--
--   THE REMOVAL. dfhack.items.remove on a null inside a jug frees
--   the jug at once: #1113 in container #979, contents 1 before and
--   0 after. The item stays findable until DF collects it, so do not
--   judge occupancy by scanning the world; ask the container.
--
-- WHY IT MATTERS. An unreaped null holds its jug, the vessel
-- reagents demand empty, and the next job pulls two more. Measured
-- at two aluminium jugs per run, and one buffalo bone stack drained
-- roughly twenty eight and ran the fort dry mid job. This is not a
-- bone problem: RETORT_WOOD minted a TAR and a VINEGAR_WOOD
-- null on a perfectly correct unpaid run.
--
-- WHY IT LIVES IN THE POLL. It needs to know nothing about jobs,
-- cycles or burn verdicts. Putting it in settle would chain it to
-- cycle detection, which is currently unreliable, and a jug would
-- stay hostage whenever a cycle failed to settle.
--
-- NEVER INVERT THIS. Stamping a null up to stack 1 turns every
-- unpaid product into real consumable fluid. That shipped once from
-- this file and minted counterfeit tar and bone oil. Removing a null
-- destroys nothing, because nothing was ever paid for it.
-- ==========================================
-- ---- WHAT AN UNPAID LIQUID IS, DEFINED ONCE ----
-- Its token when `it` is a liquid at stack 0 of this module's own
-- currency materials, else nil. Shared by the sweep and the workshop look
-- below, so the two can never disagree about what they remove.
local function unpaid_token(it)
    local sz = nil
    pcall(function() sz = it.stack_size end)
    if sz == nil or sz >= 1 then return nil end
    local tok = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(it)
        if mi then tok = tostring(mi:getToken()):upper() end
    end)
    -- This module's liquids only (its currency materials,
    -- V.CURRENCY_MATERIAL_PREFIX). A dwarf's booze in a
    -- borrowed jug is not this module's business.
    local pre = V.CURRENCY_MATERIAL_PREFIX
    if tok and pre and pre ~= '' and tok:find(pre, 1, true) then return tok end
    return nil
end

-- Removes what was collected, saying where it was found: 'by the sweep'
-- or 'at its workshop', so the log shows which look is doing the work.
local function reap_doomed(doomed, where)
    for _, d in ipairs(doomed) do
        local freed = nil
        pcall(function()
            local c = dfhack.items.getContainer(d.item)
            if c then freed = c.id end
        end)
        local ok = pcall(function() dfhack.items.remove(d.item) end)
        if ok then
            log('DETAIL', string.format(
                'REAPED unpaid %s #%d%s, %s', d.tok, d.id,
                freed and (', jug #' .. freed .. ' freed') or '', where), 'REAPER')
        else
            log('ERROR', string.format(
                'could not remove unpaid liquid #%d, its jug'
                .. ' stays occupied.', d.id), 'REAPER')
        end
    end
end

-- ---- AT THE WORKSHOP (2026-10-31) ----
-- The engine's poll calls this with the workshops a module reaction just
-- finished at, and calls the sweep below only every so often: see WHERE
-- THE REAPER LOOKS in refinish-reaction-adaptive.lua, which measured the
-- sweep at 12.2 ms a poll over 17,764 liquids with nothing to reap. A null
-- is minted into a container at its workshop, so each workshop's items
-- are looked at, and every item inside them. Collect first, remove
-- second, as the sweep does.
function reap_at(bids)
    local doomed, looked = {}, {}
    local function consider(it)
        if looked[it.id] then return end
        looked[it.id] = true
        if it:getType() ~= df.item_type.LIQUID_MISC then return end
        local tok = unpaid_token(it)
        if tok then table.insert(doomed, { item = it, id = it.id, tok = tok }) end
    end
    for bid in pairs(bids or {}) do
        pcall(function()
            local b = df.building.find(bid)
            if not b then return end
            for _, ci in ipairs(b.contained_items) do
                local it = ci.item
                if it then
                    consider(it)
                    for _, c in ipairs(dfhack.items.getContainedItems(it) or {}) do
                        consider(c)
                    end
                end
            end
        end)
    end
    reap_doomed(doomed, 'at its workshop')
end

-- The sweep: every liquid in the fort.
function reap_null_liquids()
    -- Typed vector first, indexed form as the older API shape.
    -- Neither working is a named fault rather than a silent skip.
    local vec = nil
    pcall(function() vec = df.global.world.items.other.LIQUID_MISC end)
    if not vec then
        pcall(function()
            vec = df.global.world.items.other[df.items_other_id.LIQUID_MISC]
        end)
    end
    if not vec then
        log_once('reaper_vec', 'ERROR',
            'LIQUID_MISC item vector unreachable, unpaid liquids'
            .. ' cannot be reaped and jugs will stay occupied.', 'REAPER')
        return
    end

    -- Collect first, remove second. Removing while iterating the
    -- vector DF is also mutating is asking for a skipped entry.
    local doomed = {}
    for _, it in ipairs(vec) do
        local tok = unpaid_token(it)
        if tok then
            table.insert(doomed, { item = it, id = it.id, tok = tok })
        end
    end

    reap_doomed(doomed, 'by the sweep')
end