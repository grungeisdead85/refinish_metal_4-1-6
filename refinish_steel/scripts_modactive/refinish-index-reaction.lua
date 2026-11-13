-- refinish-index-reaction.lua
-- ==========================================
-- SCRIPT LOGIC: REACTION & CATEGORY BUILDER
-- ==========================================

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body. The
-- panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: the step or thing a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INDEX_REACTIONS'
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

log('DETAIL', 'Reaction and category injection initiated.')

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_reactions_loaded == nil or _G.refinish_reactions_loaded == false then
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
            _G.refinish_reactions_loaded = true
            break
        end
    end
end

if _G.refinish_reactions_loaded then
    log('DETAIL', 'Reactions already indexed. Skipping.')
    return
end

local reactions_array = df.global.world.raws.reactions.reactions
local cat_array = df.global.world.raws.reactions.reaction_categories

if not _G.refinish_blueprint or not _G.refinish_blueprint.reactions then
    log('ERROR', 'Blueprint missing, so no refinish reactions were built.'
        .. ' refinish-scan has to run first.')
    return
end

-- ==========================================
-- 1. DYNAMIC CATEGORY INJECTION (DEPTH MAPPED)
-- ==========================================

-- THE LOAD CLOCK (refinish-startup.lua): nil outside a pipeline run.
-- The colour reactions' new and assign are summed on their own.
local LC = _G.refinish_load_clock
local t_xr = LC and LC.now()
local s_rassign = 0

-- PRE-BUILD: Snapshot every category ID already in the live array ONCE
-- before we start injecting. This replaces the O(N) linear scan that the
-- old inject_category did on every single call, which grew more expensive
-- with every category added during the same loop.
local existing_cats = {}
for _, c in ipairs(cat_array) do
    existing_cats[c.id] = true
end

local function inject_category(id, name, parent)
    -- O(1) hash lookup instead of O(N) array scan
    if existing_cats[id] then return end
    
    local c = df.reaction_category:new()
    c.id = id
    c.name = name
    c.parent = parent or ""
    cat_array:insert('#', c)
    
    -- Keep the set current so duplicate IDs within the
    -- same injection batch are also caught correctly
    existing_cats[id] = true
end

local pending_cats = {}
for _, cat_data in pairs(_G.refinish_blueprint.categories) do
    table.insert(pending_cats, cat_data)
end

-- ==========================================
-- THE FIX: DEPTH-FIRST TREE FLATTENER
-- Eliminates arbitrary name/tier sorting. Uses pure ID/Parent relationships
-- to feed categories to the engine in a contiguous state-machine order.
-- ==========================================
local cat_map = {}
local root_cats = {}

-- 1. Index everything by ID
for _, cat in ipairs(pending_cats) do
    cat_map[cat.id] = cat
    cat.children = {}
end

-- 2. Build the exact family tree
for _, cat in ipairs(pending_cats) do
    if cat.parent == "" or not cat_map[cat.parent] then
        table.insert(root_cats, cat)
    else
        table.insert(cat_map[cat.parent].children, cat)
    end
end

-- 3. Recursively sort siblings alphabetically by ID
local function sort_children(node)
    table.sort(node.children, function(a, b) return a.id < b.id end)
    for _, child in ipairs(node.children) do
        sort_children(child)
    end
end
table.sort(root_cats, function(a, b) return a.id < b.id end)
for _, root in ipairs(root_cats) do
    sort_children(root)
end

-- 4. Flatten the tree Depth-First so parents are immediately followed by their lineages
local sorted_cats = {}
local function flatten(node)
    table.insert(sorted_cats, node)
    for _, child in ipairs(node.children) do
        flatten(child)
    end
end
for _, root in ipairs(root_cats) do
    flatten(root)
end

pending_cats = sorted_cats

-- Inject cleanly contiguous lineage
for _, cat in ipairs(pending_cats) do
    inject_category(cat.id, cat.name, cat.parent)
end

-- The finished-metal grinders' folder at the quern and the millstone
-- (refinish-mint-finish.lua, THE FINISHED-METAL GRINDERS). Made every
-- cycle; refinish-clear-reaction.lua takes it off with every
-- REFINISH_STEEL_CAT_ category. A workshop lists a category only when a
-- reaction there is filed under it, so it shows once a grinder is.
inject_category("REFINISH_STEEL_CAT_GRIND_FINISHED", "Grind finished metals", "")

-- ==========================================
-- 2. TEMPLATE ACQUISITION (FROM BOOT CACHE)
-- ==========================================
-- Boot ran the metal-making and dust-making evaluators at startup
-- and cached the highest-scoring templates in _G. We pull those
-- cached results here instead of re-scanning every loaded reaction.
--
-- The evaluators score candidates on structural criteria (building
-- type, skill, reagent/product shapes, fuel flags) and pick the
-- best match. This is a scored selection, not a first-match grab.
--
-- The cached tables contain:
--   _G.refinish_best_metal_template:
--     .reaction  = the df.reaction object
--     .rgt_idx   = index of the inorganic bar reagent
--     .prod_idx  = index of the inorganic bar product
--     .code, .score
--
--   _G.refinish_best_dust_template:
--     .reaction  = the df.reaction object
--     .bag_idx   = index of the bag reagent
--     .prod_idx  = index of the powder product
--     .code, .score
-- ==========================================
local metal_rxn = nil
local metal_rgt_idx = -1
local metal_prod_idx = -1

local powder_rxn = nil
local powder_bag_idx = -1
local powder_prod_idx = -1

local inorganics = df.global.world.raws.inorganics.all

-- Pull from boot cache
local metal_cache = _G.refinish_best_metal_template
local dust_cache = _G.refinish_best_dust_template

if metal_cache and metal_cache.reaction then
    metal_rxn = metal_cache.reaction
    metal_rgt_idx = metal_cache.rgt_idx
    metal_prod_idx = metal_cache.prod_idx
end

if dust_cache and dust_cache.reaction then
    powder_rxn = dust_cache.reaction
    powder_bag_idx = dust_cache.bag_idx
    powder_prod_idx = dust_cache.prod_idx
end

if not metal_rxn or not powder_rxn then
    log('ERROR', string.format('Missing cached engine templates (metal: %s,'
        .. ' powder: %s), so no refinish reactions were built.',
        tostring(metal_rxn ~= nil), tostring(powder_rxn ~= nil)), 'TEMPLATES')
    return
else
    log('DETAIL', string.format('Cached shells acquired. Metal: %s (R:%d,'
        .. ' P:%d) | Powder: %s (R:%d, P:%d)', metal_rxn.code, metal_rgt_idx,
        metal_prod_idx, powder_rxn.code, powder_bag_idx, powder_prod_idx),
        'TEMPLATES')
end

-- ---- RM'S DUST TOOL ----
-- Refinish reactions take one of these and the grinders make them. It
-- is injected by RM's core payload through the module engine, which
-- runs before this file does. Without it there is no dust to take, so
-- no refinish reaction or grinder is built, and the log says why. The
-- next data cycle tries again.
local DUST_TOOL = "REFINISH_CORE_DUST"
local dust_subtype = nil
for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
    if td.id == DUST_TOOL then dust_subtype = td.subtype break end
end
if not dust_subtype then
    log('ERROR', DUST_TOOL .. ' is not injected, so no refinish reaction or'
        .. ' grinder was built. See refinish-core-payload.', 'TEMPLATES')
    return
end

-- Build the Virtual Template from the dynamically acquired metal reaction
local template_rxn = df.reaction:new()
template_rxn:assign(metal_rxn)

template_rxn.code = "VIRTUAL_REFINISH_TEMPLATE"
template_rxn.name = "virtual refinish template"

-- ---- THE TEMPLATE'S IDENTITY, LEFT BEHIND ----
-- assign copies the metal reaction's descriptions and raw strings as
-- vectors of pointers to that reaction's own objects, and every finish
-- reaction is copied from this one, at load and in play. Until 2026-10-03
-- every finish showed the metal reaction's description in the task pane
-- (argmod's hardsteel, in region4). resize(0) drops the pointers and
-- leaves the objects to the reaction that owns them. The same reset the
-- module engine gives its clones (refinish-module-react.lua, STEP 2.5,
-- template identity baggage).
template_rxn.raw_strings:resize(0)
template_rxn.descriptions:resize(0)
template_rxn.source_hfid = -1
template_rxn.source_enid = -1

-- THE FIX: Hardcode the fuel flag to true so all finishes demand fuel. 
-- The engine will automatically ignore this flag if the task is run at a Magma Forge.
template_rxn.flags.FUEL = true

local SAFE_INDEX = 0
for i, mat in ipairs(inorganics) do
    if mat.id == "STEEL" then SAFE_INDEX = i; break end
end

-- ==========================================
-- REAGENTS (Synthesized from Dynamic Shells)
-- ==========================================
template_rxn.reagents:resize(0)

-- 1. The Input Bar (Cloned from the dynamically found metal reagent)
local r_steel = df.reaction_reagent_itemst:new()
r_steel:assign(metal_rxn.reagents[metal_rgt_idx]) 
r_steel.code = "steel_bar"
r_steel.quantity = 450 -- Adjusted to standard 150 bar volume based on probe
r_steel.min_dimension = -1 
r_steel.mat_type = 0
r_steel.mat_index = SAFE_INDEX 
template_rxn.reagents:insert('#', r_steel)

-- ---- WHAT THE POWDER DUST NEEDED (kept for anyone building a
-- powder in a bag again) ----
-- Before 2026-09-25 the dust was POWDER_MISC in a bag, and three things
-- had to be true or the reaction never ran, each found by probe:
--   * item_type 70 is POWDER_MISC, and a powder reagent takes 150 units.
--   * THE MISSING LINK: the powder reagent MUST carry IN_CONTAINER, or
--     nothing will accept the dust as sitting in a bag.
--   * The bag reagent (cloned from the evaluated powder shell) had its
--     EMPTY bit cleared (flags1.empty = false) so it was allowed to hold
--     the dust, and its contains list pointed at the dust reagent's
--     index.
-- 2. The Dust: one of RM's dust tools, in the reagent's own material,
--    which each reaction pins below. Six dust finish the three bars, two
--    a bar, whatever the dust was ground from (2026-10-03; one dust of
--    the old unit until then). No
--    bag: dust is a tool now, not a powder, so nothing holds it.
local r_dust = df.reaction_reagent_itemst:new()
r_dust:assign(metal_rxn.reagents[metal_rgt_idx]) -- Clone the basic item shape
r_dust.code = "dust"
r_dust.item_type = df.item_type.TOOL
r_dust.item_subtype = dust_subtype
r_dust.quantity = 6 -- two dust a bar, the same for every dust
r_dust.min_dimension = -1
r_dust.mat_type = 0
r_dust.mat_index = -1
template_rxn.reagents:insert('#', r_dust)

-- ==========================================
-- PRODUCTS 
-- ==========================================
template_rxn.products:resize(0)
local p_bar = df.reaction_product_itemst:new()
p_bar:assign(metal_rxn.products[metal_prod_idx])
p_bar.count = 3 -- 3 standard bars
p_bar.product_dimension = 150 -- 150 volume per bar
p_bar.mat_type = 0
p_bar.mat_index = -1 
template_rxn.products:insert('#', p_bar)

-- ==========================================
-- 3. THE FINISHES THE FORT CAN MAKE
-- ==========================================
-- Until 2026-10-02 this built a reaction for every finish in the
-- blueprint, 99,574 with every base metal selected. Now only the pairs of
-- base metal and dust the fort has had both of are built
-- (refinish-mint-finish.lua, which also mints them in play). Their ids
-- come from there, grouped by category and sorted as the full set was,
-- and each is built there by build_reaction(), so the load and a mint in
-- play make a finish reaction the same way. The material lookup this
-- section used to build lives there too (index_of).
--
-- Without refinish-mint-finish no finish reaction or forge folder is
-- built, and the grinders below still are.
-- ==========================================
if LC then t_xr = LC.lap('reactions (finishes): categories and templates', t_xr) end
local count = 0
local ok_mint, mint = pcall(reqscript, 'refinish-mint-finish')
if not ok_mint then
    log('ERROR', 'refinish-mint-finish could not be loaded, so no finish reaction'
        .. ' or forge folder was built: ' .. tostring(mint), 'TEMPLATES')
    mint = nil
end

-- ---- THE TEMPLATE, READ ONCE ----
-- What each reaction takes from template_rxn beyond its assign (each
-- reagent's code, each product's item type) is read here once, not again
-- for every reaction: the loop used to walk the template's vectors and
-- read those fields back through DFHack 99,574 times. Each reaction's
-- own vectors are read once too (refinish-mint-finish.lua,
-- build_reaction), and the array's length once a reaction.
local tmpl_reagents, tmpl_products = {}, {}
-- ---- ONLY WHAT ASSIGN LEFT TO DO ----
-- assign copies the template's reagents, product and flags, so a write
-- below of a value the template already holds changes nothing: type0
-- marks a template reagent or product already on mat_type 0, and
-- fuel_set the template's own FUEL flag. Read once here, and those
-- writes are skipped for every reaction. MEASURED 2026-10-01 (the load
-- clock, region4): this loop cost 984 ms for 99,574 reactions. mat_type
-- is read under pcall: a reagent or product class without one is left
-- to the writes, as before.
local function mat_type_of(x) return x.mat_type end
for _, orig_rgt in ipairs(template_rxn.reagents) do
    local ok_t, mt = pcall(mat_type_of, orig_rgt)
    tmpl_reagents[#tmpl_reagents + 1] = { ref = orig_rgt, code = orig_rgt.code,
        type0 = ok_t and mt == 0 }
end
local ITEM_BAR = df.item_type.BAR
for _, orig_prod in ipairs(template_rxn.products) do
    local ok_t, mt = pcall(mat_type_of, orig_prod)
    tmpl_products[#tmpl_products + 1] = { ref = orig_prod, is_bar = orig_prod.item_type == ITEM_BAR,
        type0 = ok_t and mt == 0 }
end
local fuel_set = template_rxn.flags.FUEL

-- ---- THE ENTITY STAGE'S HANDOVER ----
-- refinish-index-entity's phase 1 needs every finish reaction's position
-- by base metal, and the grinders', and found them by reading all
-- 103,534 reaction codes (MEASURED 2026-10-01, the load clock, region4:
-- 126 ms). This stage knows each as it builds it, so it writes them down
-- in array order, with the first and last code of each base metal, and
-- publishes them with the array's length when the grinders are done.
-- Phase 1 checks them against the live array before it uses them.
local handover = { finishes = {}, first_code = {}, last_code = {}, grinders = {} }

-- One reaction written down for the entity stage, in array order, with
-- its base metal's first and last code.
local function hand_over(b_id, code, index)
    local list = handover.finishes[b_id]
    if not list then
        list = {}
        handover.finishes[b_id] = list
        handover.first_code[b_id] = code
    end
    list[#list + 1] = index
    handover.last_code[b_id] = code
end

-- ==========================================
-- 4. BUILD THE FINISH REACTIONS
-- ==========================================
-- The shell goes over first. A mint in play builds from it too, until
-- the next data cycle hands over a new one.
if mint then
    local bp_reactions = _G.refinish_blueprint.reactions
    local ok_b, err_b = pcall(function()
        mint.set_shell({
            template     = template_rxn,
            reagents     = tmpl_reagents,
            products     = tmpl_products,
            fuel_set     = fuel_set,
            powder_rxn   = powder_rxn,
            metal_rgt    = metal_rxn.reagents[metal_rgt_idx],
            dust_subtype = dust_subtype,
        })
        local ids = mint.minted_reactions()
        if LC then t_xr = LC.lap('reactions (finishes): pairs the fort can make', t_xr) end
        for _, rxn_id in ipairs(ids) do
            local idx = mint.build_reaction(rxn_id)
            if idx then
                -- Written down for the entity stage (THE ENTITY STAGE'S HANDOVER).
                hand_over(bp_reactions[rxn_id].base_metal_id, rxn_id, idx)
                count = count + 1
            end
        end
    end)
    if not ok_b then
        -- ERROR: the reactions built before the fault stand; the rest of
        -- the fort's finishes have no reaction this cycle.
        log('ERROR', 'Finish reactions not built: ' .. tostring(err_b), 'FINISHES')
    end
end

-- THE LOAD CLOCK: the finish reaction loop, its new and assign apart.
if LC then
    LC.add('reactions (finishes): new and assign', mint and mint.assign_ms() or 0, count)
    t_xr = LC.lap('reactions (finishes): colour reaction loop, all of it', t_xr)
end

-- ==========================================
-- 5. LUA-GENERATED GRINDERS
-- ==========================================
-- Four general reactions at the quern and the millstone, each grinding
-- one kind of feedstock into RM's dust tool in the feedstock's own
-- material (GET_MATERIAL_SAME off the input). No bag reagent: dust is a
-- tool now. The per-job clone that pins the material and names it
-- ("grind cinnabar into dust") is cut from these by the JIT watcher in
-- refinish_steel.
--
-- Still built on the evaluated dust template (powder_rxn), which is
-- where the reaction shell and the product's shape come from; only the
-- product's item type and subtype change.
-- ==========================================
local function build_grinder(code, name, skill, bld_type, bld_subtypes, item_type, qty, prod_count, is_worthless, requires_fuel, rclass)
    local rxn = df.reaction:new()
    rxn:assign(powder_rxn) -- The evaluated shell
    -- The shell's own descriptions and raw strings stay with it (THE
    -- TEMPLATE'S IDENTITY, LEFT BEHIND, above).
    rxn.raw_strings:resize(0)
    rxn.descriptions:resize(0)
    rxn.source_hfid = -1
    rxn.source_enid = -1

    rxn.code = code
    rxn.name = name
    rxn.skill = skill
    rxn.category = ""
    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)

    rxn.flags.FUEL = requires_fuel or false

    -- Reprogram Building
    rxn.building.type:resize(0)
    rxn.building.subtype:resize(0)
    rxn.building.custom:resize(0)
    for _, st in ipairs(bld_subtypes) do
        rxn.building.type:insert('#', bld_type)
        rxn.building.subtype:insert('#', st)
        rxn.building.custom:insert('#', -1)
    end

    -- DEEP COPY: Reagents & Products
    rxn.reagents:resize(0)

    -- Reagent 0: The Input Item
    local r_in = df.reaction_reagent_itemst:new()
    r_in:assign(metal_rxn.reagents[metal_rgt_idx]) -- Use a clean base item to overwrite
    r_in.code = "input"
    r_in.quantity = qty
    r_in.item_type = item_type
    r_in.item_subtype = -1
    r_in.mat_type = 0   -- INORGANIC
    r_in.mat_index = -1 -- ANY

    -- The input's class: none, unless the grinder takes only materials
    -- that carry one (THE METAL GRINDER'S CLASS, below).
    r_in.reaction_class = rclass or ""
    rxn.reagents:insert('#', r_in)

    -- Product 0: RM's dust tool, in the input's material
    rxn.products:resize(0)
    local p_out = df.reaction_product_itemst:new()
    p_out:assign(powder_rxn.products[powder_prod_idx])
    p_out.item_type = df.item_type.TOOL
    p_out.item_subtype = dust_subtype
    p_out.count = prod_count
    p_out.mat_type = -1
    p_out.mat_index = -1
    p_out.product_to_container = ""
    p_out.flags.GET_MATERIAL_SAME = true
    p_out.get_material.reagent_code = "input"

    rxn.products:insert('#', p_out)

    -- Insert the complete reaction into the live global array
    rxn.index = #reactions_array
    reactions_array:insert('#', rxn)
    -- Written down for the entity stage (THE ENTITY STAGE'S HANDOVER).
    handover.grinders[#handover.grinders + 1] = { code = code, index = rxn.index }

    -- Write the static C++ bitfield directly to the live memory pointer
    reactions_array[#reactions_array - 1].reagents[0].flags2.non_economic = is_worthless

end

-- The four grinders, at the quern and the millstone, named by their
-- enums so no number can drift. The counts are how many stacks: a
-- boulder's dust comes in four, so four jobs can draw from it at once,
-- and three rough gems' or a bar's in one. How much is in them is
-- measured from what was ground, in the dust's own unit: 50 from a
-- boulder, 3 and three quarters from three rough gems, 3 from a bar
-- (refinish-reaction-outputs.lua, MEASURED STACKS). The skills stay the material's
-- own: the gem cutter grinds gems, the mason stone, the metalsmith bars.
-- For reference, the grinders' old homes by number, as this file wrote
-- them before the enum names: building type 13 is a workshop; subtype 4
-- Jeweler, 2 Mason, 5 and 6 Forge and Magma Forge.
-- ==========================================
-- THE METAL GRINDER'S CLASS
-- ==========================================
-- The metal grinder took a bar of ANY inorganic, so its job details
-- picker listed every one (62,239 rows with every base metal on) and DF
-- took 31 s to open it (lag probe, 2026-09-30). With a class on its
-- input that only grindable metals carry, the same picker opened in
-- 5.1 s (class probe, same day). The list is still every inorganic, as
-- DF builds it whatever the class; what went is the rest of the 31 s,
-- read as DF counting usable bars for every row, now that only bars of
-- the grindable metals qualify. Finished bars never carry it: they are
-- ground at grinders of their own, one per base metal (THE FINISHED-METAL
-- GRINDERS, below), so they stay out of this picker.
--
-- WHO CARRIES IT: RM's valid metals, the ones the metals panel lets you
-- select (refinish-boot's list, _G.refinish_valid_bases at STEP 2.5,
-- less the entries with no known crafting path, which the panel sorts
-- with its unavailable metals and will not select), less the active base
-- metals while base protection is on, the same site data the grind
-- watcher reads. Changing protection takes a data cycle, which the
-- config panel prompts for. Anything that is also a stone is left out:
-- a class makes a material economic, and the non_economic reagents that
-- care (DF's WORTHLESS_STONE_ONLY) take boulders, never bars, so only a
-- metal that is also a stone could be moved by it.
--
-- THE LIFECYCLE: granted here, at STEP 5, after every material this
-- cycle makes (modules at STEP 2, finishes at STEP 4), so nothing copies
-- a metal while it carries the class.
-- A finish minted after this step, at a load or in play
-- (refinish-mint-finish.lua), copies its base metal with the class on
-- it, and erases the entry from its copy (THE GRINDER'S CLASS STAYS ON
-- THE BASE, there). Taken off every inorganic by
-- refinish-clear-reaction at shutdown, before the next cycle copies base
-- metals into finishes. The save hook shuts RM down before every save,
-- so the class never reaches one.
-- ==========================================
-- Words, not a token (2026-10-05): DF prints a reagent's class in the
-- grinder's hover and objection ("150 unfinished metal bars"), so the
-- class is the words a player reads. Only RM writes lowercase classes
-- (raws tokens are uppercase, and the modules' reads words are taken back
-- before any clear, refinish-material-classes.lua), so the text still
-- names RM's own strings at shutdown.
local GRIND_METAL_CLASS = 'unfinished metal'   -- refinish-clear-reaction.lua and refinish-mint-finish.lua match this string

-- reaction_class is a vector of string POINTERS: a new entry is a string
-- allocated for it, and its text is on .value.
local function new_string_ptr(s)
    local p = df.new('string'); p.value = s; return p
end

-- The protected bases, as the grind watcher reads them (refinish_steel,
-- PROTECTED BASES): protection is on only when set to YES, and the
-- protected bases are the selected ones, every base with a refinishing
-- path when none is saved (refinish-bases.lua, THE DEFAULT SELECTION).
-- Off by default since 2026-10-03: with every base selected by default,
-- protection would leave the metal grinder no metal to take. Until then
-- it was on unless set otherwise, and steel was the default base.
local function protected_bases()
    local protect = dfhack.persistent.getSiteData('refinish_config_protect')
    if protect ~= 'YES' then return {} end
    local set = {}
    local raw = dfhack.persistent.getSiteData('refinish_config_bases')
    if raw and raw ~= '' then
        pcall(function() set = require('json').decode(raw) end)
    else
        set = dfhack.script_environment('refinish-bases').default_bases() or {}
    end
    return set
end

-- Gives the class to every grindable metal. Returns how many carry it,
-- or nil when the boot scan left no valid metal list, in which case the
-- grinder keeps its open input rather than taking nothing.
local function grant_grind_class()
    local valid = _G.refinish_valid_bases
    if type(valid) ~= 'table' then return nil end
    local inorgs = df.global.world.raws.inorganics.all
    local n_inorg = #inorgs
    local skip = protected_bases()
    local granted, unavailable, protected, stones, moved = 0, 0, 0, 0, 0
    for _, e in ipairs(valid) do
        -- e.index is the 0 based DF index the boot scan read it at.
        local r = (type(e.index) == 'number' and e.index >= 0 and e.index < n_inorg)
            and inorgs[e.index] or nil
        if not r or tostring(r.id) ~= tostring(e.id) then
            moved = moved + 1
        elseif not e.has_reaction then
            -- No known crafting path: the metals panel will not select it
            -- as a base and sorts it with its unavailable metals, so it is
            -- not a valid metal for the grinder either.
            unavailable = unavailable + 1
        elseif skip[e.id] then
            protected = protected + 1
        elseif r.material.flags.IS_STONE then
            stones = stones + 1
        else
            local has = false
            for _, rc in ipairs(r.material.reaction_class) do
                if rc and rc.value == GRIND_METAL_CLASS then has = true; break end
            end
            if not has then
                r.material.reaction_class:insert('#', new_string_ptr(GRIND_METAL_CLASS))
            end
            granted = granted + 1
        end
    end
    log('DETAIL', ('metal grinder: %d valid metal(s) carry %s; left out %d with no known'
        .. ' crafting path, %d protected base(s) and %d that are also stone%s.'):format(granted,
        GRIND_METAL_CLASS, unavailable, protected, stones,
        moved > 0 and ('; ' .. moved .. ' not found where the boot scan read them') or ''))
    return granted
end

-- 0 granted still means the class: every valid metal is a protected
-- base, and then nothing may be ground, as the watcher would rule.
local grind_class = grant_grind_class() and GRIND_METAL_CLASS or ''
if grind_class == '' then
    -- WARNING: the grinder works as before, finished bars included.
    log('WARNING', 'no valid metal list from the boot scan, so the metal grinder takes any'
        .. ' bar, finished ones included, and its material picker opens slowly.')
end

local WORKSHOP = df.building_type.Workshop
local GRIND_AT = { df.workshop_type.Quern, df.workshop_type.Millstone }
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_GEMS", "grind rough gems into dust", df.job_skill.CUTGEM, WORKSHOP, GRIND_AT, df.item_type.ROUGH, 3, 1, false, false)
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_COMMON", "grind common stone into dust", df.job_skill.MASONRY, WORKSHOP, GRIND_AT, df.item_type.BOULDER, 1, 4, true, false)
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_ANY", "grind any stone into dust", df.job_skill.MASONRY, WORKSHOP, GRIND_AT, df.item_type.BOULDER, 1, 4, false, false)
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_METAL", "grind metal bars into dust", df.job_skill.METALCRAFT, WORKSHOP, GRIND_AT, df.item_type.BAR, 150, 1, false, false, grind_class)

-- ==========================================
-- 6. THE FORGE'S FOLDER PLACEHOLDERS
-- ==========================================
-- One reaction per kind folder (colour-based, material-based) inside each
-- base metal folder, so DF opens the folder that refinish-menu-forge.lua
-- fills with that kind's finishes. Why they exist
-- and how they are built: refinish-mint-finish.lua, THE FORGE'S FOLDER
-- PLACEHOLDERS (moved there 2026-10-02 with the builder, which minting
-- in play uses too). A kind folder gets one only once a finish of that
-- kind is in the array, since a folder holding nothing would open on an
-- empty list.
--
-- Built last, sorted by base id and kind, so positions repeat every
-- cycle. Each
-- joins its base metal's finishes in the handover, last, so the entity
-- stage grants it wherever it grants them, and the stage's check reads
-- its code; the stage's walk does the same by the code's prefix
-- (REFINISH_STEEL_RXN_FORGE_FOLDER_ in its sort).
-- ==========================================
local folders_built = 0
if mint then
    local forge = _G.refinish_blueprint.forge
    for _, f in ipairs(mint.folders()) do
        local ok, idx = pcall(mint.build_placeholder, f.base, f.kind)
        if ok and idx then
            hand_over(f.base, forge.bases[f.base].kinds[f.kind].rxn, idx)
            folders_built = folders_built + 1
        else
            -- ERROR: that kind's finishes stay in the forge's category
            -- lists; refinish-menu-forge files only finishes whose kind
            -- folder has its placeholder.
            log('ERROR', ('Forge folder placeholder for %s (%s) not built: %s'):format(
                tostring(f.base), tostring(f.kind), tostring(idx)), 'FORGE_FOLDERS')
        end
    end
end
log('DETAIL', folders_built .. ' forge folder placeholder(s) built.', 'FORGE_FOLDERS')

-- ==========================================
-- 7. THE FINISHED-METAL GRINDERS
-- ==========================================
-- One per base metal with a finish in the array, at the quern and the
-- millstone, filed under Grind finished metals: how and why,
-- refinish-mint-finish.lua, THE FINISHED-METAL GRINDERS. Copies of the
-- metal grinder, so built after it. Sorted by base id, so positions
-- repeat every cycle. Each joins its base metal's finishes in the
-- handover, last, so the entity stage grants it wherever it grants them;
-- the stage's walk does the same by the code's prefix
-- (REFINISH_STEEL_RXN_LUA_GRIND_FIN_ in its sort).
-- ==========================================
local fin_grinders_built = 0
if mint then
    for _, b in ipairs(mint.fin_grinder_bases()) do
        local ok, idx, code = pcall(mint.build_fin_grinder, b)
        if ok and idx then
            hand_over(b, code, idx)
            fin_grinders_built = fin_grinders_built + 1
        else
            -- ERROR: that base's finished bars cannot be ground this cycle.
            log('ERROR', ('Finished-metal grinder for %s not built: %s'):format(
                tostring(b), tostring(idx)), 'FIN_GRINDERS')
        end
    end
end
log('DETAIL', fin_grinders_built .. ' finished-metal grinder(s) built.', 'FIN_GRINDERS')

-- The handover is complete: the entity stage checks this length against
-- the array's before it uses the lists.
handover.len = #reactions_array
_G.refinish_rxn_handover = handover

_G.refinish_reactions_loaded = true

if LC then t_xr = LC.lap('reactions (finishes): grinders and grind class', t_xr) end
log('DETAIL', 'Reaction injection complete: ' .. count .. ' refinish'
    .. ' reactions added, plus the four grinders.')

-- ---- THE REACTION INDEX, BROUGHT UP TO DATE ----
-- RM's reaction index (refinish-resolve.lua, REACTIONS) is usually first
-- built during the module pipeline, before this file adds its ~100,000
-- reactions, and it reads new ones on the next lookup that misses. That
-- lookup came in play, on a workshop sheet. Reading them here puts the
-- cost in startup. reqscript is fine on this path: it runs once a cycle,
-- not per poll.
pcall(function()
    local sync = _G.refinish_reactions_sync
    if not sync then
        reqscript('refinish-resolve')
        sync = _G.refinish_reactions_sync
    end
    if sync then sync() end
end)

-- ---- STEP 5 DONE: MINTING IN PLAY MAY BUILD FOLDERS ----
-- From here a finish minted after this step (refinish-mint-finish.lua)
-- brings its kind folder's placeholder with it, and the roster keeps whatever
-- this step minted.
if mint then pcall(mint.finish_load) end

-- ---- SAVED JOBS FOLLOW THEIR REACTIONS ----
-- A job's filters name its reaction by position (refinish-module-engine,
-- JOB FILTERS FOLLOW THEIR REACTION). This file builds its reactions in
-- one order every cycle, but the set can differ from the session that
-- saved a job: a pair minted in play was appended after the placeholders
-- and is sorted into place here, and a save from before the finish
-- roster had every finish reaction. repoint_job_filters runs in the
-- module pipeline at Step 2, before any of these exist, so it runs again
-- now that they all do; its lookups use the reaction index brought up to
-- date just above.
pcall(function()
    local rp = _G.refinish_repoint_jobs
    if not rp then return end
    local n_jobs, n_filters = rp()
    if n_jobs and n_jobs > 0 then
        log('DETAIL', string.format("Re-pointed %d filter(s) on %d saved job(s) to"
            .. " their reactions' current positions.", n_filters, n_jobs), 'REPOINT')
    end
end)