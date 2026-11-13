--@ module = true
-- refinish-mint-finish-watch.lua
-- ==========================================
-- FINISHES MINTED IN PLAY
-- ==========================================
-- refinish-mint-finish.lua mints a pair of base metal and dust once the
-- fort has had both, and at every load Step 6.7 reads the bars and dusts
-- already in the fort (reconcile). This watches for new ones in play, so
-- a material's first dust, or a base metal's first bars, brings its
-- finishes the moment it exists instead of at the next load.
--
-- ---- SOURCES ----
-- Found and measured by making-fuel-coal-watcher.lua, which watches the
-- same items for its own reasons:
--   * eventful.onItemCreated fires for reactions, jobs and scripts, so a
--     grinder's dust, RM's byproduct dust and a smelter's bars are seen
--     the frame they exist. It skips trader, migrant and invader goods
--     (EventManager.cpp, manageItemCreationEvent).
--   * The poll, every POLL_FRAMES while the game runs:
--       NEW ITEMS: everything made since the last poll, read off the end
--       of world.items.all, which DF keeps in id order, so one binary
--       search finds where the new ones start. This sees what the event
--       skips.
--       WAITING: a bar or dust that is still a caravan's (flags.trader)
--       is not the fort's yet. It is kept by id and tried every poll: it
--       counts once the flag clears (bought), and is dropped once the
--       item is gone (the caravan left with it).
-- No walk of the whole BAR or TOOL list. What the two miss (a script
-- rewriting an item's material, say) is read at the next load, when
-- reconcile walks every bar and dust. MEASURED 2026-10-01 (the coal
-- watcher's poll, RM's profiler): a walk of every bar every poll was the
-- costliest Lua loop in the session, 9.3 ms a second with 60,000 bars.
--
-- ---- ONE QUESTION A MATERIAL ----
-- The minter answers 0 for a material it has already seen or that is no
-- base metal or dust this cycle, and the answer is kept by material index
-- (done), so a smelter turning out steel bars costs one table read a bar.
-- Nothing is kept while the minter is not ready (notice() answers nil:
-- before Step 5 of this cycle, or after a shutdown), so it is asked again.
--
-- An RM service: started and stopped with the others in refinish_steel.lua
-- (RM'S SERVICES FOLLOW THE DATA), so it never runs while RM's data is out
-- of RAM, and every start begins afresh.
-- ==========================================

local repeatUtil = require('repeat-util')
local eventful   = require('plugins.eventful')
local REPEAT_KEY  = 'refinish-mint-finish-watch'
local POLL_FRAMES = 100    -- the coal watcher's backstop cadence (THE SWEEP'S CADENCE there)

local BAR, TOOL = df.item_type.BAR, df.item_type.TOOL

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. Every line reaches the log on disk; the panel's Log
-- Detail setting decides what shows. No console prints. The mints
-- themselves are logged by the minter (IN_PLAY and PILES lines).
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MINT_WATCH'
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
-- The minter is resolved once a start: reqscript costs about 2 ms a call
-- (engine notes, 2026-09-30), so it is never asked for on the poll.
local mint         -- refinish-mint-finish, the running copy
local done         -- kind ('B' or 'D') -> material index -> true: asked this cycle
local waiting      -- item id -> true: a caravan's bar or dust, tried every poll
local tail_next    -- the first item id the next poll reads as new; nil until the first poll
local order_said   -- the out-of-order warning, once a start
local sub          -- RM's dust tool subtype this cycle, from the minter
local fault_said   -- the created event's fault, once a start

local function reset()
    done = { B = {}, D = {} }
    waiting = {}
    tail_next, order_said, sub, fault_said = nil, false, nil, false
end
reset()

-- ==========================================
-- ONE ITEM
-- ==========================================
-- The kind of a bar or an RM dust and its material index, or nil for
-- anything else. Only bars and tools are read past their type, and both
-- are actual items, which carry mat_type and mat_index.
local function classify(it)
    local t = it:getType()
    local kind
    if t == BAR then
        kind = 'B'
    elseif t == TOOL then
        if not sub or it:getSubtype() ~= sub then return nil end
        kind = 'D'
    else
        return nil
    end
    if it.mat_type ~= 0 then return nil end
    return kind, it.mat_index
end

-- One material to the minter, once a cycle (ONE QUESTION A MATERIAL).
local function ask(kind, mi)
    local d = done[kind]
    if d[mi] then return end
    local arr = df.global.world.raws.inorganics.all
    if mi < 0 or mi >= #arr then return end
    if mint.notice(kind, arr[mi].id) ~= nil then d[mi] = true end
end

-- An item made or found: a caravan's waits, any other bar or dust is
-- asked about.
local function take(it)
    local kind, mi = classify(it)
    if not kind then return end
    if it.flags.trader then
        waiting[it.id] = true
        return
    end
    ask(kind, mi)
end

-- ==========================================
-- THE CREATED EVENT
-- ==========================================
-- Wrapped: an error escaping into eventful breaks every other handler on
-- the event (making-fuel-coal-watcher.lua), so a fault is caught here and
-- logged once.
local function on_created(item_id)
    if not _G.refinish_active or not mint then return end
    local it = df.item.find(item_id)
    if it then take(it) end
end

local function guarded_created(item_id)
    local ok, err = pcall(on_created, item_id)
    if not ok and not fault_said then
        fault_said = true
        log('ERROR', 'created event fault: ' .. tostring(err), 'EVENT')
    end
end

-- ==========================================
-- THE POLL
-- ==========================================
-- The first position in items.all holding an item id of at least id
-- (making-fuel-coal-watcher.lua's own search).
local function first_at_or_after(all, id)
    local lo, hi = 0, #all
    while lo < hi do
        local mid = (lo + hi) // 2
        if all[mid].id < id then lo = mid + 1 else hi = mid end
    end
    return lo
end

local function poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active or not mint then return end
    if not sub then sub = mint.dust_subtype() end

    -- ---- NEW ITEMS ----
    -- The first poll only marks where new items start: everything already
    -- in the fort was read at load by reconcile.
    local all = df.global.world.items.all
    local top = df.global.item_next_id
    if not tail_next then
        tail_next = top
    elseif tail_next < top then
        local prev = -1
        for i = first_at_or_after(all, tail_next), #all - 1 do
            local it = all[i]
            local id = it.id
            if id < prev and not order_said then
                order_said = true
                -- WARNING: an item made out of order may wait for the next
                -- load's reconcile.
                log('WARNING', 'world.items.all is out of id order; new items read'
                    .. ' off its end may be missed until the next load.', 'POLL')
            end
            prev = id
            pcall(take, it)
        end
        tail_next = top
    end

    -- ---- WAITING ----
    -- Setting a key already in the table to nil while walking it is
    -- allowed in Lua, so each caravan bar or dust is settled in place.
    for id in pairs(waiting) do
        local it = df.item.find(id)
        if not it then
            waiting[id] = nil
        elseif not it.flags.trader then
            waiting[id] = nil
            pcall(take, it)
        end
    end
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- The poll rides the loop dispatcher, unpaused only: nothing it waits for
-- happens while the game is paused. Its own timer only if the dispatcher
-- is missing. The created event is DF's and fires in game time anyway.
-- ==========================================
local fallback_fault_said = false
local function guarded_poll()
    local ok, err = pcall(poll)
    if not ok and not fallback_fault_said then
        fallback_fault_said = true
        log('ERROR', 'poll fault: ' .. tostring(err), 'POLL')
    end
end

function start()
    reset()
    fallback_fault_said = false
    local ok, m = pcall(reqscript, 'refinish-mint-finish')
    if not ok then
        -- ERROR: finishes are then minted only at load (Step 6.7).
        log('ERROR', 'refinish-mint-finish could not be loaded, so nothing is minted'
            .. ' in play: ' .. tostring(m), 'START')
        mint = nil
        return
    end
    mint = m
    sub = mint.dust_subtype()
    eventful.onItemCreated[REPEAT_KEY] = guarded_created
    eventful.enableEvent(eventful.eventType.ITEM_CREATED, 0)
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(REPEAT_KEY, {
            every = POLL_FRAMES, fn = poll }) then
        repeatUtil.cancel(REPEAT_KEY)
    else
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', guarded_poll)
    end
    log('DETAIL', ('active; dust subtype %s.'):format(tostring(sub)), 'START')
end

function stop()
    eventful.onItemCreated[REPEAT_KEY] = nil
    repeatUtil.cancel(REPEAT_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(REPEAT_KEY) end
    local held = 0
    for _ in pairs(waiting) do held = held + 1 end
    reset()
    mint = nil
    -- What it was still holding goes with the stop; the next load's
    -- reconcile reads those items again if they are still here.
    log('DETAIL', ('stopped; %d caravan item(s) were waiting.'):format(held), 'STOP')
end
