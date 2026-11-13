--@ module = true
-- refinish-core-payload.lua
-- ==========================================
-- RM CORE PAYLOAD
-- ==========================================
-- What RM itself injects through the module engine, the same way a
-- module does, so everything the engine does for modules it does for
-- RM's own assets too: validation, the tool injector, the tool wash
-- across saves, the ledger, the prefix sweeps, dependency order.
--
-- ---- ISOLATION: ONE REGISTRATION PER THING THAT CAN FAIL ALONE ----
-- The engine accepts or refuses a registration as a whole. When RM's
-- dust shared a registration with the catalog's crush reactions, one
-- missing field in the reactions' module block refused the lot and
-- took the dust down with it, and with the dust every refinish
-- reaction. So nothing RM needs shares a registration with anything
-- that can fail on its own:
--
--   Refinish Core     REFINISH_CORE_     the dust tool. Always injected.
--                                        Nothing else rides with it.
--   Gravel (catalog)  REFINISH_GRAVEL_   the gravel form: its tool, its
--                                        crush reactions and its grind,
--                                        injected only when a module asks.
--   Refinish Bricks   REFINISH_BRICK_    the grog brick reaction. Always
--                                        injected: a stone dust outlet
--                                        that needs no module.
--   Refinish Dyes     REFINISH_DYE_      a mineral dye for every colour
--                                        dust comes in, built at the token
--                                        call by refinish-dyes.lua. Always
--                                        injected.
--
-- Each catalog form is its own registration, so a form that fails
-- takes down that form alone, never dust and never another form. And a
-- module's failure can never take a form away from another module:
-- every module asks for what it needs itself (its module block's
-- "requires"), so a form stays in as long as any accepted module asked.
--
-- WHY NOT RM'S FINISHING BAND. The finishing materials and reactions
-- are REFINISH_STEEL_ and built by RM's own pipeline, which runs after
-- the modules. The engine refuses any module prefix that stems with
-- REFINISH_STEEL_, and no two prefixes here stem each other.
--
-- ---- WHAT IS HERE ----
-- A reaction is named as the module engine builds it: prefix, RXN_, key
-- (refinish-module-react.lua). Anything that watches one by code must use
-- that name; the brick service once used the key without RXN_ and never
-- saw its own reaction (2026-10-04).
--   REFINISH_CORE_DUST        the dust tool, 200 a unit (100 until
--                             2026-10-07, when a boulder finished about
--                             fifty bars). Two dust, in the material it
--                             was ground or shed from, finish a bar. The refinish reactions take it, the
--                             grinders make it, and RM's byproduct
--                             service pays it whatever modules run.
--   REFINISH_GRAVEL_TOOL      the gravel tool, 600 (one bar's volume) of
--                             the stone it came from, stacked: the
--                             standard aggregate size, so a recipe taking
--                             aggregates by ratio can take any of them.
--                             A quarter boulder (2500) until 2026-10-07;
--                             slag comes in heaps the same size.
--   REFINISH_GRAVEL_RXN_CRUSH at the mason's workshop, one boulder into
--   REFINISH_GRAVEL_RXN_CRUSH_COMMON  twelve gravel and the rest as dust:
--                             the gravel is 7200, and the dust is what
--                             the boulder measured less the gravel (14
--                             from a 10000 boulder), favouring gravel
--                             because gravel is what the mason is after.
--   REFINISH_GRAVEL_RXN_GRIND at the quern and the millstone, beside RM's
--                             stone grinders, twelve stone gravel into 36
--                             dust, all of it: gravel's route to grog
--                             bricks, the dyes and finishing. The dust goes
--                             back onto the gravel's stone
--                             (refinish-material-aggregate.lua, THE UNHOP).
--   REFINISH_BRICK_RXN_GROG   at the kiln, a clay boulder and 13 stone dust
--                             of grog into vanilla's bricks of the clay's
--                             fired material. How many is measured by
--                             refinish-bricks.lua, which pays vanilla's make
--                             clay bricks by volume too.
--   REFINISH_DYE_RXN_MAKE_<material>
--                             at the dyer, two dust of that material and an
--                             empty bag into its colour's mineral dye, one
--                             per stone, gem and metal, in Make mineral dye
--                             under Make dye; built by refinish-dyes.lua.
--   (melting)                 metal dust and scrap go back to bars through
--                             DF's own melt job, not a reaction here: see
--                             refinish-melt.lua.
--   REFINISH_<FORM>_TOOL      the byproduct forms, one registration each:
--                             SAWDUST, BARK, SCRAP, CULLET, CRUST. See
--                             CATALOG: THE BYPRODUCTS.
--   REFINISH_HEAP_TOOL        the heap, 600, stacked: loose bulk by the
--                             bar, slag for RM and whatever a module
--                             heaps (manure, compost). See CATALOG: THE
--                             HEAP.
--   REFINISH_HEAP_SLAG        slag, carried by the HEAP registration. RM
--                             pays an ore smelt's whole loss as slag
--                             heaps whenever a module asks for HEAP
--                             (refinish-job-byproducts.lua).
--   REFINISH_CRUST_GALL       gall, carried by the CRUST registration.
--
-- ---- WHAT BELONGS HERE, AND WHAT DOES NOT ----
-- RM holds shared systems and shared content: content many modules
-- would want, provided once so no two modules load their own (one
-- gravel, never five CRUSH_GRAVELs in a load order), usable as a
-- package or as a building block. The test for anything moving here:
-- would a second module want it, and does it work without the first
-- module's systems? Content whose meaning lives in one module's systems
-- stays with that module.
--
-- By that test, 2026-09-25, Making Fuel's fuels and feedstocks
-- (kindling, branch, tinder, dung, straw, dried straw, mash) and its
-- reaction keys came here and went back the same day: their materials
-- and everything that makes or uses them are Making Fuel's, and each key
-- is owned by one watcher that sweeps it by subtype, so no second module
-- could share one. The fuel equipment never came. BRIQUETTE and CINDER
-- were dropped: nothing made or used either tool (briquettes are bars
-- on Making Fuel's coal host), and cinder is combustion residue, the
-- fuel system's business. The heap it wore stays in
-- refinish-sprite-art-forms.lua for any powder form that wants it,
-- named sawdust since 2026-09-26: sawdust and cement wear it.
--
-- A PREFIX NEVER STEMS ANOTHER. The engine refuses two prefixes where
-- one is a stem of the other, because their assets could not be told
-- apart in a sweep: REFINISH_STRAW_ would have swept REFINISH_STRAW_DRIED_,
-- which is why Making Fuel's dried straw sat here as DRIED_STRAW.
--
-- ---- STACKS ----
-- Every form here but the vessels declares stack = true. A reaction's
-- new items of it merge per material into one stack each
-- (refinish-reaction-outputs.lua; RM's grinders excepted, see there),
-- and the byproduct service pays it as one stack per job
-- (refinish-job-byproducts.lua, make). Measured 2026-10-03: one reagent
-- slot fills from any number of stacks, and DF draws exactly what a
-- reaction asks for (RM_Stacked_Tools.md). The vessels are not stacked:
-- each holds its own liquid.
--
-- ---- THE CATALOG ----
-- A registration whose module block carries catalog = '<NAME>' is a
-- catalog form. The module engine keeps it only when some accepted
-- module lists that name in its module block's "requires", and drops
-- it otherwise (see THE CATALOG in run_module_pipeline). A module that
-- asks for a form that is not registered is told so in the log and
-- runs without it.
--
-- mod_id is nil on purpose: the engine only gates a listener on the
-- world's active mods when it names one, and these are part of RM, so
-- they are broadcast in every world RM runs in.
--
-- Every module block carries a version: the reactions validator refuses
-- a block without one, and that is how the first catalog delivery was
-- refused.
-- ==========================================

local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CORE_PAYLOAD'
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

-- The vanilla powder pile, used as the base art for both tools. Dust
-- looks right in it as is; gravel's gravel pattern is what shows, drawn
-- per material by refinish-sprite-tool-tint from refinish-sprite-art-forms.
local BASE_ART = {
    fields = {
        texpos_item  = 'PAGE:ITEM_CONSTRUCTION:2:3',
        texpos_stone = { source = 'PAGE:ITEM_CONSTRUCTION:2:3', fill = 7 },
        texpos_wood  = { source = 'PAGE:ITEM_CONSTRUCTION:2:3', fill = 7 },
        texpos_metal = { source = 'PAGE:ITEM_CONSTRUCTION:2:3', fill = 7 },
        texpos_glass = { source = 'PAGE:ITEM_CONSTRUCTION:2:3', fill = 7 },
    },
}

-- ==========================================
-- REFINISH CORE: THE DUST, ALONE
-- ==========================================
-- size is one dust's volume, and since 2026-10-03 it is also the unit
-- every class pays in: dust of one class finishes no better than
-- another, it only comes easier or harder, and each job's measured loss
-- decides that. The byproduct service divides a loss by it
-- (refinish-job-byproducts.lua, CORE DUST), and the grinders and
-- crushers size their dust by it (refinish-reaction-outputs.lua,
-- MEASURED STACKS). 100 makes a boulder (10000), a bar and a block (600
-- each, measured) and the aggregate quarter (2500) whole numbers of
-- dust; a rough gem (250) is two and a half, the half banked. Two dust
-- finish a bar. Until then size was 400, and one dust was a quarter
-- boulder, three rough gems or one bar, by class.
local CORE = {
    module = {
        id      = 'REFINISH_CORE',
        prefix  = 'REFINISH_CORE_',
        name    = 'Refinish Core',
        version = '1.0',
    },
    tools = {
        {
            key           = 'DUST',
            name          = 'dust',
            name_plural   = 'dust',
            stack         = true,
            graphics      = BASE_ART,
            value         = 1,
            tile          = 250,
            size          = 200,   -- 100 until 2026-10-07, when finishing was too cheap
            material_size = 1,
            capacity      = 0,
            tool_use      = {},
            flags         = { hard_mat = true, no_default_job = true },
        },
    },
}

-- ==========================================
-- CATALOG: GRAVEL
-- ==========================================
-- The crush reactions name REFINISH_CORE_DUST for their dust. Refinish
-- Core sorts ahead of this registration, so dust is injected first
-- without a declared dependency: gravel does not depend on dust being
-- healthy, only the crush reactions' dust product does.
local GRAVEL = {
    module = {
        id      = 'REFINISH_GRAVEL',
        prefix  = 'REFINISH_GRAVEL_',
        name    = 'Refinish Catalog: Gravel',
        version = '1.0',
        catalog = 'GRAVEL',
    },
    tools = {
        {
            key           = 'TOOL',
            tint          = 'gravel',
            name          = 'gravel',
            name_plural   = 'gravel',
            stack         = true,
            graphics      = BASE_ART,
            value         = 1,
            tile          = 249,
            size          = 600,   -- the aggregate size, as slag heaps (2500 until 2026-10-07)
            material_size = 1,
            capacity      = 0,
            tool_use      = {},
            flags         = { hard_mat = true, no_default_job = true },
        },
    },
    reactions = {
        {
            key         = 'CRUSH',
            name        = 'crush any stone into gravel',
            building    = 'MASON',
            skill       = 'MASONRY',
            fuel        = false,
            permissions = { mode = 'AUTO' },
            reagents    = {
                { code = 'stone', type = 'BOULDER_ANY', quantity = 1,
                  flags = { non_economic = false } },
            },
            products    = {
                { type = 'TOOL', subtype = 'REFINISH_GRAVEL_TOOL', count = 12,
                  get_material_same = 'stone' },
                -- measure: the dust is what the boulder measured less the
                -- twelve gravel, in dust units; count 1 is one stack
                -- (refinish-reaction-outputs.lua, MEASURED STACKS).
                -- whole: a boulder less twelve gravel is 14 dust exactly, so
                -- nothing is ever left to bank, and the mason shows no
                -- output bank for it (refinish-reaction-outputs.lua,
                -- ALWAYS VISIBLE).
                { type = 'TOOL', subtype = 'REFINISH_CORE_DUST', count = 1,
                  get_material_same = 'stone', measure = true, whole = true },
            },
        },
        {
            key         = 'CRUSH_COMMON',
            name        = 'crush common stone into gravel',
            building    = 'MASON',
            skill       = 'MASONRY',
            fuel        = false,
            permissions = { mode = 'AUTO' },
            reagents    = {
                { code = 'stone', type = 'BOULDER_ANY', quantity = 1,
                  flags = { non_economic = true } },
            },
            products    = {
                { type = 'TOOL', subtype = 'REFINISH_GRAVEL_TOOL', count = 12,
                  get_material_same = 'stone' },
                -- measure: the dust is what the boulder measured less the
                -- twelve gravel, in dust units; count 1 is one stack
                -- (refinish-reaction-outputs.lua, MEASURED STACKS).
                -- whole: a boulder less twelve gravel is 14 dust exactly, so
                -- nothing is ever left to bank, and the mason shows no
                -- output bank for it (refinish-reaction-outputs.lua,
                -- ALWAYS VISIBLE).
                { type = 'TOOL', subtype = 'REFINISH_CORE_DUST', count = 1,
                  get_material_same = 'stone', measure = true, whole = true },
            },
        },
        {
            -- ---- GRAVEL BACK TO DUST (2026-10-29) ----
            -- Gravel's route to bricks: grog is stone dust. Twelve gravel,
            -- one boulder's crushing, are 7200, so 36 dust at 200, and
            -- nothing is lost, as RM's grinders lose nothing: a boulder
            -- crushed and its gravel ground comes to the 50 dust that
            -- grinding it whole makes. Ground where they grind stone, at
            -- the quern and the millstone, by a mason, as the stone
            -- grinders are (refinish-index-reaction.lua, LUA-GENERATED
            -- GRINDERS).
            key         = 'GRIND',
            name        = 'grind gravel into dust',
            building    = 'MILL',
            skill       = 'MASONRY',
            fuel        = false,
            permissions = { mode = 'AUTO' },
            reagents    = {
                -- Stone gravel only. AGGREGATE is on the twins that every
                -- stone's gravel wears (refinish-material-aggregate.lua), so
                -- gravel of a module's own material is left alone: Making
                -- Concrete's clinker nodules, which it grinds into cement.
                -- reads: the words DF prints for the class, as Making
                -- Concrete's concrete mix has them (refinish-module-react.lua,
                -- READS).
                { code = 'gravel', type = 'TOOL', tool_id = 'REFINISH_GRAVEL_TOOL',
                  quantity = 12, reaction_class = 'AGGREGATE', reads = 'stone' },
            },
            products    = {
                -- A fixed count, not measure. A measured product is sized from
                -- the volume its reagent's slot holds (refinish-reaction-
                -- outputs.lua, read_sources), and a slot holds whole stacks,
                -- of which DF draws only the twelve asked for
                -- (RM_Stacked_Tools.md, B): a stack of twenty would be paid as
                -- twenty. The 36 merge into one stack, as the crushers' 14 dust
                -- come in one. They are made on the gravel's material, the
                -- twin, and go back onto its stone the frame they exist (THE
                -- UNHOP, refinish-material-aggregate.lua).
                { type = 'TOOL', subtype = 'REFINISH_CORE_DUST', count = 36,
                  get_material_same = 'gravel' },
            },
        },
    },
}

-- ==========================================
-- REFINISH BRICKS
-- ==========================================
-- A stone dust outlet that needs no module: stone dust fired into a clay
-- body as grog, at the kiln, into vanilla's own bricks of the clay's fired
-- material (earthenware, stoneware or porcelain). The clay is the binder;
-- the dust is a fifth of the body, as grog is in real brick clays.
-- How many bricks a job pays is measured by refinish-bricks.lua, for this
-- reaction and for vanilla's make clay bricks: count 1 here is DF's
-- placeholder, sized there from the clay's and the grog's volume.
-- Always injected, and its own registration so it fails alone
-- (ISOLATION). depends_on: its grog is the dust tool, and REFINISH_BRICK_
-- sorts ahead of REFINISH_CORE_, so without it the reaction would be
-- built before the tool exists.
local BRICKS = {
    module = {
        id         = 'REFINISH_BRICK',
        prefix     = 'REFINISH_BRICK_',
        name       = 'Refinish Bricks',
        version    = '1.0',
        depends_on = { 'REFINISH_CORE_' },
    },
    reactions = {
        {
            key         = 'GROG',
            name        = 'make clay bricks with stone dust',
            building    = 'KILN',
            skill       = 'POTTERY',
            fuel        = true,
            permissions = { mode = 'AUTO' },
            reagents    = {
                { code = 'clay', type = 'BOULDER_ANY', quantity = 1,
                  has_material_reaction_product = 'FIRED_MAT' },
                -- The grog. refinish-bricks.lua reads this quantity off the
                -- built reaction, so it is set here and nowhere else.
                { code = 'grog', type = 'TOOL', tool_id = 'REFINISH_CORE_DUST',
                  quantity = 13, flags = { stone = true } },  -- 2600 of grog at 200 a dust (25 at 100)
            },
            products    = {
                { type = 'BLOCKS', count = 1, dimension = 150,
                  get_material_product = { reagent_code = 'clay', product_code = 'FIRED_MAT' } },
            },
        },
    },
}

-- ==========================================
-- NO GLUE HERE
-- ==========================================
-- Animal glue was RM core's for part of 2026-10-04, as the mineral dyes'
-- binder, and went back to Making Fuel the same day: a dye takes no
-- binder (vanilla's take a material and a bag, and so do RM's), while a
-- briquette does. Glue is Making Fuel's glue binder now
-- (making_fuel_materials.json, GLUE). Glue items a save made while it
-- was here come back as the tool wash leaves an unknown tool.

-- ==========================================
-- CATALOG: THE BYPRODUCTS
-- ==========================================
-- Making Fuel's byproduct forms, moved here 2026-09-25 field for field
-- from making_fuel_tools.json (MAKING_FUEL_<FORM> while they were Making
-- Fuel's; REFINISH_<FORM>_TOOL now). They are shared content: what
-- makes one distinct is the material put on it, and RM's byproduct
-- service pays them from any module's jobs, in the job's own material or
-- a byproduct material. Each is its own registration, so one form
-- failing takes nothing else down.
--
-- ART. Sheet art reads RM's own copy of the sheet,
-- images/refinish_byproducts.png in refinish_steel/data (the same cells
-- as Making Fuel's making_fuel_byproducts.png), through RM'S OWN DATA
-- FOLDER below. Vanilla page art needs nothing. SAWDUST also declares
-- tint, and its pattern moved with it into refinish-sprite-art-forms.lua,
-- as CINDER's did before the cinder form was dropped (WHAT BELONGS HERE).
--
-- SIZES are Making Fuel's, unchanged, except the aggregates: gravel is
-- 600 since 2026-10-07 (a quarter boulder, 2500, before), and slag
-- comes in RM's heaps of the same 600, so a recipe taking aggregates by
-- ratio can take either. Dust is 200 since the same day (100 before).
--
-- MATERIALS. Two registrations carry a material, so asking for one
-- brings the substance with it: HEAP carries SLAG (WASTE did until
-- 2026-10-07, when the waste form went) and CRUST carries GALL (REFINISH_<FORM>_<MATERIAL>;
-- MAKING_FUEL_<MATERIAL> while they were Making Fuel's, moved field for
-- field from making_fuel_materials.json 2026-09-25, the last content
-- move). The substance goes on the material, where its reaction classes
-- live (SLAG, AGGREGATE, POZZOLAN; GALL, ALKALI, FERTILIZER), and the form on
-- the tool, so an item reads "slag heap" (gall is paid in RM's dust tool
-- since 2026-10-06, so it reads "gall dust"). A fixed
-- material surfaces wherever DF lists materials, stockpiles and trade
-- included, so it is named distinctively: the first cut named gall
-- "glass", which would have collided with real glass in every stockpile
-- and trade list. The other byproduct forms take the material of the job
-- that shed them. A third, SCALE, held for forging and never paid by
-- anything, was deleted 2026-10-05.
-- ==========================================
local SAWDUST = {
    module = {
        id      = 'REFINISH_SAWDUST',
        prefix  = 'REFINISH_SAWDUST_',
        name    = 'Refinish Catalog: Sawdust',
        version = '1.0',
        catalog = 'SAWDUST',
    },
    tools = {
        {
            key = 'TOOL',
            tint = 'sawdust',
            name = 'sawdust',
            name_plural = 'sawdust',
            stack = true,
            graphics = {
                fields = {
                    texpos_item = 'FILE:images/refinish_byproducts.png:2:0:4',
                    texpos_stone = {
                        source = 'FILE:images/refinish_byproducts.png:2:0:4',
                        fill = 7,
                    },
                    texpos_wood = {
                        source = 'FILE:images/refinish_byproducts.png:2:0:4',
                        fill = 7,
                    },
                    texpos_metal = {
                        source = 'FILE:images/refinish_byproducts.png:2:0:4',
                        fill = 7,
                    },
                    texpos_glass = {
                        source = 'FILE:images/refinish_byproducts.png:2:0:4',
                        fill = 7,
                    },
                },
            },
            -- VALUE 0, since 2026-10-28 (1 before). DF prices a tool at
            -- its value times its material's, in whole numbers, and every
            -- vanilla wood is 1. One sawdust is 78 of wood, and a 5000
            -- log is worth 3, so 78 of it is worth about 0.05; nine
            -- sawdust press into about one tinder, worth 2, so one is
            -- worth about 0.2. At 1, a 5000 log ground at the mill read
            -- 56, and every recipe that took sawdust (Making Fuel's
            -- tinder, pulp, pressed blocks, charring and manure) paid
            -- back less than went in. Its worth arrives in what it is
            -- made into.
            value = 0,
            tile = 250,
            size = 78,
            material_size = 1,
            capacity = 0,
            tool_use = {},
            flags = {
                hard_mat = true,
                no_default_job = true,
            },
        },
    },
}

local BARK = {
    module = {
        id      = 'REFINISH_BARK',
        prefix  = 'REFINISH_BARK_',
        name    = 'Refinish Catalog: Bark',
        version = '1.0',
        catalog = 'BARK',
    },
    tools = {
        {
            key = 'TOOL',
            name = 'bark',
            name_plural = 'bark',
            stack = true,
            graphics = {
                fields = {
                    texpos_item = 'PAGE:TREES:7:3',
                    texpos_stone = {
                        source = 'PAGE:TREES:7:3',
                        fill = 7,
                    },
                    texpos_wood = {
                        source = 'PAGE:TREES:7:3',
                        fill = 7,
                    },
                    texpos_metal = {
                        source = 'PAGE:TREES:7:3',
                        fill = 7,
                    },
                    texpos_glass = {
                        source = 'PAGE:TREES:7:3',
                        fill = 7,
                    },
                },
            },
            -- VALUE 0, since 2026-10-28 (1 before), as sawdust and for
            -- the same reasons: 78 of wood, nine to a tinder and four to
            -- a pulp, so at 1 every recipe that took bark paid back less
            -- than went in. Its worth arrives in what it is made into.
            value = 0,
            tile = 247,
            size = 78,
            material_size = 1,
            capacity = 0,
            tool_use = {},
            flags = {
                hard_mat = true,
                no_default_job = true,
            },
        },
    },
}

local SCRAP = {
    module = {
        id      = 'REFINISH_SCRAP',
        prefix  = 'REFINISH_SCRAP_',
        name    = 'Refinish Catalog: Scrap',
        version = '1.0',
        catalog = 'SCRAP',
    },
    tools = {
        {
            key = 'TOOL',
            name = 'scrap',
            name_plural = 'scraps',
            stack = true,
            graphics = {
                fields = {
                    texpos_item = 'FILE:images/refinish_byproducts.png:1:1:4',
                    texpos_stone = {
                        source = 'FILE:images/refinish_byproducts.png:1:1:4',
                        fill = 7,
                    },
                    texpos_wood = {
                        source = 'FILE:images/refinish_byproducts.png:1:1:4',
                        fill = 7,
                    },
                    texpos_metal = {
                        source = 'FILE:images/refinish_byproducts.png:1:1:4',
                        fill = 7,
                    },
                    texpos_glass = {
                        source = 'FILE:images/refinish_byproducts.png:1:1:4',
                        fill = 7,
                    },
                },
            },
            value = 1,
            tile = 250,
            size = 150,
            material_size = 1,
            capacity = 0,
            tool_use = {},
            flags = {
                hard_mat = true,
                no_default_job = true,
            },
        },
    },
}

local CULLET = {
    module = {
        id      = 'REFINISH_CULLET',
        prefix  = 'REFINISH_CULLET_',
        name    = 'Refinish Catalog: Cullet',
        version = '1.0',
        catalog = 'CULLET',
    },
    tools = {
        {
            key = 'TOOL',
            name = 'cullet',
            name_plural = 'cullet',
            stack = true,
            graphics = {
                fields = {
                    texpos_item = 'FILE:images/refinish_byproducts.png:2:1:4',
                    texpos_stone = {
                        source = 'FILE:images/refinish_byproducts.png:2:1:4',
                        fill = 7,
                    },
                    texpos_wood = {
                        source = 'FILE:images/refinish_byproducts.png:2:1:4',
                        fill = 7,
                    },
                    texpos_metal = {
                        source = 'FILE:images/refinish_byproducts.png:2:1:4',
                        fill = 7,
                    },
                    texpos_glass = {
                        source = 'FILE:images/refinish_byproducts.png:2:1:4',
                        fill = 7,
                    },
                },
            },
            value = 1,
            tile = 250,
            size = 150,
            material_size = 1,
            capacity = 0,
            tool_use = {},
            flags = {
                hard_mat = true,
                no_default_job = true,
            },
        },
    },
}

-- ==========================================
-- CATALOG: THE HEAP
-- ==========================================
-- A heap of loose bulk, bar sized (600) and stacked: Making Fuel's heap
-- form until 2026-10-07, moved here so Making Fuel and Making Concrete
-- share one heap and one slag. It replaced the WASTE registration, whose
-- waste tool carried the slag before.
--
-- SLAG rides with it, so asking for HEAP brings the substance as well,
-- and while the heap is injected RM pays an ore smelt's whole loss as
-- slag heaps, the way it pays gravel for GRAVEL
-- (refinish-job-byproducts.lua, register_core). 600 is the aggregate
-- size gravel shares, so slag keeps AGGREGATE and a recipe can take
-- either. A module heaps its own bulk (manure, compost) by naming
-- REFINISH_HEAP_TOOL with its own material.
--
-- ART. The vanilla boulder page cell Making Fuel's heap used.
local HEAP = {
    module = {
        id      = 'REFINISH_HEAP',
        prefix  = 'REFINISH_HEAP_',
        name    = 'Refinish Catalog: Heap',
        version = '1.0',
        catalog = 'HEAP',
    },
    tools = {
        {
            key           = 'TOOL',
            name          = 'heap',
            name_plural   = 'heaps',
            stack         = true,
            graphics      = {
                fields = {
                    texpos_item  = 'PAGE:BOULDERS:1:15',
                    texpos_stone = { source = 'PAGE:BOULDERS:1:15', fill = 7 },
                    texpos_wood  = { source = 'PAGE:BOULDERS:1:15', fill = 7 },
                    texpos_metal = { source = 'PAGE:BOULDERS:1:15', fill = 7 },
                    texpos_glass = { source = 'PAGE:BOULDERS:1:15', fill = 7 },
                },
            },
            value         = 1,
            tile          = 247,
            size          = 600,
            material_size = 1,
            capacity      = 0,
            tool_use      = {},
            flags         = { hard_mat = true, no_default_job = true },
        },
    },
    materials = {
        {
            key = 'SLAG',
            name = 'slag',
            material_class = 'STONE',
            color = 'SLATE_GRAY',
            fallback_colors = { 'TAUPE_GRAY', "ASH_GRAY" },
            value = 1,
            solid_density = 2900,
            heat = {
                spec_heat = 840,
                melting_point = 62000,
            },
            strength = {
                yield = {
                    IMPACT = 10000,
                    COMPRESSIVE = 10000,
                    TENSILE = 10000,
                    TORSION = 10000,
                    SHEAR = 10000,
                    BENDING = 10000,
                },
                fracture = {
                    IMPACT = 20000,
                    COMPRESSIVE = 20000,
                    TENSILE = 20000,
                    TORSION = 20000,
                    SHEAR = 20000,
                    BENDING = 20000,
                },
                max_edge = 0,
            },
            block_name = { 'block', 'blocks' },
            reaction_classes = { 'SLAG', 'AGGREGATE', 'POZZOLAN' },
            reaction_products = {},
            material_flags = {
                ITEMS_HARD = true,
            },
            inorganic_flags = {},
        },
    },
}

local CRUST = {
    module = {
        id      = 'REFINISH_CRUST',
        prefix  = 'REFINISH_CRUST_',
        name    = 'Refinish Catalog: Crust',
        version = '1.0',
        catalog = 'CRUST',
    },
    -- No tool (cut 2026-10-06). Gall is paid in RM's dust tool, so the crust
    -- form was never made. The catalog stays, under its old name, because it
    -- carries the GALL material (REFINISH_CRUST_GALL) that gall dust is made of.
    materials = {
        {
            key = 'GALL',
            name = 'gall',
            material_class = 'STONE',
            color = 'WHITE',
            fallback_colors = { 'PALE_BLUE', 'ASH_GRAY' },
            value = 1,
            solid_density = 2200,
            heat = {
                spec_heat = 840,
            },
            strength = {
                yield = {
                    IMPACT = 10000,
                    COMPRESSIVE = 10000,
                    TENSILE = 10000,
                    TORSION = 10000,
                    SHEAR = 10000,
                    BENDING = 10000,
                },
                fracture = {
                    IMPACT = 20000,
                    COMPRESSIVE = 20000,
                    TENSILE = 20000,
                    TORSION = 20000,
                    SHEAR = 20000,
                    BENDING = 20000,
                },
                max_edge = 0,
            },
            block_name = { 'crust', 'crusts' },
            -- FERTILIZER: gall is skimmed only off the pearlash glasses, so it
            -- is the sulfate and muriate of potash the pearlash carried, and
            -- DF's fertilize job takes it (refinish-fertilize.lua).
            reaction_classes = { 'GALL', 'ALKALI', 'FERTILIZER' },
            reaction_products = {},
            material_flags = {},
            inorganic_flags = {},
        },
    },
}

-- ==========================================
-- CORE OUTLETS
-- ==========================================
-- Dust gathers whether a player finishes metal with it or not, so RM
-- carries outlets of its own that work with no module installed
-- (2026-10-03: whatever does not depend on a module is a core outlet).
-- Each is a registration of its own, so one that fails takes nothing
-- else down (ISOLATION, header), and Refinish Core sorts ahead of them,
-- so the dust tool their reagents name is injected first, as for the
-- crush reactions.
--
-- Melting is not here. REFINISH_MELT_RXN_DUST (six metal dust into a bar
-- at the smelter) was retired 2026-10-03: metal dust and scrap go back
-- to bars through DF's own melt job, marked from the item sheet as any
-- metal item is, with refinish-melt.lua measuring every melt.

-- ==========================================
-- REGISTRATION, AT LOAD
-- ==========================================
-- refinish_steel loads this file at its own load, so every listener is
-- in place before the first token call of any world. Each registers on
-- its own: one failing to register cannot stop the next.
-- ---- RM'S OWN DATA FOLDER ----
-- A form whose art is a sprite sheet reads it from RM's own images
-- folder (refinish_steel/data/images/refinish_byproducts.png, a copy of
-- Making Fuel's making_fuel_byproducts.png made 2026-09-25), so no
-- form's art depends on a module being installed. The folder is found the way a module finds
-- its own (see making_fuel.lua): scriptmanager.getModSourcePath with the
-- mod's ID, refinish_steel (info.txt). Resolved at the token call, when
-- the world's mods are known, and handed to the engine as data_dir.
-- Unresolved, a form with sheet art keeps its vanilla base art and the
-- log says so once; the forms still inject.
--
-- LOST ONCE, 2026-09-25: the whole file delivered for the byproduct forms
-- was built from a copy without this section, dropped it, and every
-- sheet sprite then failed with "could not load image" against an empty
-- root. Keep it when this file is rebuilt.
local RM_MOD_ID = 'refinish_steel'
local rm_data, said_no_data = nil, false
local function rm_data_dir()
    if rm_data then return rm_data end
    pcall(function()
        local root = require('script-manager').getModSourcePath(RM_MOD_ID)
        if root then
            rm_data = tostring(root):gsub('[/\\]+$', '') .. '/data'
        end
    end)
    if not rm_data and not said_no_data then
        said_no_data = true
        -- WARNING: sheet art falls back to vanilla base art.
        log('WARNING', 'RM\'s own data folder did not resolve (mod id '
            .. RM_MOD_ID .. '); forms drawn from RM\'s sprite sheets keep'
            .. ' their base art this session.', 'DATA')
    end
    return rm_data
end

local ok, engine = pcall(reqscript, 'refinish-module-engine')
if ok and engine and engine.register_listener then
    for _, payload in ipairs({ CORE, GRAVEL, BRICKS, SAWDUST, BARK, SCRAP, CULLET, HEAP,
                               CRUST }) do
        local ok_r, err = pcall(engine.register_listener, payload.module.name,
            function()
                payload.data_dir = rm_data_dir()
                return payload
            end)
        if not ok_r then
            -- ERROR: this registration's assets are missing this session.
            log('ERROR', ('%s did not register: %s'):format(payload.module.name,
                tostring(err)), 'REGISTER')
        end
    end
    -- ---- REFINISH DYES ----
    -- Built at the token call rather than written here: its colours are
    -- the world's own (refinish-dyes.lua, EVERY COLOUR, READ LIVE).
    local ok_d, err_d = pcall(engine.register_listener, 'Refinish Dyes', function()
        local p = reqscript('refinish-dyes').payload()
        p.data_dir = rm_data_dir()
        return p
    end)
    if not ok_d then
        -- ERROR: no mineral dyes this session.
        log('ERROR', 'Refinish Dyes did not register: ' .. tostring(err_d), 'REGISTER')
    end
else
    -- ERROR: no core payload this session, and nothing else would say so.
    log('ERROR', 'refinish-module-engine did not load; RM\'s own payloads are'
        .. ' not registered and RM has no dust tool this session.', 'REGISTER')
end