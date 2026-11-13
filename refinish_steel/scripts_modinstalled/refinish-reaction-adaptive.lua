--@ module = true
-- refinish-reaction-adaptive.lua
-- ==========================================
-- RM ADAPTIVE REACTION ENGINE
-- ==========================================
-- Swaps a queued adaptive reaction to a per job ghost reaction, then
-- writes that ghost's product counts from the actual value of what
-- walked in. A reaction is adaptive when every product count is zero
-- (and not every probability): the engine fills the counts in.
--
-- One item per job. Fractional value carries between jobs in a bank
-- rather than being collected within one job.
--
-- WHOSE. RM's. This was Making Fuel's making-fuel-ghost.lua, split over
-- eight steps (see THE PROVIDER) so that everything the engine needs to
-- know about a module comes from that module's PROVIDER: what its
-- reactions are, what things are worth, how a banked total is written,
-- its bank, its prefixes and its settings. The engine names nothing of
-- any module's.
--
-- A MODULE USES IT by registering, from its own start():
--   _G.refinish_adaptive_api.register(owner, {
--       valuation = <its valuation module>,   -- the provider interface
--       reactions = <its reaction definitions>,
--   })
-- which starts the engine for it, and unregister(owner) from its stop.
-- register_alias and resweep_orphans are on the same handle.
--
-- EVERY MODULE THAT REGISTERS IS SERVED, all at once. Each keeps its
-- own provider, config, bank and prefixes (PROVIDERS), and every job is
-- handled with its own module's provider: the engine switches to it
-- (use) before touching the job, so no module ever sees another's
-- valuation, bank or liquids. A module is refused only for its own
-- fault (no valuation, or a reaction prefix that collides with one
-- already served), named, and every other module is untouched.
--
-- Every number this file uses comes from the provider (V.setting,
-- V.dial). There are no yield constants here.
-- ==========================================

-- ==========================================
-- ADAPTIVE REACTION FINDINGS
-- ==========================================
-- Established by testing. Every line below was confirmed in game or
-- against the raws, not inferred. Preserve this block.
--
-- A ghost reaction owns everything about a job except which items were
-- already attached when the swap happened.
--
-- PRODUCT COUNTS are writable on a live ghost at any point before the
-- job completes, and completion honours the latest value. The whole
-- design rests on this and it holds.
--
-- MULTI ITEM COLLECTION DOES NOT WORK. THE FILTER VECTOR SURVIVES A
-- REPEAT JOB'S RE-POST. job_items is materialised once at job creation
-- and never re-derived, so growing it to two means every later cycle
-- is BORN demanding two items. When the pile ran dry the job asked for
-- a second, found none, and DF cancelled it inside one second without
-- it ever entering the working phase. Proven on job 826: the last
-- bucket landed at attached=1 filters=2, no working=true was ever
-- logged, and the AUDIT fired one second later still holding it.
--
-- THE SIZE EXPONENT IS SUB ADDITIVE. Below 1.0, n equal pieces of one
-- whole are worth n^(1-exponent) times the whole. At 0.5 that is 2x
-- for four pieces and 7x for fifty. Two consequences, both handled:
--   Split counts are derived from YIELD, not volume, which cancels the
--   exponent and makes split-then-char exactly SPLIT_EFFICIENCY of
--   charring directly at every size.
--   Corpse pieces are computed as the WHOLE creature's yield times the
--   piece fraction, so a creature's parts sum to the creature. The old
--   form raised each piece to the exponent separately and made a river
--   otter toe worth 57x its share.
--
-- ITEMS THAT LIE ABOUT VOLUME. getVolume returns a flat number
-- regardless of the real thing:
--   CORPSE     350 for a rabbit and for a sperm whale
--   REMAINS    200 across cap hopper, olm, cave swallow and bat
--   CLOTH      20,  real measure is getTotalDimension at 10000
--   THREAD     30,  real measure is getTotalDimension at 15000
-- Corpses and remains come from caste.misc.adult_size instead. Cloth
-- and thread are not handled here at all and are excluded from the
-- adaptive set.
--
-- getVolume DOES scale with stack size. A stack of five dog tripe
-- reads 1000 against one at 200, so summing job.items is correct
-- whether DF attaches one stacked ref or five loose ones.
--
-- getMaterial returns -1 on every corpse. Identity comes from
-- matinfo.decode on the fields, and from .race and .caste.
--
-- ALL INTERNAL SIZES ARE ONE TENTH of the wiki published figure.
--
-- A job whose attached count reaches zero consumed its items. A job
-- that vanishes still holding items was cancelled. job.flags.working
-- distinguishes them: a cancelled job never sets it.
--
-- Do NOT raise .quantity on a reagent to consume more. It deadlocks
-- the job.
-- ==========================================

local repeatUtil = require('repeat-util')
local utils      = require('utils')
-- Job completions, which tell the reaper where to look (WHERE THE
-- REAPER LOOKS, at the watcher loop).
local eventful   = require('plugins.eventful')

-- ==========================================
-- THE PROVIDER
-- ==========================================
-- Everything this engine needs from Making Fuel it asks of
-- making-fuel-adaptive-valuation (V), and it reads nothing else of the
-- module's: not its tuning, not its names. V is the interface a module
-- gives the adaptive engine, and it is the whole of it:
--   config_for, streams, value_of, tars_in, fluids_of, write   what
--       reactions are, what things are worth, how a total is written
--   traits, DEFAULT_PROFILE    how the engine treats each profile
--   bank, bank_key             the module's bank and how it names entries
--   REACTION_PREFIX            the module's adaptive reactions
--   CURRENCY_MATERIAL_PREFIX   a liquid currency's material is this plus
--                              the currency
--   setting, dial              the few settings the engine reads
--   is_fuel_slot               which filters are the module's fuel slots
--   start_banner               the start-up line
--
-- How it got here, one step at a time:
-- What things are worth and how a banked total becomes products now
-- live in making-fuel-adaptive-valuation.lua: the classifier, item
-- value, split count, currencies, ladders, profiles, slot writers and
-- streams. Everything below that used them reads these names, the
-- boundary the rest of the split turns into a declared interface.
--
-- Step 2 moved each profile's stream policy (V.streams) out of
-- streams_for, so the engine no longer names a single currency or
-- ladder. Step 3 moved what each adaptive reaction IS (V.config_for:
-- its profile and slots) out of derive_config, which keeps the
-- adaptive test, the creature keying and the storing. Step 4 moved
-- what each held item is worth (V.value_of), the tars a pitch job
-- carries (V.tars_in) and the retort's liquid yield (V.fluids_of) out
-- of the preserved slot loop, which keeps the slot skip, the stack
-- fraction, the inert check and the tally. Step 5 moved the choice of
-- slot writer (V.write) out of apply_banked_yield, which keeps liquid:
-- containers and vessels are the engine's. Step 6 replaced every
-- profile the engine named with a TRAIT the module declares
-- (V.traits: carries_tars, drains) and a default (V.DEFAULT_PROFILE),
-- made bank naming a call (V.bank_key), and gave the start-up line to
-- the module (V.start_banner). The engine imports no names now: it
-- asks V. What it asks is the whole interface a module must provide.
--
-- Step 7 routed the last of it through V: the reaction and liquid
-- material prefixes, the bank, the fuel slot test, and the settings
-- (EPSILON, LIQUID_STANDARD, LIQUID_STANDARD_DEFAULT,
-- INERT_SUSPENDS_JOB), so making-fuel-tuning is no longer read here.
--
-- Step 8 moved the engine into RM: V is no longer loaded here but
-- handed over by each module that registers (see REGISTRATION at the
-- end), and V is whichever of them is in use (see PROVIDERS below).
-- ==========================================
local V = {}

-- ---- THE VESSELS, THE ENGINE'S OTHER HALF ----
-- refinish-reaction-adaptive-vessels.lua: containers, liquid writing,
-- drains and the reaper. RM's own file, so without it the engine does
-- not run at all (register refuses, naming it): half an engine would
-- pay liquids into containers it cannot measure.
local VS = nil
pcall(function() VS = reqscript('refinish-reaction-adaptive-vessels') end)

-- ---- EVERY PROVIDER, AND THE ONE IN USE ----
-- PROVIDERS[owner] = { V, prefix, mat_prefix, bank, drain_cache,
-- reactions }. The file level V, MODULE_PREFIX, MAT_PREFIX,
-- drain_mat_cache and yield_bank are the CURRENT provider's; use()
-- switches them. Lua runs one thing at a time, so a job handled after
-- use(its owner) sees only its own module throughout.
local PROVIDERS = {}
local CURRENT   = nil

local REPEAT_KEY    = 'refinish-reaction-adaptive'

-- ---- JOB SURGERY ----
-- The rules for adding and removing filters on a live job are RM's, in
-- refinish-job-surgery.lua. collapse_vessels takes its vessel filters
-- off through it. Guarded: without it the extras stay on until the job
-- ends, which is the state a failed collapse always left.
local surgery = nil
pcall(function() surgery = reqscript('refinish-job-surgery') end)
-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to.
-- The onus is on the module to hand RM correct information, so the
-- system and subsystem are stated here rather than inferred anywhere
-- else.
--
-- Guarded reqscript: a bare top level one is a hard load time
-- dependency and has taken a module down before. Without it the log
-- falls back to the same grammar, unsanitised, and the script still
-- loads.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'REACTION_ADAPTIVE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)
local MODULE_PREFIX = V.REACTION_PREFIX or ''
local POLL_FRAMES   = 10

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity is declared by the module, not
-- inferred anywhere: RM core does not know this module exists.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   YIELD    the module made something, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: LEDGER for a completed job's
-- accounting, VESSEL, DRAIN and STACK for the liquid and stack
-- mechanics, FILTER and SLOT for job shape, INERT, REAPER, CACHE,
-- ALIAS, JIT, SWAP, CLASSIFY, AUDIT, PHASE, POLL, START and STOP.
--
-- The ledger's first line and its "out" line are a YIELD when the job
-- burned, so Info shows each finished job and what it made; the rest
-- of the block is DETAIL and reads in full at Debug.
--
-- This replaces a log() gated by a private level (refinish_fuel_loglevel,
-- default 2): 0 faults, 1 normal, 2 debug. The panel's Log Detail
-- setting does that job now, so the level and its global are gone and
-- every line reaches the disk log. Level 2 lines are DETAIL, and the
-- rest are typed by what they say. The old log() also let refinish-log
-- guess TYPE from the words (read_type).
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- ==========================================
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

-- ---- CRASH BREADCRUMBS ----
-- TEMPORARY. Delete this and its call sites once the CTD is found.
--
-- The log writer opens, writes and closes the file on every call, so
-- nothing is buffered and the last line on disk is genuinely the last
-- line executed. That makes a breadcrumb trail a reliable way to name
-- the statement a hard crash died on, which a pcall cannot do because
-- a C++ crash is not a Lua error.
--
-- No log_once, deliberately: it has to repeat, because it is the LAST
-- one that matters. Every line reaches the disk log whatever the Log
-- Detail setting, so a crumb always lands.
-- SILENCED, not deleted. All fourteen call sites are left exactly
-- where they are, so re-arming the trail is this one line rather than
-- reconstructing where the crumbs went. They cost nothing while the
-- body is empty.
--
-- They earned their retirement by not being needed: all three crashes
-- this week were found from ordinary log lines, and the crumb volume
-- actively got in the way of reading them.
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
-- THE BANK
-- ==========================================
-- [base reaction code] = value carried forward.
--
-- WHY THIS REPLACED MULTI ITEM COLLECTION
--
-- A barrel is worth 0.632 charcoal and a bucket 0.245. Neither is a
-- whole product alone, so the old design made one job collect several
-- items until they added up. That required an unfilled filter, an
-- unfilled filter is what DF cancels a job over, and the filter vector
-- survives a repeat job's re-post so the demand became permanent.
--
-- The bank reaches a whole product without ever opening a slot. One
-- item per job, filters permanently at the base reaction's count,
-- fractional value accumulated here between jobs. DF has nothing to
-- cancel because nothing is ever outstanding. It also stops the old
-- per job rounding loss, which threw away up to a quarter charcoal on
-- every completion.
--
-- Keyed on the BASE code, so every furniture job shares one running
-- total no matter which wood walked in, and each reaction keeps its
-- own. The UNIT follows the profile: charcoal for CHAR reactions,
-- kindling for SPLIT reactions.
--
-- KEPT WITH THE SAVE. This said session scoped, a reload dropping at
-- most one payout unit per reaction, which held while the bank carried
-- fractions. Banked liquids per retort and still made a reload cost
-- whole packages, so since 2026-09-24 the bank is RM's: refinish-banks
-- restores it from the save and writes every change back through. See
-- start_background_scripts in making_fuel.lua.
-- ==========================================
-- ---- WHY THIS LIVES ON A GLOBAL ----
-- The bank must survive a RAM transition, and a RAM transition happens
-- on EVERY save under the hotsave protocol, not just on a world
-- reload. Clearing it there destroyed a partial balance every time the
-- game saved. At FLESH 0.125 a corpsepiece bank needs roughly sixteen
-- legs to reach a single cinder, so that was not a rounding error.
--
-- It is safe to keep across a cycle in a way ghost_cache is not: this
-- holds no pointers, only reaction code strings against numbers, and
-- those codes are stable. Living on a global also carries it across a
-- world unload and reload, since start() runs again on load.
--
-- By hand, through the proxy so the save follows:
--   :lua for k in pairs(refinish_fuel_bank) do refinish_fuel_bank[k] = nil end
local yield_bank = V.bank and V.bank() or {}

-- BANK SCOPE moved to making-fuel-adaptive-valuation with bank_key,
-- the one thing that reads it.

-- ==========================================
-- THE VESSELS
-- ==========================================
-- Vessel expansion, how much the grabbed container holds, which banks
-- a drain pours and the null liquid reaper live in
-- refinish-reaction-adaptive-vessels.lua (VS). The engine calls them
-- there, and binds that file to the module it is serving whenever it
-- switches (use), so both halves always work for the same module.
-- Loaded at the top with the provider section.
-- ==========================================

-- ==========================================
-- DRAIN: PICKING WHAT TO POUR
-- ==========================================

local function streams_for(cfg, fluids, pitch_cur, pitch_n, job,
                           base_code, ghost)

    -- ---- DRAIN ----
    -- No feed, so no credit: the projection is purely what the bank
    -- already holds. write_liquid then pays each slot up to its own
    -- container's capacity and settle carries the remainder, exactly
    -- as it does for a burn. Nothing downstream needs to know this
    -- reaction is different.
    if V.traits(cfg.profile).drains then
        local slots = cfg.drain_slots or {}
        local cands = (job and ghost)
                      and VS.drain_candidates(base_code, job) or {}
        local out = {}
        for i, at in ipairs(slots) do
            local c = cands[i]
            local mi = c and VS.currency_mat_index(c.cur) or nil
            if c and mi then
                -- The material write this whole design rests on.
                pcall(function()
                    ghost.products[at].mat_type  = 0
                    ghost.products[at].mat_index = mi
                end)
                table.insert(out, { currency = c.cur, at = at,
                    credit = 0, kind = 'liquid',
                    name = string.lower(c.cur) })
            else
                -- A slot with no bank behind it is zeroed rather than
                -- left carrying whatever a previous cycle wrote. Same
                -- stale slot hazard the writer already had.
                pcall(function() ghost.products[at].count = 0 end)
                if c and not mi then
                    log_once('drain_nomat:' .. tostring(c.cur), 'WARNING', string.format(
                            'DRAIN: %s has a bank but no inorganic'
                            .. ' named %s%s, so it cannot be poured.',
                            tostring(c.cur), tostring(V.CURRENCY_MATERIAL_PREFIX or ''),
                            tostring(c.cur)), 'DRAIN')
                end
            end
        end
        if #out == 0 then
            -- INFO: it answers why a drain run poured nothing.
            log_once('drain_empty:' .. tostring(job and job.id or '?'), 'INFO', 'DRAIN: no bank at this furnace holds a whole package'
                .. ' of any liquid, so this run pours nothing.', 'DRAIN')
        end
        return out
    end

    -- Every other profile's streams are the module's policy: what it
    -- pays, in which currency, at which slot and in what share. They
    -- live with the valuation (streams in making-fuel-adaptive-valuation).
    -- DRAIN stays here because it is mechanics: it picks which banks
    -- to pour and rewrites the ghost's product materials to match.
    return V.streams(cfg, fluids, pitch_cur, pitch_n)
end

-- ==========================================
-- BANKED OUTPUT
-- ==========================================
-- Values what the job holds, credits each stream's bank with its
-- share on the way in, writes the ghost's product counts, and
-- reports what the payout consumes.
--
-- NOTHING IS DEBITED HERE. The banks are settled only when a job is
-- confirmed to have burned its items, in the audit sweep. A job that
-- dies holding its item must not be charged for value it never
-- burned, and this function cannot tell the difference.
--
-- Returns streams, detail, inert_hit, out, haul.
--
-- `streams` is one record per currency: the bank it drew on, what
-- that bank held, what this job added, the total the slots were
-- written from, and what those slots cost. settle() carries the
-- difference. `out` is what was actually written to the products;
-- without it there is no way to tell a payout that fired from one
-- that did not, which is exactly the question a bank raises every
-- time it moves.
-- ==========================================
-- ==========================================
-- PRESERVED SLOT, ONE IMPLEMENTATION, FILE SCOPE
-- ==========================================
-- Takes everything it reads as parameters, because this file has
-- now shipped the same wound twice in one hunt: code in one
-- function silently calling names that live inside another, with a
-- pcall eating the nil call for rounds. The witness insert did it
-- from apply into handle's tables; the identity block did it from
-- handle into apply's nested function. Nothing here reaches for an
-- upvalue again.
-- job_item_idx names a FILTER; the filter names its reagent. An
-- unreadable mapping counts the item IN, since false evidence has
-- lost credits and never once invented one.
-- ---- AN UNREADABLE SLOT IS PRESERVED, NOT FEED ----
--
-- This used to return false whenever the read failed, which put the
-- item into the consumable pile. That default is backwards: not
-- knowing what a slot is must never mean "burn it".
--
-- MEASURED, and it crashed the game. A corpse job expanded to five
-- vessel slots, then a data cycle deleted its ghost, and sweep_orphans
-- reverted the job onto MAKING_FUEL_RXN_RETORT_CORPSE, which declares
-- THREE reagents. The job still held five items. Reagent indices 3 and
-- 4 did not exist on the reaction it now pointed at, the read threw,
-- and both of those jugs were valued as feed:
--
--   . aluminum jug  size=30  INERT  d=2700  = 0.000000
--   . aluminum jug  size=30  INERT  d=2700  = 0.000000
--   INERT REFUSED: job 19 holds aluminum jug, which does not burn.
--
-- Exactly two, which is five items minus the three reagents the base
-- has. That count is the fingerprint.
--
-- The three outcomes now differ, and each is honest about what it
-- knows:
--
--   no owner recorded   not preserved, the original behaviour, and
--                       genuinely unowned
--   read succeeded      whatever the reagent says
--   read failed         PRESERVED, because the job and the reaction
--                       disagree about their own shape and the only
--                       safe move is to leave the item alone
--
-- The last case is a fault, so it is named once per item rather than
-- swallowed. On a well formed job it never fires.
local function slot_preserved(job, rxn, iref)
    local idx = iref.job_item_idx
    if not idx or idx < 0 then return false end

    -- ---- DF'S FUEL IS NOT A REAGENT ----
    -- A fuel:true reaction gets one extra job_item that DF wrote
    -- itself, carrying reagent_index -1 and reaction_id -1. Measured
    -- on a live MAKE_CLAY_JUG: it is disconnected from the reaction
    -- entirely. Looking -1 up on rxn.reagents throws, which used to
    -- land in the fault path below and name a well formed job as
    -- broken once per fuel item.
    --
    -- Answered as PRESERVED because that is what it is from this
    -- file's point of view: DF consumes the fuel through its own
    -- machinery and the ghost must neither value it nor charge for
    -- it. The difference from the fault path is only that this is
    -- expected and says nothing.
    local ri = nil
    pcall(function() ri = job.job_items.elements[idx].reagent_index end)
    if ri and ri < 0 then return true end

    local ok, preserved = pcall(function()
        return rxn.reagents[ri].flags.PRESERVE_REAGENT
    end)
    if ok then return preserved == true end

    -- ---- WHAT THIS HAS MEANT IN PLAY ----
    -- MEASURED, job 10111, BOIL_TAR: a fuel item left pointing past the
    -- end of job_items after access.lua's start sweep erased bulk fuel
    -- copies under it (since guarded: the sweep no longer erases under
    -- an item). DF completed the job without a crash and burned what it
    -- held, 2 dried dung of the 4 owed. So on a fuel item this line
    -- means an underpaid cycle, not a coming crash. R22's crash was a
    -- different mismatch, a FILTER naming a reagent the reaction does
    -- not have. Register L22.
    local iid = '?'
    pcall(function() iid = tostring(iref.item.id) end)
    log_once('slotgap:' .. tostring(job.id) .. ':' .. iid, 'WARNING', string.format(
        'Job %d holds item #%s in a slot %s does not have. The job and'
        .. ' the reaction disagree about their shape. Treating it as'
        .. ' PRESERVED so nothing is consumed by accident.',
        job.id, iid, tostring(rxn and rxn.code or '?')), 'SLOT')
    return true
end

-- ==========================================
-- THE HELD ITEMS, PRICED ONCE
-- ==========================================
-- MEASURED 2026-10-01, refinish-section-probe, big fort, 612 s: valuing
-- the held items cost 91 us a call over 31716 calls, 4.71 ms/sec, the
-- largest part of apply_banked_yield. handle_ghosted runs on every poll
-- for every ghosted job holding items, and every poll priced the same
-- items again: value_of, a description, and formatted log lines for
-- each one.
--
-- A job's held items rarely change from one poll to the next, so what
-- the valuation loop works out (the haul, the fluids, an inert item
-- and the detail lines) is kept per job beside the identity of what it
-- priced: each held item's id, stack, material, and the slot it fills.
-- Any difference prices again. That covers a new item, a stack burned
-- down by a cycle, and wet fuel drying in place, which changes the
-- material. A profile that carries tars always prices again, because
-- its feedstock sits inside the jugs, where this identity cannot see.
--
-- Keyed by job id, so reset_engine empties it (DF hands out low job
-- ids again after a reload: EVERYTHING KEYED BY JOB ID, OR IT OUTLIVES
-- THE WORLD) and audit_sweep drops a job once it leaves the list.
local valued = {}

-- ---- THE SAME ITEMS AS THE LAST POLL ----
-- MEASURED 2026-10-01, refinish-section-probe, big fort, 437 s: with the
-- valuation kept, handle_ghosted still cost about 210 us a job a poll,
-- and most of it rebuilt what the last poll had just built from the
-- same items: the stack rule 41 us, the item identity tables 24 us, the
-- snapshot's item descriptions most of 21 us. So handle_ghosted keeps,
-- per job, the identity below and what it built from it, and a poll
-- holding the same items (same ghost too) skips those three. The stack
-- rule is the only writer of a ghost reagent's quantity, and it writes
-- only when the count differs, so skipping it on unchanged items skips
-- nothing it would have done.
--
-- Not for a profile that carries tars (the feedstock is inside the
-- jugs, unseen here) or one that drains (its witness is what the
-- vessels hold, which changes with nothing else changing). Emptied and
-- pruned with valued.
local steady = {}

-- A liquid or thread is consumed by dimension, which a stack count does
-- not show, so the identity carries it too. Named, so no closure is made
-- per item.
local function dim_of(it) return it.dimension end

-- ---- A DIMENSION, READ WITHOUT A THROW ----
-- MEASURED 2026-10-01, refinish-section-probe, big fort, 818 s: once the
-- identity read every held item's dimension through pcall(dim_of, it),
-- "yield: held items, priced before" went from 10 us a call (the 437 s
-- run before it) to 20 to 30 us, and the stack rule's lap, which holds
-- the identity, ran 28 to 45 us. The engine as a whole stayed at 12.2
-- ms/sec, the skips' savings spent.
--
-- Only some item classes declare a dimension field: bars, liquids and
-- powders, globs, thread, cloth and sheets (df-structures, df.item.xml).
-- Logs, tools, boulders, plants and corpse pieces do not, and reading a
-- field a class lacks does not answer nil: DFHack raises "Cannot read
-- field <class>.dimension: not found." (LuaTypes.cpp lookup_field into
-- LuaWrapper.cpp field_error, a luaL_error with a formatted message). A
-- pcall that catches it costs several plain reads, and every such item
-- paid it on every identity, twice a poll (ONE IDENTITY A POLL, in
-- handle_ghosted).
--
-- So whether a type carries the field is learned once per item type, by
-- one guarded read, and kept. An item type is exactly one class (the
-- item_type enum's classname, df.d_basics.xml: 93 types, no class used
-- twice) and a class's fields are fixed, so an answer never goes stale
-- and nothing here belongs to a world. After that, an item of a type
-- without the field costs a type read and a table lookup.
local has_dimension = {}     -- item type -> true or false

-- The item's dimension, or nil when its class has no such field.
local function dimension_of(it)
    local ty = it:getType()
    local has = has_dimension[ty]
    if has == nil then
        has = pcall(dim_of, it)
        has_dimension[ty] = has
    end
    if has then return it.dimension end
    return nil
end

-- The identity of what the valuation loop prices, as one string, or
-- nil when it cannot be read, which only means the loop runs.
local function held_identity(job)
    local ok, key = pcall(function()
        local parts = {}
        for i, iref in ipairs(job.items) do
            local it = iref.item
            -- A DIMENSION, READ WITHOUT A THROW: nil for a class without
            -- the field, as the failed read gave. Anything else that
            -- throws lands in the pcall around this loop.
            local dm = dimension_of(it)
            parts[#parts + 1] = it.id .. ':' .. it.stack_size .. ':'
                .. it:getMaterial() .. ':' .. it:getMaterialIndex() .. ':'
                .. iref.job_item_idx .. ':' .. tostring(dm or '-')
        end
        return table.concat(parts, ',')
    end)
    if ok then return key end
    return nil
end

-- held_key: the identity of the held items, built once a poll by
-- handle_ghosted (ONE IDENTITY A POLL). nil for a profile that carries
-- tars, or when the items could not be read, and either way the
-- valuation loop below runs.
local function apply_banked_yield(job, ghost, base_code, cfg, held_key)
    if not ghost or #ghost.products < 1 then return nil end
    -- SECTION CLOCK (refinish-section-probe): laps between the parts
    -- below, quiet while the probe is off.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    local profile = cfg.profile

    -- ---- VALUE OF WHAT THE JOB HOLDS ----
    -- One item under normal running. More only on a legacy job left
    -- mid-collection by the old shape, which needs no special casing
    -- because this simply sums whatever is there.
    local haul      = 0
    local detail    = {}
    local inert_hit = nil
    -- The tar currency this cycle holds, for the pitch purse.
    local pitch_cur = nil
    -- The burn witnesses, returned to the CALLER, because ids,
    -- stacks and dims are handle_ghosted locals: an insert from in
    -- here lands on nil and the pcall eats the throw. Three rounds
    -- of silently discarded evidence taught this comment its tone.
    -- A LIST now: fractionations hold several tars per cycle.
    local pitch_witness = {}
    local pitch_n = 0
    local pitch_seen = {}
    -- [currency] = liquid units this job's items condense to. Only
    -- ever filled on a reaction with liquid slots.
    local fluids    = {}
    -- Units held under each filter, a stack counting its whole size, for
    -- the stack fraction below. Declared here, above the jump to
    -- priced_before, because a goto may not jump into a local's scope;
    -- filled after it, so a poll that reuses last poll's prices reads no
    -- item twice.
    local slot_units = {}

    -- ---- PRESERVED REAGENTS ARE NOT FEEDSTOCK ----
    -- job.items is every item DF attached, which includes the empty
    -- buckets and the container holding a liquid reagent. Those are
    -- PRESERVE_REAGENT slots: they come back out untouched, so they
    -- are apparatus, not charge, and valuing them is wrong twice.
    --
    -- A wooden bucket classifies WOOD and gets burned as feedstock,
    -- silently inflating every retort yield by the volume of the
    -- container. A metal one classifies INERT and trips the refusal
    -- below, which suspends the job, releases the item, and lets the
    -- repeat job pick the same bucket again forever.
    --
    -- The refusal comment says an inert hit means a reagent is
    -- missing its material gate. That holds for feedstock. It does
    -- not hold for containers, which are deliberately ungated because
    -- any bucket will do, so they have to be skipped here instead.
    --
    -- iref.job_item_idx indexes the reagent list. It is -1 when DF
    -- attached an item to no particular filter, and those are left in
    -- rather than guessed at.
    -- Delegates to the file scope implementation above so the chain
    -- lives exactly once. The local name survives for the call
    -- sites in the valuation loop below.
    local function is_preserved_slot(iref)
        return slot_preserved(job, ghost, iref)
    end

    -- THE HELD ITEMS, PRICED ONCE: the same items as the last poll take
    -- that poll's results and skip the loop.
    -- held_key is the argument (ONE IDENTITY A POLL): built here until
    -- 2026-10-01, which read every held item a second time each poll.
    local priced = held_key and valued[job.id]
    if priced and priced.key == held_key then
        haul, detail = priced.haul, priced.detail
        inert_hit, fluids = priced.inert_hit, priced.fluids
        if sc then t0 = sc.lap('yield: held items, priced before', t0) end
        goto priced_before
    end

    for _, iref in ipairs(job.items) do
        pcall(function()
            local k = iref.job_item_idx
            slot_units[k] = (slot_units[k] or 0) + (iref.item.stack_size or 1)
        end)
    end

    for _, iref in ipairs(job.items) do
        local v, size, class, density, path, mat_token
        -- Corpse pieces also hand back whole size and piece share.
        local whole_size, piece_share
        if V.traits(profile).carries_tars then
            -- The feedstock is never ATTACHED: tars ride inside
            -- preserved jugs, so this branch runs BEFORE the preserved
            -- slot skip. Which tars count and which purse each names
            -- is the module's (tars_in in making-fuel-adaptive-
            -- valuation); counting, witnessing and the log are here.
            for _, hit in ipairs(V.tars_in(iref.item, pitch_seen)) do
                pitch_cur = hit.cur
                pitch_n = pitch_n + 1
                table.insert(detail, hit.detail)
                table.insert(pitch_witness, { id = hit.id, stack = hit.stack, dim = hit.dim })
            end
            goto next_item
        end
        if is_preserved_slot(iref) then
            goto next_item
        end
        -- What the item is worth, and what it is, are the module's
        -- (value_of in making-fuel-adaptive-valuation).
        v, size, class, density, path, mat_token,
            whole_size, piece_share = V.value_of(iref.item, profile)

        -- ---- STACK FRACTION ----
        -- v is the WHOLE item's value, and getVolume scales with the
        -- stack, but DF consumes only the reagent's quantity from a
        -- stack and leaves the rest as the same item. Value only what
        -- this cycle takes: quantity over stack size, capped at one.
        -- Measured on rotten meat fed one unit per cycle: a [20] stack
        -- was priced at 4000 volume every cycle while one unit burned.
        -- Non-stacked items are untouched (fraction one).
        -- PER SLOT, NOT PER ITEM (2026-10-03). One slot fills from any
        -- number of stacks (RM_Stacked_Tools.md: a slot asking for 5 took
        -- stacks of 3 and 2, and from 4 and 4 drew 5 and left 3), so the
        -- quantity this cycle takes is spread over every unit the slot
        -- holds. Priced per item, stacks of 3 and 2 in a slot asking for 4
        -- were each priced whole: 5 units valued, 4 used. A slot holding
        -- one stack prices exactly as before.
        local frac = 1
        pcall(function()
            local sz = slot_units[iref.job_item_idx] or iref.item.stack_size or 1
            if sz > 1 then
                -- Consumption per completion is the RAWS reagent
                -- quantity (measured: one unit per cycle even with the
                -- job item zeroed), so the fraction reads the ghost
                -- clone's own reagent, which mirrors the base. The job
                -- item quantity only governs seeking.
                -- The SLOT'S OWN reagent, found the way the stack rule
                -- finds it (reagent_index): the feed's quantity once the
                -- rule has raised it, any other slot's as declared. This
                -- read reagent 0 for every slot until 2026-10-06, which
                -- priced a second slot by the feed's quantity: a compost
                -- job's 6 sawdust were priced as 3 while all 6 burned.
                local q = 1
                pcall(function()
                    local ri = job.job_items.elements[iref.job_item_idx].reagent_index
                    q = ghost.reagents[ri].quantity
                end)
                if not q or q < 1 then q = 1 end
                frac = math.min(1, q / sz)
            end
        end)

        -- ---- RETORT: THE LIQUID SIDE OF THE SAME ITEM ----
        -- Its own curve, split across liquids by class. Size and
        -- class are the ones item_value already read; a stack's
        -- volume carries through, and a corpse piece prices the
        -- whole creature times its share below.
        if cfg.liquid_slots and v and size and class ~= 'INERT' then
            -- How much liquid the item yields, split by liquid, is the
            -- module's (fluids_of in making-fuel-adaptive-valuation).
            for cur, amount in pairs(V.fluids_of(size, class, density, mat_token,
                                                  whole_size, piece_share, frac)) do
                fluids[cur] = (fluids[cur] or 0) + amount
            end
        end

        -- ---- INERT ----
        -- A wood furnace cannot consume something that does not burn.
        -- This should be unreachable: the reagent gate stops DF ever
        -- selecting an inert item. Reaching it means a reagent is
        -- missing its material flag, so it is reported as a fault
        -- rather than silently valued at zero.
        --
        -- EXCEPT ON A DRAIN. Its only consumed reagent is the key, a
        -- fireproof tool that exists to make the reaction available and
        -- is destroyed by running it. It is not fuel and was never
        -- meant to burn, so "this does not burn" is not a complaint
        -- worth suspending a job over. Without this gate every drain
        -- run would suspend itself on its own key.
        if class == 'INERT' and not V.traits(cfg.profile).drains then
            local d = '?'
            pcall(function() d = dfhack.items.getDescription(iref.item, 0) end)
            inert_hit = tostring(d)
        end

        if v then
            haul = haul + v * frac
            local d = '?'
            pcall(function() d = dfhack.items.getDescription(iref.item, 0) end)
            table.insert(detail, string.format(
                '%s  size=%.0f %s d=%s -> %.6f',
                tostring(d), size or -1, tostring(class),
                tostring(density or '-'), v))
            -- Keyed on the ITEM, not on the value. handle_ghosted runs
            -- six times a second per job, so an unkeyed line here
            -- produced hundreds of identical entries. Keying on the
            -- item id prints once per item that actually arrives,
            -- which is the event worth seeing, while still showing a
            -- repeat if the same item is somehow read twice.
            log_once('item:' .. job.id .. ':' .. tostring(iref.item.id), 'DETAIL', string.format('    . %s  size=%.0f  %s  d=%s  [%s]  = %.6f',
                    tostring(d), size or -1, tostring(class),
                    tostring(density or '-'), tostring(path), v), 'AUDIT')
        end
        ::next_item::
    end

    if held_key then
        valued[job.id] = { key = held_key, haul = haul, detail = detail,
                           inert_hit = inert_hit, fluids = fluids }
    end
    if sc then t0 = sc.lap('yield: value the items', t0) end
    ::priced_before::
    -- ---- REFUSE ONLY A CHARGE THAT CANNOT BURN AT ALL ----
    -- This used to refuse on the FIRST inert item, whatever else was
    -- in the job. MEASURED, job 20: a fluxed retort holding lignite
    -- worth 8.043 and one limestone was suspended on the limestone,
    -- and the log said the reagent was missing a material gate. The
    -- gate was correct. Limestone is a flux stone, the flux slot asks
    -- for one on purpose, and it is where the gypsum and brimstone
    -- come from.
    --
    -- The guard's actual purpose is that a furnace cannot consume a
    -- charge that does not burn, and the honest test of that is the
    -- haul, not any single item. A job that valued something burns;
    -- an inert item beside it is an additive, not a mistake. A lone
    -- stone chair still hauls zero and is still refused.
    --
    -- The tolerated case is logged rather than silent, because an
    -- inert item IS consumed for no yield and that is worth seeing
    -- once if a reagent really is ungated.
    if inert_hit then
        if haul <= 0 then
            return nil, detail, inert_hit, nil, haul
        end
        log_once('inertok:' .. tostring(job.id), 'DETAIL', string.format(
            'job %d consumes %s, which does not burn, alongside a'
            .. ' charge worth %.4f. Allowed as an additive.',
            job.id, tostring(inert_hit), haul), 'AUDIT')
    end

    -- ---- ONE STREAM PER CURRENCY ----
    -- Each stream is credited with its share of the haul on top of
    -- what its bank already holds, writes its slots from that total,
    -- and records total and cost for settle().
    local streams = {}
    local out     = {}

    -- ---- CONTAINERS, SPLIT IN PROPORTION TO WHAT WAS EARNED ----
    -- The containers are shared across a job's currencies, because
    -- two currencies asking for a second jug are competing for the
    -- same pile and counting per stream would promise the same jug
    -- twice. Sharing was right; FIRST COME was not.
    --
    -- Measured on one whale: ammonia runs earlier in the stream order,
    -- took all seven containers on its 11 packages, and oil bone,
    -- which had earned 35, got none at all. A currency earning three
    -- times as much came away with nothing because of the order the
    -- loop happened to visit it in.
    --
    -- So the wants are totalled BEFORE anything is handed out, and
    -- each currency gets its share of the pile. Largest remainder, so
    -- the whole pile is dealt out rather than lost to rounding.
    local spec_list = streams_for(cfg, fluids, pitch_cur, pitch_n,
                                  job, base_code, ghost)

    -- ---- SAY WHEN SLOTS AND CLASS DISAGREE ----
    -- streams_for builds the liquid list from the UNION of what this
    -- reaction declares a container for and what the feed actually
    -- earned, so the two can disagree in either direction and neither
    -- one is an error the code can decide on its own. Both are silent
    -- without this, and both were reported identically to a stream
    -- that was working, which is exactly how a fat banked bone oil
    -- for as long as RETORT_GLOB existed.
    --
    -- EARNED WITH NO CONTAINER. Legitimate: banks key on currency and
    -- building, BANK_OIL_BONE@5, so a sibling reaction at the same
    -- furnace pays it out and nothing is lost. Worth saying once so a
    -- currency piling up somewhere it can never leave is visible.
    --
    -- CONTAINER WITH NOTHING TO PUT IN IT. This is the one that
    -- matters. A declared slot the feed never funds pays zero and DF
    -- mints a null into it on every single run, which the reaper then
    -- clears. Harmless and endless. It means the reaction's slots and
    -- the feed's FLUID_SPLIT do not agree, which is an authoring
    -- fault, not a runtime one.
    --
    -- Gated on two things so it does not cry wolf. The job must have
    -- earned SOME liquid, otherwise an inert feed would light up every
    -- slot it has. And the bank must be empty too, because
    -- streams_for deliberately keeps a slot alive on a zero earning
    -- job so a balance stranded by another feedstock can drain
    -- through it, and that is working as intended rather than a
    -- disagreement.
    --
    -- log_once keyed on reaction and currency, not on job, because
    -- this is a property of how the reaction is written. Once per
    -- session is the whole point; saying it per job would be noise.
    do
        local earned_any = false
        for _, v in pairs(fluids or {}) do
            if (v or 0) > 0 then earned_any = true end
        end

        for _, spec in ipairs(spec_list) do
            if spec.kind == 'liquid' then
                local c = spec.credit or 0
                if not spec.at then
                    if c > 0 then
                        log_once('noslot:' .. tostring(base_code)
                                 .. ':' .. tostring(spec.currency), 'DETAIL', string.format(
                                'VESSEL: job %d earned %.6f %s, which %s has'
                                .. ' no container for. It banks at this'
                                .. ' furnace and a reaction here that does'
                                .. ' declare one will pay it out.',
                                job.id, c, tostring(spec.name),
                                tostring(base_code)), 'VESSEL')
                    end
                elseif c <= 0 and earned_any then
                    local held = 0
                    if not spec.nobank then
                        pcall(function()
                            held = yield_bank[
                                V.bank_key(base_code, spec.currency, job)] or 0
                        end)
                    end
                    if held <= 0 then
                        log_once('deadslot:' .. tostring(base_code)
                                 .. ':' .. tostring(spec.currency), 'WARNING', string.format(
                                'VESSEL: %s declares a container for %s but'
                                .. ' this feed funds none of it and the bank'
                                .. ' is empty, so that slot pays nothing and'
                                .. ' DF mints a null every run. Check this'
                                .. ' reaction against FLUID_SPLIT for the'
                                .. ' class it is being fed.',
                                tostring(base_code), tostring(spec.name)), 'VESSEL')
                    end
                end
            end
        end
    end

    if sc then t0 = sc.lap('yield: inert check, streams, slot check', t0) end
    -- SECTION CLOCK, INSIDE THE PLAN: t0 still times the whole plan and
    -- write ('yield: vessel plan, write products'), and t_sub splits it.
    -- MEASURED 2026-10-02 (section probe): the whole was 0.051 ms a call,
    -- 15,535 calls in 306 s, 2.57 ms/sec, the costliest part of a ghosted
    -- job's poll. Split before anything in it is changed.
    local t_sub = t0
    local free_vessels = nil
    local allow = {}

    do
        local wants, total, pkgs = {}, 0, {}
        for _, spec in ipairs(spec_list) do
            if spec.kind == 'liquid' and spec.at then
                -- NOT `spec.nobank and nil or bank_key(...)`. In Lua
                -- that expression can never yield nil: `true and nil`
                -- is nil, and `nil or x` is x, so the fallback fired
                -- on BOTH branches and nobank never once took effect.
                local key = nil
                if not spec.nobank then
                    key = V.bank_key(base_code, spec.currency, job)
                end
                local banked = key and (yield_bank[key] or 0) or 0
                local credit = spec.credit
                    or (spec.share and haul * spec.share) or 0
                -- Containers, not packages. See containers_wanted.
                local pk = (V.setting('LIQUID_STANDARD') or {})[spec.currency]
                           or V.setting('LIQUID_STANDARD_DEFAULT') or 1
                if pk < 1 then pk = 1 end
                -- Both numbers are kept. `wants` counts CONTAINERS,
                -- which is what gets allotted. `pkgs` counts PACKAGES,
                -- which is what the player is told they earned. Since
                -- a jug holds sixteen, reporting one where the other
                -- is meant is a log that lies.
                local pw = VS.packages_wanted(banked + credit, spec.currency)
                local w = VS.containers_wanted(job, ghost, spec.at, pw, pk) - 1
                pkgs[spec.currency] = pw
                if w > 0 then
                    wants[spec.currency] = w
                    total = total + w
                end
            end
        end

        -- Asked once, here, so the whole pre pass is skipped for a
        -- job that cannot use containers anyway. That saves a full
        -- item vector walk in count_free_vessels, and it stops the
        -- allotment line claiming a job was allotted 35 containers
        -- on a run where it was never able to ask for one.
        if total > 0 and not VS.collection_open(job, VS.expand_for(job)) then
            total = 0
        end

        if total > 0 then
            local t_cv = sc and sc.now()
            free_vessels = VS.count_free_vessels(job, ghost)
            if sc then sc.lap('yield: count_free_vessels (inside the plan)', t_cv) end
            local pool = free_vessels
            if pool > total then pool = total end

            -- Floor each share, then hand the remainder to whoever
            -- lost the most to rounding. Without this a pile of 7
            -- split 34 to 10 deals out 5 and 1 and strands a
            -- container nobody asked for.
            local left, rema = pool, {}
            for cur, w in pairs(wants) do
                local exact = pool * w / total
                local n = math.floor(exact)
                allow[cur] = n
                left = left - n
                table.insert(rema, { cur = cur, r = exact - n })
            end
            table.sort(rema, function(a, b) return a.r > b.r end)
            local i = 1
            while left > 0 and #rema > 0 do
                local cur = rema[i].cur
                if allow[cur] < (wants[cur] or 0) then
                    allow[cur] = allow[cur] + 1
                    left = left - 1
                end
                i = i + 1
                if i > #rema then
                    -- One full pass handed nothing out, so every
                    -- currency is already at its want. Stop rather
                    -- than spin.
                    if left == pool then break end
                    i, pool = 1, left
                end
            end

            for cur, n in pairs(allow) do
                if n > 0 then
                    log_once('vessel_alloc:' .. job.id .. ':' .. cur, 'DETAIL', string.format(
                            'VESSEL: job %d allots %d extra container(s)'
                            .. ' of %d free to %s, which earned %d'
                            .. ' package(s). One container takes many.',
                            job.id, n, free_vessels,
                            string.lower(cur), pkgs[cur] or 0), 'VESSEL')
                end
            end
        end
    end

    if sc then t_sub = sc.lap('yield: plan, liquid pre-pass', t_sub) end
    for _, spec in ipairs(spec_list) do
        -- Same trap as the liquid loop above: `x and nil or y` is
        -- always y. Every `each` stream in the module has been
        -- carrying a bank key it was explicitly denied, which is how
        -- BANK_oil lubricating@4 came to exist with a space in it.
        local key = nil
        if not spec.nobank then
            key = V.bank_key(base_code, spec.currency, job)
        end
        local banked    = key and (yield_bank[key] or 0) or 0
        local credit    = spec.credit
            or (spec.share and haul * spec.share) or 0
        local projected = banked + credit

        local paid, wrote
        if spec.kind == 'liquid' then
            -- Containers, not packages. The same conversion the pre
            -- pass uses, so the two cannot disagree about how many
            -- vessels this currency is asking for.
            local pk = (V.setting('LIQUID_STANDARD') or {})[spec.currency]
                       or V.setting('LIQUID_STANDARD_DEFAULT') or 1
            if pk < 1 then pk = 1 end
            local want  = VS.containers_wanted(job, ghost, spec.at,
                VS.packages_wanted(projected, spec.currency), pk)
            local slots = { spec.at }
            if want > 1 and spec.at then
                -- Its OWN allowance from the pre pass, not whatever
                -- the pile happens to hold when the loop reaches it.
                -- Anything it does not spend goes back, so a currency
                -- that cannot use its full share does not strand it.
                local mine_pool = allow[spec.currency] or 0
                local before = mine_pool
                slots, mine_pool = VS.slots_for_liquid(
                    job, ghost, spec.at, want, mine_pool, spec.currency,
                    VS.packages_wanted(projected, spec.currency))
                allow[spec.currency] = mine_pool
                local spent = before - mine_pool
                if free_vessels then free_vessels = free_vessels - spent end
            end
            -- The crumb's text only when crumbs are on: an argument is
            -- built before the call, whether the call prints or not.
            if CRUMBS_ON then
                crumb('G VS.write_liquid in', string.format('%s slots=%d',
                      tostring(spec.currency), #slots))
            end
            paid, wrote = VS.write_liquid(job, ghost, slots, projected,
                                       spec.name, spec.currency)
            if CRUMBS_ON then crumb('H VS.write_liquid out', tostring(paid)) end
            if sc then t_sub = sc.lap('yield: plan, a liquid stream written', t_sub) end
        else
            -- Ladder, each and whole units: how a banked total becomes
            -- product counts is the module's (write in making-fuel-
            -- adaptive-valuation). Liquid stays here above, because
            -- containers and vessels are the engine's mechanics.
            paid, wrote = V.write(spec, ghost, projected)
            if sc then t_sub = sc.lap('yield: plan, a solid stream written', t_sub) end
        end
        for _, o in ipairs(wrote) do table.insert(out, o) end

        table.insert(streams, {
            currency = spec.currency, bank = key,
            bank_in = banked, haul = credit, sum = projected, paid = paid,
        })
    end

    if sc then sc.lap('yield: vessel plan, write products', t0) end
    return streams, detail, nil, out, haul, pitch_witness
end

-- ==========================================
-- FILTER REPAIR
-- ==========================================
-- Two jobs, both narrow, and NEITHER of them grows anything.
--
--   1. Clear the material lock off every filter, every poll.
--   2. Shrink a filter vector that a previous build left too long.
--
-- WHY THERE IS NO GROWTH PATH ANY MORE
--
-- The old version set its target from #job.items and grew the filter
-- and reagent vectors to match. That is only correct if one item means
-- one filter, which was true under the old collection scheme and is
-- false now.
--
-- A REAGENT WITH quantity N IS ONE FILTER THAT WANTS N ITEMS. Dung is
-- one reagent at quantity 8, branches one at quantity 2. So eight dung
-- attached means #job.items is 8 while #job.job_items.elements is 1.
-- Reading 8 as a filter count grew the vector to 8, each clone
-- carrying quantity 8 from the prototype, so the job then wanted 64.
-- Every arrival grew it again. Observed live: dung reached filters=26
-- and branches filters=65, and neither job could ever be satisfied.
-- 28 of the 123 adaptive reactions declare quantity above 1.
--
-- The base reaction already declares the right reagent count and the
-- right quantity. DF materialises filters from it correctly. There is
-- nothing for this function to add.
--
-- Shrinking erases but does not delete(). A leaked job_item is a few
-- dozen bytes; a use after free is a crash.
-- ==========================================
-- Base reactions resolved once per code and cached. The repair runs
-- five times a second per live job; walking the reaction array that
-- often would be a scan per poll for a value that never changes.
--
-- ---- THE CACHE VALIDATES ITSELF ON READ ----
--
-- MEASURED, second whale after an ESC menu. A data cycle logs
-- `CLEAR RXN: Excised 594 injected reactions from RAM` and then
-- rebuilds. A pointer cached before that points at a freed block, and
-- the allocator hands that block to one of the reactions injected
-- afterwards. It is not corrupted memory: it is a real, live, WRONG
-- reaction.
--
-- What that did. repair_filters copies materials off base.reagents
-- onto the live job's filters. The address held one of the RM alloy
-- variants, which carry `mat_type = 0` and a specific inorganic
-- mat_index (refinish-index-reaction.lua:309 and :316) and have two
-- reagents. So a corpse job came back with
--
--   [0] type=CORPSE mat=0/8    [1] type=TOOL mat=0/83    [2] mat=-1/-1
--
-- Filter 2 was untouched because that object has no third reagent.
-- mat_type 0 is INORGANIC and a corpse is 22, so slot 0 could never
-- be satisfied and DF cancelled: "needs corpse".
--
-- Clearing the cache on a cycle is not enough on its own, because it
-- depends on someone remembering to call the hook. Comparing the
-- cached object's own code against the one asked for costs one string
-- read and cannot be forgotten. A mismatch means the address was
-- reused, so the entry is dropped and the array rescanned.
--
-- ---- AND A MISS IS NEVER CACHED ----
--
-- The old `false` sentinel meant "looked, not there, never look
-- again". That was safe while every reaction existed at boot. It is
-- not any more: making-fuel-drain-key.lua mints per retort drain
-- clones during play, so a drain job in flight across a cycle can ask
-- for a clone that has not been re-minted yet. Caching that miss
-- would leave the job on wildcard filters for the rest of the session
-- with nothing said. Same rule the concrete watcher states for its own
-- ghost lookup.
-- ---- ONE LOOKUP, NOT ONE WALK ----
-- MEASURED 2026-09-30: a walk of the reactions array for one code cost
-- 38 ms with 103,543 reactions (walk probe), and a new ghost made two:
-- its own code, a miss that runs to the end, then its base. With the
-- fort working this engine ran 0.99 ms a call, 9.5 ms/sec, 94 ms at
-- worst, and a JIT compile at 19:27:11 sat on a 156 ms frame (lag
-- probe). Lookups by code go to RM's reaction index instead
-- (refinish-resolve.lua, REACTIONS), checked on every use and published
-- as a global. The walk stays as the fallback for a session where the
-- resolver did not load; loading it is tried once, since reqscript
-- costs about 2 ms.
local resolver_tried = false
local function find_rx(code)
    local f = _G.refinish_find_reaction
    if not f and not resolver_tried then
        resolver_tried = true
        pcall(reqscript, 'refinish-resolve')
        f = _G.refinish_find_reaction
    end
    if f then
        local ok, r = pcall(f, code)
        if ok then return r end
    end
    local found = nil
    pcall(function()
        for _, rx in ipairs(df.global.world.raws.reactions.reactions) do
            if rx.code == code then found = rx; break end
        end
    end)
    return found
end

local base_cache = {}
local function base_reaction(code)
    local hit = base_cache[code]
    if hit then
        local live = nil
        pcall(function() live = tostring(hit.code) end)
        if live == code then return hit end
        base_cache[code] = nil
        log_once('stale_base:' .. code, 'WARNING', string.format(
            'Base reaction %s was cached across a data cycle and its'
            .. ' address now holds %s. Dropped and rescanned.',
            code, tostring(live)), 'CACHE')
    end

    local found = find_rx(code)   -- ONE LOOKUP, NOT ONE WALK
    if found then base_cache[code] = found end
    return found
end

-- ==========================================
-- FUEL FILTERS ARE NOT THE GHOST'S
-- ==========================================
-- A reaction with fuel on carries DF's own fuel filter, and on the
-- kiln tier making-fuel-access.lua appends three copies of it (the
-- bulk surcharge: four bulk fuels or one finished fuel). None of them
-- belongs to a reagent, so none is part of the authored shape
-- repair_filters defends, and none is the ghost's to stamp or erase.
--
-- MEASURED, job 10050, BOIL_TAR at the kitchen with fuel on: access
-- grew the job to 5 filters, repair_filters counted them against 2
-- reagents and shrank it back to 2, and the job burned one bulk fuel
-- where it owed four. The shrink erases from the END, which is where
-- the surcharge copies sit.
--
-- Recognised by is_fuel_slot in making-fuel-tuning.lua, the one
-- definition the fuel access layer uses too: a slot that serves no
-- reagent and looks like fuel. A reagent that IS coal names its reagent,
-- so it is restored and counted like any other reagent. Register L21.
--
-- ---- WHAT LEAVING FUEL ALONE DOES NOT COVER ----
-- Read before putting fuel on any ghosted reaction.
--
-- 1. THE TAIL IS SHARED, AND BOTH SIDES NOW KNOW IT. The fuel access
--    layer appends its bulk copies at the END of job_items, and
--    restore_fuel puts a tanked job's slot back at the END.
--    append_vessel_triple appends here too, a filter, a reagent and a
--    product per extra jug. Each side now takes back only what it can
--    name: the fuel side its own copies, which own no reagent, and this
--    side the filters owned by the reagents it appended. Neither reads
--    position any more.
--    UNTESTED TOGETHER: no ghosted reaction that makes liquids has run
--    with fuel on. Before turning fuel on for the retort reactions or
--    the distils, run one full cycle with jugs expanded and read the
--    VESSEL line: it should release as many filters as jug slots, and
--    the job's DETAIL line should keep its fuel count. Register R31.
--
-- 2. A REAGENT TYPED AS BUILTIN COAL. access.lua swaps it for the
--    module's coals (widen_coal_reagents, register L15), then
--    repair_filters restores the authored material, builtin COAL, on
--    every poll. The coal watcher makes sure no builtin coal exists, so
--    the job waits forever. On a ghosted reaction, author coal reagents
--    by identity class (COKE, CHARCOAL, COAL), never as builtin coal.
--
-- 3. FUEL IS OUTSIDE THE BAND. FILTER REPAIR and SLOT DESYNC count
--    reagent filters only. Fuel shows as "(N fuel)" on the job's DETAIL
--    and PHASE lines: 4 on the kiln tier, 1 on the smith tier, none on
--    a tanked job or a wood furnace job.
--
-- 4. "HOLDS ITEM #N IN A SLOT ... DOES NOT HAVE" ON A FUEL ITEM means
--    an underpaid cycle, not a coming crash. See slot_preserved.
local function is_fuel_filter(e)
    if not V.is_fuel_slot then return false end
    return V.is_fuel_slot(e) == true
end

local function repair_filters(job, ghost, base_code)
    if not ghost then return -1, -1 end
    local base = base_code and base_reaction(base_code) or nil

    -- ---- THE LEGAL FILTER COUNT IS A BAND, NOT A NUMBER ----
    -- The ghost declares the reagents, and the ghost is deep copied
    -- from the base, so its reagent count is the authored shape. What
    -- it does NOT tell us is how many FILTERS DF will post for that
    -- shape, because DF sometimes folds a contained reagent into its
    -- container's filter and sometimes does not.
    --
    -- MEASURED, both directions, same engine:
    --   BOIL_PITCH        2 reagents, 1 contained, DF posted 1
    --   DISTIL_TAR_COAL   3 reagents, 1 contained, DF posted 3
    --
    -- The old code predicted the fold always happens. That matched the
    -- boil, which is where it was derived, and called the still broken
    -- six times a second for its whole run. Predicting it never
    -- happens would just move the noise onto the boil. The fold is not
    -- predictable from the reagent list, so it is not predicted.
    --
    -- CEILING     one filter per reagent, nothing folded.
    -- FOLD_FLOOR  every contained reagent folded into its container.
    --
    -- Between the two is DF being DF and is not a fault. Above the
    -- ceiling is the growth bug, which is what the shrink recovery
    -- below exists for. Below the floor is genuine loss.
    local ceiling, fold_floor = 0, 0
    pcall(function()
        ceiling = #ghost.reagents
        fold_floor = ceiling
        for _, r in ipairs(ghost.reagents) do
            if r.flags.IN_CONTAINER then
                fold_floor = fold_floor - 1
            end
        end
    end)
    if ceiling < 1 then return -1, -1 end

    -- ---- FUEL FILTERS STAND OUTSIDE THE BAND ----
    -- Marked once, up front, by index. Every fuel filter is skipped by
    -- the material restore below, left out of the count the shrink and
    -- the band check compare, and never erased. See FUEL FILTERS ARE
    -- NOT THE GHOST'S above. The marks stay valid through the shrink,
    -- because it only ever erases from the end.
    local fuel_at, n_fuel = {}, 0
    pcall(function()
        local els = job.job_items.elements
        for i = 0, #els - 1 do
            if is_fuel_filter(els[i]) then
                fuel_at[i] = true
                n_fuel = n_fuel + 1
            end
        end
    end)

    pcall(function()
        local els = job.job_items.elements

        -- ---- RESTORE FILTERS TO THE AUTHOR ----
        -- History, because this block has now been wrong in both
        -- directions. The JIT clone is specialised per creature, and
        -- on a re-post DF rebuilds job_items from the CLONE, so a
        -- corpse job inherited an exact tissue and race lock and
        -- waited forever beside a fort full of other creatures'
        -- parts. The first fix wiped every filter to WILDCARD, which
        -- killed that stall and quietly erased every gate an author
        -- had declared: the filter is the only lock DF honours when
        -- fetching, so wiping it is how a dried dung job ate wet
        -- piles. Proven on job 466, five dried and three wet in one
        -- burn.
        --
        -- The principle that survives both failures: filters mirror
        -- the BASE reaction, never the clone and never the wildcard.
        -- The base says -1 for corpses, so the race lock stays dead.
        -- The base says dried dung for CHAR_DUNG_DRIED, so the gate
        -- survives the repair. This only holds because the engine
        -- now actually resolves mat_id onto base reagents; with no
        -- base in hand the old wildcard wipe is kept, since a stale
        -- clone lock is worse than an open filter.
        --
        -- Every poll rather than only on change, because DF
        -- re-materialises filters whenever it likes and we do not
        -- get to see when.
        -- ---- AN OCCUPIED SLOT IS NOT SEEKING ----
        -- The stall this block prevents happens on a RE-POST, when DF
        -- rebuilds job_items from the clone and inherits its race
        -- lock. A re-post starts with nothing attached, so the repair
        -- still does its whole job if it skips slots that already
        -- hold their item.
        --
        -- Skipping them stops it destroying a seal another watcher put
        -- there on purpose. MEASURED: the rot watcher sealed job 25's
        -- filter to `mat=21/296`, rotten wolf meat, and this loop
        -- wrote it back to `mat=-1/-1` because RETORT_ROT's base
        -- declares no material. The demand was then re-raised
        -- elsewhere and DF filled it with a chopped naked mole dog
        -- liver, which is not rotten and was never consumed.
        --
        -- It is also what R19 did: 0/8 stamped onto an occupied corpse
        -- slot, which cancelled the job. Both faults are this loop
        -- writing a material onto a slot whose item had already
        -- arrived.
        local occupied = {}
        pcall(function()
            for _, iref in ipairs(job.items) do
                local ix = iref.job_item_idx
                if ix and ix >= 0 then occupied[ix] = true end
            end
        end)

        for i = 0, #els - 1 do
            -- A fuel filter keeps its own material. It has no owner, so
            -- the positional fallback below would stamp a base reagent's
            -- material onto it, locking the fuel slot to that material
            -- on any reaction with enough reagents. Caught before access
            -- widens it, the same write would also wipe the COAL that
            -- marks it as fuel, and access would never find it.
            if occupied[i] or fuel_at[i] then goto next_filter end
            pcall(function()
                -- Each filter names its owner: reagent_index. The old
                -- loop mapped by position, which is only true when
                -- filters are one to one with reagents. Under the
                -- fold, filter 0 is the CONTAINER filter (owner
                -- reagent 1), and mapping by position stamped the
                -- tar reagent's material onto it every poll. Proven
                -- in a live dump: the ghosted container filter
                -- carried 0/-1 while the native one carried -1/-1.
                local mt, mi = -1, -1
                local ri = -1
                pcall(function() ri = els[i].reagent_index end)
                if base and ri >= 0 and ri < #base.reagents then
                    mt = base.reagents[ri].mat_type
                    mi = base.reagents[ri].mat_index
                elseif base and ri < 0 and i < #base.reagents then
                    -- No owner recorded on this build: the old
                    -- positional read, kept as the fallback.
                    mt = base.reagents[i].mat_type
                    mi = base.reagents[i].mat_index
                end
                els[i].mat_type  = mt
                els[i].mat_index = mi
            end)
            ::next_filter::
        end

        -- ---- SHRINK ONLY ----
        -- Recovery from a save made while the growth bug was live, or
        -- from the old collection build. Back to front, so surviving
        -- indices and the reagent_index each filter carries do not
        -- shift underneath the job.
        -- ---- NEVER SHRINK PAST AN OCCUPIED FILTER ----
        -- Shrinking is a recovery path, and pulling a filter out from
        -- under an item that is sitting in it is not recovery. A job
        -- reverted onto a base with fewer reagents than it has
        -- attached items reaches here holding all of them, and erasing
        -- those slots would leave every item above the cut pointing at
        -- a filter that no longer exists.
        --
        -- The occupied floor is the highest occupied slot plus one. If
        -- that is above the ceiling the job keeps its shape and says
        -- so, which is a state worth seeing rather than one to quietly
        -- force.
        --
        -- SHRINK TO THE CEILING, NEVER TO THE FOLD FLOOR. The ceiling
        -- is one filter per reagent, a shape DF posts every day and
        -- this fort completes every day. Shrinking to the fold floor
        -- would have erased a legitimate unfolded filter off any still
        -- caught before its hauler arrived, and the only reason that
        -- never fired is that DISTIL_TAR_COAL happened to be fully
        -- attached on every poll we ever looked at. The occupied guard
        -- was carrying a rule that should never have needed it.
        local floor_idx = -1
        pcall(function()
            for _, iref in ipairs(job.items) do
                local ix = iref.job_item_idx
                if ix and ix > floor_idx then floor_idx = ix end
            end
        end)
        local floor = floor_idx + 1

        -- The legal count is the reagents plus the fuel filters the job
        -- carries, so fuel alone never reads as growth.
        local target = ceiling + n_fuel
        if #els > target then
            if target < floor then
                log_once('noshrink:' .. tostring(job.id), 'WARNING', string.format(
                    'FILTER REPAIR: job %d has %d filters against %d'
                    .. ' reagent(s), but %d of them are occupied. NOT'
                    .. ' shrinking; an attached item must never lose the'
                    .. ' slot it is standing in.',
                    job.id, #els, ceiling, floor), 'FILTER')
            elseif fuel_at[#els - 1] then
                -- Growth sitting BELOW a fuel filter. Reaching it would
                -- mean erasing mid vector or erasing the fuel, and
                -- neither is this repair's to do, so it says so once.
                log_once('fuelshrink:' .. tostring(job.id), 'WARNING', string.format(
                    'FILTER REPAIR: job %d has %d filters against %d'
                    .. ' reagent(s) and %d fuel, with a fuel filter last.'
                    .. ' NOT shrinking; fuel filters are never the'
                    .. ' ghost\'s to erase.',
                    job.id, #els, ceiling, n_fuel), 'FILTER')
            else
                -- INFO: a job left grown by an earlier build, repaired. Nothing for
                -- the player to do.
                log('INFO', string.format(
                    'FILTER REPAIR: job %d had %d filters against %d'
                    .. ' reagent(s) and %d fuel. Shrinking. This job was'
                    .. ' left grown by an earlier build.',
                    job.id, #els, ceiling, n_fuel), 'FILTER')
                -- Off the end only, and never through a fuel filter.
                while #els > target and not fuel_at[#els - 1] do
                    els:erase(#els - 1)
                end
            end
        end
    end)

    local n_f, n_r = -1, -1
    pcall(function()
        n_f = #job.job_items.elements
        n_r = #ghost.reagents
    end)

    -- Reporting one number and calling it "slots" is what hid a
    -- filters-2 reagents-1 job for two rounds. The comparison is now
    -- against the BAND, because a single expected number is a
    -- prediction about DF's fold and DF does not honour it. The boil
    -- sits on the floor at 1 of 2, the still sits on the ceiling at 3
    -- of 3, and both are correct. Only a count outside the band is a
    -- shape neither the author nor DF ever asked for.
    -- Fuel filters stand outside the band: DF's own one and the
    -- surcharge copies belong to no reagent, so only the rest is the
    -- authored shape being checked.
    local n_core = n_f - n_fuel
    if n_core < fold_floor or n_core > ceiling then
        -- WARNING, once per job and shape: this runs on every poll,
        -- several times a second, for as long as the desync lasts.
        log_once('desync:' .. tostring(job.id) .. ':' .. tostring(n_f),
            'WARNING', string.format(
            'SLOT DESYNC: job %d filters=%d (%d fuel) outside'
            .. ' %d..%d (reagents=%d).',
            job.id, n_f, n_fuel, fold_floor, ceiling, n_r), 'FILTER')
    end

    return n_f, n_r, n_fuel
end

-- ==========================================
-- JIT CONFIGURATION
-- ==========================================
-- Which reactions are adaptive, and what their products mean.
--
-- DERIVED AT START from the same reactions table making_fuel.lua
-- hands the engine, never hand written. A reaction is adaptive
-- exactly when every product count in its JSON is zero, because a
-- zero count is the reaction declaring that something else fills
-- it in. Profile falls out of the FIRST product, which is the
-- primary: a coal bar is the charcoal chain, an ash bar is the ash
-- chain, a lone kindling product is the split chain. Creature
-- keying falls out of the reagents.
--
-- The secondary slot is read from its fixed position and CHECKED:
-- slot 3 of a charcoal reaction must be BAR_ASH, slot 1 of an ash
-- reaction must be BAR_COAL. A reaction missing the slot pays its
-- primary only and is named once at start; a reaction with the
-- wrong product type in the slot is a fault, named at level 0, and
-- its secondary is not paid rather than written into whatever
-- happens to sit there.
--
-- This used to be three hardcoded lists regenerated by hand, and
-- the hand missed: three JSON renames once left the leather and
-- shield reactions consuming items and paying NOTHING, with totals
-- that still looked right, and a later addition never made it into
-- the list at all. Derivation makes both failures impossible. Edit
-- the JSON and the ghost follows. Add a reaction, it is covered.
-- Delete one, it is forgotten.
--
-- STILL FIXED, and deliberately so:
--   CHAR_CHAR_BOULDER is the packing ladder itself. Its fixed
--   counts (3 charcoal and 4 cinders) are the definition of what a
--   char boulder is worth, and making it adaptive would desync the
--   raws from CHARCOAL_PER_BOULDER. CHAR_CINDERS was removed
--   (2026-09-28), and CHAR_CHAR_BLOCKS never existed in play.
--   CHAR_CLOTH, CHAR_PLANT_CLOTH and CHAR_THREAD report a flat
--   volume and need getTotalDimension, which is a different read.
--   None of them declare zero counts, so none of them derive, and
--   none of them pay a secondary.
--
-- Creature keyed reactions key on race and caste rather than on
-- material, because a corpse's mat_index is the creature but its
-- mat_type is whichever tissue dominates. The same dwarf appears
-- as BONE on one corpse and SKIN on another, so keying on material
-- alone scatters one creature across several ghosts and lets two
-- creatures collide on a shared tissue. Any reaction eating a
-- corpse, corpse piece or remains gets this treatment, read
-- straight from its reagent type.
-- ==========================================
local CREATURE_REAGENTS = {
    CORPSE = true, CORPSEPIECE = true, REMAINS = true,
}

-- Every reaction key the MODULE DECLARED, adaptive or not. JIT_CONFIG
-- holds only the adaptive ones, so "no config" on its own cannot tell
-- a deliberately flat reaction from a runtime clone whose maker forgot
-- register_alias. This set is the discriminator.
--
-- AUTHORED means the key came out of the module's own reactions table.
-- A flat authored reaction paying its declared counts is the design:
-- CALCINE_GREEN_COKE is 16 breeze to 4 coke to 1 green coke and is
-- meant to be deterministic, exactly as char is. Roughly 77 of the 432
-- reactions are flat on purpose, and every one of them used to fire a
-- level 0 warning saying it pays nothing.
--
-- Rebuilt by derive_config on every data cycle alongside JIT_CONFIG,
-- so the two can never drift apart.
local AUTHORED    = {}
local JIT_CONFIG  = {}
local cached_rxns = nil

-- ---- WHOSE IS IT, AND SWITCHING TO IT ----
-- Declared here, after every piece of provider state they switch, and
-- before the first function that calls them.
-- The module whose reaction prefix a code carries, or nil.
local function prefix_owner(code)
    for owner, P in pairs(PROVIDERS) do
        if P.prefix ~= '' and code:sub(1, #P.prefix) == P.prefix then
            return owner
        end
    end
    return nil
end

-- Switches the file level provider state to owner's. The drain
-- material cache is the one piece built lazily, so it is saved back to
-- the provider it came from before switching away.
local function use(owner)
    if owner == nil then return false end
    if owner == CURRENT then return true end
    local P = PROVIDERS[owner]
    if not P then return false end
    V, MODULE_PREFIX, yield_bank = P.V, P.prefix, P.bank
    -- The vessel half binds to the same module, keeping its own lazily
    -- built drain material cache in the module's record.
    if VS then VS.use(P) end
    CURRENT = owner
    return true
end

-- The module a code belongs to: its config's owner, else its prefix.
local function owner_of(code)
    local c = code and JIT_CONFIG[code]
    if c and c.owner then return c.owner end
    return code and prefix_owner(code) or nil
end


-- SECONDARY_SLOT moved to making-fuel-adaptive-valuation with config_for,
-- the one thing that reads it.

-- Rebuilds JIT_CONFIG from the module's reactions table. Returns
-- three lists of reaction keys so start() can name them out loud
-- instead of letting them pay nothing in silence: adaptive but
-- recognizable by no chain; recognized but with no secondary slot;
-- recognized with the wrong product in the secondary slot.
local function derive_config(rxns)
    -- Only this provider's entries are replaced: every other module's
    -- configs stay exactly as they are.
    for code, c in pairs(JIT_CONFIG) do
        if c.owner == CURRENT then JIT_CONFIG[code] = nil end
    end
    for code, owner in pairs(AUTHORED) do
        if owner == CURRENT then AUTHORED[code] = nil end
    end
    local skipped, no_secondary, bad_layout = {}, {}, {}
    for _, r in ipairs(rxns or {}) do
        -- Recorded BEFORE the adaptive test, because the flat ones are
        -- the whole reason this set exists. Same key shape JIT_CONFIG
        -- uses below, so a lookup that finds one finds the other.
        AUTHORED[MODULE_PREFIX .. tostring(r.key)] = CURRENT

        local prods = r.products or {}
        local adaptive = #prods > 0
        for _, p in ipairs(prods) do
            if (p.count or 1) ~= 0 then adaptive = false end
        end
        -- WATCHER OWNED IS NOT ADAPTIVE. A zero COUNT means the engine
        -- fills the count in. A zero PROBABILITY means nothing is ever
        -- minted at all: a watcher does the whole job, and the product
        -- exists only because refinish-module-validate.lua:675 refuses
        -- an empty products array.
        --
        -- Checked against the module (2026-09-26): the reactions whose
        -- every product is at probability 0 are FILL_TANK,
        -- INSTALL_BURNER, INSTALL_ATOMISER and DISTIL_ETHANOL, watcher
        -- owned and paying nothing here. They were never meant to be
        -- paid. They stay AUTHORED, recorded above, so they
        -- read as deliberately flat rather than as faults.
        if adaptive then
            local silent = true
            for _, p in ipairs(prods) do
                if (p.probability or 100) ~= 0 then silent = false end
            end
            if silent then adaptive = false end
        end
        if adaptive then
            local creature = false
            for _, a in ipairs(r.reagents or {}) do
                if CREATURE_REAGENTS[a.type] then creature = true end
            end

            -- ---- WHAT IT IS: THE MODULE'S TO SAY ----
            -- The profile and its slots come from the valuation
            -- (config_for in making-fuel-adaptive-valuation). The engine
            -- keeps the creature keying, read from the reagent types above,
            -- and the storing.
            local cfg, problem = V.config_for(r)
            if not cfg then
                table.insert(skipped, tostring(r.key))
            else
                cfg.is_creature = creature
                cfg.owner = CURRENT
                if problem and problem.no_secondary then
                    table.insert(no_secondary, tostring(r.key))
                end
                if problem and problem.bad_layout then
                    table.insert(bad_layout, problem.bad_layout)
                end
                JIT_CONFIG[MODULE_PREFIX .. r.key] = cfg
            end
        end
    end
    return skipped, no_secondary, bad_layout
end

local ghost_cache     = {}
local last_ram_loaded = nil

-- ==========================================
-- COMPLETION AUDIT
-- ==========================================
-- [job.id] = snapshot of the last poll that saw this job holding
-- items. When a job id stops being refreshed, that cycle is over and
-- this holds the state it had.
--
-- It is also where the bank is settled, because this is the only point
-- at which we know whether the job burned or died.
--
--   worked  true if job.flags.working was EVER observed set during
--           this cycle. A completed job always sets it; a cancelled
--           job never does. This is the burn test.
--   ids     item ids, checked as a second opinion.
--   paid    value the written products represent.
-- ==========================================
local audit_state = {}
local audit_tick  = 0

-- Job ids seen in world.jobs.list on the current poll. A snapshot can
-- only be called cancelled if its job is NOT here: a job that is still
-- in the list is still running, however long it takes. Without this
-- the sweep declared NOT CONSUMED on live jobs that simply went two
-- ticks without a refresh, then logged BURNED ten seconds later.
local live_jobs = {}

-- Forward declaration. handle_ghosted settles the previous cycle, and
-- settle is defined after it because it reads the bank and the log
-- helpers that sit between them.
local settle

-- ==========================================
-- READ THE INPUT MATERIAL
-- ==========================================
-- Identifies what walked in, which decides which ghost this job gets.
--
-- One branch, not four. Every reaction in this file resolves through
-- matinfo.decode, which reads the item's material FIELDS rather than
-- calling getMaterial, and those fields are populated even on corpses
-- where the accessor returns -1.
-- ==========================================
local function read_input_material(job)
    for _, iref in ipairs(job.items) do
        local item = iref.item
        if item then
            local mat_type, mat_index = -1, -1
            local nice_name = ''
            pcall(function()
                local mi = dfhack.matinfo.decode(item)
                if mi then
                    mat_type  = mi.type
                    mat_index = mi.index
                end
            end)
            pcall(function()
                nice_name = dfhack.items.getDescription(item, 0)
            end)
            if nice_name == '' then nice_name = 'item' end
            return mat_type, mat_index, nice_name
        end
    end
    return nil, nil, nil
end

-- ==========================================
-- GHOST COMPILER
-- ==========================================
-- Deep copies the base reaction into a new reaction owned by one job,
-- so that job's product counts can be rewritten without touching any
-- other job running the same reaction.
--
-- Ghosts accumulate in the reactions array for the session and carry
-- the module prefix so the shutdown sweep collects them.
-- ==========================================
local function build_ghost_jit(base_code, ghost_code, mat_type, mat_index)
    local base_rxn = find_rx(base_code)   -- ONE LOOKUP, NOT ONE WALK
    if not base_rxn then return false end

    local reactions_array = df.global.world.raws.reactions.reactions
    local rxn = df.reaction:new()
    rxn:assign(base_rxn)
    rxn.code = ghost_code

    -- The base reaction's name is kept. Renaming would be right if the
    -- input were chosen, but every reaction here takes whatever turns
    -- up, and naming a job after the first thing through the door is a
    -- label that stops being true on the next cycle.

    -- Keep the ghost out of the workshop UI menus.
    rxn.building.type:resize(0)
    rxn.building.subtype:resize(0)
    rxn.building.custom:resize(0)

    -- Deep copy reagents and products. assign() on the reaction copies
    -- these vectors BY REFERENCE, so without this the ghost and the
    -- base share them and every product write would reach the base
    -- reaction and every other job running it.
    rxn.reagents:resize(0)
    for _, old_r in ipairs(base_rxn.reagents) do
        local r_new = old_r._type:new()
        r_new:assign(old_r)
        rxn.reagents:insert('#', r_new)
    end
    rxn.products:resize(0)
    for _, old_p in ipairs(base_rxn.products) do
        local p_new = old_p._type:new()
        p_new:assign(old_p)
        rxn.products:insert('#', p_new)
    end

    -- Lock the material into the clone's reagent, which drives
    -- completion. Filters are unlocked again in normalize_slots,
    -- because filters drive collection.
    if rxn.reagents[0] then
        rxn.reagents[0].mat_type  = mat_type
        rxn.reagents[0].mat_index = mat_index
    end

    -- Reagent COUNT is left exactly as the base reaction declares it.
    -- Nothing decides how much a job consumes any more: one item per
    -- job, fraction banked between jobs.

    rxn.index = #reactions_array
    reactions_array:insert('#', rxn)
    ghost_cache[ghost_code] = rxn

    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)
    log('DETAIL', 'JIT Compiled: ' .. ghost_code .. ' (' .. tostring(rxn.name) .. ')', 'JIT')
    return true
end

-- ==========================================
-- PER JOB HANDLING
-- ==========================================
-- Runs on every poll that sees a ghosted job holding at least one
-- item, and once more immediately after a swap so a job that finishes
-- inside the ten frame poll gap still gets correct products.
--
-- Products are written BEFORE slots are normalised, so if normalising
-- is what lets the job complete, the counts it completes on are
-- already right.
-- ==========================================
local function handle_ghosted(job, base_code)
    local ghost = ghost_cache[tostring(job.reaction_name)]
    if not ghost then return end
    if #job.items < 1 then return end
    -- SECTION CLOCK (refinish-section-probe): a lap between the sections
    -- below, quiet while the probe is off. A return part way leaves the
    -- later laps unrecorded, which is right: those sections did not run.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()

    -- BEFORE anything reads a reagent. Everything below indexes
    -- ghost.reagents by a filter's reagent_index, so a ghost that
    -- cannot describe the job has to be made able to first. Cheap and
    -- idempotent: on a job whose shapes already agree it is one length
    -- comparison and a return.
    VS.reconcile_reagents(job, ghost)
    if sc then t0 = sc.lap('ghosted: reconcile reagents', t0) end

    -- The poll only sends jobs whose base has a config, so the
    -- fallback is belt and braces: plain charcoal, no secondary.
    local cfg     = JIT_CONFIG[base_code]
                    or { profile = V.DEFAULT_PROFILE, is_creature = false }
    local profile = cfg.profile

    -- THE SAME ITEMS AS THE LAST POLL: whether this poll holds what the
    -- last one did, for the three parts below that are skipped if so.
    --
    -- ---- ONE IDENTITY A POLL ----
    -- Built here once, for this record and for the valuation memo in
    -- apply_banked_yield (THE HELD ITEMS, PRICED ONCE), which takes it as
    -- an argument. Until 2026-10-01 each built its own, a second read of
    -- every held item each poll (MEASURED in A DIMENSION, READ WITHOUT A
    -- THROW). The valuation keys on it for every profile but those that
    -- carry tars; this record also leaves out drains.
    local tr = V.traits(profile)
    local held_key = nil
    if not tr.carries_tars then held_key = held_identity(job) end
    local steady_key = nil
    if not tr.drains then steady_key = held_key end
    local st = steady_key and steady[job.id]
    local same = st and st.key == steady_key and st.ghost == ghost or false

    -- ---- A STACK BURNS WHOLE ----
    -- THE RULE: if a feed item holds several units, the job takes all
    -- of them in one run. Nobody sits through forty runs for one
    -- output, and a player only has to learn one behaviour: whole
    -- stacks burn and the output matches the arithmetic.
    --
    -- DF consumes the reagent's QUANTITY per completion, so a
    -- quantity of 1 against a stack of fourteen took fourteen runs.
    -- Raising the quantity to the stack's own count collapses that to
    -- one run, and on a corpsepiece it fixes three separate faults at
    -- the same time:
    --
    --   The valuation credits the WHOLE pile every run, because the
    --   stack fraction reads stack_size and a corpsepiece pins that
    --   at 1, so it never divides. Measured at 8.7x over five runs.
    --   The pile SURVIVES each completion, so settle's burn test,
    --   which asks whether the item vanished, its stack shrank or its
    --   dimension dropped, answers no to all three and reads NOT
    --   CONSUMED.
    --   NOT CONSUMED never debits, so a payout that fired was free.
    --   Measured at six free jugs of bone oil off one buffalo.
    --
    -- Consuming the pile whole makes the item VANISH, which settle
    -- already detects, and makes crediting the whole pile correct,
    -- because the whole pile really did burn. Proven in game on a 14
    -- bone water buffalo stack: item gone, ledger BURNED, every bank
    -- carried, all eight figures reconciled to six decimals.
    --
    -- WHERE THE COUNT LIVES, and it is not one field:
    --   CORPSEPIECE  material_amount. stack_size is pinned at 1, so
    --                reading it sees a pile of fourteen as a single
    --                bone. This is the case that hid the bug.
    --   everything   stack_size, the ordinary count. Plants, meat,
    --   else         fish and cheese all work this way.
    --
    -- NOT COVERED, deliberately: items that carry their amount in
    -- DIMENSION rather than a count, meaning thread and cloth. They
    -- read stack_size 1, so the guard below skips them and they keep
    -- their existing behaviour. Whether a dimensioned item can be
    -- consumed whole the same way is UNMEASURED, and it is not being
    -- guessed at here.
    --
    -- BOTH SIDES, TOGETHER. The reagent drives completion and the
    -- job_item filter drives collection. RM_Adaptive_Reactions
    -- records raising a reagent alone as a confirmed deadlock, which
    -- is why both move together. That case was also a different
    -- shape: it gathered several SEPARATE items and the dwarf could
    -- not haul enough. One stack is one item already in hand, so
    -- there is nothing further to fetch.
    --
    -- SCOPE:
    --   Slots holding a stack of 2 or more only, so a single skull,
    --   limb or plant keeps whatever its reaction asked for. CHAR_SKULL
    --   and ASH_SKULL ask for ten single skulls by design and are
    --   untouched, and so is any slot holding only singles.
    --   A SLOT'S WHOLE CONTENTS (2026-10-05). The quantity is everything
    --   the slot holds, every stack summed. Until then the first item
    --   decided it, which was right while a reagent declaring several
    --   items (dung at 8, kindling at 8) only ever gathered singles.
    --   Once kindling stacked, CHAR_KINDLING gathered stacks of 2, 2, 3
    --   and 5 for its demand, the first set the quantity to 2, and the
    --   run burned 2, credited 2, and left 10 attached (job 1386,
    --   2026-10-05). Summed, everything the dwarves hauled burns and is
    --   paid for, as one stack always was.
    --   The feed slot only, reagent 0 (THE FEED ONLY, below). Preserved
    --   vessels are skipped explicitly; they also read 1 and would be
    --   skipped anyway, but relying on that would be an accident rather
    --   than a rule.
    --   Inside handle_ghosted, which runs for adaptive jobs only. A
    --   static reaction pays a fixed output, so consuming more would
    --   be pure loss. BOIL_BONE_GLUE is static, never ghosted, and
    --   never reaches this.
    --
    -- Re-read every poll rather than set once, because a repeat job
    -- keeps its id across cycles and the next stack is a different
    -- size. Setting it at swap would demand fourteen from a stack of
    -- six.
    --
    -- KNOWN BOUND: a stack large and dense enough to earn more than
    -- one package of a liquid banks the surplus, because a reaction
    -- declares one output container per liquid slot. Measured: every
    -- bone stack up to a cow fits in one jug, a water buffalo earns
    -- 1.14 and drains the remainder on the next carcass, and only
    -- elephants, dragons and large dense plant stacks exceed that.
    -- Multi vessel output is the fix for those and is separate work.
    --
    -- Skipped on the same items as the last poll (THE SAME ITEMS AS THE
    -- LAST POLL): the count it would read has not changed.
    if not same then pcall(function()
        -- Each reagent slot's whole contents (A SLOT'S WHOLE CONTENTS):
        -- units summed over every item in it, how many items, whether
        -- any is a stack, and the first item, for the log.
        local slot_n, slot_items, slot_stack, slot_first = {}, {}, {}, {}

        for _, iref in ipairs(job.items) do
            local it = iref.item
            if slot_preserved(job, ghost, iref) then goto next_q end
            local idx = iref.job_item_idx
            if not idx or idx < 0 then goto next_q end

            -- ---- THE FEED ONLY ----
            -- Only the feed, reagent 0, burns whole. Any other consumed
            -- slot is an additive taken by its declared quantity: the
            -- fluxed retorts' 25 flux dust, the sawdust in compost and
            -- manure. Raising those to their stack ate whole stacks of
            -- them (measured 2026-10-06: a compost job took all 6
            -- sawdust). DISTIL_TAR and DISTIL_OIL's second jug is feed
            -- too, but a jug holds exactly its declared 150, so the rule
            -- never raised it and this changes nothing there.
            local fri = nil
            pcall(function() fri = job.job_items.elements[idx].reagent_index end)
            if fri ~= 0 then goto next_q end

            -- How many units this one item holds.
            local n = 1
            if it:getType() == df.item_type.CORPSEPIECE then
                n = 0
                local ma = it.material_amount
                for i = 0, #ma - 1 do
                    if ma[i] > n then n = ma[i] end
                end
            else
                -- ---- A DIMENSIONED FEED BURNS WHOLE TOO ----
                -- THE RULE IS THE SAME ONE: whatever the dwarf is
                -- holding, burn all of it. Nobody scoops a spoonful
                -- out of a glob forty times.
                --
                -- Thread, cloth and globs carry their amount in
                -- DIMENSION, not in stack_size, so `n` has to be read
                -- from the field that actually holds it. Writing a
                -- stack count into a dimension quantity is nonsense:
                -- RETORT_GLOB asks for 150, which is ONE glob by the
                -- vanilla convention, and a glob reading stack_size 2
                -- would have rewritten that 150 into 2 and collapsed
                -- the demand to almost nothing.
                --
                -- THIS ALSO CLOSES AN OVER CREDIT, which is the real
                -- reason it is worth doing rather than just skipping
                -- these items. The stack fraction below divides by
                -- stack_size, and a dimensioned item pins that at 1,
                -- so frac is 1 and the valuation credits the WHOLE
                -- item. getVolume scales with the amount held. So a
                -- 300 dimension glob was being priced at 300 while
                -- the reaction consumed 150. Same shape as the
                -- corpsepiece fault, which was measured at 8.7x.
                -- Consuming the whole makes credit and consumption
                -- agree instead of papering over the gap.
                --
                -- Settle already copes: untouched() watches dimension
                -- as well as stack, so a drained glob reads BURNED.
                --
                -- pcall because reading .dimension on an item without
                -- the field raises, and a failed read means this is an
                -- ordinary counted item.
                -- MEASURED, water buffalo fat, job 15: the item read
                -- "[9]", getVolume 540, and one run took it to "[8]"
                -- with getVolume 480. Sixty volume per unit, and the
                -- reagent asked for 150 and got exactly one unit.
                --
                -- So a glob is BOTH: stack_size holds how many, and
                -- dimension holds how big each one is. Reading only
                -- dimension gave 150, which already equalled what the
                -- reaction asked for, so the guard wrote nothing and
                -- the stack burned one unit per run. That was my
                -- error in the previous round.
                --
                -- The total the dwarf is holding is stack times
                -- dimension, and the quantity DF consumes is counted
                -- in dimension units, which is why 150 removed one
                -- unit of nine. So 9 x 150 asks for the whole pile.
                --
                -- Thread and cloth fall out of the same arithmetic: a
                -- single item at stack 1 gives 1 x 15000, which is
                -- what those reactions already ask for, so nothing
                -- changes for them unless a stacked one turns up.
                --
                -- pcall because reading .dimension on an item without
                -- the field raises, and a failed read means this is an
                -- ordinary counted item like meat or bone.
                local sz, dim = 1, nil
                pcall(function() sz = it.stack_size or 1 end)
                -- A DIMENSION, READ WITHOUT A THROW: nil for a class
                -- without the field, as the failed read gave.
                local okd, dmv = pcall(dimension_of, it)
                if okd then dim = dmv end
                if dim and dim > 0 then
                    n = sz * dim
                    -- ---- SAY IT EVERY TIME, NOT ONLY ON A CHANGE ----
                    -- The log below only speaks when the quantity
                    -- actually moves, which is exactly why the fat
                    -- defect was invisible: it read 150, matched, and
                    -- said nothing. This territory is unexplored, so
                    -- every dimensioned item reports what it is made
                    -- of whether or not anything is done about it.
                    log_once('dimfeed:' .. job.id .. ':' .. it.id, 'DETAIL', string.format(
                            'STACK: #%d is a dimensioned feed, stack %d'
                            .. ' at dimension %d, so %d unit(s) held in'
                            .. ' total.', it.id, sz, dim, n), 'STACK')
                else
                    n = sz
                end
            end
            do
                -- ---- ONE SLOT, ONE QUANTITY: ITS WHOLE CONTENTS ----
                -- Summed into the slot, decided once below. Each visit
                -- writing its own item's size made the quantity flip
                -- between items forever while the rot watcher pushed it
                -- back from the other side (MEASURED, job 25: a [20] and
                -- a [5] in one slot logged that pair over a hundred
                -- times in a run). One sum per slot cannot flip.
                local ri = job.job_items.elements[idx].reagent_index
                slot_n[ri] = (slot_n[ri] or 0) + n
                slot_items[ri] = (slot_items[ri] or 0) + 1
                if n >= 2 then slot_stack[ri] = true end
                slot_first[ri] = slot_first[ri] or it.id
            end
            ::next_q::
        end

        for ri, n in pairs(slot_n) do
            -- A slot holding only singles keeps its declared quantity.
            if slot_stack[ri] and ghost.reagents[ri].quantity ~= n then
                ghost.reagents[ri].quantity = n

                -- ---- THE JOB ITEM QUANTITY IS NOT WRITTEN ----
                -- It used to be set to n alongside the reagent, and
                -- that is what made a burn fetch a SECOND stack it
                -- then never consumed.
                --
                -- The two fields do different jobs, and this file
                -- already measured which: "consumption per completion
                -- is the RAWS reagent quantity (measured: one unit per
                -- cycle even with the job item zeroed) ... the job
                -- item quantity only governs SEEKING." So raising the
                -- reagent is what burns the whole stack, and raising
                -- the job item only tells DF to go and get more.
                --
                -- It does not even count what is already there. An
                -- attached stack in transit contributes nothing toward
                -- the demand, so a stack of five raised the demand to
                -- five, counted the stack as zero, and sent a dwarf
                -- for another five. On completion the reagent took its
                -- five out of the first stack and the second was left
                -- attached and untouched.
                --
                -- ON THE ROT REACTION IT IS WORSE. The rot watcher
                -- seals the filter to the chosen item's exact type and
                -- material and then zeroes this same field for exactly
                -- this reason (making-fuel-rot-watcher.lua:482). This
                -- write landed afterwards and undid it, so the demand
                -- came back on a filter that now reads "meat of that
                -- material" and DF happily fetched FRESH meat to fill
                -- it.
                --
                -- Left alone rather than zeroed. Zeroing is right when
                -- the filter is already satisfied, which is the rot
                -- watcher's situation, but a declared multi item
                -- reagent like dung at quantity 8 may still be
                -- collecting, and zeroing would strand it half filled.
                log('DETAIL', string.format(
                    'STACK: job %d takes all %d in slot %d (%d item(s), first #%d) in one run',
                    job.id, n, ri, slot_items[ri] or 0, slot_first[ri] or -1), 'STACK')
            end
        end
    end) end

    if sc then t0 = sc.lap('ghosted: stack rule', t0) end
    -- ---- CURRENT ITEM IDENTITY ----
    -- A repeat job keeps its id forever, so the id alone cannot say
    -- whether this is the same run continuing or a fresh one that has
    -- already replaced the last. The item ids can.
    -- Stack size is recorded alongside the id because DF does not
    -- always destroy a consumed reagent. CHAR_PLANT takes 15 from a
    -- stack of 20 amaranths and leaves 5, so the item survives with a
    -- smaller stack. Testing existence alone reads that as "nothing
    -- was consumed" and the bank never gets credited for value that
    -- was very much burned.
    local ids, stacks, dims, contents = {}, {}, {}, {}
    -- THE SAME ITEMS AS THE LAST POLL: the tables that poll built. A drain
    -- never takes this (steady_key is nil for it), so the drain block
    -- below always runs for one.
    if same then
        ids, stacks, dims, contents = st.ids, st.stacks, st.dims, st.contents
    end

    -- ---- DRAIN WITNESS ----
    -- A drain consumes nothing, so the ordinary ledger stays empty and
    -- untouched() can never return false: the cycle would pay out and
    -- never settle, which is R2, a free payout, at scale.
    --
    -- But a vessel goes in EMPTY and comes out FULL, and that is just
    -- as observable as a feed vanishing. So the vessels themselves are
    -- the witness here, recorded with the number of items inside them.
    -- Same idea as the boil's pitch witness: a profile is allowed its
    -- own way of filling the ledger, as long as it puts in something
    -- DF will actually change.
    --
    -- This is the ONLY place preserved slots enter the ledger, and it
    -- is gated on the profile so nothing else inherits it.
    if V.traits(cfg.profile).drains then
        pcall(function()
            for _, iref in ipairs(job.items) do
                local iid = iref.item.id
                table.insert(ids, iid)
                contents[iid] =
                    #(dfhack.items.getContainedItems(iref.item) or {})
            end
        end)
    end

    if not same then pcall(function()
        for _, iref in ipairs(job.items) do
            -- Preserved slots are contractually returned. Their
            -- survival is the design, not evidence that nothing
            -- burned, so they never enter the consumption ledger.
            -- Char never had a preserved slot, which is why this
            -- rule could sleep until the boil: its ONLY attached
            -- item is the preserved jug, and a ledger holding just
            -- the jug reads every burned tar as NOT CONSUMED.
            if not slot_preserved(job, ghost, iref) then
                local iid = iref.item.id
                table.insert(ids, iid)
                local sz = 1
                pcall(function() sz = iref.item.stack_size or 1 end)
                stacks[iid] = sz
                -- Liquids are consumed by DIMENSION, the way stacks
                -- are consumed by count. Record it where it exists
                -- so untouched() can see a drained jugful.
                -- A DIMENSION, READ WITHOUT A THROW: nil where the
                -- class has no such field, which records nothing.
                local okd, dmv = pcall(dimension_of, iref.item)
                if okd and dmv then dims[iid] = dmv end
            end
        end
    end) end
    if steady_key and not same then
        steady[job.id] = { key = steady_key, ghost = ghost, ids = ids,
                           stacks = stacks, dims = dims, contents = contents }
    end
    if sc then t0 = sc.lap('ghosted: item identity, drain witness', t0) end
    local id_key = table.concat(ids, ',')

    -- Did every item the snapshot recorded survive intact? An item
    -- that vanished, or one whose stack shrank, was consumed.
    local function untouched(s)
        if not s or not s.ids then return true end
        for _, iid in ipairs(s.ids) do
            local it = nil
            pcall(function() it = df.item.find(iid) end)
            if not it then return false end
            local sz = 1
            pcall(function() sz = it.stack_size or 1 end)
            if sz < ((s.stacks or {})[iid] or sz) then return false end
            -- The liquid twin of the stack rule above: a drained
            -- dimension is a consume, and so is an item DF has
            -- already flagged for cleanup but not yet removed.
            -- A DIMENSION, READ WITHOUT A THROW: nil where the class has
            -- no such field, as the failed read gave.
            local dm = nil
            local okd, dmv = pcall(dimension_of, it)
            if okd then dm = dmv end
            if dm and dm < ((s.dims or {})[iid] or dm) then
                return false
            end
            -- ---- A FILLED CONTAINER IS A FIRED CYCLE ----
            -- The drain's witness. Recorded only for PROFILE_DRAIN, so
            -- for every other reaction s.contents is empty and this
            -- test can never fire. A vessel that gained an item was
            -- poured into, and that is the cycle completing.
            -- Contents only count against a baseline, and only drains
            -- record one, so with none the contained items are not read:
            -- that read copies a vector, per item, per poll.
            local was = (s.contents or {})[iid]
            if was then
                local cn = nil
                pcall(function()
                    cn = #(dfhack.items.getContainedItems(it) or {})
                end)
                if cn and cn > was then return false end
            end

            local gc = false
            pcall(function() gc = it.flags.garbage_collect end)
            if gc then return false end
        end
        return true
    end

    local prev = audit_state[job.id]

    -- ---- SETTLE THE PREVIOUS CYCLE FIRST ----
    -- ORDER IS LOAD BEARING. This ran AFTER the valuation below, which
    -- meant the products were computed from a bank that had not yet
    -- been credited for the item the last cycle burned. The figure was
    -- permanently one item behind, and a job that completed before the
    -- next poll wrote its products from that stale number. The payout
    -- threshold was reached a cycle late and the value was already
    -- spent by then, so a bank that was filling correctly still
    -- produced nothing.
    -- ---- HAS THE PREVIOUS CYCLE ACTUALLY ENDED ----
    -- An id change alone does NOT mean a new cycle. A reagent with
    -- quantity above 1 gathers its items one at a time, so the id set
    -- changes on every arrival. Settling on that reported NOT CONSUMED
    -- once per item and buried the real ledger: bark logged it at one,
    -- two and three items before finally burning at four.
    --
    -- Growth is the old ids still being present. A genuinely new cycle
    -- means at least one of them is gone or reduced.
    local settled_now = false
    -- Same item id, smaller stack, is a completed cycle too. The old
    -- id-change test never fired while a job re-fed the same stack,
    -- so twenty one-unit burns settled once, at the end.
    if prev and prev.id_key and not untouched(prev) then
        settle(job.id, prev, true)
        audit_state[job.id] = nil
        prev = nil
        settled_now = true
    end

    if sc then t0 = sc.lap('ghosted: untouched test, settle', t0) end
    local streams, detail, inert, out, haul, pitch_witness =
        apply_banked_yield(job, ghost, base_code, cfg, held_key)
    if sc then t0 = sc.lap('ghosted: apply_banked_yield, whole', t0) end
    -- Deposit the witness where the verdict actually looks. These
    -- tables live HERE, in handle_ghosted; the valuation loop that
    -- finds the tar lives in apply_banked_yield and cannot reach
    -- them, which is precisely how three rounds of witness code ran
    -- without a single id arriving.
    for _, w in ipairs(pitch_witness or {}) do
        table.insert(ids, w.id)
        stacks[w.id] = w.stack
        -- ---- THE BASELINE IS TAKEN ONCE, AT COLLECTION ----
        -- dims is rebuilt from scratch on every poll, so writing w.dim
        -- outright replaces the opening reading with the current one
        -- and settle ends up comparing a value against itself.
        --
        -- prev is nil on the first poll of a cycle, because settling
        -- clears it, so that poll records the dimension as collected.
        -- Every later poll in the same cycle carries that value
        -- forward untouched. One snapshot per cycle, compared against
        -- what is left when the cycle closes.
        if w.dim then
            local opened = prev and prev.dims and prev.dims[w.id]
            dims[w.id] = opened or w.dim
        end
    end

    if sc then t0 = sc.lap('ghosted: pitch witness', t0) end
    -- ---- INERT REFUSAL ----
    -- A wood furnace cannot consume something that does not burn, so
    -- the item must come back out. Suspending is the only way to
    -- release it without a livelock: preserving the reagent and
    -- producing nothing also releases it, but then the repeat job
    -- re-posts and picks the same stone chair again forever.
    --
    -- This should be unreachable. The reagent's material gate stops DF
    -- selecting an inert item in the first place. A suspended job here
    -- means a reagent is missing its flag, which is a bug report, not
    -- a gameplay path.
    -- ---- ONCE PER JOB, NOT ONCE PER POLL ----
    -- A refusal is a terminal verdict. Re-asserting it six times a
    -- second means writing to a job's flags and re-reading its item
    -- list while DF is releasing those items, and that is what turned
    -- one malformed job into a crash: sixteen seconds of this at the
    -- end of the log, then a CTD in "Advancing unit moves".
    --
    -- The suspend write is skipped once the job already carries it, so
    -- nothing touches a job DF has already parked, and the report is
    -- keyed on the job so it is said exactly once.
    if inert then
        if V.setting('INERT_SUSPENDS_JOB') then
            local already = false
            pcall(function() already = job.flags.suspend == true end)
            if not already then
                pcall(function() job.flags.suspend = true end)
            end
            log_once('inert:' .. tostring(job.id), 'WARNING', string.format(
                'INERT REFUSED: job %d holds %s, which does not burn.'
                .. ' Job SUSPENDED and the item released.',
                job.id, tostring(inert)), 'INERT')
            log_once('inertwhy:' .. tostring(job.id), 'WARNING', '  The reagent on ' .. tostring(base_code)
                .. ' is missing a material gate. Nothing was consumed.', 'INERT')
        end
        return
    end

    if not streams then return end

        -- Once per cycle, not once per poll. Only the first poll of a
    -- cycle, or one that just settled the previous cycle, has anything
    -- new to say; the other five per second repeat it verbatim.
    if sc then t0 = sc.lap('ghosted: inert refusal, streams', t0) end
    local n_f, n_r, n_fuel = repair_filters(job, ghost, base_code)
    if sc then t0 = sc.lap('ghosted: repair_filters', t0) end
    -- The early returns hand back two values, so fuel reads as none.
    n_fuel = n_fuel or 0
    if settled_now or not prev then
        -- One line per currency, so a char job shows its charcoal
        -- and its ash filling side by side.
        for _, st in ipairs(streams) do
            log('DETAIL', string.format(
                '    . job %d  %s  %d item(s)  %s bank %.6f + %.6f'
                .. ' = %.6f  [filters %d (%d fuel) reagents %d]',
                job.id, profile, #job.items, string.lower(st.currency),
                st.bank_in, st.haul, st.sum, n_f, n_fuel, n_r), 'AUDIT')
        end
    end

    -- ---- BURN TEST ----
    -- job.flags.working is the only reliable difference between a job
    -- that completed and one that was cancelled. A completing job
    -- holds it for its whole run, roughly twelve seconds at the
    -- observed rate; a cancelled job never sets it at all.
    --
    -- Sticky for the cycle, because the poll that catches the job may
    -- not be the poll on which it finishes. It resets naturally: the
    -- audit sweep deletes the snapshot when the cycle ends and the
    -- next cycle builds a fresh one.
    local wk = false
    pcall(function() wk = job.flags.working end)
        local worked = wk or (prev and prev.worked) or false

    if prev and not prev.worked and worked then
        log('DETAIL', string.format('PHASE: job %d working (attached=%d filters=%d,'
            .. ' %d fuel)', job.id, #job.items, n_f, n_fuel), 'PHASE')
    end

    local snap = {
        code = tostring(job.reaction_name), base = base_code,
        profile = profile, items = {},
        -- One entry per currency this job pays: what the bank held,
        -- what this job added, the total the slots were written
        -- from, and what those slots cost. settle() carries the
        -- difference into each bank.
        streams = streams, out = out, haul = haul,
        id_key = id_key, ids = ids, stacks = stacks, dims = dims,
        contents = contents,
        detail = detail, worked = worked, seen = audit_tick,
    }
    -- THE SAME ITEMS AS THE LAST POLL: their descriptions, as that poll
    -- read them. Read only here, for the ledger's lines.
    if same and st.names then
        snap.items = st.names
    else
        pcall(function()
            for _, iref in ipairs(job.items) do
                local d = '?'
                pcall(function() d = dfhack.items.getDescription(iref.item, 0) end)
                table.insert(snap.items, tostring(d))
            end
        end)
        local rec = steady_key and steady[job.id]
        if rec and rec.key == steady_key then rec.names = snap.items end
    end
    -- The header's contract, enforced on EVIDENCE, not attachment:
    -- audit_state must hold the last snap that carries witness ids.
    -- The first cut guarded on #job.items, and retort char walked
    -- straight through it: the log dies mid job while the preserved
    -- vessels stay attached, so later polls held items but zero
    -- evidence, overwrote the snap, and every liquid credit was
    -- discarded as NOT CONSUMED. A snap WITH ids may always land; a
    -- snap without them lands only when nothing better exists.
    local prior = audit_state[job.id]
    local prior_ev = prior and prior.ids and #prior.ids > 0
    if #ids > 0 or not prior_ev then
        audit_state[job.id] = snap
    end
    if sc then sc.lap('ghosted: burn test, snapshot', t0) end
end

-- ==========================================
-- SWAP A FRESH JOB TO ITS GHOST
-- ==========================================
local function swap_to_ghost(job, rname, config)
    local mat_type, mat_index = read_input_material(job)
    -- PITCH: the attached item is the preserved jug; the feedstock
    -- is the liquid INSIDE it. Sampling the jug once locked a clone
    -- to the jug's material, and that clone consumed nothing,
    -- forever. Sample the contents instead: the lock below then pins
    -- reagent[0] to the actual tar, completion consumes exactly that
    -- tar, and GET_MATERIAL derives from it. No tar visible yet
    -- means no swap this poll; the base job waits, the same way an
    -- empty char job does.
    if V.traits(config.profile).carries_tars then
        mat_type, mat_index = nil, nil
        pcall(function()
            for _, iref in ipairs(job.items) do
                local inside = dfhack.items.getContainedItems(iref.item)
                if inside then
                    for _, c in ipairs(inside) do
                        if c:getType() == df.item_type.LIQUID_MISC
                           and c.mat_type == 0 and c.mat_index >= 0 then
                            mat_type, mat_index = 0, c.mat_index
                            return
                        end
                    end
                end
            end
        end)
    end
    if not mat_type or not mat_index then return end

    local suffix = ''
    if config.is_creature then
        local ok, r, c = pcall(function()
            return job.items[0].item.race, job.items[0].item.caste
        end)
        if ok and r then suffix = '_R' .. r .. 'C' .. (c or 0) end
    end

    -- Per JOB, not per material. Product counts are rewritten live, so
    -- two jobs sharing one ghost would overwrite each other's output.
    -- The job id is the only key that cannot collide.
    local ghost_code = rname .. '_GHOST_' .. mat_type .. '_' .. mat_index
                       .. suffix .. '_J' .. tostring(job.id)

    local rxn = ghost_cache[ghost_code]
    if not rxn then
        rxn = find_rx(ghost_code)   -- ONE LOOKUP, NOT ONE WALK
        if rxn then ghost_cache[ghost_code] = rxn end
    end
    if not rxn then
        build_ghost_jit(rname, ghost_code, mat_type, mat_index)
        rxn = ghost_cache[ghost_code]
    end
    if not rxn then return end

    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)
    job.reaction_name = ghost_code
    log_once('swap:' .. job.id, 'DETAIL', 'Ghost Swap: ' .. rname .. ' -> ' .. ghost_code, 'SWAP')

    -- Products and snapshot IMMEDIATELY, not on the next poll. A one
    -- item job can finish inside the ten frame gap. If it does and
    -- nothing ran here, it completes on whatever counts the ghost was
    -- built with, and no snapshot ever exists so the bank is never
    -- settled for it. Both failures are silent.
    handle_ghosted(job, rname)
end

-- ==========================================
-- SETTLEMENT
-- ==========================================
-- Credits the bank for one finished job cycle and prints the ledger
-- block for it. Called from TWO places, and it needs both.
--
--   1. handle_ghosted, the moment it sees the job holding DIFFERENT
--      items than the snapshot it already has.
--   2. audit_sweep, when a snapshot goes stale because the job
--      finished and nothing replaced it.
--
-- Path 1 exists because path 2 alone loses value. The sweep only fires
-- on a snapshot that has been stale for two poll ticks. When a job
-- completes and grabs its next item faster than that, the snapshot is
-- overwritten before the sweep ever sees it and the burned item is
-- never credited. Measured on a live corpsepiece run: 2 of 22 pieces
-- vanished that way, 4.4 percent of the value fed in.
--
-- BURN TEST. job.flags.working is the only reliable difference between
-- a job that completed and one that was cancelled: a completing job
-- holds it for its whole run, a cancelled job never sets it. Item
-- existence corroborates, since a consumed reagent is destroyed and
-- df.item.find returns nil for its id.
-- ==========================================
-- force skips the retry below. Used when a new cycle has already
-- started, because the snapshot cannot survive under the same job id
-- and a verdict has to be reached now.
--
-- Returns true when a verdict was reached, false when the caller
-- should keep the snapshot and let the sweep look again.
function settle(id, s, force)
    -- Consumed means vanished OR reduced. A partly eaten stack is the
    -- common case on plants, food and cloth, where DF takes what the
    -- reagent asked for and leaves the rest as the same item.
    local gone = false
    for _, iid in ipairs(s.ids or {}) do
        local it = nil
        pcall(function() it = df.item.find(iid) end)
        if not it then
            gone = true
        else
            local sz = 1
            pcall(function() sz = it.stack_size or 1 end)
            if sz < ((s.stacks or {})[iid] or sz) then gone = true end

            -- ---- A DRAINED DIMENSION IS A CONSUME ----
            -- The liquid twin of the stack rule above, and it belongs
            -- HERE for the same reason the drain's contents witness
            -- does: untouched() decides a CYCLE BOUNDARY, this decides
            -- the VERDICT, and wiring a witness into the first while
            -- the second cannot see it looks right and does nothing.
            -- That is the note directly below, made a second time.
            --
            -- MEASURED, BOIL_PITCH job 12 over three cycles: tar #1535
            -- read dim 2400, then 2250, then 2100, exactly 150 drawn
            -- per cycle, and every verdict was NOT CONSUMED because
            -- none of the three tests above could see it.
            --
            -- This slept until the jugs were filled. A jug holding one
            -- unit was DESTROYED by a 150 draw, so the tar vanished
            -- and the first test caught it; a jug holding sixteen
            -- survives at 2250 and leaves the dimension as the only
            -- surviving evidence.
            local dm = nil
            pcall(function() dm = it.dimension end)
            if dm and dm < ((s.dims or {})[iid] or dm) then
                gone = true
            end

            -- ---- A FILLED VESSEL IS A FIRED CYCLE ----
            -- The drain's witness, and it belongs HERE rather than in
            -- untouched(). untouched decides a CYCLE BOUNDARY inside
            -- handle_ghosted; this function decides the VERDICT, and
            -- they are not the same test. I wired the witness into
            -- untouched first, which looked right and did nothing: a
            -- drain poured real liquid and settle refused to debit it,
            -- which is R2, a free payout.
            --
            -- s.contents is populated for PROFILE_DRAIN only, so for
            -- every other reaction the lookup is nil and this can
            -- never fire. A vessel that gained an item was poured
            -- into, and that is the cycle completing.
            local cn = nil
            pcall(function()
                cn = #(dfhack.items.getContainedItems(it) or {})
            end)
            local was = (s.contents or {})[iid]
            if cn and was and cn > was then gone = true end
        end
    end

    -- ---- ITEM DESTRUCTION IS THE TEST ----
    -- job.flags.working used to be ORed in here and that was wrong. A
    -- job cancelled BEFORE it started never sets the flag, which is
    -- what the original evidence showed, but a job cancelled DURING
    -- the burn has it set and consumed nothing. So worked credited
    -- every mid-burn cancellation.
    --
    -- Gone means consumed. Still present means the job released them.
    --
    -- One retry, because DF may not free a consumed reagent in the
    -- same frame the job completes. Guessing there would trade this
    -- bug for the opposite one, losing value on completed jobs. Only a
    -- cycle that looked like it worked earns the retry; one that never
    -- worked is already a cancellation.
    if not gone and s.worked and not s.recheck and not force then
        s.recheck = true
        s.seen    = audit_tick
        return false
    end

    local burned = gone

    -- ---- LEDGER BLOCK ----
    -- Reads top to bottom as one transaction: what went in, what the
    -- bank held before, what came out, what is left. The old format
    -- printed a running total with no statement of what was produced,
    -- which made a payout that fired indistinguishable from one that
    -- did not.
    local short = tostring(s.base):gsub('^' .. MODULE_PREFIX, '')
    -- YIELD when the job burned: this line and the out line below are
    -- what Info shows of each finished job.
    log(burned and 'YIELD' or 'DETAIL', string.format('%s  job %d  %s', short, id,
        burned and 'BURNED' or 'NOT CONSUMED'), 'LEDGER')

    local tally, order = {}, {}
    for _, d in ipairs(s.detail or {}) do
        if not tally[d] then table.insert(order, d) end
        tally[d] = (tally[d] or 0) + 1
    end
    for _, d in ipairs(order) do
        log('DETAIL', string.format('  in    %dx %s', tally[d], d), 'LEDGER')
    end

    -- ---- ONE LINE PER CURRENCY ----
    -- A char job reads charcoal and ash; an ash job reads ash and
    -- charcoal. Each line is that currency's transaction: what the
    -- bank held, what this job added, what the slots were written
    -- from.
    local streams = s.streams or {}
    for _, st in ipairs(streams) do
        log('DETAIL', string.format('  bank  %-8s %.6f held + %.6f in = %.6f',
            string.lower(st.currency or '?'),
            st.bank_in or 0, st.haul or 0, st.sum or 0), 'LEDGER')
    end

    -- ---- WHAT THE PRODUCTS WERE SET TO ----
    -- The line whose absence made this whole run unreadable. These are
    -- the numbers written into the ghost, so if the workshop produced
    -- something different the fault is downstream of this file.
    local parts = {}
    for _, o in ipairs(s.out or {}) do
        table.insert(parts, string.format('%d %s', o.n, o.name))
    end
    if #parts == 0 then parts = { 'nothing' } end
    local costs = {}
    for _, st in ipairs(streams) do
        table.insert(costs, string.format('%s %.6f',
            string.lower(st.currency or '?'), st.paid or 0))
    end
    if #costs == 0 then costs = { '0' } end
    log(burned and 'YIELD' or 'DETAIL', string.format('  out   %s   (costing %s)',
        table.concat(parts, ', '), table.concat(costs, ', ')), 'LEDGER')

    if not burned then
        for _, st in ipairs(streams) do
            log('DETAIL', string.format(
                '  bank  %-8s unchanged at %.6f, nothing was consumed',
                string.lower(st.currency or '?'),
                yield_bank[st.bank] or 0), 'LEDGER')
        end
        return true
    end

    -- ---- CARRY, PER BANK ----
    -- Each currency settles into its own pool. What this job burned
    -- minus what its slots paid is what waits for the next job in
    -- that currency, whichever reaction or vanilla job that turns
    -- out to be.
    for _, st in ipairs(streams) do
        local carry = (st.sum or 0) - (st.paid or 0)
        if carry < 0 then carry = 0 end
        if not st.bank then goto next_stream end
        yield_bank[st.bank] = carry
        log('DETAIL', string.format('  bank  %-8s %.6f carried in %s',
            string.lower(st.currency or '?'), carry, tostring(st.bank)), 'LEDGER')
        ::next_stream::
    end
    return true
end

-- ==========================================
-- AUDIT SWEEP
-- ==========================================
-- Any snapshot not refreshed for two ticks belongs to a cycle that is
-- over with nothing replacing it. Settle and drop it.
-- ==========================================
local function audit_sweep()
    -- THE HELD ITEMS, PRICED ONCE: a job gone from the list takes its
    -- priced items with it. live_jobs is complete here: the poll fills
    -- it before the sweep runs.
    for id in pairs(valued) do
        if not live_jobs[id] then valued[id] = nil end
    end
    for id in pairs(steady) do
        if not live_jobs[id] then steady[id] = nil end
    end
    for id, s in pairs(audit_state) do
        if s.seen < audit_tick - 1 then
            if live_jobs[id] then
                -- Still in the job list, so it has not been cancelled.
                -- Re-arm and say nothing.
                s.seen = audit_tick
            elseif use(owner_of(s.base)) and settle(id, s) then
                audit_state[id] = nil
            end
        end
    end
end

-- ==========================================
-- WATCHER LOOP
-- ==========================================
local err_reported = false

-- ---- WHO WALKS THE LIST ----
-- RM's dispatcher walks the job list once per tick for every subscriber
-- and hands this file only the module's own reaction jobs, base or
-- ghost, which is every job this loop ever acts on: JIT_CONFIG and
-- AUTHORED are keyed under MODULE_PREFIX, a ghost code starts with its
-- base, and an alias only takes for a module base. live_jobs is read by
-- audit_sweep for those same jobs alone, so filling it from them loses
-- nothing. poll() below is this file's own loop, kept for an RM without
-- a dispatcher, and walks every job exactly as it always did.
local function is_module_job_name(name)
    return prefix_owner(name) ~= nil
end

-- ==========================================
-- WHERE THE REAPER LOOKS (2026-10-31)
-- ==========================================
-- The null liquid reaper (refinish-reaction-adaptive-vessels.lua) walked
-- every LIQUID_MISC item in the fort on every poll. MEASURED, section
-- probe, 315 s, 161 dwarf fort: 12.2 ms of the poll's 13.6, about 90% of
-- this engine, over 17,764 liquids with none at stack 0 and nothing
-- reaped all session. The walk grows with every liquid a fort keeps and
-- finds nothing almost every time.
--
-- A null is minted by one thing: a module reaction completing with a
-- liquid slot at count 0, into a container at that reaction's workshop.
-- So a completion of one of the served modules' reactions marks its
-- workshop, and the next poll reaps only what that workshop holds. DFHack
-- reports ordinary and repeating jobs and a work order's last unit; RM's
-- job units service reports every other unit of a work order. The
-- handler keeps the workshop's id and nothing of the job (JOBS ARE ONLY
-- GOOD FOR THE TICK, refinish-loop-dispatch.lua).
--
-- THE SWEEP STAYS, every REAP_SWEEP_POLLS and on the first poll of each
-- data cycle, for anything the workshop look did not see: a completion
-- with no workshop to read, a container hauled off before the next poll,
-- a null left by an earlier session. That keeps WHY IT LIVES IN THE POLL
-- whole: no jug stays hostage longer than one sweep, whatever happened to
-- the cycle. At 300 polls of 10 frames the sweep runs about every 40
-- seconds of play, about 0.3 ms/sec at the cost measured above.
-- ==========================================
local REAP_SWEEP_POLLS = 300
local reap_due         = {}     -- building id -> true, a workshop to look at
local reap_sweep_due   = false  -- a completion with no workshop: sweep next poll
local reap_countdown   = 0      -- polls to the next sweep; 0 sweeps at once

-- The completion handler, for eventful and for RM's job units service.
-- Inside pcall: an error escaping into eventful breaks every other
-- listener in the process.
local function on_completed(job)
    pcall(function()
        local name = tostring(job.reaction_name)
        if name == '' or not prefix_owner(name) then return end
        local bid = nil
        pcall(function()
            local b = dfhack.job.getHolder(job)
            if b then bid = b.id end
        end)
        if bid then reap_due[bid] = true else reap_sweep_due = true end
    end)
end

-- jobs is the dispatcher's list, or nil for this file's own loop.
local function poll_with(jobs)
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end

    -- ---- PAUSE GATE ----
    -- The poll is scheduled on frames, which keep advancing while the
    -- game is paused. Nothing here needs to run then: no items move
    -- and no jobs progress. Letting the audit tick advance while
    -- paused would also age snapshots out and settle banks for jobs
    -- that are simply frozen.
    if dfhack.world.ReadPauseState() then return end

    local ram_loaded = _G.refinish_ram_loaded
    if ram_loaded ~= last_ram_loaded then
        -- Ghosts must not be held across a RAM transition. They become
        -- dangling the moment clear_module_assets() runs.
                -- yield_bank is NOT cleared here. See its declaration: it
        -- holds no pointers, and a RAM transition fires on every
        -- save.
        ghost_cache     = {}
        audit_state     = {}
        seen            = {}
        last_ram_loaded = ram_loaded
    end
    if not ram_loaded then return end

    local ok, err = pcall(function()
        -- SECTION CLOCK: timing points for refinish-section-probe, which
        -- installs the clock; one global read a poll while it is off.
        local sc = _G.refinish_section_clock
        local t_poll = sc and sc.now()
        audit_tick = audit_tick + 1

        -- Clear unpaid liquids out of the jugs before anything
        -- else touches them. Independent of jobs and cycles by
        -- design; see NULL LIQUID REAPER above.
        -- Each module's liquids, with its own provider in use.
        -- Only the workshops a module reaction finished at, and the
        -- whole fort only on the sweep: see WHERE THE REAPER LOOKS.
        reap_countdown = reap_countdown - 1
        local sweep = reap_sweep_due or reap_countdown <= 0
        if sweep or next(reap_due) then
            for owner in pairs(PROVIDERS) do
                if use(owner) then
                    if sweep then VS.reap_null_liquids()
                    else VS.reap_at(reap_due) end
                end
            end
            if sweep then reap_countdown = REAP_SWEEP_POLLS end
            reap_due, reap_sweep_due = {}, false
        end
        VS.tick()
        if sc then sc.lap('adaptive: reap and vessel tick', t_poll) end

        -- ---- WHO IS ALIVE THIS POLL ----
        -- live_jobs was declared and read and NEVER WRITTEN TO. It has
        -- been empty on every poll since it was added, so the branch
        -- in audit_sweep that re-arms a still running job could never
        -- be taken, and the sweep settled live jobs mid cycle. Its own
        -- comment describes the bug it was meant to prevent, and that
        -- bug has been live the whole time.
        --
        -- Cleared and refilled rather than accumulated: a job id that
        -- has left the list must stop being alive, and the sweep runs
        -- after this loop so it always sees a complete set.
        for k in pairs(live_jobs) do live_jobs[k] = nil end

        if not jobs then
            jobs = {}
            for _, job in utils.listpairs(df.global.world.jobs.list) do
                jobs[#jobs + 1] = job
            end
        end
        for _, job in ipairs(jobs) do
            live_jobs[job.id] = true
            if job.job_type == df.job_type.CustomReaction then
                local rname = tostring(job.reaction_name)

                -- ---- ALREADY GHOSTED ----
                -- After the swap rname is the ghost code, so the
                -- direct config lookup misses. Recover the base code
                -- from the ghost code to keep tracking it.
                -- Any served module's ghost: the base is whatever comes
                -- before _GHOST_, and it counts only if it is configured,
                -- which also says whose it is.
                local ghost_base = string.match(rname, '^(.-)_GHOST_')
                if ghost_base and not (JIT_CONFIG[ghost_base]
                                       and use(JIT_CONFIG[ghost_base].owner)) then
                    ghost_base = nil
                end

                if ghost_base and JIT_CONFIG[ghost_base] then
                    if #job.items > 0 then
                        -- Mark that this cycle actually held something,
                        -- so the empty list below is the END of a cycle
                        -- and not the pre haul window a job opens with.
                        local es = VS.expand_state[job.id]
                        if es then es.held = true end
                        handle_ghosted(job, ghost_base)
                    else
                        -- ---- BETWEEN CYCLES ----
                        -- The item set emptying is DF's own cycle
                        -- boundary, and nothing is attached, so no
                        -- job_item_idx can be pointing at a slot being
                        -- removed. Extras come off here so the next
                        -- cycle is born at the reaction's own shape and
                        -- never demands a jug it does not need.
                        local es = VS.expand_state[job.id]
                        if es and es.held and es.n > 0 then
                            local g = ghost_cache[tostring(job.reaction_name)]
                            if g then VS.collapse_vessels(job, g) end
                        end

                        -- ---- AND SETTLE HERE ----
                        -- This is where a cycle actually ends, so this
                        -- is where it gets its verdict. Until now the
                        -- only thing settling a repeat cycle was the
                        -- audit sweep firing through the dead
                        -- live_jobs guard, two ticks after the
                        -- snapshot went stale. That is why six
                        -- consumptions produced four ledger lines: the
                        -- sweep fired when the empty window happened
                        -- to last two ticks and not otherwise.
                        --
                        -- It also fired MID cycle, while the reagent
                        -- was still sitting there, which is why every
                        -- one of those verdicts read NOT CONSUMED.
                        -- Here the reagent has either gone or it has
                        -- not, so the burn test means something.
                        --
                        -- Not forced, so the one retry still applies:
                        -- DF does not always free a consumed reagent
                        -- in the same frame the cycle closes.
                        local s = audit_state[job.id]
                        if s and s.ids and #s.ids > 0 then
                            if settle(job.id, s) then
                                audit_state[job.id] = nil
                            end
                        end
                    end
                else
                    -- ---- NOT YET GHOSTED ----
                    -- Wait for at least one item: the ghost is keyed
                    -- on what walked in and there is nothing to read
                    -- until something has.
                    -- A runtime clone reaches this lookup under its
                    -- OWN code and is adopted only if its maker
                    -- registered it. An unadopted clone is named once
                    -- rather than silently completing on its own
                    -- counts, which is what a per retort drain did:
                    -- two jugs filled, nothing debited, and the only
                    -- trace was the reaper clearing liquids that were
                    -- never paid for.
                    --
                    -- AUTHORED IS THE GUARD, NOT THE CONFIG. Missing
                    -- config used to be the whole test, which made
                    -- this fire at level 0 for every deliberately flat
                    -- reaction in the module. A reaction the module
                    -- declared is doing what it was told; only a code
                    -- the module never declared can be an unadopted
                    -- clone. Putting a false fault in the fault
                    -- channel is how a real one gets missed.
                    local config = JIT_CONFIG[rname]
                    if config and not use(config.owner) then config = nil end
                    if not config then use(prefix_owner(rname)) end
                    if config and #job.items > 0 then
                        swap_to_ghost(job, rname, config)
                    elseif not config and #job.items > 0
                           and not AUTHORED[rname]
                           and prefix_owner(rname) ~= nil
                           and not rname:find('_GHOST_', 1, true) then
                        -- ERROR: an unadopted clone completes on its own counts and banks
                        -- nothing, the same fault drain-key reports for its drains.
                        log_once('unadopted:' .. rname, 'ERROR', string.format(
                            'Job %d runs %s, which the module never'
                            .. ' declared and which has no config. That'
                            .. ' makes it a runtime clone whose maker'
                            .. ' did not call register_alias. It will'
                            .. ' complete on its own counts and bank'
                            .. ' nothing.', job.id, rname), 'ALIAS')
                    end
                end
            end
            ::next_job::
        end

        local t_sweep = sc and sc.now()
        audit_sweep()
        if sc then
            sc.lap('adaptive: audit sweep', t_sweep)
            sc.lap('adaptive: whole poll', t_poll)
        end
    end)

    if not ok then
        if not err_reported then
            log('ERROR', 'ERROR in poll: ' .. tostring(err), 'POLL')
            err_reported = true
        end
    else
        if err_reported then log('INFO', 'Poll recovered after previous error.', 'POLL') end
        err_reported = false
    end
end

-- This file's own loop, for an RM without the dispatcher.
local function poll() poll_with(nil) end

-- ==========================================
-- ORPHAN SWEEP AND LIFECYCLE
-- ==========================================
-- A job left pointing at a ghost code from a previous session names a
-- reaction that no longer exists, so it can never run. Point it back
-- at its base and let the swap happen again cleanly.
-- ==========================================
local function sweep_orphans()
    local reverted = 0
    pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local rname = tostring(job.reaction_name)
                local base = string.match(rname, '^(.-)_GHOST_')
                if base and JIT_CONFIG[base] then
                    job.reaction_name = base
                    reverted = reverted + 1
                end
            end
        end
    end)
    -- ---- WORK ORDERS TOO ----
    -- A work order names its reaction by code, and DF copies that code
    -- onto every job the order posts. A ghost is swept at every save and
    -- only a job swapped this session gets one again, so after a load an
    -- order carrying a ghost code posts every job on a reaction that does
    -- not exist, and the manager lists the order as "Reaction".
    -- SEEN 2026-10-16: MAKING_FUEL_RXN_RETORT_LIGNITE_GHOST_0_195_J24379
    -- was cut at 17:56 for job 24379 (not logged as a work order's job),
    -- and two minutes later order 200 carried that code; after the next
    -- load it posted job after job on it. Nothing in this file writes an
    -- order, and a ghost keeps its base's name, so the order was most likely
    -- made from the ghost itself (unmeasured: whether DF offers a
    -- reaction with no building in its New work order list).
    -- Whatever the cause, an order on a ghost goes back to its base here,
    -- as the loop above does for jobs; the base's jobs are swapped afresh
    -- as they take their items.
    local orders = 0
    pcall(function()
        for _, o in ipairs(df.global.world.manager_orders.all) do
            if o.job_type == df.job_type.CustomReaction then
                local base = string.match(tostring(o.reaction_name),
                    '^(.-)_GHOST_')
                if base and JIT_CONFIG[base] then
                    o.reaction_name = base
                    orders = orders + 1
                end
            end
        end
    end)
    if reverted > 0 then
        log('INFO', 'Reverted ' .. reverted .. ' orphaned ghost job(s).', 'ORPHANS')
    end
    if orders > 0 then
        -- INFO: an order that read "Reaction" works again.
        log('INFO', 'Pointed ' .. orders .. ' work order(s) named for a'
            .. ' ghost back at their base reactions.', 'ORPHANS')
    end
end

-- ==========================================
-- RUNTIME CLONES OF A MANAGED REACTION
-- ==========================================
-- JIT_CONFIG is keyed on the reaction key the module DECLARED, so a
-- reaction cloned into the raws at runtime is invisible to this engine
-- however well formed it is. Its jobs fall through the swap, keep the
-- authored product counts, and DF mints liquids nothing ever paid for,
-- which the reaper then clears. Every symptom of that is downstream
-- and none of them names the cause.
--
-- The per retort drains are exactly this: making-fuel-drain-key.lua
-- cuts one RETORT_DRAIN clone per furnace so each can be gated on its
-- own key material.
--
-- The clone's maker declares what it is rather than this engine
-- guessing from the name. A name test would make the engine know a
-- watcher's private naming scheme, and would break the day a declared
-- reaction key happened to look like one.
--
-- The alias points at the SAME cfg table, not a copy, so a clone can
-- never drift from the base it was cut from. Aliases are not counted
-- in the startup banner because they are added by later polls, after
-- start() has already counted, and every one of them is discarded when
-- derive_config rebuilds JIT_CONFIG on the next data cycle.
function register_alias(clone_code, base_code)
    local cfg = JIT_CONFIG[base_code]
    if not cfg then
        -- A base the module DECLARED but which has no config is
        -- deliberately flat: a watcher does its work and there is
        -- nothing here to pay, so there is no config to share. Its
        -- clones are declared by extension all the same, so they
        -- inherit AUTHORED rather than being named in the fault
        -- channel as unadopted. The orphan check's own rule is that
        -- AUTHORED is the guard, not the config.
        --
        -- Without this, a per building FILL_TANK_B<id> clone meets
        -- every condition of that check: no config, the module
        -- prefix, no _GHOST_, and AUTHORED keyed on the declared code
        -- only, never on a clone of it.
        --
        -- Re-asserted by the caller every poll like everything else
        -- here, because derive_config rebuilds AUTHORED on each data
        -- cycle. A vanilla base is in neither table, so it still
        -- returns false, and false still means unmanaged.
        if AUTHORED[base_code] then
            -- The clone belongs to its base's module (AUTHORED holds the
            -- owner, so a module leaving takes its clones with it).
            AUTHORED[clone_code] = AUTHORED[base_code]
            return true
        end
        return false
    end
    if JIT_CONFIG[clone_code] == cfg then return true end
    JIT_CONFIG[clone_code] = cfg
    log('DETAIL', 'Adopted runtime clone ' .. tostring(clone_code)
        .. ' as ' .. tostring(base_code), 'ALIAS')
    return true
end

-- ==========================================
-- ORPHAN SWEEP, RE RUNNABLE
-- ==========================================
-- start() sweeps orphans before any alias can exist, so a job left
-- mid drain across a data cycle is still pointing at a ghost code cut
-- from a clone this engine has not been told about yet, and the sweep
-- passes it over. The clone's maker calls this once its aliases are
-- back, and the same revert then fires. Idempotent: a reverted job no
-- longer matches the ghost pattern.
function resweep_orphans()
    sweep_orphans()
end

-- ---- ENGINE WIDE ----
-- Reset once per data cycle (the first module to register in it) and
-- the loop subscribed once, whatever the number of modules served.
local running = false

local function reset_engine()
    seen         = {}
    ghost_cache  = {}
    audit_state  = {}
    -- THE HELD ITEMS, PRICED ONCE and THE SAME ITEMS AS THE LAST POLL:
    -- keyed by job id.
    valued       = {}
    steady       = {}
    err_reported = false

    -- Both of these validate themselves on read, so this is belt and
    -- braces rather than the load bearing fix. It is here because it
    -- is deterministic: start() runs on every data cycle, so the
    -- common case never reaches the validation path at all.
    --
    -- Deliberately NOT added to the RAM transition block in poll().
    -- poll() returns early while the game is paused and the whole
    -- silent cycle completes inside the ESC handler in about a
    -- second, so that block is not reliably reached and putting the
    -- clear there would read as coverage it does not provide.
    base_cache      = {}

    -- ---- EVERYTHING KEYED BY JOB ID, OR IT OUTLIVES THE WORLD ----
    -- These three were missing, and the omission corrupts working
    -- retorts rather than merely leaking.
    --
    -- MEASURED: leave to the main menu, re-enter an earlier save
    -- without recycling, and the first whale dies on arrival. DF hands
    -- out low job ids again after a reload, so a fresh job 10 inherits
    -- the expand_state of a whale that expanded in the PREVIOUS
    -- session, `held = true` and `n = 2` and all.
    --
    -- The between cycles branch then reads that stale record and calls
    -- collapse_vessels, which erases n slots from the END of
    -- job.job_items and of the ghost's reagents and products. On a job
    -- that appended nothing, those are its REAL base vessel slots. A
    -- retort missing its vessel filters cannot run, and no amount of
    -- collection_open helps because the damage lands before collection
    -- matters.
    --
    -- It is also why a recycle always worked and a reload never did: a
    -- recycle rebuilds this environment, a reload does not.
    --
    -- vessel_poll goes with them because expand_state records it as
    -- `tick`, and a cleared table beside a running counter is only
    -- half a reset. The container cache is keyed on the same counter.
    live_jobs         = {}
    -- WHERE THE REAPER LOOKS: a new data cycle starts with a sweep.
    reap_due, reap_sweep_due, reap_countdown = {}, false, 0
    -- Re-point at the global rather than replacing it, so a world
    -- reload does not discard a balance the previous fort accrued.
    -- The vessel half's own state: expansion, the pool cache, its
    -- poll count and the drain material cache.
    if VS then VS.reset() end
end

local function start_loop()
    if running then return end
    -- ---- THE JOB POLL RIDES THE DISPATCHER ----
    -- RM's dispatcher walks the job list once per tick for every
    -- subscriber and hands this file only its own jobs. With no
    -- dispatcher (an RM without refinish-loop-dispatch), or a
    -- subscription it refuses, this file's own loop runs exactly as it
    -- did. Whichever runs, the other is cleared, so a start after a
    -- start can never leave both serving the same jobs. Not paused:
    -- this loop has always stood still while the game does (see PAUSE
    -- GATE in poll_with), and the dispatcher skips it then the same way.
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(REPEAT_KEY,
            { every = POLL_FRAMES, jobs = is_module_job_name, fn = poll_with }) then
        repeatUtil.cancel(REPEAT_KEY)
    else
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', poll)
    end
    -- WHERE THE REAPER LOOKS: completions mark workshops for the reaper.
    -- Enabled here rather than trusting another file to have done it: a
    -- hook on an event nobody enabled is never called.
    eventful.onJobCompleted[REPEAT_KEY] = on_completed
    pcall(function() eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0) end)
    local units = _G.refinish_job_units_api
    if units and units.subscribe then units.subscribe(REPEAT_KEY, on_completed) end

    -- The banner reads T, so a tuning table that is nil or missing a
    -- field throws HERE, at the end of start, after the poll is already
    -- scheduled. Guarded so a cosmetic line can never be what stops
    -- the module, and so the field that is actually missing gets named.
    running = true
end

local function stop_loop()
    repeatUtil.cancel(REPEAT_KEY)
    -- Out of the dispatcher as well as repeat-util: whichever start()
    -- chose, stop() leaves neither.
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(REPEAT_KEY) end
    eventful.onJobCompleted[REPEAT_KEY] = nil
    local units = _G.refinish_job_units_api
    if units and units.unsubscribe then units.unsubscribe(REPEAT_KEY) end
    running = false
    log('DETAIL', 'Stopped.', 'STOP')
end

-- ---- ONE MODULE ----
-- What start(rxn_data) did for Making Fuel, for whichever module is in
-- use: derive its configs from its reactions, name its faulty ones,
-- sweep ghosts it left, and log its start-up line.
local function start_provider(owner)
    local P = PROVIDERS[owner]
    if not P or not use(owner) then return end
    if not P.reactions then
        log('ERROR', owner .. ' registered no reaction data; none of its'
            .. ' reactions is adaptive and every zero count reaction pays'
            .. ' nothing.', 'START')
        return
    end
    local skipped, no_secondary, bad_layout = derive_config(P.reactions)
    if #skipped > 0 then
        log('WARNING', 'adaptive but recognizable by no chain,'
            .. ' paying nothing: ' .. table.concat(skipped, ', '), 'START')
    end
    if #bad_layout > 0 then
        log('WARNING', 'secondary slot declares the wrong product,'
            .. ' secondary NOT paid: ' .. table.concat(bad_layout, ', '),
            'START')
    end
    if #no_secondary > 0 then
        log('DETAIL', 'no secondary slot, primary only: '
            .. table.concat(no_secondary, ', '), 'START')
    end

    sweep_orphans()
    local ok_banner, err_banner = pcall(function()
        -- What the start-up line says about the reactions and their
        -- numbers is the module's (start_banner in making-fuel-adaptive-
        -- valuation): it counts its own profiles and quotes its own dials.
        -- Only this module's configs: the line is its own account.
        local mine = {}
        for code, c in pairs(JIT_CONFIG) do
            if c.owner == owner then mine[code] = c end
        end
        log('DETAIL', V.start_banner(mine), 'START')
    end)
    if not ok_banner then
        -- ERROR: the tuning table is missing a field, and whatever else
        -- reads it will be wrong as well. This used to print to the
        -- console at every load it happened on.
        log('ERROR', 'started, but the banner failed: '
            .. tostring(err_banner) .. '. The tuning table is missing a'
            .. ' field. The watcher is running; yields may be wrong.',
            'START')
    end
end

function stop()
    stop_loop()
end

-- ==========================================
-- REGISTRATION
-- ==========================================
-- A module hands the engine its provider and its reactions, and the
-- engine starts for it; the same moment making_fuel used to start the
-- ghost itself. Everything the engine read of the module at load time
-- (its reaction prefix, its liquid material prefix, its bank) is set
-- here, because it now arrives with the module rather than being known.
--
-- ONE PROVIDER: a second owner while one is served is refused and named
-- (see ONE PROVIDER FOR NOW in the header). The same owner registering
-- again, as it does on every data cycle, simply restarts with its new
-- reactions.
-- ==========================================
local cycle_registry = nil

function register(owner, spec)
    if type(owner) ~= 'string' or owner == '' then return false, 'no owner' end
    if type(spec) ~= 'table' or type(spec.valuation) ~= 'table' then
        return false, 'no valuation'
    end
    if not VS then
        -- ERROR: RM's own file is missing; no module gets adaptive reactions.
        log('ERROR', 'refinish-reaction-adaptive-vessels did not load, so the'
            .. ' engine cannot run for ' .. owner .. '.', 'REGISTER')
        return false, 'vessels not loaded'
    end
    local val = spec.valuation
    local prefix = tostring(val.REACTION_PREFIX or '')
    if prefix == '' then return false, 'no REACTION_PREFIX' end
    -- A new data cycle: every module registers again in it, so the
    -- engine starts clean on the first one and adds the rest.
    if _G.refinish_module_registry ~= cycle_registry then
        cycle_registry = _G.refinish_module_registry
        PROVIDERS, JIT_CONFIG, AUTHORED, CURRENT = {}, {}, {}, nil
        reset_engine()
    end
    -- The only refusal: a reaction prefix another served module's stems
    -- or is stemmed by, which would make their jobs indistinguishable.
    for other, P in pairs(PROVIDERS) do
        if other ~= owner and (prefix:sub(1, #P.prefix) == P.prefix
                               or P.prefix:sub(1, #prefix) == prefix) then
            -- ERROR: that module runs without adaptive reactions.
            log('ERROR', ('%s asked for the adaptive engine with reaction prefix'
                .. ' %s, which collides with %s (%s); refused. %s runs without'
                .. ' adaptive reactions; %s is untouched.'):format(owner, prefix,
                other, P.prefix, owner, other), 'REGISTER')
            return false, 'prefix collides with ' .. other
        end
    end
    local old = PROVIDERS[owner]
    PROVIDERS[owner] = {
        V = val, prefix = prefix,
        mat_prefix  = tostring(val.CURRENCY_MATERIAL_PREFIX or ''),
        bank        = val.bank and val.bank() or {},
        drain_cache = nil,
        -- A module registering again without reactions keeps the last
        -- set it handed over, the way the ghost cached making_fuel's
        -- handoff so a bare console restart reused it instead of going
        -- dark.
        reactions   = spec.reactions or (old and old.reactions),
    }
    if CURRENT == owner then CURRENT = nil end   -- force use() to reload it
    start_provider(owner)
    start_loop()
    return true
end

function unregister(owner)
    if not PROVIDERS[owner] then return end
    for code, c in pairs(JIT_CONFIG) do
        if c.owner == owner then JIT_CONFIG[code] = nil end
    end
    for code, o in pairs(AUTHORED) do
        if o == owner then AUTHORED[code] = nil end
    end
    PROVIDERS[owner] = nil
    if CURRENT == owner then CURRENT, V = nil, {} end
    if next(PROVIDERS) == nil then stop_loop() end
end

-- ---- THE HANDLE ----
-- Published at load: refinish_steel loads this file at its own load, so
-- the handle exists before any module starts.
_G.refinish_adaptive_api = {
    register        = register,
    unregister      = unregister,
    register_alias  = register_alias,
    resweep_orphans = resweep_orphans,
}