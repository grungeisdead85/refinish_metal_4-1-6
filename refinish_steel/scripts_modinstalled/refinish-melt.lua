--@ module = true
-- refinish-melt.lua
-- ==========================================
-- RM SERVICE: EVERY MELT IS MEASURED
-- ==========================================
-- WHAT IT DOES
-- Melting is vanilla's: the player designates an item for melting, a
-- smelter's melt a metal object job melts it, and DF keeps what the melt
-- returns under a whole bar in that smelter, per metal (THE SMELTER'S
-- STORE). This service corrects HOW MUCH a melt returns. DF credits by a
-- table that pays many items more metal than they cost to make (the DF
-- wiki's Melt item page, v53.16: leggings, giant axe blades and two
-- handed swords 150%, shields, picks and battle axes 120%, a single bolt
-- 250%, a single coin 5000%, a stack of 500 coins 110%), RM's dust and
-- scrap at 3 tenths a unit whatever their volume, and either of those on
-- top of what RM's forging already paid out as dust and scrap. Left
-- alone, forging and melting made metal.
--
-- THE MEASURE (decided 2026-10-04: every process loses material, and
-- a melt returns what was in what it melted, less its loss)
-- A melt returns NINE TENTHS of what is IN what it melted:
--   * WHAT IS IN IT. RM's dust and scrap hold their volume. Anything else
--     holds what it cost to make (WHAT AN ITEM COSTS TO MAKE), less what
--     RM's forging paid out for it: a forge job's loss is the bars' volume
--     in less the item's volume out (refinish-job-byproducts.lua), so what
--     stays in an item is the smaller of its cost and its volume. These
--     are DF's own measures, read as they are. One DF measures oddly is a
--     measuring problem for a mod to fix; RM represents what it says.
--   * NINE TENTHS (MELT_YIELD). Forging pays out what it loses as dust and
--     scrap, so a product and all its waste, brought back to a smelter,
--     still hold what went in; the melt is where the loss is taken. Every
--     melt loses it, RM's forms included: material only ever goes down
--     the chain, and each process leaves less of it. Nine tenths is DF's
--     own rate, the yield it gives every item its whole-bar rounding does
--     not distort.
-- DF's own credit is no measure: it pays a table a bar of its three, a
-- bar half of itself, and leggings half again what they cost. Until
-- 2026-10-04 it capped a melt, which is how a gold table still came back
-- as one bar. It is read only for what DF did, to undo it, and for an
-- item of a type with no cost known, credited nine tenths of the lesser of
-- its volume and DF's credit, said once per type.
-- KEPT TO THE HUNDREDTH. The store holds whole tenths of a bar; the
-- part of a melt under a tenth (a scrap is 2.5 tenths, a coin a fiftieth
-- of one) is kept as the smelter's REMAINDER for that metal, in RM's own
-- bank (refinish-persist-banks, REFINISH_MELT), by metal name, and added
-- in at that smelter's next melt of the metal. Until 2026-10-04 it was
-- rounded down and lost: four single scraps made 0.8 of a bar. From then
-- until 2026-10-07 it was kept to a millionth of a unit of volume, and
-- that left crumbs: a credit is nine tenths of what an item holds, so a
-- melt can end on any fraction of a tenth, down to a small fraction of
-- one unit of volume, and each crumb waited for another melt of the same
-- metal at the same smelter that might never come, one per metal ever
-- melted there. The remainder is now kept in whole hundredths of a bar
-- (REMAINDER_UNIT, 6 units of volume), the precision the bank readout
-- shows; the part under a hundredth is part of the melt's loss. That is
-- less than the 10% every melt already loses, even on a single dust (10
-- of its 100).
--
-- MEASURED
--   * The store (df-structures: building_furnacest.melt_remainder, one
--     entry per inorganic) counts tenths of a bar, and DF makes a bar of
--     a metal once its entry reaches 10. Measured across fourteen melts of
--     RM forms (2026-10-03 and 04), each checked against DF's credit of 3
--     tenths a unit before this file generalised.
--   * DF destroys the item whole, and the completion event fires for
--     every cycle of a repeating melt (refinish-melt-probe and this
--     file's earlier versions, 2026-10-03).
--
-- HOW
--   1. WATCH. The poll sees every melt job and notes the item it is to
--      melt (the one carrying the melt mark): its metal, what it holds and
--      what it cost (THE MEASURE), the smelter, the store's value for the
--      metal, and where DF's item numbers stand. RM forms count every RM
--      stack the job holds in that metal, a retired filter's included.
--   2. CORRECT, two ticks after completion. What DF credited is the bars of
--      the metal it made at that smelter in the job's window, in tenths,
--      plus what the store gained. The credit (THE MEASURE) is added to
--      what the store and the remainder held, and the bars, the store and
--      the remainder are set to it: bars DF made past that are taken back,
--      and any it fell short of are made.
--   3. RETIRE. A job saved by the hijacking version still carries the
--      filters it appended, asking for RM forms. Each is set to ask for
--      nothing the first time a poll sees it. Stacks such a filter already
--      holds melt with the job, and are credited with it.
--   4. THE STORE COVERS THE ARRAY. DF sizes a furnace's store to the
--      inorganics when the furnace is built, and writes a melted metal's
--      entry by its index. RM mints finishes in play, past the end of a
--      store sized before them, so before any melt at a smelter the poll
--      grows that smelter's store to the array. The ledger fits every
--      store to the array at each load (refinish-ledger.lua, fit_stores).
--   5. SHOWN. A smelter's melt bank shows on RM's bank readout
--      (refinish-bank-readout.lua) while its sheet is open: one row per
--      metal, store and remainder together, exactly (THE PART BARS, SHOWN).
--
-- An RM service: loaded at refinish_steel's load, started and stopped
-- with the others (RM'S SERVICES FOLLOW THE DATA there).
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local utils      = require('utils')

local KEY            = 'refinish-melt'
local EVERY          = 10    -- frames between polls
local GRACE_POLLS    = 30    -- polls a vanished job's memo is kept (300 frames)
local BAR_VOLUME     = 600   -- a bar's measured volume (2026-09-24)
local BAR_DIM        = 150   -- a whole bar's dimension
local TENTHS         = 10    -- the store's units in a bar (MEASURED)
local TENTH_VOLUME   = BAR_VOLUME / TENTHS   -- 60: one tenth, in volume
local MELT_YIELD     = 0.9   -- DF's own rate, of the cost to make (THE MEASURE)
-- 6: a hundredth of a bar, the finest remainder kept (KEPT TO THE HUNDREDTH)
local REMAINDER_UNIT = BAR_VOLUME / 100
local FORM_PREFIX    = 'REFINISH_'   -- RM core's byproduct forms, by tool itemdef id
local BANK_NAME      = 'REFINISH_MELT'   -- the remainders (THE MEASURE)

-- ---- WHAT AN ITEM COSTS TO MAKE ----
-- An item with a material size costs a third of a bar per point, in whole
-- bars, at least one: max(1, floor(size / 3)), shared between the two of a
-- pair. That is the "Bars to make" column of the DF wiki's melt table
-- (Melt item, v53.16) for every sized item it lists: a cap, helm or dagger
-- 1, leggings 1, greaves and mail shirts 2, a breastplate 3, gauntlets and
-- boots half a bar each, made in pairs. The size is read off the item's
-- own definition, so a module's items are costed the same way.
--
-- An item with no material size costs what the same column says, per item:
-- ammo is made 25 a bar and coins 500; flasks and goblets 3; crafts 1 to 3,
-- costed here at the least one can hold, a third, so a craft is never
-- credited more than went in; blocks, mechanisms, chains, buckets, animal
-- traps, instruments and toys a bar each; furniture, cages, splints,
-- crutches and ballista arrows and arrowheads three. A type not named here
-- has no cost known, and keeps DF's credit (HOW, 2).
local COST_BARS = {
    AMMO = 1 / 25, COIN = 1 / 500, BAR = 1,
    FLASK = 1 / 3, GOBLET = 1 / 3,
    FIGURINE = 1 / 3, AMULET = 1 / 3, SCEPTER = 1 / 3, CROWN = 1 / 3,
    RING = 1 / 3, EARRING = 1 / 3, BRACELET = 1 / 3,
    BLOCKS = 1, TRAPPARTS = 1, CHAIN = 1, BUCKET = 1, ANIMALTRAP = 1,
    INSTRUMENT = 1, TOY = 1,
    DOOR = 3, FLOODGATE = 3, CHAIR = 3, TABLE = 3, COFFIN = 3, STATUE = 3,
    BOX = 3, BIN = 3, ARMORSTAND = 3, WEAPONRACK = 3, CABINET = 3,
    ANVIL = 3, BARREL = 3, CAGE = 3, GRATE = 3, HATCH_COVER = 3,
    PIPE_SECTION = 3, TRACTION_BENCH = 3, SPLINT = 3, CRUTCH = 3,
    SIEGEAMMO = 3, BALLISTAARROWHEAD = 3,
}
-- Made two to a job: the cost of a pair is shared.
local PAIRED_NAMES = { 'GLOVES', 'SHOES' }

-- Keyed by item type value, resolved guarded: a name DF does not have is
-- simply not costed, never an error at load.
local COST_OF, PAIRED = {}, {}
for name, bars in pairs(COST_BARS) do
    local v = df.item_type[name]
    if v ~= nil then COST_OF[v] = bars end
end
for _, name in ipairs(PAIRED_NAMES) do
    local v = df.item_type[name]
    if v ~= nil then PAIRED[v] = true end
end

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. DETAIL is one line per melt corrected; WARNING is a melt
-- that did not go as measured, with the numbers.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MELT'
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
-- memo[job id], ids and numbers only, never a job or item object (a job
-- is good only for the tick it is handed out in, refinish-loop-dispatch):
--   jid       the job's id
--   mi        the metal (inorganic index)
--   mid       the metal's id, which keys its remainder
--   ids       [item id] = true, the items the job will melt in that metal
--   meas      what they hold and cost (measure), or nil with no cost known
--   itype     the item's type in words, for the log
--   name      the marked item in words, for the log
--   bld       the smelter's id
--   store0    the store's value for the metal at the last poll, or nil
--   window    item_next_id at the poll before the last: the job's window
--   last      the poll it was last seen on
local memo, polls, tail = {}, 0, nil

-- The remainders, opened at start (THE MEASURE): REMAINDER@<smelter id>:
-- <metal id> -> volume under a tenth.
local bank = nil
local function remainder_key(bid, mid)
    return 'REMAINDER@' .. tostring(bid) .. ':' .. tostring(mid)
end

-- ==========================================
-- SMALL READS
-- ==========================================
local function stack_of(it)
    local n = nil
    pcall(function() n = it.stack_size end)
    return n or 1
end

-- An item DF has destroyed stays in the item list for a few ticks (the
-- probe read a melted stack 2 ticks after its melt), flagged for removal.
local function gone(it)
    if not it then return true end
    local g = false
    pcall(function() g = it.flags.garbage_collect or it.flags.removed end)
    return g
end

-- An RM form's tool subtype, or nil.
local function rm_form_sub(it)
    local sub = nil
    pcall(function()
        if it:getType() ~= df.item_type.TOOL then return end
        local id = it.subtype.id
        if id and string.find(id, FORM_PREFIX, 1, true) == 1 then sub = it:getSubtype() end
    end)
    return sub
end

-- The metal an item is made of, as its inorganic index, or nil.
local function metal_of(it)
    local mi = nil
    pcall(function()
        if it:getMaterial() ~= 0 then return end
        local idx = it:getMaterialIndex()
        local inorg = df.global.world.raws.inorganics.all[idx]
        if inorg and inorg.material.flags.IS_METAL then mi = idx end
    end)
    return mi
end

-- A unit's volume in a form: the tool's size, where RM writes the unit
-- (dust 200, scrap 150; refinish-core-payload.lua).
local function unit_of(sub)
    local u = nil
    pcall(function() u = df.global.world.raws.itemdefs.tools[sub].size end)
    return u
end

-- An item in words for the log, with its count.
local function name_of(it)
    local s = '?'
    pcall(function() s = dfhack.items.getDescription(it, 0, false) end)
    return s
end

-- A metal's id from its index, which keys its remainder: an index moves
-- between loads, an id does not.
local function id_of(mi)
    local s = nil
    pcall(function() s = df.global.world.raws.inorganics.all[mi].id end)
    return s
end

-- What a melted item other than an RM form holds and what it cost to make,
-- in volume (THE MEASURE): { held, cost, vol }. An item of a type with no
-- cost known (WHAT AN ITEM COSTS TO MAKE) is { held = its volume, unknown }
-- and credit_of bounds it by DF's credit.
local function measure(it)
    local t, n = nil, stack_of(it)
    pcall(function() t = it:getType() end)
    if t == nil then return nil end
    local bars = nil
    local ms = nil
    pcall(function() ms = it.subtype.material_size end)
    if type(ms) == 'number' and ms > 0 then
        bars = math.max(1, ms // 3)
        if PAIRED[t] then bars = bars / 2 end
    else
        bars = COST_OF[t]
    end
    local vol = nil
    pcall(function() vol = it:getVolume() end)
    if not bars then
        return { held = (type(vol) == 'number' and vol > 0) and vol or math.huge,
                 vol = vol, unknown = true }
    end
    local cost = bars * BAR_VOLUME * n
    local held = cost
    if type(vol) == 'number' and vol > 0 and vol < cost then held = vol end
    return { held = held, cost = cost, vol = vol }
end

-- The credit, in volume, by THE MEASURE: nine tenths of what is in it. For
-- a type with no cost known, of the lesser of its volume and DF's credit.
local function credit_of(meas, df_vol)
    local held = meas.held
    if meas.unknown then held = math.min(held, df_vol) end
    return MELT_YIELD * held
end

-- ==========================================
-- THE SMELTER'S STORE OF PART BARS
-- ==========================================
-- DF keeps what a melt returns under a whole bar in the smelter itself,
-- per metal (building_furnacest.melt_remainder, indexed by inorganic,
-- df-structures), in tenths of a bar, and makes a real bar of the metal
-- once a store reaches ten. It is vanilla's own bank for melting: this
-- file only ever sets the entry a melt of an RM form just changed.
local function store_of(bld, mi)
    local v = nil
    pcall(function()
        local r = bld.melt_remainder
        if mi < #r then v = r[mi] end
    end)
    return v
end

-- True when set. An entry the vector does not reach yet is made first,
-- the vector grown to the inorganics as DFHack itself sizes a new
-- furnace's (library/modules/Buildings.cpp).
local function set_store(bld, mi, v)
    local ok = false
    pcall(function()
        local r = bld.melt_remainder
        if mi >= #r then r:resize(#df.global.world.raws.inorganics.all) end
        if mi < #r then
            r[mi] = v
            ok = true
        end
    end)
    return ok
end



-- A furnace's store grown to the whole inorganics array when it falls
-- short of it (THE STORE COVERS THE ARRAY, header). Two length reads when
-- it does not.
local function cover_store(bld)
    local r = bld.melt_remainder
    local n = #df.global.world.raws.inorganics.all
    if #r < n then r:resize(n) end
end

-- ==========================================
-- RETIRING THE HIJACK'S FILTERS
-- ==========================================
-- Filters the hijacking version appended to melt jobs, a TOOL of an RM
-- form (DF's own melt filter asks for no tool), set to ask for nothing so
-- they fetch no more (RETIRE, header). Left on the job, not erased: an
-- item may still be attached through one, and erasing a filter under it
-- would leave its index pointing at nothing.
local function retire_filters(job)
    pcall(function()
        local els = job.job_items.elements
        for i = 0, #els - 1 do
            local e = els[i]
            if e.item_type == df.item_type.TOOL and e.quantity > 0 and e.item_subtype >= 0 then
                local id = nil
                pcall(function() id = df.global.world.raws.itemdefs.tools[e.item_subtype].id end)
                if id and string.find(id, FORM_PREFIX, 1, true) == 1 then
                    e.quantity = 0
                    log_once('retire:' .. tostring(job.id), 'DETAIL', ('a filter the hijacking'
                        .. ' version added now asks for nothing.'), 'JOB_' .. tostring(job.id))
                end
            end
        end
    end)
end

-- ==========================================
-- 1. WATCH
-- ==========================================
-- What a melt job will melt: its marked item (the one carrying the melt
-- mark) and its metal. For an RM form, every RM stack the job holds in that
-- metal (the others can only be a retired filter's). Returns nil when it
-- holds no marked metal item yet.
local function read_job(job)
    local first, mi = nil, nil
    for _, ref in ipairs(job.items) do
        local it = ref.item
        if it and it.flags.melt then
            local m = metal_of(it)
            if m then
                first, mi = it, m
                break
            end
        end
    end
    if not first then return nil end
    local r = { mi = mi, mid = id_of(mi), ids = {}, name = name_of(first) }
    if rm_form_sub(first) then
        local held, units = 0, 0
        for _, ref in ipairs(job.items) do
            local it = ref.item
            local sub = it and rm_form_sub(it)
            if sub and metal_of(it) == mi then
                local n = stack_of(it)
                r.ids[it.id] = true
                units = units + n
                held = held + n * (unit_of(sub) or 0)
            end
        end
        r.meas = { held = held, cost = held, form = true, units = units }
        r.itype = 'RM form'
    else
        r.ids[first.id] = true
        r.meas = measure(first)
        pcall(function() r.itype = df.item_type[first:getType()] end)
        r.itype = r.itype or '?'
    end
    return r
end

local function serve(jobs)
    polls = polls + 1
    local window = tail
    tail = df.global.item_next_id
    for _, job in ipairs(jobs) do
        retire_filters(job)
        -- THE STORE COVERS THE ARRAY (header), for every melt. WARNING,
        -- once a session, if it cannot: a melt there of a metal past the
        -- store's end would be written past it.
        local ok_c, err_c = pcall(function()
            local b = dfhack.job.getHolder(job)
            if b then cover_store(b) end
        end)
        if not ok_c then
            log_once('cover', 'WARNING', 'a smelter store could not be grown to the'
                .. ' material array: ' .. tostring(err_c), 'JOB_' .. tostring(job.id))
        end
        local r = read_job(job)
        if r then
            local m = memo[job.id] or {}
            memo[job.id] = m
            m.jid, m.mi, m.mid, m.ids, m.meas, m.itype, m.name =
                job.id, r.mi, r.mid, r.ids, r.meas, r.itype, r.name
            pcall(function()
                local b = dfhack.job.getHolder(job)
                m.bld = b and b.id
            end)
            local bld = m.bld and df.building.find(m.bld)
            m.store0 = bld and store_of(bld, m.mi) or nil
            m.window = window or tail
            m.last = polls
        end
    end
    for id, m in pairs(memo) do
        if polls - m.last > GRACE_POLLS then memo[id] = nil end
    end
end

-- ==========================================
-- 2. CORRECT
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

-- A whole bar of the metal, into the smelter as the byproduct service
-- places its payouts, else on its centre tile.
local function make_bar(mi, bld)
    local it = nil
    pcall(function()
        local list = dfhack.items.createItem(df.global.world.units.active[0],
            df.item_type.BAR, -1, 0, mi)
        it = type(list) == 'table' and list[1] or nil
        -- One bar asked for: anything more createItem hands back goes, as
        -- the byproduct service's payouts do (refinish-job-byproducts, make).
        for i = 2, (type(list) == 'table' and #list or 0) do
            pcall(function() dfhack.items.remove(list[i]) end)
        end
    end)
    if not it then return false end
    pcall(function() it.dimension = BAR_DIM end)
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

-- A volume for the log: whole when whole, else to two places.
local function vol_text(v)
    if v == math.floor(v) then return tostring(math.floor(v)) end
    return ('%.2f'):format(v)
end

local function settle(m)
    local subj = 'JOB_' .. tostring(m.jid)
    for iid in pairs(m.ids) do
        if not gone(df.item.find(iid)) then
            -- WARNING: DF completed a melt and left an item it held.
            log('WARNING', ('%s: an item it held is still here after the melt; nothing'
                .. ' corrected.'):format(m.name), subj)
            return
        end
    end
    local bld = m.bld and df.building.find(m.bld)
    if not bld then
        -- WARNING: the smelter went with the melt; nothing to correct.
        log('WARNING', ('%s: the smelter is gone; nothing corrected.'):format(m.name), subj)
        return
    end

    -- What DF credited: its bars of the metal at this smelter in the job's
    -- window, in tenths, plus what the store gained.
    local made = {}
    for iid = (m.window or df.global.item_next_id), df.global.item_next_id - 1 do
        local b = df.item.find(iid)
        if b and not gone(b) and b:getType() == df.item_type.BAR
           and b:getMaterial() == 0 and b:getMaterialIndex() == m.mi
           and in_building(b, bld) then
            made[#made + 1] = b
        end
    end
    local store0 = m.store0 or 0
    local store1 = store_of(bld, m.mi) or 0
    local credited = TENTHS * #made + (store1 - store0)
    if credited < 0 then
        -- WARNING: DF never takes metal away in a melt; with the numbers
        -- this far off, nothing is touched.
        log('WARNING', ('%s: DF credited %d tenths (%d bar(s), store %d to %d), less'
            .. ' than nothing; nothing corrected.'):format(m.name, credited, #made,
            store0, store1), subj)
        return
    end
    if not m.meas then
        -- WARNING: nothing could be read off the item at all.
        log('WARNING', ('%s: nothing could be measured; DF\'s credit of %d tenths'
            .. ' stands.'):format(m.name, credited), subj)
        return
    end
    if m.meas.unknown then
        -- DETAIL, once per type: no cost known (WHAT AN ITEM COSTS TO MAKE).
        log_once('nocost:' .. tostring(m.itype), 'DETAIL', ('no cost is known for %s'
            .. ' items, so they are credited nine tenths of the lesser of their volume'
            .. ' and DF\'s credit (THE MEASURE).'):format(tostring(m.itype)), subj)
    end

    -- THE MEASURE, on top of what the store and the remainder held.
    local df_vol = credited * TENTH_VOLUME
    local credit = credit_of(m.meas, df_vol)
    local key = m.mid and remainder_key(bld.id, m.mid)
    local res0 = (bank and key and tonumber(bank[key])) or 0
    local total = store0 * TENTH_VOLUME + res0 + credit
    local tenths = math.floor(total / TENTH_VOLUME + 1e-9)
    -- KEPT TO THE HUNDREDTH (header): the remainder carries in whole
    -- hundredths of a bar, and the part under one is the melt's loss. The
    -- epsilon keeps a float a hair under a whole hundredth (29.9999999 for
    -- 30) from dropping it; a float a hair under a whole tenth comes out as
    -- that tenth, which goes to the store.
    local res = total - tenths * TENTH_VOLUME
    res = math.floor(res / REMAINDER_UNIT + 1e-6) * REMAINDER_UNIT
    if res >= TENTH_VOLUME then tenths, res = tenths + 1, res - TENTH_VOLUME end
    if res < 0 then res = 0 end
    local bars, rest = tenths // TENTHS, tenths % TENTHS
    local taken, added = 0, 0
    for k = #made, bars + 1, -1 do
        pcall(function() dfhack.items.remove(made[k]) end)
        taken = taken + 1
    end
    for _ = #made + 1, bars do
        if make_bar(m.mi, bld) then added = added + 1 end
    end
    local stored = set_store(bld, m.mi, rest)
    local kept = true
    if bank and key then
        kept = pcall(function() bank[key] = (res > 0) and res or nil end)
    end

    -- DETAIL: one line per melt. WARNING if the store, the remainder or a
    -- bar could not be set.
    local fault = (not stored) or (not kept) or (#made - taken + added ~= bars)
    local held
    if m.meas.form then
        held = ('holds %s'):format(vol_text(m.meas.held))
    elseif m.meas.unknown then
        held = ('no cost known, volume %s'):format(m.meas.vol and vol_text(m.meas.vol) or '?')
    else
        held = ('holds %s of the %s it cost%s'):format(vol_text(m.meas.held),
            vol_text(m.meas.cost), m.meas.vol and (', volume ' .. vol_text(m.meas.vol)) or '')
    end
    local of_cost = (m.meas.cost and m.meas.cost > 0)
        and (', %d%% of its cost'):format(math.floor(100 * credit / m.meas.cost + 0.5)) or ''
    log(fault and 'WARNING' or 'DETAIL', ('melted %s (%s): DF credited %s (%d tenths:'
        .. ' %d bar(s), store %d to %d); credited %s%s; store %d and remainder %s became'
        .. ' %d bar(s), store %d, remainder %s%s%s%s%s.'):format(
        m.name, held, vol_text(df_vol), credited, #made, store0, store1, vol_text(credit),
        of_cost, store0, vol_text(res0), bars, rest, vol_text(res),
        taken > 0 and ('; ' .. taken .. ' of DF\'s bar(s) taken back') or '',
        added > 0 and ('; ' .. added .. ' bar(s) made past DF\'s') or '',
        stored and '' or '; the store could NOT be set',
        kept and '' or '; the remainder could NOT be kept'), subj)
end

local function on_completed(job)
    local id = nil
    pcall(function() id = job.id end)
    local m = id and memo[id]
    if not m then
        -- DETAIL, once a session: a melt that finished between two polls,
        -- or before the first, is not measured; DF's credit stood for it.
        local melt = false
        pcall(function() melt = job.job_type == df.job_type.MeltMetalObject end)
        if melt then
            log_once('unseen', 'DETAIL', 'a melt completed before a poll saw it, so it'
                .. ' was not measured and DF\'s credit stood.', 'JOB_' .. tostring(id))
        end
        return
    end
    memo[id] = nil
    dfhack.timeout(2, 'ticks', function()
        local ok, err = pcall(settle, m)
        if not ok then log('ERROR', 'melt not settled: ' .. tostring(err), 'JOB_' .. tostring(id)) end
    end)
end

-- ==========================================
-- THE PART BARS, SHOWN
-- ==========================================
-- DF keeps a smelter's part bars where no one can see them. RM's bank
-- readout (refinish-bank-readout.lua) shows them while a smelter's sheet
-- is open, as its MELT BANK: one row per metal with a part bar waiting,
-- vanilla's as well as RM's, the store and the remainder together (THE
-- MEASURE), its bar filling by the tenth toward the whole bar it becomes,
-- and the number in bars. An empty bank says so, so the bank is there to
-- read before it has ever been used. Smelters and magma smelters only:
-- nothing else melts metal.
--
-- The store is read once per STORE_READ_MS for the open smelter, up to the
-- array's end (an entry past it belongs to no material), and the rows
-- kept between reads: the panel asks every frame, and a store is only ever
-- changed by a melt, a few times a minute at most.
local STORE_READ_MS = 250
local SMELTERS = {}
for _, name in ipairs({ 'Smelter', 'MagmaSmelter' }) do
    local v = df.furnace_type[name]
    if v ~= nil then SMELTERS[v] = true end
end

-- Under the LENGTH IS LOAD BEARING rule (making-fuel-bank-readout.lua):
-- 42 columns at most, or a footer wraps and the panel comes up short.
local PART_BAR_FOOTERS = {
    'melt remainders per metal',
}

local shown = { bid = nil, at = nil, rows = nil }

local function part_bar_rows(bld)
    local now = dfhack.getTickCount()
    if shown.bid == bld.id and shown.at and now - shown.at < STORE_READ_MS then
        return shown.rows
    end
    local rows = {}
    pcall(function()
        local all = df.global.world.raws.inorganics.all
        -- In volume, per metal index: the store's tenths, then each
        -- remainder this smelter keeps, found by its metal's id.
        local held = {}
        local r = bld.melt_remainder
        local n = math.min(#r, #all)
        for i = 0, n - 1 do
            local v = r[i]
            if v ~= 0 then held[i] = v * TENTH_VOLUME end
        end
        if bank then
            local prefix = 'REMAINDER@' .. tostring(bld.id) .. ':'
            for k, res in pairs(bank) do
                if type(k) == 'string' and k:sub(1, #prefix) == prefix then
                    local mi = nil
                    pcall(function()
                        mi = dfhack.matinfo.find('INORGANIC:' .. k:sub(#prefix + 1)).index
                    end)
                    if mi and tonumber(res) then held[mi] = (held[mi] or 0) + tonumber(res) end
                end
            end
        end
        for i, v in pairs(held) do
            local name = nil
            pcall(function() name = all[i].material.state_name.Solid end)
            if not name or name == '' then pcall(function() name = all[i].id end) end
            rows[#rows + 1] = { key = 'MELT:' .. tostring(bld.id) .. ':' .. i,
                                label = string.lower(tostring(name or '?')),
                                value = v / BAR_VOLUME, full = false }
        end
    end)
    table.sort(rows, function(a, b) return a.label < b.label end)
    shown.bid, shown.at, shown.rows = bld.id, now, rows
    return rows
end

local function bank_section(bld)
    local smelter = false
    pcall(function()
        smelter = bld:getType() == df.building_type.Furnace and SMELTERS[bld.type] == true
    end)
    if not smelter then return nil end
    local rows = part_bar_rows(bld)
    if #rows == 0 then
        rows = { { key = 'MELT:none', text = 'empty', pen = COLOR_GREY } }
    end
    return { title = 'melt bank', rows = rows, footers = PART_BAR_FOOTERS }
end

-- Registered with RM's panel at this file's load (PROVIDERS, in
-- refinish-bank-readout.lua). Order 20: after Making Fuel's rows, which
-- head a smelter's panel when that module is installed.
_G.refinish_bank_providers = _G.refinish_bank_providers or {}
_G.refinish_bank_providers.melt = { order = 20, fn = bank_section }

-- ==========================================
-- WHO WALKS THE LIST
-- ==========================================
-- RM's dispatcher walks the job list for every subscriber and hands this
-- file only melt jobs. poll() is this file's own walk, for an RM without
-- a dispatcher. Nothing here removes a job or fetches an item.
local MELT = df.job_type.MeltMetalObject
local function is_melt(_, job_type) return job_type == MELT end

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
            if job.job_type == MELT then jobs[#jobs + 1] = job end
        end
        serve(jobs)
    end)
    if not ok then log_once('poll', 'ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- The remainders, opened from the save. A remainder whose smelter is gone
-- goes with it, as DF's own part bars do when a smelter is torn down.
local function open_bank()
    bank = nil
    local ok, b = pcall(function() return reqscript('refinish-persist-banks').open(BANK_NAME) end)
    if not ok or not b then
        log('WARNING', 'the remainders could not be opened: melts are measured, but a'
            .. ' part under a tenth is lost until they can.', 'START')
        return
    end
    bank = b
    local dropped = 0
    local orphans = {}
    for k in pairs(bank) do
        local bid = type(k) == 'string' and tonumber(k:match('^REMAINDER@(%d+):'))
        if bid and not df.building.find(bid) then orphans[#orphans + 1] = k end
    end
    for _, k in ipairs(orphans) do
        bank[k] = nil
        dropped = dropped + 1
    end
    if dropped > 0 then
        log('DETAIL', ('%d remainder(s) of smelters no longer standing dropped.'):format(dropped),
            'START')
    end
end

function start()
    open_bank()
    memo, polls, tail, said = {}, 0, nil, {}
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
    -- Paused included, so a melt queued while paused is watched before the
    -- game runs.
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(KEY,
            { every = EVERY, jobs = is_melt, fn = on_dispatch, paused = true }) then
        repeatUtil.cancel(KEY)
    else
        repeatUtil.scheduleEvery(KEY, EVERY, 'frames', poll)
    end
    log('DETAIL', 'started: every melt is measured, and remainders kept.', 'START')
end

function stop()
    bank = nil
    repeatUtil.cancel(KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(KEY) end
    eventful.onJobCompleted[KEY] = nil
    local units = _G.refinish_job_units_api
    if units and units.unsubscribe then units.unsubscribe(KEY) end
    memo = {}
    log('DETAIL', 'stopped.', 'STOP')
end

-- For the mock tests and anything that wants the arithmetic.
_G.refinish_melt_math = { TENTHS = TENTHS, bank_section = bank_section,
                          measure = measure, credit_of = credit_of }