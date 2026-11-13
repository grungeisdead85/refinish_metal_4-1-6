--@ module = true
-- refinish-bricks.lua
-- ==========================================
-- RM SERVICE: BRICKS BY VOLUME
-- ==========================================
-- WHAT IT DOES
-- A clay boulder is 10000 of clay, and vanilla's make clay bricks pays one
-- brick for it, where a stone boulder makes four blocks at the mason's.
-- This service pays the bricks the clay makes by volume, for vanilla's
-- reaction and for RM's own, which fires stone dust into the clay as grog
-- (refinish-core-payload.lua, REFINISH BRICKS), and since 2026-10-28 for
-- any brick reaction a module registers with its own temper (A MODULE'S
-- RECIPE, below). The bricks are vanilla's own: the clay's fired material,
-- earthenware, stoneware or porcelain, as DF makes them.
--
-- TEMPER is what is worked into the clay besides it: grog, or a module's
-- (Making Fuel's dried dung). Until 2026-10-28 grog was the only temper and
-- this file read it as RM's dust tool alone.
--
-- THE MEASURE (decided 2026-10-04)
--   * Clay shrinks as it dries and fires. 8% linear is the low end of
--     brick clays: one brickworks' clay measured 5 to 6.4% in drying
--     alone, less with grog in it, and firing adds more. Linear shrinkage
--     S leaves (1 - S)^3 of the volume (ASTM C326), so 8% keeps about 78%:
--     CLAY_KEEP.
--   * Grog is stone already and does not shrink. It keeps the nine tenths
--     every process allows (GROG_KEEP, the melt's rate).
--   * A temper that burns out, as dung does, leaves its room in the brick
--     as pores and shrinks with the clay around it: CLAY_KEEP (2026-10-28).
--     Dung in fired brick is an old practice. In Practical Action's trials
--     (Utilization of Cow-dung in Brickmaking, KnO-100068), dried, sieved
--     dung worked into clay at 5 to 47 percent by volume improved its
--     plasticity, cut green breakage and firing cracks, and left pores as it
--     burned out; the more dung, the lighter and weaker the brick, and 20 to
--     30 percent was the best of it. It acts as fuel inside the brick, but
--     the saving in kiln fuel was left to further research, so a dung brick
--     job still takes its fuel. (Cited until 2026-10-29 as a technical brief
--     on firing bricks with dung.)
--   * A BRICK IS AN EIGHTH OF A BOULDER. A cut block costs a quarter
--     boulder: vanilla's mason makes four blocks from a 10000 boulder with
--     nothing but labour, and the rest is cut away (paid back as dust and
--     gravel, refinish-job-byproducts.lua). A molded or fired block costs
--     half that, an eighth of a boulder (1250) of what is left after its
--     process takes its loss: the extra steps and the fuel buy the yield,
--     and a material formed rather than cut loses less of itself. Concrete
--     and asphalt go by the same (decided 2026-10-04). Shipped and replaced
--     the same day: DF's own block volume (600), which made bricks four
--     times cheaper than any other block (12 from a clay boulder, 16 with
--     grog), and a quarter boulder, which made them no better than stone
--     (3 and 4).
--   * A brick is whole: what is left under one is part of the loss.
--   So a clay boulder alone makes 6 bricks where vanilla made 1, and with
--   13 dust of grog (2600 at 200 a dust) it makes 8. A stone boulder makes 4 blocks.
--   With 38 dried dung (2850 at 75 a dung, 22 percent of the mix), shrinking
--   with the clay, it makes 8, as grog does (Making Fuel's make clay bricks
--   with dung). A dung adds about a twenty-first of a brick and a dust of
--   grog about a seventh: a dung is 75 to the dust's 200, and it shrinks.
--
--   A TEMPER IS SET BY WHERE ITS BRICKS LAND, not by its share of the mix
--   alone, since a brick is whole. Dung shipped 2026-10-28 at 33, a fifth
--   of the mix as the grog is: that came to 7.77 bricks and paid 7, one
--   more than clay alone. 38 is the least that makes 8, and the only count
--   inside the trials' 20 to 30 percent that lands on a whole brick (60,
--   for 9, is 31 percent). Grog's 13 lands at 8.10.
--
-- HOW
--   1. WATCH. The poll sees each brick job (RECIPES, and the modules'
--      recipes) and notes what it holds: the clay's volume, the kiln, and
--      where DF's item numbers stand. Taken again whenever the job holds a
--      different number of items, since a job gathers its items one at a
--      time (the byproduct service's memo measured a three bar table as one
--      bar until 2026-10-04). The temper is what the reaction asks for, not
--      what the job holds: a slot holds whole stacks and DF draws exactly
--      what it asks (RM_Stacked_Tools.md). Dung is fuel as well as temper,
--      so a dung brick job can hold a fuel pile of the same tool beside its
--      temper (making-fuel-access.lua), which is one more reason the
--      reaction's own quantity is what counts.
--   2. PAY, two ticks after completion. The bricks DF made at that kiln in
--      the job's window give the bricks' material; the rest of what the
--      measure makes are made beside them, each a brick of its own as DF's
--      are (a stack of blocks is not something DF builds with).
--
-- ---- A MODULE'S RECIPE (2026-10-28) ----
-- A module adds a brick reaction of its own by naming it and its temper:
--   local api = _G.refinish_bricks_api
--   api.register('MAKING_FUEL_RXN_MAKE_BRICKS_DUNG_DRIED',
--                { tool = 'MAKING_FUEL_PILE', keep = 'CLAY', word = 'dung' })
--   api.unregister('MAKING_FUEL_RXN_MAKE_BRICKS_DUNG_DRIED')
--   code   the reaction's code as the module engine builds it: prefix,
--          RXN_, key (the GROG lesson at RECIPES, below).
--   tool   the temper's tool id. Its volume is the tool's own size, read
--          off its itemdef, times the stack, and only the reaction's
--          reagent of that tool is read as the temper.
--   keep   how much of the temper's volume a brick keeps: 'CLAY' to shrink
--          with the clay (CLAY_KEEP), as a temper that burns out does;
--          'GROG' for nine tenths (GROG_KEEP), as stone keeps; or a number
--          from 0 to 1.
--   word   what the log calls the temper.
-- Registered from a module's start hook, which runs in the pipeline
-- before this service starts, so the handle is published at this file's
-- load. Kept on _G so a reload of this file keeps them, and dropped at
-- stop(), so the next fort's modules register again in their own start
-- hooks, as RM's byproduct service does. A code RM's own recipes hold is
-- refused.
--
-- An RM service: loaded at refinish_steel's load, started and stopped
-- with the others (RM'S SERVICES FOLLOW THE DATA there).
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local utils      = require('utils')

local KEY          = 'refinish-bricks'
local EVERY        = 10     -- frames between polls
local GRACE_POLLS  = 30     -- polls a vanished job's memo is kept (300 frames)
local CLAY_SHRINK  = 0.08   -- linear, drying and firing (THE MEASURE)
local CLAY_KEEP    = (1 - CLAY_SHRINK) ^ 3   -- about 0.779 of the volume
local GROG_KEEP    = 0.9    -- nine tenths, as every process (THE MEASURE)
local BRICK_COST   = 1250   -- what goes into one brick: an eighth of a boulder (THE MEASURE)
local DUST_TOOL    = 'REFINISH_CORE_DUST'

-- The reactions paid by volume: vanilla's, and RM's with grog. RM's goes
-- by the name the module engine gives every reaction it builds: prefix,
-- RXN_, key (refinish-module-react.lua), so GROG under REFINISH_BRICK_.
-- Written without the RXN_ until 2026-10-04: it never matched, and the
-- grog reaction paid DF's one brick.
--
-- Each names its temper since 2026-10-28 (A MODULE'S RECIPE, in the
-- header): vanilla's takes none, RM's takes the dust tool as grog. Until
-- then this was BRICK_CODES, a set of the two codes, and the grog was
-- whatever TOOL reagent a reaction had, counted in dust units.
local RECIPES = {
    MAKE_CLAY_BRICKS        = {},
    REFINISH_BRICK_RXN_GROG = { tool = DUST_TOOL, keep = GROG_KEEP, word = 'grog' },
}

-- The modules' recipes, by reaction code, in the same shape (A MODULE'S
-- RECIPE). On _G so a reload of this file keeps them.
_G.refinish_brick_recipes = _G.refinish_brick_recipes or {}
local MODULE_RECIPES = _G.refinish_brick_recipes

-- A reaction's recipe: RM's own first, then a module's; nil for any
-- reaction that is not a brick job.
local function recipe_of(code)
    return RECIPES[code] or MODULE_RECIPES[code]
end

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. DETAIL is one line per brick job; faults are WARNING.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'BRICKS'
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

local said = {}
local function log_once(key, typ, msg, subject)
    if said[key] then return end
    said[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- STATE
-- ==========================================
-- memo[job id], ids and numbers only, never a job or item object:
--   jid      the job's id
--   code     its reaction
--   rec      its recipe as the job was first seen (a plain table: tool,
--            keep, word), so a module that unregisters mid job does not
--            change how the job is paid
--   clay     the clay's volume
--   held     the temper the job holds, in volume (the fallback, below)
--   n        how many items it held when taken
--   bld      the kiln's id
--   window   item_next_id at the poll before the last: the job's window
--   last     the poll it was last seen on
local memo, polls, tail = {}, 0, nil

-- Per reaction, the temper it asks for, in volume (temper_volume). It was
-- grog_of, the grog asked for, until 2026-10-28.
local temper_of = {}

-- ==========================================
-- REGISTRATION (2026-10-28)
-- ==========================================
-- See A MODULE'S RECIPE in the header. keep is resolved here, once: 'CLAY'
-- and 'GROG' to this file's own rates, so a module never copies a number
-- that lives here.
local KEEP_WORDS = { CLAY = CLAY_KEEP, GROG = GROG_KEEP }

function register(code, spec)
    if type(code) ~= 'string' or code == '' then
        return false, 'no reaction code'
    end
    if RECIPES[code] then
        return false, code .. " is one of RM's own recipes"
    end
    if type(spec) ~= 'table' or type(spec.tool) ~= 'string' or spec.tool == '' then
        return false, 'no temper tool'
    end
    local keep = KEEP_WORDS[spec.keep] or spec.keep
    if type(keep) ~= 'number' or keep < 0 or keep > 1 then
        return false, 'keep is not CLAY, GROG or a number from 0 to 1'
    end
    local word = (type(spec.word) == 'string' and spec.word ~= '') and spec.word or 'temper'
    MODULE_RECIPES[code] = { tool = spec.tool, keep = keep, word = word }
    temper_of[code] = nil
    log('DETAIL', ('%s registered: %s (%s) tempers its clay, keeping %.3f of'
        .. ' its volume.'):format(code, word, spec.tool, keep), 'REGISTER')
    return true
end

function unregister(code)
    if code == nil then return end
    MODULE_RECIPES[code] = nil
    temper_of[code] = nil
end

-- ==========================================
-- SMALL READS
-- ==========================================
local function stack_of(it)
    local n = nil
    pcall(function() n = it.stack_size end)
    return n or 1
end

-- An item DF has destroyed stays in the item list for a few ticks,
-- flagged for removal.
local function gone(it)
    if not it then return true end
    local g = false
    pcall(function() g = it.flags.garbage_collect or it.flags.removed end)
    return g
end

-- A tool's unit, its size, read off its itemdef: the dust tool's is 200
-- (refinish-core-payload.lua), the pile tool's 75 a dung, a pile being a
-- stack of them (making_fuel_tools.json, PILE). It was dust_unit, the
-- dust tool's alone, until 2026-10-28.
local function tool_unit(id)
    local u = nil
    pcall(function()
        for _, d in ipairs(df.global.world.raws.itemdefs.tools) do
            if d.id == id then
                u = d.size
                break
            end
        end
    end)
    return u
end

-- The temper a reaction asks for, in volume: its temper reagent's quantity
-- in the temper tool's units. Read off the live reaction, so the recipe in
-- the reaction's data (the payload, or the module's JSON) is the only place
-- the number lives. 0 for vanilla's, which takes none.
--
-- ONLY THE TEMPER'S OWN REAGENT (2026-10-28). It was grog_volume, which
-- counted every TOOL reagent a reaction had, in dust units: right while
-- grog was the only temper, and a dung pile's quantity counted that way
-- would have read 33 dung as 33 dust. A reagent is the temper's when its
-- tool is the recipe's tool, by id through the reagent's subtype.
local function temper_volume(code, rec)
    if temper_of[code] ~= nil then return temper_of[code] end
    local vol = 0
    if rec and rec.tool then
        pcall(function()
            local unit = tool_unit(rec.tool) or 0
            for _, r in ipairs(df.global.world.raws.reactions.reactions) do
                if r.code == code then
                    for _, g in ipairs(r.reagents) do
                        if g.item_type == df.item_type.TOOL then
                            local def = nil
                            pcall(function()
                                def = dfhack.items.getSubtypeDef(df.item_type.TOOL, g.item_subtype)
                            end)
                            if def and def.id == rec.tool then
                                vol = vol + (g.quantity or 0) * unit
                            end
                        end
                    end
                    break
                end
            end
        end)
    end
    temper_of[code] = vol
    return vol
end

-- ==========================================
-- 1. WATCH
-- ==========================================
-- What a brick job holds: the clay boulder's volume, and the temper it
-- holds, in volume: every item of the recipe's tool, stack times the
-- tool's size. It was the dust it held for grog until 2026-10-28.
local function read_job(job, rec)
    local clay, held, unit = 0, 0, nil
    local tool = rec and rec.tool
    for _, ref in ipairs(job.items) do
        local it = ref.item
        if it then
            local t = nil
            pcall(function() t = it:getType() end)
            if t == df.item_type.BOULDER then
                local v = 0
                pcall(function() v = it:getVolume() end)
                clay = clay + (v or 0)
            elseif tool and t == df.item_type.TOOL then
                local id = nil
                pcall(function() id = it.subtype.id end)
                if id == tool then
                    unit = unit or tool_unit(tool) or 0
                    held = held + stack_of(it) * unit
                end
            end
        end
    end
    return clay, held
end

local function serve(jobs)
    polls = polls + 1
    local window = tail
    tail = df.global.item_next_id
    for _, job in ipairs(jobs) do
        local code = nil
        pcall(function() code = job.reaction_name end)
        local rec = code and recipe_of(code)
        if rec then
            local n = #job.items
            local m = memo[job.id]
            if n > 0 and (not m or m.n ~= n) then
                m = m or {}
                -- The recipe the job was first seen with stays its recipe.
                m.rec = m.rec or rec
                local clay, held = read_job(job, m.rec)
                memo[job.id] = m
                m.jid, m.code, m.clay, m.held, m.n = job.id, code, clay, held, n
                pcall(function()
                    local b = dfhack.job.getHolder(job)
                    m.bld = b and b.id
                end)
            end
            if m then
                m.window = window or tail
                m.last = polls
            end
        end
    end
    for id, m in pairs(memo) do
        if polls - m.last > GRACE_POLLS then memo[id] = nil end
    end
end

-- ==========================================
-- 2. PAY
-- ==========================================
local function in_building(it, bld)
    local yes = false
    pcall(function()
        local h = dfhack.items.getHolderBuilding(it)
        if h and h.id == bld.id then
            yes = true
            return
        end
        local p = it.pos
        yes = p.z == bld.z and p.x >= bld.x1 and p.x <= bld.x2
            and p.y >= bld.y1 and p.y <= bld.y2
    end)
    return yes
end

-- One brick of the material, into the kiln as RM's payouts are placed,
-- else on its centre tile. Anything more createItem hands back goes.
local function make_brick(mt, mi, bld)
    local it = nil
    pcall(function()
        local list = dfhack.items.createItem(df.global.world.units.active[0],
            df.item_type.BLOCKS, -1, mt, mi)
        it = type(list) == 'table' and list[1] or nil
        for i = 2, (type(list) == 'table' and #list or 0) do
            pcall(function() dfhack.items.remove(list[i]) end)
        end
    end)
    if not it then return false end
    local placed = false
    pcall(function()
        placed = dfhack.items.moveToBuilding(it, bld, df.building_item_role_type.TEMP, false)
    end)
    if not placed then
        pcall(function()
            dfhack.items.moveToGround(it, { x = bld.centerx, y = bld.centery, z = bld.z })
        end)
    end
    return true
end

local function settle(m)
    local subj = 'JOB_' .. tostring(m.jid)
    local bld = m.bld and df.building.find(m.bld)
    if not bld then
        -- WARNING: the kiln went with the job; nothing to pay.
        log('WARNING', ('%s: the kiln is gone; nothing paid.'):format(m.code), subj)
        return
    end
    -- The bricks DF made: blocks at this kiln in the job's window.
    local made = {}
    for iid = (m.window or df.global.item_next_id), df.global.item_next_id - 1 do
        local b = df.item.find(iid)
        if b and not gone(b) and b:getType() == df.item_type.BLOCKS and in_building(b, bld) then
            made[#made + 1] = b
        end
    end
    if #made == 0 then
        -- WARNING: no brick to measure or copy; DF's output stands.
        log('WARNING', ('%s: no brick found at the kiln after the job; nothing paid.')
            :format(m.code), subj)
        return
    end
    local first = made[1]
    local mt, mi = nil, nil
    pcall(function() mt, mi = first:getMaterial(), first:getMaterialIndex() end)
    if not mt then
        log('WARNING', ('%s: the brick\'s material could not be read; DF\'s output stands.')
            :format(m.code), subj)
        return
    end

    -- THE MEASURE. The temper is what the reaction asks for, never more
    -- than the job held; the job's own count when the reaction cannot be
    -- read. It keeps its recipe's share (A MODULE'S RECIPE): GROG_KEEP for
    -- grog, as it always did, CLAY_KEEP for a temper that burns out.
    local rec = m.rec or {}
    local asked = temper_volume(m.code, rec)
    local temper = (asked > 0) and math.min(asked, m.held) or m.held
    local kept = m.clay * CLAY_KEEP + temper * (rec.keep or GROG_KEEP)
    local want = math.floor(kept / BRICK_COST + 1e-9)
    if want < 1 then want = 1 end

    local added, taken = 0, 0
    for _ = #made + 1, want do
        if make_brick(mt, mi, bld) then added = added + 1 end
    end
    for k = #made, want + 1, -1 do
        pcall(function() dfhack.items.remove(made[k]) end)
        taken = taken + 1
    end

    -- DETAIL: one line per job. WARNING if a brick could not be made.
    local name = '?'
    pcall(function() name = dfhack.matinfo.decode(mt, mi):toString() end)
    local fault = (#made + added - taken) ~= want
    log(fault and 'WARNING' or 'DETAIL', ('%s: clay %d and %s %d keep %d, %d %s'
        .. ' brick(s) at %d each; DF made %d%s%s.'):format(m.code, m.clay,
        rec.word or 'temper', temper, math.floor(kept), want, name, BRICK_COST, #made,
        added > 0 and ('; ' .. added .. ' made beside them') or '',
        taken > 0 and ('; ' .. taken .. ' of DF\'s taken back') or ''), subj)
end

local function on_completed(job)
    local id = nil
    pcall(function() id = job.id end)
    local m = id and memo[id]
    if not m then return end
    memo[id] = nil
    dfhack.timeout(2, 'ticks', function()
        local ok, err = pcall(settle, m)
        if not ok then log('ERROR', 'bricks not paid: ' .. tostring(err), 'JOB_' .. tostring(id)) end
    end)
end

-- ==========================================
-- WHO WALKS THE LIST
-- ==========================================
-- RM's dispatcher hands this file custom reaction jobs; serve() keeps the
-- brick ones. poll() is this file's own walk, for an RM without a
-- dispatcher. Nothing here removes a job or fetches an item.
local CUSTOM = df.job_type.CustomReaction
local function is_custom(_, job_type) return job_type == CUSTOM end

local function ready()
    return dfhack.isMapLoaded() and _G.refinish_active
end

local function on_dispatch(jobs)
    if not ready() then return end
    local ok, err = pcall(serve, jobs)
    if not ok then log_once('poll', 'ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

local function poll()
    if not ready() then return end
    local ok, err = pcall(function()
        local jobs = {}
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == CUSTOM then jobs[#jobs + 1] = job end
        end
        serve(jobs)
    end)
    if not ok then log_once('poll', 'ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

-- ==========================================
-- START AND STOP
-- ==========================================
function start()
    -- The modules' recipes are not reset here: they registered in the
    -- pipeline, before this start (A MODULE'S RECIPE).
    memo, polls, tail, said, temper_of = {}, 0, nil, {}, {}
    eventful.onJobCompleted[KEY] = on_completed
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    -- ---- AND EVERY UNIT OF A WORK ORDER ----
    -- DFHack reports a work order's job once, at the order's last unit;
    -- RM's job units service reports every unit on the tick it finishes,
    -- to this same handler (refinish-job-units.lua). Without the service,
    -- DFHack's report is the only one, as before.
    local units = _G.refinish_job_units_api
    if units and units.subscribe then units.subscribe(KEY, on_completed) end
    -- The dispatcher when RM has one; this file's own loop otherwise.
    -- Paused included, so a job queued while paused is watched before the
    -- game runs.
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(KEY,
            { every = EVERY, jobs = is_custom, fn = on_dispatch, paused = true }) then
        repeatUtil.cancel(KEY)
    else
        repeatUtil.scheduleEvery(KEY, EVERY, 'frames', poll)
    end
    -- Which module recipes this start serves, named, so a module whose
    -- registration did not land reads as missing here and not as silence.
    local names = {}
    for code in pairs(MODULE_RECIPES) do names[#names + 1] = code end
    table.sort(names)
    log('DETAIL', ('started: bricks are paid by the volume of their clay and temper;'
        .. ' module recipes: %s.'):format(#names > 0 and table.concat(names, ', ') or 'none'),
        'START')
end

function stop()
    repeatUtil.cancel(KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(KEY) end
    eventful.onJobCompleted[KEY] = nil
    local units = _G.refinish_job_units_api
    if units and units.unsubscribe then units.unsubscribe(KEY) end
    memo = {}
    -- Module recipes go with the fort; the next one's modules register
    -- again in their own start hooks (A MODULE'S RECIPE).
    for code in pairs(MODULE_RECIPES) do MODULE_RECIPES[code] = nil end
    log('DETAIL', 'stopped.', 'STOP')
end

-- For the mock tests and anything that wants the arithmetic.
_G.refinish_brick_math = { CLAY_KEEP = CLAY_KEEP, GROG_KEEP = GROG_KEEP,
                           BRICK_COST = BRICK_COST }

-- ---- THE HANDLE ----
-- Published at load: modules register during the pipeline, before start()
-- runs (A MODULE'S RECIPE).
_G.refinish_bricks_api = { register = register, unregister = unregister }