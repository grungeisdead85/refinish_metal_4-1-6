-- refinish-scan.lua
-- ==========================================
-- SCRIPT LOGIC: REFINISH-SCAN (MULTI-BASE MODE)
-- ==========================================
-- ONE FINISH, ONE MATERIAL, ONE NAME
--
-- The old scanner keyed a colour material on colour AND VALUE, so
-- every blue reagent whose arithmetic landed on a different number
-- minted its own "blue steel". Three of them existed at once. DF
-- shows a material by its display name and nothing else, so the
-- forge listed three identical rows, the two the fort had no bars
-- for start-cancelled, and the cancellation could only say "needs
-- blue steel bars". Same trap on the SPECIFIC side, where three
-- iron ores all produced a material called "ferriferous steel".
--
-- THE RULE NOW, in one line: a display name identifies exactly one
-- material, and value conservation is what a shared name costs.
--
--   COLOUR finishes   one material per colour per base metal.
--                     Value is the base metal's value, always.
--                     Every reagent of that colour makes that one
--                     material. Colour is a family, not a recipe.
--
--   SHARED finishes   a named finish more than one reagent can
--                     produce (ferriferous from three iron ores).
--                     One material, value is the base metal's.
--
--   UNIQUE finishes   a named finish exactly one reagent produces.
--                     Its own material, and value IS conserved:
--                     base plus a share of the reagent's worth.
--
-- Conservation survives wherever the material can carry it, which
-- is wherever the name points at a single recipe. Where several
-- recipes share a name, no single material can hold several values,
-- so the value goes rather than the name.
--
-- WHY TWO PASSES. Whether a finish is shared cannot be known while
-- walking the reagents, because the second taker may be hundreds of
-- entries later. Pass A surveys and counts; pass B builds knowing
-- the totals. A one pass version has to guess and is wrong for
-- whichever reagent it meets first.
-- ==========================================
local json = require('json')

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SCANNER'
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

if _G.refinish_blueprint ~= nil then
    log('DETAIL', 'Blueprint already exists in memory. Skipping scan.')
    return
end

log('DETAIL', 'Master scan initiated (multi-base mode).')

local perf_setting = dfhack.persistent.getSiteData('refinish_config_perf') or 'ON'

-- ==========================================
-- INITIALIZE BLUEPRINT & TIER 1 ROOT
-- ==========================================
_G.refinish_blueprint = {
    materials = {},
    reactions = {},
    categories = {
        -- TIER 1: THE ROOT
        ROOT = { id = "REFINISH_STEEL_CAT_ROOT", name = "Refinish metal bars", parent = "" }
    }
}

-- =================
-- OVERRIDES
-- =================
-- The prefix is the FINISH NAME. Where several reagents share one,
-- they share the finish and therefore the material: the three iron
-- ores below all make one "ferriferous steel". That sharing is the
-- point of the table, not an accident of it.
local SPECIAL_FINISH = {
    ["IRON"] = { prefix = "ironclad" },
    ["GOLD"] = { prefix = "gilded" },
    ["PLATINUM"] = { prefix = "platinized" },
    ["SILVER"] = { prefix = "silvered" },
    ["COPPER"] = { prefix = "coppered" },
    ["NICKEL"] = { prefix = "nickeled" },
    ["ZINC"] = { prefix = "galvanized" },
    ["BRONZE"] = { prefix = "bronzed" },
    ["BRASS"] = { prefix = "brassed" },
    ["ROSE_GOLD"] = { prefix = "rose-gilded" },
    ["PIG_IRON"] = { prefix = "pig" },
    ["STEEL"] = { prefix = "satin" },
    ["ELECTRUM"] = { prefix = "electrumized" },
    ["TIN"] = { prefix = "tinned" },
    ["PEWTER_FINE"] = { prefix = "fine-pewtered" },
    ["PEWTER_TRIFLE"] = { prefix = "trifle-pewtered" },
    ["PEWTER_LAY"] = { prefix = "lay-pewtered" },
    ["LEAD"] = { prefix = "leaded" },
    ["ALUMINUM"] = { prefix = "aluminized" },
    ["NICKEL_SILVER"] = { prefix = "nickel-silvered" },
    ["BILLON"] = { prefix = "billonclad" },
    ["STERLING_SILVER"] = { prefix = "sterling-silvered" },
    ["BLACK_BRONZE"] = { prefix = "black-bronzed" },
    ["BISMUTH"] = { prefix = "bismuth-washed" },
    ["BISMUTH_BRONZE"] = { prefix = "bismuth-bronzed" },
    ["ADAMANTINE"] = { prefix = "adamantinized" },
    ["HEMATITE"] = { prefix = "ferriferous" },
    ["LIMONITE"] = { prefix = "ferriferous" },
    ["GARNIERITE"] = { prefix = "kupfernickeled" },
    ["NATIVE_GOLD"] = { prefix = "auriferous" },
    ["NATIVE_SILVER"] = { prefix = "argentiferous" },
    ["NATIVE_COPPER"] = { prefix = "cupriferous" },
    ["MALACHITE"] = { prefix = "cupriferous" },
    ["GALENA"] = { prefix = "plumbiferous" },
    ["SPHALERITE"] = { prefix = "zinciferous" },
    ["CASSITERITE"] = { prefix = "stanniferous" },
    ["NATIVE_PLATINUM"] = { prefix = "platiniferous" },
    ["TETRAHEDRITE"] = { prefix = "cupriferous" },
    ["HORN_SILVER"] = { prefix = "argentiferous" },
    ["BISMUTHINITE"] = { prefix = "bismuthiferous" },
    ["MAGNETITE"] = { prefix = "ferriferous" },
    ["NATIVE_ALUMINUM"] = { prefix = "aluminiferous" },
    ["RAW_ADAMANTINE"] = { prefix = "adamantiferous" }
}

local inorganics = df.global.world.raws.inorganics.all
local colors = df.global.world.raws.descriptors.colors
local patterns = df.global.world.raws.descriptors.patterns

-- The colour behind a state_color value, or nil. state_color holds a
-- PATTERN index (DF's color_pattern), and a pattern's first colour is
-- the colour it shows, as refinish-boot.lua reads it. Read straight
-- off the colour list, a metal coloured by a mod's colour (its pattern
-- past the list's end) was named by its terminal colour instead.
local function color_of_pattern(pidx)
    if not pidx or pidx < 0 or pidx >= #patterns then return nil end
    local p = patterns[pidx]
    if not p or #p.colors == 0 then return nil end
    local ci = p.colors[0]
    if ci < 0 or ci >= #colors then return nil end
    return colors[ci]
end

-- ==========================================
-- LOAD ACTIVE BASE METALS FROM JSON
-- ==========================================
local saved_bases_str = dfhack.persistent.getSiteData('refinish_config_bases')
local active_bases_dict = {}

if saved_bases_str and saved_bases_str ~= "" then
    pcall(function() active_bases_dict = json.decode(saved_bases_str) end)
else
    -- Nothing saved: every base metal with a refinishing path is on
    -- (refinish-bases.lua, THE DEFAULT SELECTION). Steel alone until
    -- 2026-10-03.
    local b_env = dfhack.script_environment('refinish-bases')
    active_bases_dict = b_env.default_bases(b_env.get_valid_bases(true, true)) or {}
end

-- A metal switched off on its own is saved as false, not removed
-- (refinish-panel-metals.lua toggles with `not`), so the selection is
-- empty when nothing in it is true, not only when it has no keys.
-- Checking keys alone let an all-off selection fall through to the
-- check below, which logged the modules-only shell as a yellow "every
-- selected base metal was invalid" (steel, the only base, switched
-- off on 2026-09-29).
local any_selected = false
for _, on in pairs(active_bases_dict) do
    if on then any_selected = true break end
end
if not any_selected then
    -- INFO, not a fault: an empty selection is a player's choice, the
    -- modules-only shell. It still says so, since it is why no finish
    -- exists anywhere.
    log('INFO', 'No base metals selected; refinishing stays dormant.',
        'BASES')
    return
end

-- ==========================================
-- GATEKEEPER INTERCEPT
-- ==========================================
local bases_env = dfhack.script_environment('refinish-bases')
-- We pass true, true to pull the absolute maximum list of physical metals so we can check against it
local valid_metals_list = bases_env.get_valid_bases(true, true) 

local metal_reaction_lookup = {}
for _, m in ipairs(valid_metals_list) do
    metal_reaction_lookup[m.id] = m.has_reaction
end

-- Validate the Base Metals requested by the user
local active_bases = {}
for _, mat in ipairs(inorganics) do
    if active_bases_dict[mat.id] then
        if metal_reaction_lookup[mat.id] then
            local name = mat.material.state_name[0] or mat.id
            table.insert(active_bases, {
                id = mat.id,
                name = string.lower(name),
                value = mat.material.material_value
            })
        else
            -- Legitimately failed validation. Notify explicitly.
            log('WARNING', string.format('Base metal %s dropped: it has no'
                .. ' valid crafting or smelting path.', mat.id), 'BASES')
        end
    end
end

if #active_bases == 0 then
    log('WARNING', 'Every selected base metal was invalid; refinishing'
        .. ' stays dormant.', 'BASES')
    return
end

log('DETAIL', 'Loaded ' .. #active_bases .. ' verified active base metals.',
    'BASES')

-- ==========================================
-- DYNAMIC CATEGORY GENERATION (BASE-FIRST RESTRUCTURE)
-- ==========================================
for _, base in ipairs(active_bases) do
    -- Capitalize the first letter for UI readability (e.g., "steel" -> "Steel")
    local cap_name = string.gsub(base.name, "^%l", string.upper)
    
    -- TIER 2: THE BASE METAL BRANCH (e.g., "Steel finishes")
    local branch_id = "REFINISH_STEEL_CAT_BASE_" .. base.id
    _G.refinish_blueprint.categories[branch_id] = { id = branch_id, name = "Refinish " .. base.name .. " bars", parent = "REFINISH_STEEL_CAT_ROOT" }
    
    -- TIER 3: THE TYPE STEMS (Colour vs Material)
    local c_stem_id = branch_id .. "_COLOUR"
    _G.refinish_blueprint.categories[c_stem_id] = { id = c_stem_id, name = "Colour-based", parent = branch_id }
    
    local m_stem_id = branch_id .. "_MAT"
    _G.refinish_blueprint.categories[m_stem_id] = { id = m_stem_id, name = "Material-based", parent = branch_id }
    
    -- TIER 4: THE COLOUR LEAVES
    _G.refinish_blueprint.categories[c_stem_id .. "_STONE"] = { id = c_stem_id .. "_STONE", name = "Stone finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_METAL"] = { id = c_stem_id .. "_METAL", name = "Metal finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_GEM"]   = { id = c_stem_id .. "_GEM", name = "Gem finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_OTHER"] = { id = c_stem_id .. "_OTHER", name = "Other finish", parent = c_stem_id }

    -- TIER 4: THE MATERIAL LEAVES
    _G.refinish_blueprint.categories[m_stem_id .. "_STONE"] = { id = m_stem_id .. "_STONE", name = "Stone finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_METAL"] = { id = m_stem_id .. "_METAL", name = "Metal finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_GEM"]   = { id = m_stem_id .. "_GEM", name = "Gem finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_OTHER"] = { id = m_stem_id .. "_OTHER", name = "Other finish", parent = m_stem_id }
end

-- ==========================================
-- THE FORGE'S FOLDERS
-- ==========================================
-- The forge lists every metal in each of its item categories, so RM's
-- finishes buried the vanilla metals there (61,442 rows with every base
-- on). refinish-menu-forge.lua files them into one folder in each
-- category list, refinished metals, which holds a folder per base metal,
-- and in each base folder one folder per kind of finish:
--   weapons and ammunition > refinished metals > steel > colour-based
--     > amber steel
-- These are its categories, a tree beside the finishing reactions', and
-- the code of each kind folder's placeholder reaction, which
-- refinish-index-reaction.lua builds (THE FORGE'S FOLDER PLACEHOLDERS):
-- DF opens a folder only when a reaction at the forge is filed under it
-- or under a folder inside it, as refinished metals and the smelter's own
-- folders show, so a base folder needs no placeholder of its own.
-- Names are lower case, as DF's own rows are; DF draws a folder's caption
-- from its category's name.
--
-- THE KINDS: colour finishes (REFINISH_STEEL_MAT_COLOUR_) and material
-- finishes (REFINISH_STEEL_MAT_SPECIFIC_), the split the smelter's
-- folders make too (Colour-based and Material-based, above). A kind
-- folder's token and code carry the kind before the base id, so no code
-- reads a base id out of one: refinish-index-entity.lua maps each code to
-- its base through this table.
-- ==========================================
local FORGE_ROOT = "REFINISH_STEEL_CAT_FORGE_ROOT"
local FORGE_KINDS = {
    { key = "COLOUR",   name = "colour-based" },
    { key = "MATERIAL", name = "material-based" },
}
_G.refinish_blueprint.categories[FORGE_ROOT] = { id = FORGE_ROOT, name = "refinished metals", parent = "" }
_G.refinish_blueprint.forge = { root = FORGE_ROOT, bases = {} }
for _, base in ipairs(active_bases) do
    local f_id = "REFINISH_STEEL_CAT_FORGE_BASE_" .. base.id
    _G.refinish_blueprint.categories[f_id] = { id = f_id, name = base.name, parent = FORGE_ROOT }
    -- One folder per kind inside the base's (THE KINDS, above), each with
    -- the code of its placeholder reaction.
    local kinds = {}
    for _, k in ipairs(FORGE_KINDS) do
        local k_id = "REFINISH_STEEL_CAT_FORGE_" .. k.key .. "_" .. base.id
        _G.refinish_blueprint.categories[k_id] = { id = k_id, name = k.name, parent = f_id }
        kinds[k.key] = { token = k_id, name = k.name,
            rxn = "REFINISH_STEEL_RXN_FORGE_FOLDER_" .. k.key .. "_" .. base.id }
    end
    _G.refinish_blueprint.forge.bases[base.id] = { token = f_id, name = base.name, kinds = kinds }
end

local valid_reagents = 0
local color_mats_created = 0
local specific_mats_created = 0
local shared_finishes = 0
local colourless = 0

-- Turns a finish word into the stable tail of a material id.
-- Deterministic, so the same finish yields the same id every load,
-- which is what the ledger and the payload restore both depend on.
local function id_token(word)
    local t = string.upper(word)
    t = string.gsub(t, "[^%w]+", "_")
    t = string.gsub(t, "^_+", "")
    t = string.gsub(t, "_+$", "")
    return t
end

-- ==========================================
-- PASS A: INTAKE SURVEY
-- ==========================================
-- Walks every inorganic once, applies the same validation the old
-- scanner did, and records what each accepted reagent CONTRIBUTES.
-- Nothing is built here. The blueprint stays empty until pass B
-- knows how many reagents want each finish name.
--
-- The one state change that still happens here is the powder
-- rename, because it edits the live material and must run exactly
-- once per reagent.
-- ==========================================
local intake = {}
local rej_type, rej_phase, rej_value, rej_ghost = 0, 0, 0, 0

for _, mat in ipairs(inorganics) do
    if not string.find(mat.id, "REFINISH_STEEL_") then
        local mat_flags = mat.material.flags
        local inorg_flags = mat.flags 
        local reagent_val = mat.material.material_value
        local melt_point = mat.material.heat.melting_point
        
        local is_valid_type = mat_flags.IS_STONE or mat_flags.IS_METAL or mat_flags.IS_GEM or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND
        -- THE FIX: Prune ghost metals from becoming finishes
        if mat_flags.IS_METAL and not metal_reaction_lookup[mat.id] then
            is_valid_type = false
            rej_ghost = rej_ghost + 1
        end
        local is_stable_solid = (melt_point == 0 or melt_point > 10015)
        local is_valid_value = (reagent_val >= 0)

        if is_valid_type and is_stable_solid and is_valid_value then
            
            -- state_name and state_adj index by matter state: 0 is Solid,
            -- 3 is Powder (the safe integer indexing the rename used).
            -- The solid name, which the finish names are built from. The
            -- powder rename that used to follow is gone: dust is RM's dust
            -- tool now, named by its material ("cinnabar dust") with no
            -- raws edited, so there is nothing to rename or restore.
            local solid_name = mat.material.state_name[0]

            -- THE CONDENSED COLOR FINISH (Color Matching)
            local color_idx = mat.material.state_color[0]
            local color_id = "UNKNOWN"
            local clean_color_name = "unknown"

            -- color_idx stays the PATTERN: the finish is given it as its
            -- own state_color. Only the name goes through the pattern.
            local shown = color_of_pattern(color_idx)
            if shown then
                color_id = shown.id
                clean_color_name = shown.name
            end

            if color_idx < 0 then
                local states_to_check = {3, 5, 4}
                for _, s_idx in ipairs(states_to_check) do
                    local c_val = mat.material.state_color[s_idx]
                    local c_shown = color_of_pattern(c_val)
                    if c_shown then
                        color_idx = c_val
                        color_id = c_shown.id
                        clean_color_name = c_shown.name
                        break
                    end
                end
            end

            if clean_color_name and clean_color_name ~= "unknown" then
                if clean_color_name == "" then
                    clean_color_name = string.lower(string.gsub(color_id, "_", " "))
                end
            end

            if clean_color_name == "unknown" or color_idx < 0 then
                local ansi_colors = {
                    [0] = { [0] = "black",      [1] = "dark gray" },
                    [1] = { [0] = "blue",       [1] = "light blue" },
                    [2] = { [0] = "green",      [1] = "light green" },
                    [3] = { [0] = "cyan",       [1] = "light cyan" },
                    [4] = { [0] = "red",        [1] = "light red" },
                    [5] = { [0] = "magenta",    [1] = "light magenta" },
                    [6] = { [0] = "brown",      [1] = "yellow" },
                    [7] = { [0] = "light gray", [1] = "white" }
                }
                
                local b_col = mat.material.build_color[0]
                local b_brt = mat.material.build_color[2]
                
                if b_col >= 0 and b_col <= 7 then
                    local brt_idx = (b_brt > 0) and 1 or 0
                    clean_color_name = ansi_colors[b_col][brt_idx]
                    color_id = string.upper(string.gsub(clean_color_name, " ", "_"))
                end
            end

            -- WHICH LEAF THIS REAGENT'S REACTIONS FILE UNDER, and the
            -- divisor its worth is shared by when a finish is unique
            -- enough to conserve value. Depends only on the reagent,
            -- so it is settled once here rather than per base metal.
            local class = "OTHER"
            if mat_flags.IS_GEM then
                class = "GEM"
            elseif mat_flags.IS_METAL then
                class = "METAL"
            elseif mat_flags.IS_STONE or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND then
                class = "STONE"
            end

            table.insert(intake, {
                mat_id      = mat.id,
                solid_name  = solid_name,
                reagent_val = reagent_val,
                color_idx   = color_idx,
                color_id    = color_id,
                color_name  = clean_color_name,
                class       = class,
            })

            valid_reagents = valid_reagents + 1
        else
            if not is_valid_type then rej_type = rej_type + 1
            elseif not is_stable_solid then rej_phase = rej_phase + 1
            elseif not is_valid_value then rej_value = rej_value + 1
            end
        end
    end
end

-- ==========================================
-- THE FINISH CENSUS
-- ==========================================
-- The single question pass B cannot answer on its own: how many
-- reagents want each named finish. One taker means the name points
-- at one recipe and the material can carry that recipe's value.
-- More than one means the name is a family and the value goes.
--
-- The finish word is the SPECIAL_FINISH prefix where there is one,
-- because that table exists precisely to make several reagents
-- share a name. Otherwise it is the reagent's own name.
-- ==========================================
local function finish_word(entry)
    local special = SPECIAL_FINISH[entry.mat_id]
    if special then return special.prefix end
    return string.lower(entry.solid_name)
end

local finish_takers = {}
for _, e in ipairs(intake) do
    local w = finish_word(e)
    finish_takers[w] = (finish_takers[w] or 0) + 1
end

-- ==========================================
-- WORLD NAME GUARD
-- ==========================================
-- A finish whose display name already belongs to a material outside
-- RM does not go in. DF shows a material by its display name alone,
-- so a finish sharing one is indistinguishable from the material that
-- already owns it, anywhere DF lists materials. BLACK on BRONZE is
-- called "black bronze", which is vanilla BLACK_BRONZE's own name.
--
-- Nothing is renamed and nothing is redirected. The finish is simply
-- not minted, along with every reaction that would make it, so the
-- existing material is never shadowed.
--
-- Lowercased, because a name differing only in case still reads as
-- the same material to a player. RM's own mints are left out: a clash
-- between two RM finishes of one base is name_owner's job in pass B.
--
-- Snapshotted once, here. Modules inject before this scan runs
-- (refinish-startup Step 2, and the hotsave rebuild in
-- refinish-autosave keeps the same order), so everything outside RM
-- is already in the array.
local world_names = {}
for _, mat in ipairs(inorganics) do
    if not string.find(mat.id, "REFINISH_STEEL_") then
        local nm = mat.material.state_name[0]
        if nm and nm ~= "" then
            world_names[string.lower(nm)] = mat.id
        end
    end
end

-- Every skipped finish, recorded once per base however many reagents
-- asked for it, and reported after the build. A finish missing from
-- the menu should never be a mystery.
local skipped_list, skipped_seen = {}, {}
local function note_conflict(base_id, name, owner)
    local key = base_id .. "|" .. name
    if skipped_seen[key] then return end
    skipped_seen[key] = true
    table.insert(skipped_list, { base = base_id, name = name, owner = owner })
end

-- ==========================================
-- PASS B: BUILD
-- ==========================================
-- Colours first, then specifics, and the order is load bearing.
-- name_owner records which material already answers to a display
-- name for this base metal. A specific finish whose name is already
-- taken points at the material that owns it instead of minting a
-- twin, which is what keeps "emerald steel" from existing twice
-- when a colour and a stone are both called emerald.
-- ==========================================
-- ---- WHAT EACH REAGENT BRINGS TO EVERY BASE ----
-- The two routines below run once per base metal and reagent, 81 x 664
-- in region4. Every piece of a name or id that does not depend on the
-- base is made here, once per reagent, and each routine joins it to the
-- base's own pieces, made once per base. The strings come out exactly
-- as before: string.lower maps each character on its own, so lowering
-- two pieces and joining them is lowering the joined string, and %s in
-- string.format writes a string or a number the way .. does.
-- MEASURED 2026-10-01 (the load clock, region4): the scan took 534 ms.
local n_patterns = #patterns   -- the colour routine's bound: a state_color is a pattern index
local pre = {}
for i, e in ipairs(intake) do
    local dust = string.lower(e.solid_name) .. " dust"
    local word = finish_word(e)
    pre[i] = {
        dust_code      = dust,
        -- ---- REACTION NAMES ----
        -- "make <finish> bars with <dust>", as in "make amber steel bars
        -- with amber dust", lower case like vanilla's and the modules'
        -- names. The manager's work order list shows a reaction by its
        -- name alone, with none of the smelter's folders around it, so the
        -- name says what it makes and from what. Until 2026-10-03 a name
        -- was the finish with its dust in brackets.
        rxn_tail       = " bars with " .. dust,
        colour_lower   = e.color_name and string.lower(e.color_name),
        colour_mat     = e.color_id and ("REFINISH_STEEL_MAT_COLOUR_" .. e.color_id .. "_"),
        word           = word,
        word_lower     = string.lower(word),
        word_token     = id_token(word),
        -- Routine B's s_adj against c_adj: the base's name ends both.
        same_as_colour = (word == e.color_name),
        shared         = (finish_takers[word] or 1) > 1,
    }
end

for _, base in ipairs(active_bases) do
    local name_owner = {}

    -- This base's own pieces (WHAT EACH REAGENT BRINGS TO EVERY BASE).
    local name_tail    = " " .. base.name
    local lower_tail   = " " .. string.lower(base.name)
    local rxn_colour   = "REFINISH_STEEL_RXN_COLOUR_" .. base.id .. "_"
    local rxn_specific = "REFINISH_STEEL_RXN_SPECIFIC_" .. base.id .. "_"
    local mat_specific = "REFINISH_STEEL_MAT_SPECIFIC_" .. base.id .. "_"
    local cat_colour   = "REFINISH_STEEL_CAT_BASE_" .. base.id .. "_COLOUR_"
    local cat_mat      = "REFINISH_STEEL_CAT_BASE_" .. base.id .. "_MAT_"

    -- ---- ROUTINE A: COLOUR FINISH ----
    -- One material per colour. Value is the base metal's, with no
    -- reagent contribution at all: a colour is a family of recipes
    -- and no single number can speak for all of them.
    for i, e in ipairs(intake) do
        -- color_idx is a PATTERN index (color_of_pattern, above), so it is
        -- bounded by the pattern list. It was measured against the colour
        -- list until 2026-10-02, which turned away every mod colour, whose
        -- pattern lies past the colour list's end (cobalt and akimril dust,
        -- measured that day): those dusts got no colour finish at all.
        if e.color_idx >= 0 and e.color_idx < n_patterns then
            local p = pre[i]
            local c_adj    = e.color_name .. name_tail
            local c_mat_id = p.colour_mat .. base.id

            -- WORLD NAME GUARD: a colour finish named like a material
            -- outside RM is not minted, and neither is this reagent's
            -- reaction into it.
            local c_owner = world_names[p.colour_lower .. lower_tail]
            if c_owner then
                note_conflict(base.id, c_adj, c_owner)
                goto next_colour
            end

            if not _G.refinish_blueprint.materials[c_mat_id] then
                _G.refinish_blueprint.materials[c_mat_id] = {
                    color_idx = e.color_idx,
                    mat_value = base.value,
                    adj_name = c_adj,
                    base_metal_id = base.id
                }
                name_owner[c_adj] = c_mat_id
                color_mats_created = color_mats_created + 1
            end

            local c_rxn_id = rxn_colour .. e.mat_id
            _G.refinish_blueprint.reactions[c_rxn_id] = {
                name = "make " .. c_adj .. p.rxn_tail,
                reagent_id = e.mat_id,
                base_metal_id = base.id,
                dust_code = p.dust_code,
                output_mat_id = c_mat_id,
                category = cat_colour .. e.class
            }
        else
            -- No descriptor index resolved, so there is no colour to
            -- name the finish after. Counted and skipped rather than
            -- minted with an out of range state_color, which is what
            -- the old scanner did on this path.
            colourless = colourless + 1
        end
        -- The guard above lands here: skip this reagent, keep going.
        ::next_colour::
    end

    -- ---- ROUTINE B: SPECIFIC FINISH ----
    for i, e in ipairs(intake) do
        if perf_setting == 'ON' or SPECIAL_FINISH[e.mat_id] then
            local p = pre[i]
            local word  = p.word
            local s_adj = word .. name_tail

            -- WORLD NAME GUARD, the same rule as the colour side.
            local s_owner = world_names[p.word_lower .. lower_tail]
            if s_owner then
                note_conflict(base.id, s_adj, s_owner)
                goto next_specific
            end

            -- A reagent whose finish word IS its own colour name has
            -- nothing to add: the colour reaction above already makes
            -- a material of that name from this exact dust, so a
            -- second identical entry would only pad the menu.
            if not p.same_as_colour then
                local s_mat_id = name_owner[s_adj]

                if not s_mat_id then
                    -- Value is conserved only where the name points
                    -- at a single recipe. Shared names take the base
                    -- metal's value, because one material cannot hold
                    -- three reagents' worth.
                    local shared = p.shared
                    local val = base.value
                    if not shared then
                        -- Each finished bar carries two dust, 400 volume
                        -- since dust went to 200 (2026-10-07; 200 volume
                        -- before), whatever the dust was ground from: its
                        -- share of the reagent is that volume over the
                        -- reagent item's, measured 2026-09-24. A
                        -- twenty-fifth of a boulder (10000), eight fifths
                        -- of a rough gem (250), two thirds of a bar (600).
                        -- At 100 a dust they were a fiftieth, four fifths
                        -- and a third; until 2026-10-03 a gem gave a whole
                        -- one and stone a twelfth.
                        if e.class == "GEM" then
                            val = base.value + math.floor(e.reagent_val * 8 / 5)
                        elseif e.class == "METAL" then
                            val = base.value + math.floor(e.reagent_val * 2 / 3)
                        elseif e.class == "STONE" then
                            val = base.value + math.floor(e.reagent_val / 25)
                        end
                    else
                        shared_finishes = shared_finishes + 1
                    end

                    -- Keyed on the FINISH, not the reagent, so every
                    -- taker of a shared name lands on the same id no
                    -- matter which one the loop reaches first.
                    s_mat_id = mat_specific .. p.word_token

                    _G.refinish_blueprint.materials[s_mat_id] = {
                        color_idx = e.color_idx,
                        mat_value = val,
                        adj_name = s_adj,
                        base_metal_id = base.id
                    }
                    name_owner[s_adj] = s_mat_id
                    specific_mats_created = specific_mats_created + 1
                end

                local s_rxn_id = rxn_specific .. e.mat_id
                _G.refinish_blueprint.reactions[s_rxn_id] = {
                    name = "make " .. s_adj .. p.rxn_tail,
                    reagent_id = e.mat_id,
                    base_metal_id = base.id,
                    dust_code = p.dust_code,
                    output_mat_id = s_mat_id,
                    category = cat_mat .. e.class
                }
            end
        end
        -- The guard above lands here: skip this reagent, keep going.
        ::next_specific::
    end
end

local total_rejected = rej_type + rej_phase + rej_value + rej_ghost
log('DETAIL', string.format('Intake complete. %d reagents accepted, %d'
    .. ' rejected (Type: %d, Phase: %d, Value: %d, Ghost Metal: %d).',
    valid_reagents, total_rejected, rej_type, rej_phase, rej_value,
    rej_ghost), 'INTAKE')

-- ==========================================
-- WORLD NAME GUARD REPORT
-- ==========================================
-- One line per skipped finish, with the base metal as its subject.
-- INFO rather than a fault: nothing failed, the guard did its job,
-- and the line exists so the gap in the menu explains itself.
for _, s in ipairs(skipped_list) do
    log('INFO', string.format("Finish '%s' not minted: the name already"
        .. ' belongs to %s. Skipped with every reaction into it.',
        s.name, s.owner), s.base)
end

-- ==========================================
-- UI DICTIONARY CACHE (O(1) LOOKUPS FOR HUD)
-- ==========================================
_G.refinish_blueprint.ui_dict = { 
    metal_names = {}, 
    ore_map = {}, 
    finish_counts = {}
}

for _, inorg in ipairs(inorganics) do
    local raw_name = inorg.material.state_name[0] or inorg.id
    local clean_name = raw_name:gsub("_", " "):gsub("(%S+)", function(word)
        return word:sub(1,1):upper() .. word:sub(2):lower()
    end)
    _G.refinish_blueprint.ui_dict.metal_names[inorg.id] = clean_name

    if inorg.metal_ore and inorg.metal_ore.mat_index then
        for _, target_idx in ipairs(inorg.metal_ore.mat_index) do
            local target_mat = inorganics[target_idx]
            if target_mat then _G.refinish_blueprint.ui_dict.ore_map[target_mat.id] = true end
        end
    end
end

for _, rxn in pairs(_G.refinish_blueprint.reactions) do
    local base = rxn.base_metal_id
    if base then
        _G.refinish_blueprint.ui_dict.finish_counts[base] = (_G.refinish_blueprint.ui_dict.finish_counts[base] or 0) + 1
    end
end

-- ==========================================
-- CIV TECH (FROM BOOT CACHE)
-- ==========================================
-- Boot's Pass 4 already evaluated every civilization's tech capabilities
-- and cached the results in _G.refinish_civ_tech. We copy it into the
-- blueprint so downstream consumers (index-entity, panel-civs, etc.)
-- find it in the expected location.
-- ==========================================
_G.refinish_blueprint.civ_tech = _G.refinish_civ_tech or {}

local total_mats = color_mats_created + specific_mats_created
log('DETAIL', string.format('Scan complete. Mapped %d reagents across %d'
    .. ' bases to %d materials (%d colour, %d specific, %d shared'
    .. ' finishes, %d colourless).', valid_reagents, #active_bases,
    total_mats, color_mats_created, specific_mats_created, shared_finishes,
    colourless), 'SCAN')