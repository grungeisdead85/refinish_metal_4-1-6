--@ module = true
-- refinish-job-byproducts.lua
-- ==========================================
-- RM BYPRODUCTS
-- ==========================================
-- Material a job destroys, recovered as items. A mason turns a boulder
-- into a smaller door and vanilla drops the difference; this measures
-- the difference and pays part of it back as forms (dust, gravel,
-- scrap, sawdust...) in the material the job was worked from.
--
-- RM RUNS DUST ITSELF. Stone, gem and metal loss pays REFINISH_CORE_DUST
-- whatever modules are installed. Modules declare their own streams
-- (gravel, sawdust, scrap...) and this pays them from the SAME
-- measurement, once per job.
--
-- WHERE IT CAME FROM. Making Fuel's hijacker measured and paid every
-- stream itself (memo_poll, waste_output, loss_class). The measurement
-- is general knowledge, what a job consumed and what came out, so it
-- lives here now, field for field, and the hijacker only declares
-- Making Fuel's streams.
--
-- It GIVES BACK PART OF WHAT A JOB DESTROYED, sized from what it
-- actually destroyed rather than from a number written here, and it runs
-- alongside whatever else the job does: a carpentry job keeps its vanilla
-- furniture untouched and simply gains the sawdust. Banked like
-- everything else, so a job losing less than one whole item does not
-- lose the value, and so the item cap can hold excess over rather than
-- throwing it away. (Carried over from the hijacker's waste path.)
--
-- ---- THE MEASUREMENT ----
-- 1. COVERAGE: the vanilla job types that destroy material. 'AUTO'
--    classifies from what the job was fed; three job types cannot be
--    inferred from their feedstock item and say their class outright.
-- 2. THE MEMO, every MEMO_EVERY frames on the dispatcher, once per
--    job: the volume of everything attached except fuel, the feedstock
--    (first item type by FEEDSTOCK_ORDER), its material and volume, and
--    the mark, DF's next item number at the last poll, so the items the
--    job makes are known by their numbers (WHERE THE OUTPUT STARTS).
-- 3. AT COMPLETION, DFHack's report of a finished job, or RM's job units
--    service's report of each unit of a work order, which DFHack reports
--    once per order (refinish-job-units.lua): output is what the workshop
--    holds numbered at or above the mark, of the item type the job makes
--    (THE JOB'S OWN PRODUCT), minus anything this file made itself. Loss
--    is input minus output.
-- 4. THE CLASS: from the feedstock (a boulder is STONE, a bar METAL, a
--    rough or cut gem GEM, or GLASS by its token, a corpsepiece BONE,
--    LEATHER or CLOTH by its material) or the job type's own override.
--
-- ---- WHAT A STREAM IS ----
-- A form (a tool id), a share of its class's recovery, and a unit: how
-- much recovered loss makes one item. Recovered loss is banked per
-- form per building and paid out in whole items, so small jobs bank
-- and large ones pay. VOLUME streams count loss in volume; VALUE
-- streams convert it through their owner's valuation first.
--
-- ---- CORE DUST ----
-- One dust is the dust tool's own volume, the same for every class
-- (2026-10-03): dust of one class finishes no better than another, it
-- only comes easier or harder, and what each job measurably loses
-- decides that. The unit is read off the dust itemdef's size (200,
-- refinish-core-payload.lua), so a mod that resizes the tool moves the
-- unit with it. Until 2026-10-03 each class had its own unit, the
-- grinder's yield from its reference item: a quarter boulder (2500),
-- three rough gems (750), one bar (600).
--
-- CORE_DUST is the knob: the fraction of each measured loss that
-- becomes dust. What comes out is what went in, in other forms, so the
-- fractions are set to conserve the loss once a module or the catalog
-- supplies the rest:
--   stone 0.40   the other 0.60 is gravel, which favours gravel without
--                burying the mason in it. Stone is the largest loss in
--                the game: a 10000 boulder becomes four blocks and the
--                rest stops existing. Dressing stone makes both coarse
--                spalls and fine dust and all of it is still on the
--                floor, so recovery is whole and the split is two ways.
--                (Making Fuel's STONE note, carried here with the class.)
--   gem   1.00   cutting rough throws away most of the stone and every
--                bit of it is abrasive. Nothing burns or evaporates, so
--                it all comes back, and it is all fines. (Making Fuel's
--                GEM note, carried here with the class.)
--   metal 0.60   the other 0.40 is scrap: offcuts rather than filings
-- With RM alone, the part no module claims is lost, as in vanilla. Set
-- 2026-09-24: measured, conserved, favouring gravel.
--
-- ---- THE AGGREGATE UNIT ----
-- Aggregates (gravel, slag) share one standard size, so a recipe that
-- takes them by ratio can take any of them: the gravel tool's own size,
-- read off its itemdef like the dust unit (600, one bar's volume, since
-- 2026-10-07; a quarter boulder, 2500, before), else 600 when no module
-- has asked for gravel this world. A module stream asks for it with
-- unit = 'AGGREGATE' instead of vol.
--
-- ---- CONSISTENCY ----
-- RM's dust is the same with or without modules. Per class, core
-- streams are paid from the whole loss first. Module streams share
-- what is left, 1 minus core's fraction: if theirs add up to more, all
-- of them in that class are scaled down together and it is logged
-- once. Core is never reduced. A module stream naming a form core
-- already pays for that class is refused, logged, and the rest of the
-- module's streams run.
--
-- ---- REGISTERING, from a module's start() ----
--   local api = _G.refinish_byproducts_api
--   api.register(owner, {
--       classes = { STONE = { mode = 'VOLUME', recovery = 0.60, cap = 12,
--                   streams = { { form = 'MAKING_FUEL_GRAVEL',
--                                 share = 0.65, vol = 750 } } }, ... },
--       value   = function(volume, class, density) ... end, -- VALUE mode
--       is_fuel = function(item) ... end,  -- this module's fuel items,
--   })                                     -- kept out of the input
--   api.unregister(owner)
--   api.credit(mode, form, building_id, amount)   -- move a balance in
--   api.switches()   -- RM config's two rows as this file reads them,
--                    -- { all, dust, rate } (THE SWITCH, THE RATE), for a
--                    -- module that pays byproducts of its own
-- A stream's `mat` (a material token) fixes its material; without it
-- the item is made in the feedstock's material. Registering again
-- under the same owner replaces the old registration.
--
-- ---- THE SWITCH ----
-- RM config's Byproducts row: ON, NO DUST or OFF (THE SWITCH, below the
-- constants). Grinders and crushers are orders, not byproducts: they
-- make dust whatever it says.
--
-- ---- LIFECYCLE ----
-- refinish_steel loads this file at its own load (so the handle exists
-- before any module starts), starts it beside the dispatcher and stops
-- it at map unload, which drops every module registration. Balances
-- live in refinish-persist-banks, bank REFINISH_BYPRODUCTS, saved with the fort.
-- ==========================================

local eventful = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local EVENT_KEY   = 'refinish_byproducts'
local MEMO_KEY    = 'refinish-job-byproducts-memo'
local MEMO_EVERY  = 100
local CORE_OWNER  = 'REFINISH_CORE'
local CORE_FORM   = 'REFINISH_CORE_DUST'
-- Units one stream may pay a job at once: a runaway guard and nothing
-- more (THE CAP IS A SAFETY VALVE, NOT A GOVERNOR, in pay). Payouts are
-- one stack, so the item count no longer matters, and at a dust of 200
-- an ordinary block job pays about 15 (about 30 at 100). It was 12 at
-- the old units.
local CORE_CAP    = 1000

-- The knob. See CORE DUST above.
local CORE_DUST = { STONE = 0.40, GEM = 1.00, METAL = 0.60 }

-- The catalog's gravel, paid by RM itself whenever a module has asked
-- for the GRAVEL form, in the standard aggregate unit. With RM's 0.40
-- dust it conserves the whole stone loss; without the request it is not
-- paid and RM's dust is unchanged either way.
local CORE_GRAVEL = { STONE = 0.60 }
local GRAVEL_FORM = 'REFINISH_GRAVEL_TOOL'

-- The catalog's slag, paid by RM itself whenever a module has asked for
-- the HEAP form (2026-10-07; Making Fuel paid it before): all of an ore
-- smelt's loss, as heaps of RM's slag in the standard aggregate unit.
-- Without the request it is not paid.
local HEAP_FORM   = 'REFINISH_HEAP_TOOL'
local SLAG_MAT    = 'INORGANIC:REFINISH_HEAP_SLAG'

-- ---- THE SWITCH ----
-- RM config's Byproducts row (refinish-panel-config.lua), per fort:
--   ON       every stream pays, RM's and every module's.
--   NO_DUST  no stream pays dust, whoever declared it; every other stream
--            pays as usual.
--   OFF      no stream pays at all.
-- RM core pays one byproduct of its own, dust, so one row covers it.
-- Read at every job, so a change applies to the next job with no data
-- cycle. A share switched off is NOT handed to another stream: module
-- streams still share 1 minus core's whole fraction, dust's included,
-- so they pay exactly what they pay with dust on, and dust keeps its
-- claim on the loss whether or not it is collected. Balances already
-- banked stay banked and pay once the stream is on again.
-- No stored value, or one this file does not know, reads as ON.
-- (Replaced two settings, Byproducts and Byproduct Dust, on 2026-10-03;
-- a stored refinish_config_dust is no longer read.)
local SWITCH_KEY = 'refinish_config_byproducts'

-- ---- THE RATE ----
-- One multiplier on everything a job pays, every stream alike, set by
-- the Byproduct Rate row (added 2026-10-07 so players can turn output
-- down while the recovery rates are still being tuned). It scales the
-- amount each stream is paid, not the fractions: core still takes its
-- fraction of the loss and modules share what is left, exactly as at
-- 100, so the split between streams never changes with the rate. What
-- is too small for a whole item still banks, so a low rate slows output
-- rather than stopping it. Stored as the percentage, a string; no value,
-- or one this file does not know, reads as 100. Balances moved in
-- through credit() were earned before and are never scaled.
local RATE_KEY = 'refinish_config_byproduct_rate'
local RATES = { ['100'] = 1.0, ['75'] = 0.75, ['50'] = 0.5, ['25'] = 0.25, ['10'] = 0.1 }

local function switches()
    local v, r = nil, nil
    pcall(function() v = dfhack.persistent.getSiteData(SWITCH_KEY) end)
    pcall(function() r = dfhack.persistent.getSiteData(RATE_KEY) end)
    return { all = v ~= 'OFF', dust = v ~= 'OFF' and v ~= 'NO_DUST',
             rate = RATES[r] or 1.0 }
end

-- ==========================================
-- LOG FUNNEL
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'BYPRODUCTS'
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

local said = {}
local function log_once(key, typ, msg, subject)
    if said[key] then return end
    said[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- COVERAGE
-- ==========================================
-- A job type name DF does not have simply adds nothing: no version of
-- this list needs a patch for a DF that renames or drops a job.
--
-- In the hijacker these carpentry rows read 'SAWDUST', and a row's value
-- was an override only when it named a real LOSS_STREAMS class. Every
-- 'SAWDUST' row fell through to the feedstock classifier, which is what
-- 'AUTO' says outright here: the forty one carpentry rows behave exactly
-- as they always did.
local COVERAGE = {}
for _, name in ipairs({
    'ConstructDoor', 'ConstructFloodgate', 'ConstructBed',
    'ConstructThrone', 'ConstructCoffin', 'ConstructTable',
    'ConstructChest', 'ConstructBin', 'ConstructArmorStand',
    'ConstructWeaponRack', 'ConstructCabinet', 'ConstructBlocks',
    'ConstructHatchCover', 'ConstructGrate', 'ConstructSplint',
    'ConstructCrutch', 'ConstructCatapultParts', 'ConstructBallistaParts',
    'ConstructBoltThrowerParts', 'MakeBarrel', 'MakeBucket',
    'MakeCage', 'MakeAnimalTrap', 'MakeGoblet',
    'MakeToy', 'MakeTool', 'MakeWindow',
    'ConstructStatue', 'ConstructTractionBench', 'ConstructMechanisms',
    'MakeChain', 'MakeFlask', 'MakeTotem',
    'MakeBackpack', 'MakeQuiver', 'MakeTrapComponent',
    'MakeCrafts', 'MakeWeapon', 'MakeAmmo',
    'MakeShield', 'MakePipeSection',
    'ConstructQuern', 'ConstructMillstone', 'ConstructSlab',
    'ConstructBag', 'MakeArmor', 'MakeHelm',
    'MakePants', 'MakeGloves', 'MakeShoes',
    'MakeBallistaArrowHead', 'ForgeAnvil', 'MintCoins',
    'MakeFigurine', 'MakeAmulet', 'MakeScepter',
    'MakeCrown', 'MakeRing', 'MakeEarring',
    'MakeBracelet', 'CutGems', 'CutGlass',
    'MakeGem', 'WeaveCloth', 'SpinThread',
}) do
    local jt = df.job_type[name]
    if jt then COVERAGE[jt] = 'AUTO' end
end
-- Building construction is not covered (2026-10-05). ConstructBuilding
-- places a building, a workshop or a wall, from its materials, which go
-- into it whole: DF keeps them as the building's own items and gives
-- them back when it is taken down. Nothing is cut away, so nothing is
-- owed; counted as a job it paid dust and scrap off materials that were
-- still standing. The furniture and block jobs above make new items
-- from their stock and stay covered.
--
-- Melting is not covered (2026-10-04). A melt turns metal back into
-- metal: it makes no dust and no scrap. And DF keeps what a melt returns
-- under a whole bar in the smelter's store, not as an item, so a loss
-- counted from a melt's items was mostly metal DF had kept: a bar melts
-- to half a bar, and dust and scrap were paid on all of it. What a melt
-- returns is measured in refinish-melt.lua, against what forging paid
-- here: an item holds the smaller of its cost and its volume.
for name, cls in pairs({
    SmeltOre = 'ORE',
    ExtractMetalStrands = 'METAL',
}) do
    local jt = df.job_type[name]
    if jt then COVERAGE[jt] = cls end
end

-- ==========================================
-- CLASSIFICATION
-- ==========================================
local FEEDSTOCK_ORDER = {
    df.item_type.WOOD, df.item_type.BOULDER, df.item_type.BAR,
    df.item_type.SKIN_TANNED, df.item_type.CLOTH, df.item_type.THREAD,
    df.item_type.ROUGH, df.item_type.SMALLGEM, df.item_type.CORPSEPIECE,
}

local FEEDSTOCK_CLASS = {
    [df.item_type.WOOD]        = 'WOOD',
    [df.item_type.BOULDER]     = 'STONE',
    [df.item_type.BAR]         = 'METAL',
    [df.item_type.SKIN_TANNED] = 'LEATHER',
    [df.item_type.CLOTH]       = 'CLOTH',
    [df.item_type.THREAD]      = 'CLOTH',
    [df.item_type.ROUGH]       = 'GEM',
    [df.item_type.SMALLGEM]    = 'GEM',
    [df.item_type.CORPSEPIECE] = 'BONE',
}

-- A corpsepiece is as likely a hide as a bone; its material token's
-- last word says which. Meat and fat owe nothing and read nil.
local CORPSE_CLASS = {
    BONE = 'BONE', SHELL = 'BONE', HORN = 'BONE', HOOF = 'BONE',
    TOOTH = 'BONE', IVORY = 'BONE', PEARL = 'BONE', CHITIN = 'BONE',
    CARTILAGE = 'BONE',
    SKIN = 'LEATHER', SCALE = 'LEATHER', LEATHER = 'LEATHER',
    HAIR = 'CLOTH', WOOL = 'CLOTH', SILK = 'CLOTH', FEATHER = 'CLOTH',
}

local function token_of(mt, mi)
    local tok = nil
    pcall(function()
        local m = dfhack.matinfo.decode(mt, mi)
        tok = m and m:getToken() or nil
    end)
    return tok and tostring(tok) or nil
end

-- DECLARED BELOW THE TABLES IT READS, ON PURPOSE. In the hijacker this
-- function once sat above WASTE; WASTE then resolved as a nil GLOBAL
-- rather than the local a few lines down, the function silently never
-- found an override, and luac -p reported nothing wrong, because a
-- forward reference to a local is legal Lua. Keep every table classify
-- reads above it.
local function classify(memo, override)
    if override and override ~= 'AUTO' then return override end
    local cls = FEEDSTOCK_CLASS[memo.itype]
    if cls == 'GEM' then
        local tok = token_of(memo.type, memo.index)
        if tok and tok:find('GLASS', 1, true) then cls = 'GLASS' end
    elseif memo.itype == df.item_type.CORPSEPIECE then
        local tok = token_of(memo.type, memo.index)
        local tail = tok and tok:match('([^:]+)$')
        cls = tail and CORPSE_CLASS[tail:upper()] or nil
    end
    return cls
end

-- ==========================================
-- REGISTRATIONS
-- ==========================================
-- owner -> { classes, value, is_fuel }. On _G so a reload of this file
-- keeps them. Core is registered by start().
_G.refinish_byproducts_regs = _G.refinish_byproducts_regs or {}
local REGS = _G.refinish_byproducts_regs

function unregister(owner)
    REGS[owner] = nil
end

function register(owner, spec)
    if type(owner) ~= 'string' or owner == '' then return false, 'no owner' end
    if type(spec) ~= 'table' or type(spec.classes) ~= 'table' then
        return false, 'no classes'
    end
    local core = REGS[CORE_OWNER]
    local clean = {}
    for cls, c in pairs(spec.classes) do
        local streams = {}
        for _, st in ipairs(c.streams or {}) do
            -- EXCLUSIVE: a form core already pays in this class.
            local taken = false
            if owner ~= CORE_OWNER and core and core.classes[cls] then
                for _, cst in ipairs(core.classes[cls].streams) do
                    if cst.form == st.form then taken = true end
                end
            end
            if taken then
                log('WARNING', ('%s declared %s for %s, which RM already pays;'
                    .. ' that stream is refused and the rest run.'):format(
                    owner, tostring(st.form), cls), 'REGISTER')
            elseif type(st.form) == 'string' and (st.share or 0) > 0 then
                streams[#streams + 1] = st
            end
        end
        if #streams > 0 then
            clean[cls] = { mode = c.mode or 'VOLUME', recovery = c.recovery or 0,
                           cap = c.cap, streams = streams }
        end
    end
    REGS[owner] = { classes = clean, value = spec.value, is_fuel = spec.is_fuel }
    log('DETAIL', ('%s registered its streams.'):format(owner), 'REGISTER')
    return true
end

-- ==========================================
-- BANKS
-- ==========================================
local bank = nil   -- this fort's balances, opened on first need

-- Opened on first need, not only by start(): a module moves old
-- balances in from its own start(), which runs in the pipeline before
-- this file's start().
local function ensure_bank()
    if bank then return bank end
    local ok_b, banks = pcall(reqscript, 'refinish-persist-banks')
    if ok_b and banks and banks.open then
        bank = banks.open('REFINISH_BYPRODUCTS')
    else
        bank = {}
        log('WARNING', 'refinish-persist-banks did not load; byproduct balances are'
            .. ' session scoped.', 'BANK')
    end
    return bank
end

-- ---- TWO WAYS TO PRICE A LOSS, AND THEY MUST NOT MIX ----
-- VALUE runs the loss through the owner's valuation (Making Fuel's fuel
-- curve, so a dense hardwood pays more than a softwood) and the bank
-- holds that value: right only for things that burn. VOLUME counts raw
-- volume and the bank holds volume: right for everything recovered as
-- mass. Pricing a rock on a fuel curve would mint free fuel out of a
-- boulder.
--
-- SEPARATE BANK TAGS, and that is the load bearing part. The hijacker's
-- old BANK_WASTE keys held volume, and when the code moved to value the
-- two meanings shared a key and a volume balance paid out as fuel. BP is
-- value, BV is volume, and a key written under one meaning can never be
-- read under the other.
--
-- KEYED ON THE FORM, not the class, for a module's streams: a stone
-- scrap remainder and a leather scrap remainder share one purse, which
-- matches how the wood banks always worked (banks hold worth; only
-- minted items carry a species). RM's own dust is the exception and is
-- keyed per class too, because each class's dust has its own unit.
-- Per building either way, so two workshops never race one purse.
local function bank_key(mode, form, cls, bid)
    local tag = (mode == 'VALUE') and 'BP' or 'BV'
    if cls then return ('%s:%s:%s@%d'):format(tag, form, cls, bid) end
    return ('%s:%s@%d'):format(tag, form, bid)
end

function credit(mode, form, bid, amount)
    if type(amount) ~= 'number' then return false end
    ensure_bank()
    local k = bank_key(mode, form, nil, bid)
    bank[k] = (bank[k] or 0) + amount
    return true
end

-- ==========================================
-- FUEL IS NOT FEEDSTOCK
-- ==========================================
-- Vanilla's own fuel, charcoal and coke, by token; and whatever each
-- registered module says its fuel items are.
local function is_fuel(item)
    local fuel = false
    pcall(function()
        if item:getType() == df.item_type.BAR then
            local tok = token_of(item:getMaterial(), item:getMaterialIndex())
            fuel = (tok == 'COAL:CHARCOAL' or tok == 'COAL:COKE')
        end
    end)
    if fuel then return true end
    for _, r in pairs(REGS) do
        if r.is_fuel then
            local ok, yes = pcall(r.is_fuel, item)
            if ok and yes then return true end
        end
    end
    return false
end

-- ==========================================
-- THE MEMO
-- ==========================================
-- job id -> memo. absent[id] counts memo ticks a job has been missing
-- from the list; a memo is dropped only after two, so a completion
-- event always has its memo, whichever of the two runs first. A memo is
-- retaken while the job gathers its items (THE MEMO FOLLOWS THE JOB, in
-- on_memo_tick), and n is how many it held when taken.
local memos, absent, nofeed = {}, {}, {}

local function take_memo(job)
    local total_in, have, first = 0, {}, {}
    for _, iref in ipairs(job.items) do
        local it = iref.item
        if it and not is_fuel(it) then
            local ok, v = pcall(function() return it:getVolume() end)
            if ok and v and v > 0 then total_in = total_in + v end
            local ok2, t = pcall(function() return it:getType() end)
            if ok2 and t then
                have[t] = true
                first[t] = first[t] or it
            end
        end
    end
    local want = nil
    for _, t in ipairs(FEEDSTOCK_ORDER) do
        if have[t] then want = t break end
    end
    if not want then
        -- Nothing classifiable attached yet, or never will be. Named
        -- once after five polls while the job works.
        local working = false
        pcall(function() working = job.flags.working end)
        if working then
            local n = (nofeed[job.id] or 0) + 1
            nofeed[job.id] = n
            if n == 5 then
                log('DETAIL', ('job %d (%s) has worked five polls with no'
                    .. ' feedstock this file recognises; nothing is owed.'):format(
                    job.id, tostring(df.job_type[job.job_type])), 'FEEDSTOCK')
            end
        end
        return nil
    end
    local it = first[want]
    local mt, mi = nil, nil
    pcall(function() mt, mi = it:getMaterial(), it:getMaterialIndex() end)
    if mt == nil then return nil end
    local vol = nil
    pcall(function() vol = it:getVolume() end)
    local desc = '?'
    pcall(function() desc = dfhack.items.getDescription(it, 0) end)
    -- mark: DF's next item number now, moved on at every poll by
    -- on_memo_tick (WHERE THE OUTPUT STARTS). A snapshot of the
    -- workshop's contents stood here until 2026-10-09.
    return { type = mt, index = mi, itype = want, vol = vol,
             mark = df.global.item_next_id,
             total_in = total_in, desc = desc }
end

-- The dispatcher hands every covered job in the list.
local function on_memo_tick(jobs)
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end
    -- Byproducts OFF (THE SWITCH): no memo is taken or kept, so nothing
    -- is measured while it is off. A job already running when it comes
    -- back on has no memo and pays nothing, the same as one that attached
    -- and finished between two memo polls.
    if not switches().all then
        memos, absent, nofeed = {}, {}, {}
        return
    end
    local live = {}
    for _, job in ipairs(jobs) do
        local id = job.id
        live[id] = true
        absent[id] = nil
        -- ---- THE MEMO FOLLOWS THE JOB ----
        -- Taken again whenever the job holds a different number of items,
        -- and the last one before completion is the one paid on. A job
        -- needing several stacks has them brought one at a time, and a memo
        -- taken once, at the first, measured only what was there then:
        -- MEASURED 2026-10-04, a gold table (three bars) logged "gold bars
        -- went in at 600". A retake that finds nothing it recognises keeps
        -- the memo it had.
        local n = #job.items
        local had = memos[id]
        if n > 0 and (not had or had.n ~= n) then
            local ok, m = pcall(take_memo, job)
            if ok and m then
                m.n = n
                memos[id] = m
                nofeed[id] = nil
            end
        end
        -- ---- WHERE THE OUTPUT STARTS ----
        -- A workshop runs one job at a time, and DF numbers every new item
        -- from item_next_id upward, so the number read here, at every
        -- poll, draws the line between what the workshop already held and
        -- what this job makes: its output is what the workshop holds at
        -- completion numbered at or above the last poll's mark. The same
        -- line making-fuel-binder-watcher.lua (WHERE THIS JOB'S OUTPUT
        -- STARTS) and refinish-reaction-outputs.lua draw.
        -- A completion is always reported before a poll can move the mark
        -- past its unit: DFHack's events run before every Lua loop in an
        -- update, and RM's job units service reports a work order's unit
        -- on the dispatcher's every frame tier, ahead of this one
        -- (refinish-job-units.lua, FIRST IN THE TICK). And it moves only
        -- while the job holds its items: a unit's products appear on the
        -- tick the job lets go of them, so a poll that lands between a
        -- unit and its report (possible when either runs on its own loop
        -- instead of the dispatcher) leaves the mark where the unit started.
        -- Until 2026-10-09 the line was a snapshot of the workshop's
        -- contents, taken with the memo. The memo is first taken when the
        -- job claims its item, before the item arrives (THE MEMO FOLLOWS
        -- THE JOB), so whatever entered the workshop at any point in the
        -- job counted as its output. MEASURED 2026-10-09: a bin, which
        -- reads 3000 (39 bins from highwood logs each lost 2000, the first
        -- one too, and a log is 5000), came out at 6000, and a mechanism,
        -- which reads 2000, at 18000, so neither paid anything. The bin came
        -- from a work order, whose units DFHack reports once per order
        -- (refinish-job-units.lua), so one memo stood for several units;
        -- and the snapshot also counted whatever was carried in while a job
        -- ran. The line names what it counts now (AT COMPLETION).
        local cur = memos[id]
        if cur and n > 0 then cur.mark = df.global.item_next_id end
    end
    for id in pairs(memos) do
        if not live[id] then
            absent[id] = (absent[id] or 0) + 1
            if absent[id] >= 2 then memos[id], absent[id], nofeed[id] = nil, nil, nil end
        end
    end
end

-- This file's own loop, for a core without the dispatcher.
local function memo_poll()
    local jobs = {}
    local link = df.global.world.jobs.list.next
    while link do
        local j = link.item
        if j and COVERAGE[j.job_type] then jobs[#jobs + 1] = j end
        link = link.next
    end
    on_memo_tick(jobs)
end

-- ==========================================
-- CORE DUST UNITS
-- ==========================================
-- One dust is the dust tool's size (CORE DUST, header), read off its
-- itemdef and checked against its id on every use, since injection can
-- move a subtype. Looked up here rather than through tool_subtype,
-- which is declared further down: a forward reference to a local reads
-- a nil global (see classify's note).
-- REF and its boulder measurement went 2026-10-07, when the aggregate
-- unit stopped being a quarter boulder (aggregate_unit, below).

local dust_sub = nil
local function dust_unit()
    local size = nil
    pcall(function()
        local defs = df.global.world.raws.itemdefs.tools
        if not (dust_sub and dust_sub < #defs and defs[dust_sub].id == CORE_FORM) then
            dust_sub = nil
            for i, d in ipairs(defs) do
                if d.id == CORE_FORM then dust_sub = i break end
            end
        end
        size = dust_sub and defs[dust_sub].size or nil
    end)
    return (size and size > 0) and size or nil
end

-- THE AGGREGATE UNIT (header): the gravel tool's own size, read off its
-- itemdef and checked against its id on every use, as dust_unit does, so
-- a mod that resizes gravel moves the unit with it. 600 when no gravel is
-- injected this world. Until 2026-10-07 it was a quarter of a measured
-- boulder (2500); memo is no longer read, and stays a parameter so the
-- callers need no change.
local AGGREGATE_FALLBACK = 600
local gravel_sub = nil
local function aggregate_unit(memo)
    local size = nil
    pcall(function()
        local defs = df.global.world.raws.itemdefs.tools
        if not (gravel_sub and gravel_sub < #defs and defs[gravel_sub].id == GRAVEL_FORM) then
            gravel_sub = nil
            for i, d in ipairs(defs) do
                if d.id == GRAVEL_FORM then gravel_sub = i break end
            end
        end
        size = gravel_sub and defs[gravel_sub].size or nil
    end)
    return (size and size > 0) and size or AGGREGATE_FALLBACK
end

-- ==========================================
-- PAYOUT
-- ==========================================
local ours = {}   -- item ids this file made, never counted as output
local subtype_of = {}

local function tool_subtype(id)
    if subtype_of[id] then return subtype_of[id] end
    for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
        if td.id == id then
            subtype_of[id] = td.subtype
            return td.subtype
        end
    end
    return nil
end

-- ---- ONE STACK, NOT n ITEMS ----
-- A payout is one item carrying n in its stack, never n items
-- (2026-10-03). Measured with refinish-stack-probe (RM_Stacked_Tools.md):
-- one reagent slot fills from any number of stacks, a job holds whole
-- stacks, and DF draws exactly the reagent quantity at completion. So a
-- consumer can ask for any quantity, and a payout costs one item however
-- large it is.
-- Makes n of form in mat at bld as one stack; returns how many it made:
-- n, or 1 if the stack could not be set, or 0. Only what was made
-- leaves the bank (pay, below), so a failed spawn loses nothing.
local function make(form, mat, n, bld)
    local sub = tool_subtype(form)
    if not sub then
        log_once('noform:' .. form, 'WARNING', ('no tool %s is injected; its'
            .. ' stream banks and pays nothing.'):format(form), 'PAYOUT')
        return 0
    end
    if n < 1 then return 0 end
    local ok, list = pcall(dfhack.items.createItem,
        df.global.world.units.active[0], df.item_type.TOOL, sub,
        mat.type, mat.index)
    if not ok or type(list) ~= 'table' or not list[1] then return 0 end
    local item = list[1]
    ours[item.id] = true
    local made = 1
    if n > 1 and pcall(function() item.stack_size = n end) then made = n end
    -- createItem hands back a list. A tool comes as one item; anything
    -- more would be units no bank paid for, so it goes, and says so.
    for i = 2, #list do
        log_once('extra:' .. form, 'WARNING', ('createItem made %d items for one'
            .. ' %s; the extras were removed.'):format(#list, form), 'PAYOUT')
        pcall(function() dfhack.items.remove(list[i]) end)
    end
    local placed = false
    pcall(function()
        placed = dfhack.items.moveToBuilding(item, bld,
            df.building_item_role_type.TEMP, false)
    end)
    if not placed then
        pcall(function()
            dfhack.items.moveToGround(item,
                { x = bld.centerx, y = bld.centery, z = bld.z })
        end)
    end
    return made
end

-- One stream of one job. `amount` is recovered loss in the stream's own
-- measure (volume or value); unit is how much of it makes one item.
local function pay(st, mode, cls_key, amount, unit, cap, memo, bld, report)
    if not unit or unit <= 0 then return end
    local k = bank_key(mode, st.form, cls_key, bld.id)
    local projected = (bank[k] or 0) + amount
    local n = math.floor(projected / unit)
    -- ---- THE CAP IS A SAFETY VALVE, NOT A GOVERNOR ----
    -- A cap below the true output does not reduce the output, it STRANDS
    -- it: the excess stays banked, the next job adds more than the cap
    -- can pay, and the purse grows forever while the declared recovery
    -- rate quietly becomes a lie. Measured on stone at the first sizing:
    -- one block job wanted 19 gravel against a cap of 4. So the real
    -- output sets the number and the cap only catches a runaway, and
    -- when it does bite it SAYS SO, once per class and form, because
    -- value disappearing into a bank with nothing in the log is the kind
    -- of silence that costs a week to find.
    if cap and n > cap then
        log_once('cap:' .. tostring(cls_key or '') .. ':' .. st.form, 'INFO',
            ('CAP: %s %s wanted %d item(s) and the cap is %d. The rest stays'
            .. ' banked and the bank will keep growing until the cap is'
            .. ' raised or the recovery lowered.'):format(tostring(cls_key or '-'),
            st.form, n, cap), 'CAP')
        n = cap
    end
    local made = 0
    if n >= 1 then
        -- ---- FORM VERSUS SUBSTANCE ----
        -- No mat on the stream and the byproduct INHERITS the feedstock,
        -- so a feather wood door gives feather wood bark and a
        -- microcline block gives microcline dust. A stream that names a
        -- mat is a substance the input was not: scale is iron oxide
        -- rather than iron, slag is the gangue rather than the ore, so
        -- neither can inherit and both say what they are.
        local mat = nil
        if st.mat then
            mat = dfhack.matinfo.find(st.mat)
        else
            pcall(function() mat = dfhack.matinfo.decode(memo.type, memo.index) end)
        end
        if mat then made = make(st.form, mat, n, bld) end
    end
    -- Only what was made leaves the bank, so a failed spawn loses nothing.
    bank[k] = projected - made * unit
    -- The unit beside it, for the bank readout (THE READOUT): a balance
    -- reads as a share of one item only beside the unit that makes one.
    -- Saved like the balance, and written only when it changes. A VALUE
    -- stream's unit is the last item's worth, so its share is close
    -- rather than exact when the next feedstock prices differently.
    if bank['U:' .. k] ~= unit then bank['U:' .. k] = unit end
    report[#report + 1] = ('%s %d (%.2f/%.2f)'):format(st.form, made, bank[k], unit)
end

-- ==========================================
-- THE JOB'S OWN PRODUCT (2026-11-05)
-- ==========================================
-- Only items of the type a job makes count as its output. DF's own job
-- definitions name it: df.job_type.attrs[<job type>].item (a bin job
-- makes BIN, a block job BLOCKS), or a possible_item list where the
-- product varies (Make Crafts: figurine, amulet, ring, earring, crown,
-- bracelet, scepter). Read from DFHack's data, so a DF update that
-- changes a job's product is followed with no edit here.
--
-- WHY. Another mod's byproduct service can pay into the same workshop
-- on the same completion. SEEN 2026-11-05: Advanced Agriculture's
-- byproduct-system.lua makes a glob of 5 bark, in the log's
-- BYPRODUCT_MAT, in the carpenter whenever DFHack reports a carpentry
-- job done. Handlers for one event run in no fixed order, so whenever
-- theirs ran first, the glob sat in the workshop numbered past the mark
-- and was read as part of the job's output: the job measured smaller
-- than it was and every stream here paid less, a foreign byproduct
-- quietly taking the place of ours. Two services paying on one job each
-- pay their own; neither one is the job. A player who wants only one of
-- them switches the other off.
--
-- CHECKED against the df-structures commit DFHack 53.16-r3 builds from
-- (d8ff8a6, df.job.xml): every job in COVERAGE declares its product
-- except SpinThread, which declares none and so keeps counting every new
-- item in its workshop, as before (said once a session).
--
-- A KNOWN LIMIT: an item another service makes of the job's own product
-- type (a tool paid into a Make Tool job, say) still counts, since
-- nothing on the item tells it apart from DF's product.
--
-- [job type] = { set = { [item type] = true }, label = 'BIN' }, or false
-- for a job that declares no product. Kept for the session: DF's job
-- definitions do not change while it runs.
local product_cache = {}
local function product_types(jt)
    local c = product_cache[jt]
    if c ~= nil then return c or nil end
    local set, names = {}, {}
    pcall(function()
        local a = df.job_type.attrs[jt]
        local t = a.item
        if type(t) == 'number' and t >= 0 then
            set[t] = true
            names[#names + 1] = tostring(df.item_type[t])
        end
        -- possible_item is a read-only list (DFHack's enum_list_attr):
        -- its length by #, its entries numbered from 0.
        local pi = a.possible_item
        for i = 0, #pi - 1 do
            local p = pi[i]
            if type(p) == 'number' and p >= 0 and not set[p] then
                set[p] = true
                names[#names + 1] = tostring(df.item_type[p])
            end
        end
    end)
    c = (#names > 0) and { set = set, label = table.concat(names, '/') } or false
    product_cache[jt] = c
    return c or nil
end

-- ==========================================
-- AT COMPLETION
-- ==========================================
-- ---- NO SILENT RETURNS ----
-- The hijacker's waste path learned this three times. A return that
-- says nothing makes a correct silence and a total failure look
-- identical: once is_fuel started excluding every item on every
-- hardcoded job, no memo was ever written, all forty one carpentry types
-- stopped producing, and the log stayed perfectly clean. So every
-- return below that means "nothing owed" says why, and the wording
-- separates a legitimate case from a fault: once per job type or class
-- where the reason is the same every time, and every job where the
-- numbers are the job's own (THE LAST SILENT RETURN), since a job's own
-- numbers are what show a fault.
local function on_completed(job)
    if not _G.refinish_active or not bank then return end
    -- Not a job this service covers: nothing to say.
    if not COVERAGE[job.job_type] then return end
    -- THE SWITCH, read once a job. OFF: nothing is owed, said once a
    -- session; the change itself is logged by the config panel.
    local sw = switches()
    if not sw.all then
        memos[job.id], absent[job.id], nofeed[job.id] = nil, nil, nil
        log_once('switch:off', 'DETAIL', 'Byproducts are OFF in RM config: no job pays'
            .. ' any byproduct until they are on again.', 'SWITCH')
        return
    end
    local memo = memos[job.id]
    if not memo then
        log_once('nomemo:' .. tostring(job.job_type), 'DETAIL', ('%s completed with'
            .. ' no memo, so nothing is owed. Either the memo found no feedstock'
            .. ' it recognises in the job (expected on a material with no class;'
            .. ' NOT expected on wood, stone, bar, leather, cloth, gem or bone),'
            .. ' or the job attached and finished between two memo polls.'):format(
            tostring(df.job_type[job.job_type])), 'WASTE')
        return
    end
    memos[job.id], absent[job.id], nofeed[job.id] = nil, nil, nil

    local ok, err = pcall(function()
        local bld = dfhack.job.getHolder(job)
        if not bld then return end
        -- What the job made: the items in the workshop numbered at or
        -- above the mark (WHERE THE OUTPUT STARTS), less this file's own,
        -- and only of the item type the job makes (THE JOB'S OWN PRODUCT).
        -- Each kind is named with its count and volume, so the line shows
        -- exactly what was counted as output, and anything new left out
        -- is named on a line of its own.
        local makes = product_types(job.job_type)
        if not makes then
            log_once('noproduct:' .. tostring(job.job_type), 'DETAIL', ('%s declares no product'
                .. ' in DF\'s job definitions, so every new item in its workshop counts as its'
                .. ' output.'):format(tostring(df.job_type[job.job_type])), 'WASTE')
        end
        local out_vol, kinds, order = 0, {}, {}
        local skipped = {}      -- new items of another type, by description
        for _, ci in ipairs(bld.contained_items) do
            local it = ci.item
            local mine = it and it.id >= memo.mark and not ours[it.id]
            if mine and makes then
                local okt, t = pcall(function() return it:getType() end)
                if not (okt and makes.set[t]) then
                    local d = '?'
                    pcall(function() d = dfhack.items.getDescription(it, 0) end)
                    skipped[#skipped + 1] = d
                    mine = false
                end
            end
            if mine then
                local v = it:getVolume()
                if v and v > 0 then
                    out_vol = out_vol + v
                    local d = '?'
                    pcall(function() d = dfhack.items.getDescription(it, 0) end)
                    local k = kinds[d]
                    if not k then
                        k = { n = 0, vol = 0 }
                        kinds[d] = k
                        order[#order + 1] = d
                    end
                    k.n, k.vol = k.n + 1, k.vol + v
                end
            end
        end
        local parts = {}
        for _, d in ipairs(order) do
            local k = kinds[d]
            parts[#parts + 1] = (k.n > 1) and ('%s x%d %d'):format(d, k.n, k.vol)
                                or ('%s %d'):format(d, k.vol)
        end
        local out_desc = (#parts > 0) and table.concat(parts, ', ') or 'nothing'
        -- THE JOB'S OWN PRODUCT: what was new in the workshop and left out.
        if #skipped > 0 then
            log('DETAIL', ('%s job %d: new in the workshop but not its product (%s), so not'
                .. ' counted as its output: %s.'):format(tostring(df.job_type[job.job_type]),
                job.id, makes.label, table.concat(skipped, ', ')), 'WASTE')
        end
        local lost = memo.total_in - out_vol
        if lost <= 0 then
            -- ---- THE LAST SILENT RETURN, NOW SPOKEN ----
            -- Output at least as big as input destroyed nothing, a real
            -- and common case (a cloth bag is about the size of its
            -- cloth). Silent, it looked exactly like a broken job, and
            -- "no logs at all" on clothing and bags is what it produced.
            -- EVERY JOB, NOT ONCE A JOB TYPE (2026-10-09). Said once, a
            -- second job that measured the same left no line at all, so
            -- two bin completions read as one bin and something else.
            log('DETAIL', ('%s job %d: %s went in at %d and came out at %d'
                .. ' (%s), so nothing was lost and nothing is owed. Correct where'
                .. ' the product is about the size of its stock; suspicious if the'
                .. ' output should obviously be smaller.'):format(
                tostring(df.job_type[job.job_type]), job.id,
                tostring(memo.desc or '?'), memo.total_in, out_vol, out_desc), 'WASTE')
            return
        end
        local cls = classify(memo, COVERAGE[job.job_type])
        if not cls then
            -- No class: the feedstock is something no stream covers,
            -- usually legitimate (a rock door owes no sawdust). Said
            -- once, so a fort full of rock doors says it once.
            log_once('noclass:' .. tostring(job.job_type), 'DETAIL', ('no loss class'
                .. ' for %s: feedstock item type %s. Nothing owed.'):format(
                tostring(df.job_type[job.job_type]),
                tostring(df.item_type[memo.itype])), 'WASTE')
            return
        end
        -- A class nobody pays for: RM alone pays stone, gem and metal;
        -- the rest wait on a module that declares them.
        local anyone = false
        for _, r in pairs(REGS) do
            if r.classes[cls] then anyone = true break end
        end
        if not anyone then
            log_once('nostream:' .. cls, 'DETAIL', ('%s loss measured, but no'
                .. ' stream is declared for %s, so nothing is owed. RM alone pays'
                .. ' stone, gem and metal; the rest come from a module that'
                .. ' declares them.'):format(cls, cls), 'WASTE')
            return
        end
        local dens = nil
        pcall(function()
            dens = dfhack.matinfo.decode(memo.type, memo.index).material.solid_density
        end)

        local report = {}
        -- Core first, from the whole loss.
        local core = REGS[CORE_OWNER]
        local core_frac = 0
        local cc = core and core.classes[cls]
        if cc then
            for _, st in ipairs(cc.streams) do
                local frac = cc.recovery * st.share
                core_frac = core_frac + frac
                local unit = (st.unit == 'AGGREGATE') and aggregate_unit(memo)
                             or dust_unit()
                if st.form == CORE_FORM and not sw.dust then
                    -- NO DUST (THE SWITCH): dust's fraction stays in
                    -- core_frac above and is simply not recovered.
                    log_once('switch:nodust', 'DETAIL', 'Byproducts are NO DUST in RM'
                        .. ' config: dust shares go unrecovered, and every other'
                        .. ' byproduct pays as usual.', 'SWITCH')
                else
                    pay(st, 'VOLUME', cls, lost * frac * sw.rate, unit, cc.cap, memo, bld, report)
                end
            end
        end
        -- Modules share what is left.
        local total = 0
        for owner, r in pairs(REGS) do
            if owner ~= CORE_OWNER and r.classes[cls] then
                local c = r.classes[cls]
                for _, st in ipairs(c.streams) do total = total + c.recovery * st.share end
            end
        end
        local room = math.max(0, 1 - core_frac)
        local scale = 1
        if total > room and total > 0 then
            scale = room / total
            log_once('scale:' .. cls, 'INFO', ('%s: module streams ask for %.2f'
                .. ' of the loss and %.2f is left after RM; every module stream'
                .. ' in the class is scaled to fit.'):format(cls, total, room), 'CONSISTENCY')
        end
        local owners = {}
        for owner in pairs(REGS) do
            if owner ~= CORE_OWNER then owners[#owners + 1] = owner end
        end
        table.sort(owners)
        for _, owner in ipairs(owners) do
            local r = REGS[owner]
            local c = r.classes[cls]
            if c then
                for _, st in ipairs(c.streams) do
                    local frac = c.recovery * st.share * scale
                    if st.form == CORE_FORM and not sw.dust then
                        -- NO DUST covers a module's stream paid in RM's dust
                        -- tool as well (THE SWITCH).
                        log_once('switch:nodust', 'DETAIL', 'Byproducts are NO DUST in RM'
                            .. ' config: dust shares go unrecovered, and every other'
                            .. ' byproduct pays as usual.', 'SWITCH')
                    elseif c.mode == 'VALUE' then
                        if r.value then
                            local okv, v_lost = pcall(r.value, lost, cls, dens)
                            local oku, unit = pcall(r.value, st.vol, cls, dens)
                            -- A stream may name its unit outright, as a value in
                            -- the module's own currency, when one piece must be
                            -- worth the same whatever it came from. value(st.vol)
                            -- scales with the input's density and cancels it out
                            -- of the count; a fixed unit keeps it in, so a dense
                            -- input pays more pieces and a light one fewer.
                            if type(st.unit) == 'number' and st.unit > 0 then
                                oku, unit = true, st.unit
                            end
                            if okv and oku then
                                pay(st, 'VALUE', nil, v_lost * frac * sw.rate, unit, c.cap, memo, bld, report)
                            end
                        end
                    else
                        local unit = (st.unit == 'AGGREGATE') and aggregate_unit(memo) or st.vol
                        pay(st, 'VOLUME', nil, lost * frac * sw.rate, unit, c.cap, memo, bld, report)
                    end
                end
            end
        end
        if #report > 0 then
            -- The rate rides on the line whenever it is below 100, so a
            -- small payout in the log never reads as a fault.
            local rate_note = (sw.rate < 1)
                and (' | rate %d%%'):format(math.floor(sw.rate * 100 + 0.5)) or ''
            log('DETAIL', ('%s job %d: %s %d in, %s out -> %d lost, class %s | %s%s'):format(
                tostring(df.job_type[job.job_type]), job.id, tostring(memo.desc),
                memo.total_in, out_desc, lost, cls, table.concat(report, ' | '), rate_note), 'WASTE')
        end
    end)
    if not ok then log('ERROR', 'COMPLETION ERROR: ' .. tostring(err), 'HOOK') end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- Core's own streams: dust for stone, gem and metal. Registered at load
-- as well as at start, so a module registering during the pipeline is
-- already checked against them (see EXCLUSIVE in register).
--
-- Gravel joins when the catalog carries it this world: the gravel form
-- is its own registration, kept only when some module asked for it.
-- Slag joins the same way, as the ORE class, when the catalog carries
-- the heap (2026-10-07).
-- Each stream is expressed as its own fraction of the loss (recovery 1,
-- share = fraction), so dust and gravel keep their own fractions side
-- by side.
local function gravel_active()
    return (_G.refinish_module_registry or {})['REFINISH_GRAVEL_'] ~= nil
end

local function heap_active()
    return (_G.refinish_module_registry or {})['REFINISH_HEAP_'] ~= nil
end

local function register_core()
    local classes = {}
    local gravel = gravel_active()
    for cls, frac in pairs(CORE_DUST) do
        local streams = { { form = CORE_FORM, share = frac } }
        if gravel and CORE_GRAVEL[cls] then
            streams[#streams + 1] = { form = GRAVEL_FORM, share = CORE_GRAVEL[cls],
                                      unit = 'AGGREGATE' }
        end
        classes[cls] = { mode = 'VOLUME', recovery = 1, cap = CORE_CAP,
                         streams = streams }
    end
    -- SLAG: the whole of an ore smelt's loss, in the heap, in RM's slag.
    if heap_active() then
        classes.ORE = { mode = 'VOLUME', recovery = 1, cap = CORE_CAP,
                        streams = { { form = HEAP_FORM, share = 1.00,
                                      unit = 'AGGREGATE', mat = SLAG_MAT } } }
    end
    register(CORE_OWNER, { classes = classes })
end

function start()
    said, memos, absent, nofeed, ours, subtype_of = {}, {}, {}, {}, {}, {}
    ensure_bank()
    register_core()

    eventful.onJobCompleted[EVENT_KEY] = on_completed
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    -- ---- AND EVERY UNIT OF A WORK ORDER ----
    -- DFHack reports a work order's job once, at the order's last unit;
    -- RM's job units service reports every unit on the tick it finishes,
    -- to this same handler (refinish-job-units.lua). Without the service,
    -- DFHack's report is the only one, as before.
    -- Order 10, ahead of the default 50: this measures what DF made, so it
    -- reads the workshop before any other subscriber adds to it.
    local units = _G.refinish_job_units_api
    if units and units.subscribe then units.subscribe(EVENT_KEY, on_completed, 10) end
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(MEMO_KEY, {
            every = MEMO_EVERY,
            jobs = function(_, jt) return COVERAGE[jt] ~= nil end,
            fn = on_memo_tick }) then
        repeatUtil.cancel(MEMO_KEY)
    else
        repeatUtil.scheduleEvery(MEMO_KEY, MEMO_EVERY, 'frames', memo_poll)
    end
    log('DETAIL', 'started; RM pays dust for stone, gem and metal.', 'START')
end

function stop()
    eventful.onJobCompleted[EVENT_KEY] = nil
    local units = _G.refinish_job_units_api
    if units and units.unsubscribe then units.unsubscribe(EVENT_KEY) end
    repeatUtil.cancel(MEMO_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(MEMO_KEY) end
    -- Module registrations go with the fort; the next one's modules
    -- register again in their own start(). Core's stay.
    for owner in pairs(REGS) do
        if owner ~= CORE_OWNER then REGS[owner] = nil end
    end
    memos, absent, nofeed, ours = {}, {}, {}, {}
    bank = nil
    log('DETAIL', 'stopped.', 'STOP')
end

-- ==========================================
-- THE READOUT (2026-10-05)
-- ==========================================
-- What this service holds back at the open building, as rows for RM's
-- bank readout (refinish-bank-readout.lua, PROVIDERS): one row per
-- stream this building can bank, zero included (ALWAYS VISIBLE). Keys
-- are BP:<form>@<building> and BV:<form>@<building>, with a class
-- between for RM's own dust and gravel (bank_key, above). A form is a
-- tool id, so a row is named by its tool, and a dust row by its class
-- too: "stone dust", "metal dust", "bone dust", while "scrap", "cullet" and
-- "gravel" stand alone. Dust of several classes shares buildings, and a
-- building's banks share one screen (the mason's output bank holds the
-- crush's dust remainders), so a bare "dust" collides. Decided 2026-10-05,
-- back from bare names the same day. A row reads as a share of one item,
-- so it needs the unit that makes one: the unit saved at payout ('U:'
-- beside the balance, in pay) where there is one, and otherwise the unit
-- pay would use, worked out the same way. A VALUE stream's unit is priced
-- by its owner's valuation with no density given until a payout here
-- saves the real one; if the valuation cannot answer, the row reads zero.
--
-- ---- ALWAYS VISIBLE (2026-10-05) ----
-- A building that banks shows its bank always, every row it can bank,
-- zero included: the law Making Fuel's rows follow (THE DISPLAY LAW,
-- making-fuel-bank-readout.lua). Until then a row showed only once its
-- stream had banked there, so a metalsmith's bank sat invisible until its
-- first forging. What a building can bank is the loss classes its jobs
-- take, and DF fixes those per workshop: BUILDING_CLASSES holds the ones
-- that are certain, by DF's own enum names, resolved guarded so a renamed
-- one is a missing row, never a dead file. A class a building takes that
-- is not listed (a craftsdwarf's leather, say) shows once it has paid
-- there since this readout landed, which is when pay began saving the
-- unit beside a balance. A balance with no unit saved shows nowhere: it
-- never paid here since, and old forts hold such balances under buildings
-- their jobs can never fill (building construction paid byproducts until
-- 2026-10-05, COVERAGE). Shown, they put dust and scrap rows on buildings
-- that bank neither (seen in play 2026-10-05). Only
-- classes some registered stream pays make rows, so with RM alone a
-- carpenter shows nothing, which is right: nothing banks there. The
-- switch is honoured: OFF shows no byproduct bank, NO DUST no dust row.
-- [<enum>:<value>] = the loss classes DF's own jobs at that workshop or
-- furnace take, where that is certain (ALWAYS VISIBLE). Keyed by enum and
-- value, because workshop and furnace types are numbered apart.
local BUILDING_CLASSES = {}
local function building_classes(enum, name, classes)
    local v = df[enum] and df[enum][name]
    if v ~= nil then BUILDING_CLASSES[enum .. ':' .. tostring(v)] = classes end
end
building_classes('workshop_type', 'Carpenters',        { 'WOOD' })
building_classes('workshop_type', 'Masons',            { 'STONE' })
building_classes('workshop_type', 'MetalsmithsForge',  { 'METAL' })
building_classes('workshop_type', 'MagmaForge',        { 'METAL' })
building_classes('workshop_type', 'Jewelers',          { 'GEM', 'GLASS' })
building_classes('workshop_type', 'Craftsdwarfs',      { 'STONE', 'WOOD', 'BONE' })
building_classes('workshop_type', 'Bowyers',           { 'WOOD' })
building_classes('workshop_type', 'Mechanics',         { 'STONE' })
building_classes('workshop_type', 'Siege',             { 'WOOD' })
building_classes('workshop_type', 'Leatherworks',      { 'LEATHER' })
building_classes('workshop_type', 'Clothiers',         { 'CLOTH' })
building_classes('workshop_type', 'Loom',              { 'CLOTH' })
building_classes('furnace_type',  'GlassFurnace',      { 'GLASS' })
building_classes('furnace_type',  'MagmaGlassFurnace', { 'GLASS' })
building_classes('furnace_type',  'Smelter',           { 'ORE' })
building_classes('furnace_type',  'MagmaSmelter',      { 'ORE' })

-- The listed classes of the building on the sheet, or an empty list.
local function classes_at(bld)
    local list = nil
    pcall(function()
        local bt = bld:getType()
        if bt == df.building_type.Workshop then
            list = BUILDING_CLASSES['workshop_type:' .. tostring(bld.type)]
        elseif bt == df.building_type.Furnace then
            list = BUILDING_CLASSES['furnace_type:' .. tostring(bld.type)]
        end
    end)
    return list or {}
end

local readout_tools = {}   -- tool id -> { name, size }, once found
local function readout_tool(id)
    local d = readout_tools[id]
    if d then return d end
    pcall(function()
        for _, t in ipairs(df.global.world.raws.itemdefs.tools) do
            if t.id == id then d = { name = t.name, size = t.size }; break end
        end
    end)
    readout_tools[id] = d
    return d
end

local function readout(bld)
    if not (bld and bank) then return nil end
    local sw = switches()
    if not sw.all then return nil end
    local suffix = '@' .. tostring(bld.id)
    -- [bank key] = { form, qual, unit }: every stream the building's
    -- classes can bank first, then any other balance that has paid here
    -- since this readout landed (its unit saved beside it).
    local want = {}
    for _, cls in ipairs(classes_at(bld)) do
        for owner, r in pairs(REGS) do
            local c = r.classes[cls]
            if c then
                local core = (owner == CORE_OWNER)
                local mode = core and 'VOLUME' or c.mode
                for _, st in ipairs(c.streams) do
                    if sw.dust or st.form ~= CORE_FORM then
                        -- The same key pay writes: core's carry the class.
                        local k = bank_key(mode, st.form, core and cls or nil, bld.id)
                        if not want[k] then
                            -- The unit pay would use, where none is saved.
                            local unit = tonumber(bank['U:' .. k])
                            if not unit then
                                if st.unit == 'AGGREGATE' then
                                    unit = aggregate_unit({})
                                elseif core then
                                    unit = dust_unit()
                                elseif mode == 'VALUE' then
                                    local ok, u = pcall(r.value, st.vol, cls, nil)
                                    unit = ok and tonumber(u) or nil
                                else
                                    unit = st.vol
                                end
                            end
                            -- Its class where the form says no more: core's dust,
                            -- and a module's stream paid in RM's dust tool
                            -- (bone dust).
                            local show = (core or st.form == CORE_FORM) and cls or nil
                            want[k] = { form = st.form, qual = show, unit = unit }
                        end
                    end
                end
            end
        end
    end
    pcall(function()
        for k in pairs(bank) do
            if type(k) == 'string' and k:sub(1, 2) ~= 'U:'
                    and k:sub(-#suffix) == suffix and not want[k]
                    and bank['U:' .. k] ~= nil then
                local form, cls = k:match('^B[PV]:([^:@]+):?([^@]*)@%d+$')
                if form and (sw.dust or form ~= CORE_FORM) then
                    want[k] = { form = form, qual = (cls ~= '') and cls or nil,
                                unit = tonumber(bank['U:' .. k]) }
                end
            end
        end
    end)
    -- A dust row carries its class; every other form stands alone.
    local rows = {}
    for k, w in pairs(want) do
        local def = readout_tool(w.form)
        if def then
            local label = def.name
            if w.qual then label = w.qual:lower() .. ' ' .. label end
            local bal = tonumber(bank[k]) or 0
            local unit = tonumber(w.unit)
            local known = unit ~= nil and unit > 0
            rows[#rows + 1] = { key = 'RM_BYPRODUCTS:' .. k, label = label,
                                value = known and bal / unit or 0,
                                full = known and bal >= unit }
        end
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(a, b) return a.label < b.label end)
    return { title = 'byproduct bank', rows = rows }
end
_G.refinish_bank_providers = _G.refinish_bank_providers or {}
_G.refinish_bank_providers.rm_byproducts = { order = 30, fn = readout }

-- ---- THE HANDLE ----
-- Published at load: modules register during the pipeline, before
-- start() runs.
-- switches hands a module RM config's two rows as this file reads them,
-- so a module that pays byproducts of its own follows both without a
-- copy of the keys or the rate table (added 2026-10-12).
_G.refinish_byproducts_api = { register = register, unregister = unregister,
                               credit = credit, switches = switches }
register_core()