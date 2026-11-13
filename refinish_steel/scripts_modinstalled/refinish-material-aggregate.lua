-- refinish-material-aggregate.lua
-- =====================================================================
-- RM AGGREGATE STONE TWINS
-- =====================================================================
-- Every stone gets a TWIN inorganic appended to the raws: a clone of the
-- stone, same name, colour, thermals and density, PLUS the AGGREGATE
-- class. Its material flags do NOT come across, and RM's refinish scan
-- depends on that: see THE FLAGS DO NOT COME ACROSS in push() before
-- changing how a twin is copied. Gravel minted from a stone is hopped
-- onto that stone's twin after minting, so "granite gravel" reads and
-- weighs like granite while real granite never carries AGGREGATE and a
-- mason's granite blocks stay out of the road mix.
--
-- NOT AN ORE. A twin is made without its stone's ore tables, so it is
-- never smelted or spun, and never listed where DF lists ores (NOT AN ORE,
-- in push()).
--
-- WHOSE. RM's, with the catalog's gravel. This was Making Fuel's
-- making-fuel-stone-mat.lua, which pushed the twins from that module's
-- start. The twins exist only when the catalog carries GRAVEL (some
-- module asked for it), and the module engine calls push() at one fixed
-- step of its pipeline (STEP 2.5).
--
-- WHY A TWIN AND NOT A CLASS ON THE STONE. A reagent asks by class, and
-- a tool wears the material of whatever it was made from, so gravel
-- carries granite's classes. Putting AGGREGATE on granite itself would
-- make every granite item legal in a road mix, boulders included.
--
-- WHERE THIS DIFFERS FROM THE FUEL WOOD TWIN, and it matters twice. A
-- wood twin hides inside its own plant's material list, a vector nothing
-- else appends to, so its index never moves. A stone twin is a top level
-- inorganic, in the same vector the module engine injects every module
-- material into:
--
--   * Each twin needs its own id, so it is REFINISH_CORE_AGG_<SOURCE>
--     (MAKING_FUEL_AGG_<SOURCE> while it was Making Fuel's).
--   * ORDER IS THE CONTRACT. An item stores a mat_index number, not a
--     token, and RM's injected materials are not in the save. They are
--     re-pushed every session and the numbers have to land the same way.
--     So the push runs at one fixed point, the engine's STEP 2.5 (after
--     the catalog is settled and the clone donors are chosen, before any
--     module injects a material, exactly where Making Fuel's push used to
--     land), and walks the inorganics in index order. Move the call, or
--     change which stones qualify, and every saved gravel silently
--     becomes a different stone. The engine's own materials already live
--     under this rule; these twins only add more that rides on it.
--
-- APPEND ONLY. The engine washes TOOLS mid session, never materials, so
-- nothing moves under a live item while a fort runs. At shutdown the
-- twins come off with the engine's own LIFO sweep of REFINISH_CORE_
-- materials, from the end down, so indices below never move while it
-- runs; this file pops nothing itself now.
--
-- THE HOP LIVES HERE TOO, rather than in a watcher of its own: one file
-- owns the twins and the only write that depends on them. It is the fuel
-- wood hop with an inorganic's addressing, which is simpler, since an
-- inorganic item's mat_index IS the inorganic index and mat_type is
-- always 0. The hop and the twins' sprite sync run from start(), beside
-- the dispatcher: the created event hops gravel the frame it exists, a
-- slow backstop walk catches what arrived another way, and the twins'
-- sprite fields follow their stones.
--
-- AND THE UNHOP, its mirror (2026-10-29). Dust ground from gravel (the
-- catalog's REFINISH_GRAVEL_RXN_GRIND, refinish-core-payload.lua) takes
-- the gravel's material, the twin. Dust is the stone's powder, not an
-- aggregate, and on the twin it is wrong both ways: it carries AGGREGATE,
-- so an asphalt mix that asks for any AGGREGATE tool takes a 200 dust as
-- a 600 gravel (Making Fuel's MIX_ASPHALT), and no IS_STONE, so grog
-- (flags stone), a concrete mix and the stone's own dye and finishing
-- reactions, which name the stone, all refuse it. So dust is put back
-- onto the stone its twin was made from, the frame it exists, by the same
-- event and walk.
-- =====================================================================
--@ module = true

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'refinish-material-aggregate'

-- Twin ids are this plus the source stone's id. Also the marker the
-- pop scans for, so nothing else needs a manifest.
local TWIN_PREFIX = 'REFINISH_CORE_AGG_'

-- What the twin carries that the stone does not.
local CLASSES = { 'AGGREGATE' }

-- Ids the push refuses to twin: twins (which would compound every
-- session), RM's own materials, and every registered module's. Module
-- materials are not in the array yet when push() runs, but a stone
-- classed one (Making Fuel's pitch, asphalt, naphthalene) must never be
-- road aggregate whatever the order, so the rule is written down.
local SKIP_PREFIXES = { TWIN_PREFIX, 'REFINISH_' }

-- Every tool itemdef whose items must wear the twin instead of the
-- stone they were crushed from. Add an id here and the hop covers it.
local HOP_TOOLS = {
    'REFINISH_GRAVEL_TOOL',   -- RM's catalog gravel form
}

-- Every tool itemdef whose items must wear the stone, never its twin,
-- whatever they were made from (AND THE UNHOP, header).
local UNHOP_TOOLS = {
    'REFINISH_CORE_DUST',     -- RM's dust, ground from gravel
}

-- Which way a resolved subtype goes.
local HOP, UNHOP = 'hop', 'unhop'

-- ---- THE SPRITE FIELDS ----
-- MEASURED in play: oil shale reads boulder_texpos1 and 2 as 3014, and
-- its twin read 0, with every other field matching, colour included.
-- assign does not carry these. That zero is what made gravel render see
-- through on a twin while the same art on the same sheet was solid on
-- any other material.
--
-- It cannot be a copy at creation either. The 3014 is OUR dressing,
-- written onto the source stone by the sprite pass, which runs after
-- this push. So the copy is a SYNC that catches up, run at the end of
-- start and again on a slow cadence from the sweep.
--
-- The list is the engine's own: the seven texpos fields a material
-- carries plus texflag, which it copies verbatim including zero.
local SPRITE_FIELDS = {
    'bar_texpos',
    'boulder_texpos1', 'boulder_texpos2',
    'rough_texpos1',   'rough_texpos2',
    'cheese_texpos1',  'cheese_texpos2',
    'texflag',
}

-- ---- CADENCES ----
-- One tick every TICK_FRAMES. MEASURED 2026-09-24: this file cost 5.0 ms
-- a second on its old 5 frame sweep, 0.25 ms a call, most of it walking
-- every tool in the fort for gravel the created event had already
-- hopped the frame it was made.
--
--   The SYNC runs every SYNC_TICKS, about every 3 seconds at 100 frames
--   a second. Still kept forever rather than settled by a flag, which
--   would go stale the moment anything dressed a stone later in a
--   session, just no longer once a second. The first CATCH_UP ticks
--   after a start sync every time, because the sprite pass the sync
--   follows usually lands a second or so after the push.
--
--   The WALK of the TOOL vector is the backstop for what the created
--   event cannot see: anything that arrived while this file was not
--   listening, or a save written before the twins existed. It runs once
--   as soon as the gravel itemdef resolves, then every WALK_TICKS.
local TICK_FRAMES = 60
local SYNC_TICKS  = 5
local WALK_TICKS  = 10
local CATCH_UP    = 3
local ticks       = 0
local walked      = false   -- has this session's first walk run

-- Resolved on first need, then cached: itemdef subtype integer -> HOP
-- or UNHOP. Reset by start() so a recycle re-resolves against the
-- freshly injected itemdefs rather than last session's indices.
local hop_subtypes = nil

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core's own system, and this service's own subsystem.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'AGGREGATE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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
-- SUBJECT is the correlation slot: PUSH and POP for the two halves of
-- the lifecycle, TWIN for a single stone, RESOLVE for the tool lookup,
-- SPRITE and SWEEP for the two polls.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise, and printed to
-- the console when RM was not loaded.
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

local function new_string_ptr(s)
    local p = df.new('string'); p.value = s; return p
end

local function is_ours(id)
    return tostring(id):sub(1, #TWIN_PREFIX) == TWIN_PREFIX
end

local function skipped(id)
    id = tostring(id)
    for _, p in ipairs(SKIP_PREFIXES) do
        if id:sub(1, #p) == p then return true end
    end
    for p in pairs(_G.refinish_module_registry or {}) do
        if id:sub(1, #p) == p then return true end
    end
    return false
end

-- ==========================================
-- THE PUSH
-- ==========================================
-- One twin per stone, in source index order. A stone is anything the
-- raws flagged IS_STONE: all stones, no filter on
-- economics or ores, because a road takes whatever is quarried.
-- Called by the module engine at STEP 1.6 of every pipeline run whose
-- catalog carries GRAVEL. Publishes the source -> twin maps the hop
-- reads, and the twin -> source map the unhop reads.
function push()
    _G.refinish_aggregate_twin = {}
    _G.refinish_aggregate_is_twin = {}
    _G.refinish_aggregate_source = {}
    -- A new pipeline run may have injected the gravel tool at another
    -- subtype, and start() runs once per map, not per cycle, so the
    -- hop's subtype cache is dropped here, where every cycle passes.
    hop_subtypes = nil

    local raws = df.global.world.raws.inorganics.all
    local made, had, n_src = 0, 0, #raws

    -- The source list is snapshotted BEFORE anything is appended:
    -- walking a vector that grows underneath is how a push twins its
    -- own twins.
    local sources = {}
    for i = 0, n_src - 1 do
        local ok = false
        pcall(function()
            ok = raws[i].material.flags.IS_STONE and not skipped(raws[i].id)
        end)
        if ok then sources[#sources + 1] = i end
    end

    -- An existing twin means a start ran without its stop. Reuse it
    -- rather than pushing a second one: the ids are unique, so the
    -- match is exact.
    local existing = {}
    for i = 0, n_src - 1 do
        pcall(function()
            if is_ours(raws[i].id) then existing[tostring(raws[i].id)] = i end
        end)
    end

    for _, si in ipairs(sources) do
        local src_id = tostring(raws[si].id)
        local twin_id = TWIN_PREFIX .. src_id
        local at = existing[twin_id]
        if at then
            had = had + 1
        else
            local ok, err = pcall(function()
                local twin = df.inorganic_raw:new()
                -- Copy of the whole stone, material and all. One call,
                -- so a twin cannot drift from what it mirrors.
                --
                -- ---- THE FLAGS DO NOT COME ACROSS, AND THAT IS LOAD BEARING ----
                -- MEASURED from the console: granite reads IS_STONE true
                -- and MAKING_FUEL_AGG_GRANITE reads false, so this copy
                -- does not carry IS_STONE. Only IS_STONE was checked;
                -- the likely reason is that assign leaves the flag
                -- arrays behind. Names, colours and value do copy.
                --
                -- Do NOT restore the flags on their own. RM's refinish
                -- scan takes every stone, metal, gem or soil inorganic
                -- outside RM as a reagent, and the twins are already in
                -- the array when it runs. It passes over them only
                -- because they read as none of those (measured: zero
                -- twin reactions and zero twin powder renames in the
                -- blueprint). A twin with its flags back becomes a
                -- second reagent for every stone: a duplicate row per
                -- base in the refinish menu, and each stone's finish
                -- counted twice, which costs it its conserved value.
                -- Restoring the flags has to land together with a way
                -- for this module to tell RM to leave the twins out.
                twin:assign(raws[si])
                twin.id = twin_id
                twin.material.id = twin_id
                -- ---- NOT AN ORE ----
                -- assign brings the stone's ore tables across with the rest:
                -- metal_ore, the metals it smelts to, and thread_metal, the
                -- metal its strands are, so magnetite's twin was an ore of
                -- iron, as magnetite is. SEEN in play 2026-10-16: the
                -- smelter listed "smelt magnetite ore" twice, one of them
                -- the aggregate twin. DFHack's reading of DF's work order
                -- list (plugins/lua/stockflow.lua, collect_reactions) offers
                -- a smelt job for every inorganic whose metal_ore table is
                -- not empty, and a strand job for every one whose
                -- thread_metal table is not, with no other test. Gravel is
                -- never smelted or drawn into strands, so a twin carries
                -- neither table: both cleared as refinish-module-inject.lua
                -- clears an injected material's ("An injected material
                -- isn't an ore"). The flags that also mark an ore are never
                -- lent to a twin (NOT AN ORE, refinish-stockpile-windows.lua).
                twin.metal_ore.str:resize(0)
                twin.metal_ore.mat_index:resize(0)
                twin.metal_ore.probability:resize(0)
                twin.thread_metal.str:resize(0)
                twin.thread_metal.mat_index:resize(0)
                twin.thread_metal.probability:resize(0)
                for _, c in ipairs(CLASSES) do
                    twin.material.reaction_class:insert('#',
                        new_string_ptr(c))
                end
                raws:insert('#', twin)          -- APPEND: '#' is end
                at = #raws - 1
            end)
            if ok and at then made = made + 1
            else
                -- ERROR: gravel of this stone keeps the raw stone and will not answer an
                -- AGGREGATE reagent.
                log('ERROR', ('aggregate twin FAILED on inorganic %d: %s')
                    :format(si, tostring(err)), 'TWIN')
                at = nil
            end
        end
        if at then
            _G.refinish_aggregate_twin[si] = at
            _G.refinish_aggregate_is_twin[at] = true
            _G.refinish_aggregate_source[at] = si
        end
    end

    if made == 0 and had == 0 then
        log('ERROR', 'Aggregate twin push wrote NOTHING with stones present. '
            .. 'That is a bug, report it.', 'PUSH')
    else
        log('DETAIL', ('Aggregate twin push: %d twins made, %d already present, '
             .. 'from %d stone(s).'):format(made, had, #sources), 'PUSH')
    end
end

function start()
    hop_subtypes = nil
    eventful.onItemCreated[REPEAT_KEY] = function(item_id)
        local item = df.item.find(item_id)
        if item then hop(item) end
    end
    -- Enabled here as well, not left to the coal watcher. This file used
    -- to depend on the coal watcher having switched the event on, which
    -- the old 5 frame walk covered for; with the walk now a slow
    -- backstop, new gravel has to hop on the event. Frequency 0, the
    -- same as every sibling, so this changes nothing when the coal
    -- watcher has already asked for it.
    eventful.enableEvent(eventful.eventType.ITEM_CREATED, 0)
    ticks, walked = 0, false
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(REPEAT_KEY,
            { every = TICK_FRAMES, fn = function() pcall(sweep) end, paused = true }) then
        repeatUtil.cancel(REPEAT_KEY)
    else
        repeatUtil.scheduleEvery(REPEAT_KEY, TICK_FRAMES, 'frames', sweep)
    end

    -- First pass now, the rest on the tick's cadence. At this point the
    -- sprite pass may not have run yet, so this one usually copies
    -- nothing, and the CATCH_UP ticks after it do the catching up.
    pcall(sync_twins)

    -- ---- STOCKPILE WINDOWS ----
    -- A twin carries no flags (THE FLAGS DO NOT COME ACROSS), so DF would
    -- never stockpile gravel. RM's window service lends each twin its
    -- stone's flags while gravel is loose, then takes them back. The claim
    -- reads the push's own source -> twin map at every scan.
    local wapi = _G.refinish_window_api
    if wapi and wapi.claim then
        wapi.claim('REFINISH_CORE_AGGREGATE', function()
            local out = {}
            for si, ti in pairs(_G.refinish_aggregate_twin or {}) do
                out[#out + 1] = { twin = { 0, ti }, source = { 0, si } }
            end
            return out
        end, {
            item_types = { 'TOOL' },
            -- While a window lends the flags, the twins' rows in the
            -- stockpile settings read "granite (aggregate)", written to
            -- the screen's rows only (THE MENU LABEL,
            -- refinish-stockpile-windows.lua). A work order condition's
            -- Material list draws each row from the material's name and
            -- lists a twin beside its stone (in play 2026-10-15, a stone
            -- clay three times: by the code, the clay, its binder twin and
            -- this twin), so while a work order's conditions are open the
            -- tag is on the twin's name, and only then
            -- (refinish-menu-orders.lua).
            menu_tag = 'aggregate',
        })
    end
end

-- ==========================================
-- STOP
-- ==========================================
-- The runtime only. The twins themselves go with the engine's sweep of
-- REFINISH_CORE_ materials at shutdown, so there is nothing to pop.
function stop()
    eventful.onItemCreated[REPEAT_KEY] = nil
    repeatUtil.cancel(REPEAT_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(REPEAT_KEY) end
    hop_subtypes = nil
    local wapi = _G.refinish_window_api
    if wapi and wapi.unclaim then wapi.unclaim('REFINISH_CORE_AGGREGATE') end
    log('DETAIL', 'stopped.', 'STOP')
end

-- ==========================================
-- SUBTYPE RESOLUTION
-- ==========================================
-- One walk of the itemdef list builds the whole set, both ways. Returns
-- nil until at least one gravel tool resolves, so a hop attempted before
-- injection declines rather than caching an empty set and declining
-- forever. Only the gravel tools are counted: dust is always injected,
-- but without gravel there are no twins, and nothing to unhop.
function resolve_subtypes()
    if hop_subtypes then return hop_subtypes end
    local want, found, n = {}, {}, 0
    for _, id in ipairs(HOP_TOOLS) do want[id] = HOP end
    for _, id in ipairs(UNHOP_TOOLS) do want[id] = UNHOP end
    pcall(function()
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            local way = want[td.id]
            if way then
                found[td.subtype] = way
                if way == HOP then n = n + 1 end
            end
        end
    end)
    if n == 0 then return nil end
    hop_subtypes = found
    if n < #HOP_TOOLS then
        -- ERROR: each unresolved tool keeps the raw stone and will not answer an
        -- AGGREGATE reagent.
        log('ERROR', ('only %d of %d aggregate tools resolved; the rest keep the '
             .. 'raw stone, report it.'):format(n, #HOP_TOOLS), 'RESOLVE')
    end
    return hop_subtypes
end

-- ==========================================
-- THE UNHOP
-- ==========================================
-- UNHOP = put back on its stone. False = not on a twin. Two integer
-- reads for dust that is not on a twin, as the hop's early out, so the
-- walk of every dust in the fort stays cheap.
local function unhop_body(item)
    if item.mat_type ~= 0 then return false end
    local src = _G.refinish_aggregate_source
    local si = src and src[item.mat_index]
    if not si then return false end
    item.mat_index = si
    return UNHOP
end

-- ==========================================
-- THE HOP
-- ==========================================
-- True = converted. UNHOP = put back on its stone (THE UNHOP). False =
-- not ours, or already where it belongs.
--
-- The body is hoisted out of the pcall, so the walk and the created
-- event call pcall(hop_body, item) and build no closure per item.
local function hop_body(item)
    if not df.item_toolst:is_instance(item) then return false end
    local subs = resolve_subtypes()
    -- item.subtype is a POINTER to the itemdef, not an integer.
    -- The integer is one field further in.
    local way = subs and subs[item.subtype.subtype]
    if not way then return false end
    if item.flags.trader then return false end
    if way == UNHOP then return unhop_body(item) end

    local twins = _G.refinish_aggregate_twin
    local is_twin = _G.refinish_aggregate_is_twin
    if not twins then return false end

    -- ---- EARLY OUT, NO DECODE ----
    -- An inorganic item's mat_index IS the inorganic index, which
    -- is how both maps are keyed, so an item already wearing its
    -- twin is two integer reads away from being skipped.
    if item.mat_type ~= 0 then return false end
    if is_twin and is_twin[item.mat_index] then return false end

    local twin = twins[item.mat_index]
    if not twin then
        -- Gravel of something that is not a twinned stone: glass,
        -- a module material, anything the push skipped. Left as it
        -- is, and said once so the gap is visible rather than
        -- guessed at.
        log_once_missing(item.mat_index)
        return false
    end
    item.mat_index = twin
    return true
end

function hop(item)
    local ok, did = pcall(hop_body, item)
    return ok and did or false
end

-- One line per material, not per item: a fort can mint a lot of gravel.
local missing_said = {}
function log_once_missing(mi)
    if missing_said[mi] then return end
    missing_said[mi] = true
    -- A module's own material used as RM's gravel form on purpose is not
    -- a gap (Making Concrete's clinker nodules, 2026-09-25): it keeps its
    -- material, which is the point, and says so at DETAIL. It was an
    -- ERROR every session until then. Gravel of anything else with no
    -- twin, a stone the push skipped, stays an ERROR: that gravel answers
    -- no AGGREGATE reagent, and a player will meet it.
    local id = tostring(mi)
    pcall(function() id = df.global.world.raws.inorganics.all[mi].id end)
    local owned = false
    for prefix in pairs(_G.refinish_module_registry or {}) do
        if id:sub(1, #prefix) == prefix then owned = true end
    end
    if owned then
        log('DETAIL', ('gravel of %s, a module material, has no aggregate twin '
             .. 'by design: it keeps its own material and answers no AGGREGATE '
             .. 'reagent.'):format(id), 'TWIN')
    else
        log('ERROR', ('no aggregate twin for %s (inorganic %d); that gravel keeps '
             .. 'its raw stone and will not answer an AGGREGATE reagent.')
             :format(id, mi), 'TWIN')
    end
end

-- ==========================================
-- THE SPRITE SYNC
-- ==========================================
-- Copies the source stone's sprite fields onto its twin, so a twin
-- wears whatever the sprite pass gave the stone it mirrors, whenever
-- that happened. Only writes what differs, so a settled fort does the
-- comparisons and nothing else.
-- One twin, hoisted so the sync builds no closure per twin. Returns how
-- many fields it wrote.
local function sync_one(raws, si, ti)
    local sm, tm = raws[si].material, raws[ti].material
    local n = 0
    for _, f in ipairs(SPRITE_FIELDS) do
        if tm[f] ~= sm[f] then
            tm[f] = sm[f]
            n = n + 1
        end
    end
    return n
end

function sync_twins()
    local changed = 0
    local raws = df.global.world.raws.inorganics.all
    for si, ti in pairs(_G.refinish_aggregate_twin or {}) do
        local ok, n = pcall(sync_one, raws, si, ti)
        if ok then changed = changed + n end
    end
    if changed > 0 then
        log('DETAIL', ('%d sprite field(s) synced onto twins.'):format(changed), 'SPRITE')
    end
    return changed
end

-- ==========================================
-- THE SWEEP
-- ==========================================
-- One tick: the sync on its cadence, then the backstop walk on its own.
-- See CADENCES at the top for both.
function sweep()
    ticks = ticks + 1
    if ticks <= CATCH_UP or ticks % SYNC_TICKS == 0 then
        pcall(sync_twins)
    end
    if not resolve_subtypes() then return end
    if walked and ticks % WALK_TICKS ~= 0 then return end
    walked = true
    -- n hopped onto twins, u put back on their stones (THE UNHOP).
    local n, u = 0, 0
    pcall(function()
        for _, item in ipairs(df.global.world.items.other.TOOL) do
            local did = hop(item)
            if did == UNHOP then
                u = u + 1
            elseif did then
                n = n + 1
            end
        end
    end)
    if n > 0 then
        log('DETAIL', ('sweep hopped %d gravel to twin stone.'):format(n), 'SWEEP')
    end
    if u > 0 then
        log('DETAIL', ('sweep put %d dust back on its stone.'):format(u), 'SWEEP')
    end
end