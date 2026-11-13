--@ module = true
-- refinish-stockhook-defs.lua
-- ==========================================
-- STOCKHOOK DEFINITION FILES
-- ==========================================
-- WHAT: reads stockpile definitions written as plain text, in the style of
-- DF's raws, and hands them to refinish-stockhook.lua. No Lua needed from a modder
-- or a player: a mod ships stockhook/*.txt, a player can drop files into
-- dfhack-config/stockhook/. The format is in STOCKHOOK_DEFINITIONS.md.
--
-- WHERE IT LOOKS, at every reload:
--   <each active mod's folder>/stockhook/*.txt   ids become MODID:ENTRY
--   dfhack-config/stockhook/*.txt                ids become USER:ENTRY
--   <this world's save folder>/stockhook/*.txt   ids become WORLD:ENTRY
-- Only for a world Stockhook is active in (refinish-stockhook.lua, ONE WORLD ONLY):
-- a mod's files only while that mod is in the world's load order; the
-- player's dfhack-config files in every Stockhook world; a save folder's
-- files in that world alone.
--
-- TOKENS, resolved through DFHack (Lua API.txt):
--   items      dfhack.items.findType('BAR'), findSubtype('TOOL:ITEM_TOOL_X')
--   materials  dfhack.matinfo.find('PLANT_MAT:MAKING_FUEL_COAL_HOST:CINDER')
-- A material injected at run time (RM's modules inject theirs at map load)
-- may not exist yet when the files are read. Unresolved tokens are retried
-- every 100 frames for a while (THE RETRY), and anything that never
-- resolves is reported by name.
--
-- API: reload(verbose), report()

local sh = reqscript('refinish-stockhook')
local scriptmanager = require('script-manager')

local USER_DIR = 'dfhack-config/stockhook/'

-- ==========================================
-- FOLLOW TARGETS
-- ==========================================
-- [FOLLOW:<GROUP>:<KEY>]: the items take the pile's own setting for a
-- vanilla entry. Each GROUP names one settings list (df-structures
-- df.building.xml, stockpile_parameter_*st; the commit DFHack 53.16-r3
-- pins) and how its KEY becomes the list's index:
--   enum      an enum item, matched without regard to case (COAL, Coal)
--   inorganic an inorganic material id (IRON, GRANITE)
--   creature  a creature id (DOG); the list is indexed like raws.creatures.all
--   plant     a plant id (OAK); indexed like raws.plants.all
--   itemdef   an item subtype id (ITEM_WEAPON_AXE_BATTLE); indexed like
--             raws.itemdefs.<list>
--   organic   a material token (CREATURE_MAT:COW:TALLOW,
--             PLANT_MAT:PIG_TAIL:THREAD); the list is indexed like DF's
--             organic table for its category: position i holds material
--             type raws.mat_table.organic_types[cat][i] and index
--             organic_indexes[cat][i]. For fish, unprepared fish and eggs
--             the key is CREATURE:CASTE (FISH_COD:MALE) instead: there the
--             table holds a creature index and a caste index. (DFHack
--             53.16-r3 plugins/stockpiles/OrganicMatLookup.cpp,
--             food_mat_by_idx and food_idx_by_token, read the table the
--             same way.)
-- The DLL reads any byte of a pile's settings by offset, so a new row here
-- needs nothing else. Plain switches (prepared meals, dyed, undyed) and the
-- quality arrays are not lists and cannot be followed.
local function E(group, vector, enum) return { group = group, vector = vector, kind = 'enum', enum = enum } end
local function I(group, vector) return { group = group, vector = vector, kind = 'inorganic' } end
local function C(group, vector) return { group = group, vector = vector, kind = 'creature' } end
local function D(group, vector, list) return { group = group, vector = vector, kind = 'itemdef', list = list } end
local function O(group, vector, cat) return { group = group, vector = vector, kind = 'organic', cat = cat } end
local FOLLOW = {
    -- Bars and blocks
    BARS                    = E('bars_blocks', 'bars_blocks.bars_other_mats', 'stockpile_bar_mat'),
    BARS_MATERIAL           = I('bars_blocks', 'bars_blocks.bars_mats'),
    BLOCKS                  = E('bars_blocks', 'bars_blocks.blocks_other_mats', 'stockpile_block_mat'),
    BLOCKS_MATERIAL         = I('bars_blocks', 'bars_blocks.blocks_mats'),
    -- Finished goods
    FINISHED_GOODS          = E('finished_goods', 'finished_goods.other_mats', 'stockpile_finished_mat'),
    FINISHED_GOODS_MATERIAL = I('finished_goods', 'finished_goods.mats'),
    FINISHED_GOODS_TYPE     = E('finished_goods', 'finished_goods.type', 'item_type'),
    -- Furniture
    FURNITURE               = E('furniture', 'furniture.other_mats', 'stockpile_furniture_mat'),
    FURNITURE_MATERIAL      = I('furniture', 'furniture.mats'),
    FURNITURE_TYPE          = E('furniture', 'furniture.type', 'furniture_type'),
    -- Stone, coins
    STONE                   = I('stone', 'stone.mats'),
    COINS                   = I('coins', 'coins.mats'),
    -- Gems: the "other" lists are indexed by builtin material type
    -- (GLASS_GREEN, GLASS_CLEAR, GLASS_CRYSTAL)
    GEMS_ROUGH              = E('gems', 'gems.rough_other_mats', 'builtin_mats'),
    GEMS_CUT                = E('gems', 'gems.cut_other_mats', 'builtin_mats'),
    GEMS_ROUGH_MATERIAL     = I('gems', 'gems.rough_mats'),
    GEMS_CUT_MATERIAL       = I('gems', 'gems.cut_mats'),
    -- Ammo
    AMMO                    = E('ammo', 'ammo.other_mats', 'stockpile_ammo_mat'),
    AMMO_MATERIAL           = I('ammo', 'ammo.mats'),
    AMMO_TYPE               = D('ammo', 'ammo.type', 'ammo'),
    -- Weapons and trap components
    WEAPONS                 = E('weapons', 'weapons.other_mats', 'stockpile_weapon_mat'),
    WEAPONS_MATERIAL        = I('weapons', 'weapons.mats'),
    WEAPONS_TYPE            = D('weapons', 'weapons.weapon_type', 'weapons'),
    TRAPCOMP_TYPE           = D('weapons', 'weapons.trapcomp_type', 'trapcomps'),
    -- Armor
    ARMOR                   = E('armor', 'armor.other_mats', 'stockpile_armor_mat'),
    ARMOR_MATERIAL          = I('armor', 'armor.mats'),
    ARMOR_BODY              = D('armor', 'armor.body', 'armor'),
    ARMOR_HEAD              = D('armor', 'armor.head', 'helms'),
    ARMOR_FEET              = D('armor', 'armor.feet', 'shoes'),
    ARMOR_HANDS             = D('armor', 'armor.hands', 'gloves'),
    ARMOR_LEGS              = D('armor', 'armor.legs', 'pants'),
    ARMOR_SHIELD            = D('armor', 'armor.shield', 'shields'),
    -- Wood
    WOOD                    = { group = 'wood', vector = 'wood.mats', kind = 'plant' },
    -- Animals, corpses, refuse
    ANIMALS                 = C('animals', 'animals.enabled'),
    CORPSES                 = C('corpses', 'corpses.corpses'),
    REFUSE_TYPE             = E('refuse', 'refuse.type', 'item_type'),
    REFUSE_CORPSES          = C('refuse', 'refuse.corpses'),
    REFUSE_BODY_PARTS       = C('refuse', 'refuse.body_parts'),
    REFUSE_SKULLS           = C('refuse', 'refuse.skulls'),
    REFUSE_BONES            = C('refuse', 'refuse.bones'),
    REFUSE_HAIR             = C('refuse', 'refuse.hair'),
    REFUSE_SHELLS           = C('refuse', 'refuse.shells'),
    REFUSE_TEETH            = C('refuse', 'refuse.teeth'),
    REFUSE_HORNS            = C('refuse', 'refuse.horns'),
    -- Food (organic table categories, df.organic_mat_category)
    FOOD_MEAT               = O('food', 'food.meat', 'Meat'),
    FOOD_FISH               = O('food', 'food.fish', 'Fish'),
    FOOD_UNPREPARED_FISH    = O('food', 'food.unprepared_fish', 'UnpreparedFish'),
    FOOD_EGG                = O('food', 'food.egg', 'Eggs'),
    FOOD_PLANTS             = O('food', 'food.plants', 'Plants'),
    FOOD_DRINK_PLANT        = O('food', 'food.drink_plant', 'PlantDrink'),
    FOOD_DRINK_ANIMAL       = O('food', 'food.drink_animal', 'CreatureDrink'),
    FOOD_CHEESE_PLANT       = O('food', 'food.cheese_plant', 'PlantCheese'),
    FOOD_CHEESE_ANIMAL      = O('food', 'food.cheese_animal', 'CreatureCheese'),
    FOOD_SEEDS              = O('food', 'food.seeds', 'Seed'),
    FOOD_LEAVES             = O('food', 'food.leaves', 'PlantGrowth'),
    FOOD_POWDER_PLANT       = O('food', 'food.powder_plant', 'PlantPowder'),
    FOOD_POWDER_CREATURE    = O('food', 'food.powder_creature', 'CreaturePowder'),
    FOOD_GLOB               = O('food', 'food.glob', 'Glob'),
    FOOD_PASTE              = O('food', 'food.glob_paste', 'Paste'),
    FOOD_PRESSED            = O('food', 'food.glob_pressed', 'Pressed'),
    FOOD_LIQUID_PLANT       = O('food', 'food.liquid_plant', 'PlantLiquid'),
    FOOD_LIQUID_ANIMAL      = O('food', 'food.liquid_animal', 'CreatureLiquid'),
    FOOD_LIQUID_MISC        = O('food', 'food.liquid_misc', 'MiscLiquid'),
    -- Leather
    LEATHER                 = O('leather', 'leather.mats', 'Leather'),
    -- Cloth: thread and cloth by fibre
    THREAD_SILK             = O('cloth', 'cloth.thread_silk', 'Silk'),
    THREAD_PLANT            = O('cloth', 'cloth.thread_plant', 'PlantFiber'),
    THREAD_YARN             = O('cloth', 'cloth.thread_yarn', 'Yarn'),
    THREAD_METAL            = O('cloth', 'cloth.thread_metal', 'MetalThread'),
    CLOTH_SILK              = O('cloth', 'cloth.cloth_silk', 'Silk'),
    CLOTH_PLANT             = O('cloth', 'cloth.cloth_plant', 'PlantFiber'),
    CLOTH_YARN              = O('cloth', 'cloth.cloth_yarn', 'Yarn'),
    CLOTH_METAL             = O('cloth', 'cloth.cloth_metal', 'MetalThread'),
    -- Sheets
    SHEET_PAPER             = O('sheet', 'sheet.paper', 'Paper'),
    SHEET_PARCHMENT         = O('sheet', 'sheet.parchment', 'Parchment'),
}

-- An organic key -> its position in the category's organic table.
local CREATURE_KEYED = { Fish = true, UnpreparedFish = true, Eggs = true }
local function organic_index(cat_name, key)
    local cat = df.organic_mat_category[cat_name]
    local mt = df.global.world.raws.mat_table
    local types, idxs = mt.organic_types[cat], mt.organic_indexes[cat]
    local want_t, want_i
    if CREATURE_KEYED[cat_name] then
        -- CREATURE:CASTE: a creature index and a caste index.
        local cid, caste = key:upper():match('^([^:]+):([^:]+)$')
        if not cid then return nil end
        local creatures = df.global.world.raws.creatures.all
        for ci, c in ipairs(creatures) do
            if c.creature_id:upper() == cid then
                for ki, k in ipairs(c.caste) do
                    if k.caste_id:upper() == caste then want_t, want_i = ci, ki end
                end
                break
            end
        end
    else
        local ok, info = pcall(dfhack.matinfo.find, key)
        if ok and info then want_t, want_i = info.type, info.index end
    end
    if not want_t then return nil end
    for i = 0, #types - 1 do
        if types[i] == want_t and idxs[i] == want_i then return i end
    end
end

-- An enum key, without regard to case: 'COAL' finds Coal.
local function enum_value(enum_name, key)
    local enum = df[enum_name]
    for i = enum._first_item, enum._last_item do
        local name = enum[i]
        if name and name:upper() == key:upper() then return i end
    end
end

-- The index of the entry with this id in a raws vector, matched without
-- regard to case.
local function index_by_id(vec, field, id)
    id = id:upper()
    for i, x in ipairs(vec) do
        if tostring(x[field]):upper() == id then return i end
    end
end

-- A FOLLOW key -> the list index, or nil.
local function follow_index(f, key)
    local raws = df.global.world.raws
    if f.kind == 'enum' then return enum_value(f.enum, key)
    elseif f.kind == 'inorganic' then return index_by_id(raws.inorganics.all, 'id', key)
    elseif f.kind == 'creature' then return index_by_id(raws.creatures.all, 'creature_id', key)
    elseif f.kind == 'plant' then return index_by_id(raws.plants.all, 'id', key)
    elseif f.kind == 'itemdef' then return index_by_id(raws.itemdefs[f.list], 'id', key)
    elseif f.kind == 'organic' then return organic_index(f.cat, key)
    end
end

-- ==========================================
-- PARSING
-- ==========================================
-- Raw style: everything outside [brackets] is commentary. Each
-- [STOCKHOOK_ENTRY:ID] starts an entry; the tokens after it belong to it.
-- Returns entries and a list of problems ("file: what").
local function parse(text, fname)
    local out, problems, cur = {}, {}, nil
    local hides, aliases, generates, moves, keeps, frees = {}, {}, {}, {}, {}, {}
    for tok in text:gmatch('%[([^%]]+)%]') do
        local parts = {}
        for p in (tok .. ':'):gmatch('([^:]*):') do parts[#parts + 1] = p end
        local head = parts[1]
        local rest = tok:sub(#head + 2)   -- everything after "HEAD:"
        if head == 'STOCKHOOK_GENERATE' then
            -- [STOCKHOOK_GENERATE:TOOL_TYPES], [STOCKHOOK_GENERATE:ITEM_KINDS]
            -- or [STOCKHOOK_GENERATE:WOODS]:
            -- rows made from the world's own raws (GENERATED ROWS, below).
            generates[#generates + 1] = (parts[2] or ''):upper()
        elseif head == 'STOCKHOOK_ALIAS_PLANT' then
            -- [STOCKHOOK_ALIAS_PLANT:FROM:TO]: on every plant that has both
            -- materials, items of FROM file as TO (refinish-stockhook.lua, MATERIAL
            -- ALIASES). Making Fuel: its fuel wood twin as the tree's WOOD.
            -- May stand anywhere in a file.
            if parts[2] and parts[3] then
                aliases[#aliases + 1] = { from = parts[2]:upper(), to = parts[3]:upper() }
            else
                table.insert(problems, fname .. ': STOCKHOOK_ALIAS_PLANT needs FROM:TO')
            end
        elseif head == 'STOCKHOOK_MOVE' then
            -- [STOCKHOOK_MOVE:INORGANIC_ID] or [STOCKHOOK_MOVE:INORGANIC_ID:Label]:
            -- DF's own row for that material leaves every stone list and is
            -- shown in each group's other materials list instead, still
            -- DF's own setting (refinish-stockhook-rows.lua, MOVED MATERIALS). For a
            -- material made IS_STONE only so it would stockpile. May stand
            -- anywhere in a file.
            if parts[2] and parts[2] ~= '' then
                local label = tok:match('^[^:]+:[^:]+:(.+)$')
                moves[#moves + 1] = { id = parts[2]:upper(), label = label }
            else
                table.insert(problems, fname .. ': STOCKHOOK_MOVE needs a material id')
            end
        elseif head == 'STOCKHOOK_FREE' then
            -- [STOCKHOOK_FREE:INORGANIC_ID]: a material whose own entries in
            -- the inorganic lists decide nothing where its row is hidden
            -- (a twin made only as tools, say), so Stockhook keeps those
            -- hidden entries matching their list and the category colour
            -- stays true (refinish-stockhook-rows.lua, HIDDEN BYTES). A
            -- trailing * matches every id that starts with the rest:
            -- MAKING_FUEL_BINDER_* takes a binder of any clay. A row that is
            -- shown is never touched. Anywhere in a file.
            if parts[2] and parts[2] ~= '' then
                frees[#frees + 1] = parts[2]:upper()
            else
                table.insert(problems, fname .. ': STOCKHOOK_FREE needs a material id')
            end
        elseif head == 'STOCKHOOK_ARMOR_KEEP' then
            -- [STOCKHOOK_ARMOR_KEEP:TYPE:KIND]: a clothing kind (no armor
            -- level) that DF still files as armor in some material, so its
            -- row stays in the Armor group (CLOTHING OUT OF ARMOR). Vanilla:
            -- HELM:ITEM_HELM_CAP (metal caps go to armor). Anywhere in a file.
            if parts[2] and parts[3] then
                keeps[#keeps + 1] = (parts[2] .. ':' .. parts[3]):upper()
            else
                table.insert(problems, fname .. ': STOCKHOOK_ARMOR_KEEP needs TYPE:KIND')
            end
        elseif head == 'STOCKHOOK_HIDE' then
            -- [STOCKHOOK_HIDE:MODID:ENTRY]: another source's entry is not
            -- loaded at all (no row, no claims). For a mod whose world
            -- never holds what that entry covers, or that covers it itself
            -- (Making Fuel hides Stockhook's coke, charcoal and refined
            -- coal rows: its watcher replaces every builtin coal bar). It
            -- may stand anywhere in a file and wins whatever the load order.
            hides[#hides + 1] = rest:upper()
        elseif head == 'STOCKHOOK_ENTRY' then
            cur = { id = (parts[2] or ''):upper(), items = {}, materials = {}, file = fname }
            if cur.id == '' then table.insert(problems, fname .. ': STOCKHOOK_ENTRY with no id') end
            out[#out + 1] = cur
        elseif not cur then
            table.insert(problems, fname .. ': [' .. tok .. '] before any STOCKHOOK_ENTRY')
        elseif head == 'LABEL' then cur.label = rest
        elseif head == 'CATEGORY' then cur.category = rest:upper()
        elseif head == 'CONTAINER' then cur.container = rest:upper()
        elseif head == 'ITEM' then table.insert(cur.items, rest)
        elseif head == 'MATERIAL' then table.insert(cur.materials, rest)
        elseif head == 'FOLLOW' then
            -- [FOLLOW:GROUP:KEY]; KEY is everything after the second ':'.
            local group = parts[2] or ''
            cur.follow = { group = group:upper(), key = tok:sub(#head + #group + 3) }
        elseif head == 'NEVER' then cur.never = true
        elseif head == 'PART_OF' then
            -- [PART_OF:GROUP:KEY]: a module row that is a part of the vanilla
            -- entry a FOLLOW with the same GROUP and KEY would name.
            local group = parts[2] or ''
            cur.part_of = { group = group:upper(), key = tok:sub(#head + #group + 3) }
        elseif head == 'VANILLA_ITEM' then
            -- With PART_OF: DF itself files these items under that vanilla
            -- entry (oak beds under Beds, coke under Coal), so the pile's
            -- other settings, materials and quality, still apply
            -- (stockhook_dll.cpp, EF_VANILLA_ITEM).
            cur.vanilla_item = true
        else
            table.insert(problems, ('%s, %s: unknown token [%s]'):format(fname, cur.id, tok))
        end
    end
    return out, problems, hides, aliases, generates, moves, keeps, frees
end

-- ==========================================
-- RESOLVING
-- ==========================================
-- Item token -> item_type, subtype (-1 when the token names a type only).
local function resolve_item(tok)
    local tname = tok:match('^([^:]+)')
    local ok, t = pcall(dfhack.items.findType, tname)
    if not ok or not t or t < 0 then return nil end
    if tok:find(':') then
        local ok2, st = pcall(dfhack.items.findSubtype, tok)
        if not ok2 or not st or st < 0 then return nil end
        return t, st
    end
    return t, -1
end

-- Material token -> mat_type, mat_index.
-- Material token -> mat_type, mat_index, exact. A token whose last part
-- is NONE (COAL:NONE, DF's refined coal) names mat_index -1 itself, not
-- every index: exact is then true (stockhook_dll.cpp, CF_EXACT_INDEX).
-- DFHack's MaterialInfo::find reads COAL:NONE as builtin COAL, index -1.
local function resolve_material(tok)
    local ok, info = pcall(dfhack.matinfo.find, tok)
    if not ok or not info then return nil end
    local exact = info.index == -1 and tok:upper():match(':NONE$') ~= nil
    return info.type, info.index, exact
end

-- One parsed entry -> an entry spec and claim rows, or nil and what is
-- missing. Missing tokens may only be not-yet-injected: see THE RETRY.
local function build(e)
    local spec, missing = {}, {}
    if e.never then
        spec.kind = 'never'
    elseif e.follow then
        local f = FOLLOW[e.follow.group]
        if not f then return nil, { 'FOLLOW group ' .. e.follow.group .. ' (see STOCKHOOK_DEFINITIONS.md)' } end
        local idx = follow_index(f, e.follow.key)
        if not idx then return nil, { 'FOLLOW key ' .. e.follow.key } end
        spec = { kind = 'follow', group = f.group, vector = f.vector, index = idx }
    else
        spec = { kind = 'module' }
        if e.part_of then
            -- The vanilla entry this row is a part of (refinish-stockhook.lua, PART
            -- ROWS), found exactly as a FOLLOW target is.
            local f = FOLLOW[e.part_of.group]
            if not f then return nil, { 'PART_OF group ' .. e.part_of.group .. ' (see STOCKHOOK_DEFINITIONS.md)' } end
            local idx = follow_index(f, e.part_of.key)
            if not idx then return nil, { 'PART_OF key ' .. e.part_of.key } end
            spec.part_of = { group = f.group, vector = f.vector, index = idx,
                             vanilla_item = e.vanilla_item or nil }
        end
    end
    spec.label = e.label or e.id
    spec.category = e.category
    spec.container = e.container
    spec.source = e.file

    if #e.items == 0 then return nil, { 'no ITEM token' } end
    local items, mats = {}, {}
    for _, tok in ipairs(e.items) do
        local t, st = resolve_item(tok)
        if t then items[#items + 1] = { t, st } else missing[#missing + 1] = 'ITEM:' .. tok end
    end
    for _, tok in ipairs(e.materials) do
        local mt, mi, exact = resolve_material(tok)
        if mt then mats[#mats + 1] = { mt, mi, exact } else missing[#missing + 1] = 'MATERIAL:' .. tok end
    end
    -- No MATERIAL token: any material.
    if #e.materials == 0 then mats[1] = { -1, -1 } end
    if #missing > 0 then return nil, missing end

    local rows = {}
    for _, it in ipairs(items) do
        for _, m in ipairs(mats) do
            rows[#rows + 1] = { item_type = it[1], subtype = it[2], mat_type = m[1], mat_index = m[2],
                                exact_index = m[3] or nil }
        end
    end
    return spec, rows
end

-- ==========================================
-- GENERATED ROWS
-- ==========================================
-- Rows made from the world's own raws, so every tool kind and every tree,
-- vanilla or modded, gets its row without a line per kind in any file.
-- Each is an ordinary parsed entry (as parse() makes), a VANILLA_ITEM part,
-- so the pile's own material and quality settings still apply to it.
--
-- TOOL_TYPES: every tool kind as an item type of its own, in the list DF
-- itself files it under (tool_place, below): beside Tools in Finished
-- goods: type, a part of Tools ("Tools (all)"), or beside Other large tools
-- in Furniture: type, a part of that ("Other large tools (all)"). A tool kind
-- some file names itself (Making Fuel's Kindling, its NEVER keys) is left
-- to that file. Left out: tools with a Furniture entry of their own
-- (minecarts, wheelbarrows, large pots) and tools the world generates
-- (instrument pieces).
--
-- ITEM_KINDS: the item kinds (itemdefs) of a type DF lists only as a
-- whole, as rows of their own beside that type (ITEM KINDS, below):
-- clothing, armor and toys in Finished goods: type ("Body wear (all)",
-- with Breastplates, Coats ... beside it), and every item type with kinds
-- in Refuse: items (tools, weapons, ammo, armor, shields, toys).
--
-- WOODS: every tree (a plant with a WOOD material) as a material beside
-- Wood in each list that has a Wood entry, a part of that Wood entry and
-- claiming only the item types that list's group holds, so "Oak" in
-- Furniture and "Oak" in Finished goods are separate switches.

local function cap(s) s = tostring(s or ''); return s:sub(1, 1):upper() .. s:sub(2) end

-- Finished goods item types: DFHack's own list (StockpileSerializer.cpp,
-- finished_goods_type_is_allowed).
local GOODS_TYPES = { 'CHAIN', 'FLASK', 'GOBLET', 'INSTRUMENT', 'TOY', 'ARMOR', 'SHOES',
    'HELM', 'GLOVES', 'FIGURINE', 'AMULET', 'SCEPTER', 'CROWN', 'RING', 'EARRING',
    'BRACELET', 'GEM', 'TOTEM', 'PANTS', 'BACKPACK', 'QUIVER', 'SPLINT', 'CRUTCH',
    'TOOL', 'BOOK' }

-- Furniture item types: every furniture_type that is also an item type
-- (BED, TABLE, ...), plus TOOL for the large tools (TOOL_TRACK_CART, ...).
local function furniture_types()
    local out, seen = {}, {}
    for i = df.furniture_type._first_item, df.furniture_type._last_item do
        local n = df.furniture_type[i]
        if n and n ~= 'NONE' then
            local it = n:match('^TOOL_') and 'TOOL' or n
            if df.item_type[it] ~= nil and not seen[it] then seen[it] = true; out[#out + 1] = it end
        end
    end
    return out
end

local WOOD_LISTS = {
    { suffix = 'GOODS',     category = 'GOODS_OTHER',               follow = 'FINISHED_GOODS', items = GOODS_TYPES },
    { suffix = 'FURNITURE', category = 'FURNITURE_OTHER_MATERIALS', follow = 'FURNITURE',      items = 'furniture' },
    { suffix = 'BLOCKS',    category = 'BLOCKS_OTHER',              follow = 'BLOCKS',         items = { 'BLOCKS' } },
    { suffix = 'AMMO',      category = 'AMMO_OTHER',                follow = 'AMMO',           items = { 'AMMO' } },
    { suffix = 'WEAPONS',   category = 'WEAPONS_OTHER',             follow = 'WEAPONS',        items = { 'WEAPON', 'TRAPCOMP' } },
    { suffix = 'ARMOR',     category = 'ARMOR_OTHER',               follow = 'ARMOR',          items = { 'ARMOR', 'SHOES', 'HELM', 'GLOVES', 'PANTS', 'SHIELD' } },
}

-- Where DF files a tool kind, read from DF 53.16's own code (2026-11-02):
-- returns 'GOODS', 'LARGE', or nil for a kind that gets no row.
--
-- FINISHED GOODS OR FURNITURE. settings_accepts (RVA 0x55E920) tests a
-- tool against Finished goods only when it is not furniture (item_toolst
-- vtable +0x630): no FURNITURE flag and no tool use FOOD_STORAGE. Any
-- other tool skips Finished goods and is tested against Furniture
-- (vtable +0x338 is the FURNITURE flag itself).
--
-- WHICH FURNITURE ENTRY. The Furniture check (RVA 0x5AF030, item type
-- TOOL) asks in turn: tool use FOOD_STORAGE (Food storage), tool use
-- HEAVY_OBJECT_HAULING (Wheelbarrow, vtable +0xA0), tool use TRACK_CART
-- (Minecart, vtable +0x98). A tool with none of the three falls to Other
-- large tools. Those three entries already name their one kind, so only
-- Other large tools is split: vanilla stepladders, bookcases, pedestals,
-- display cases and altars, and any modded FURNITURE tool.
--
-- GENERATED. Tool kinds the world makes for itself at world creation
-- (instrument pieces) carry base flag GENERATED. They differ per world,
-- would fill the list, and DFHack's own stockpile export skips them for
-- the same reason (StockpileSerializer.cpp, serialize_list_itemdef).
local function tool_place(def)
    if def.base_flags.GENERATED then return nil end
    local uses = {}
    for _, use in ipairs(def.tool_use) do uses[use] = true end
    local U = df.tool_uses
    if not def.flags.FURNITURE and not uses[U.FOOD_STORAGE] then return 'GOODS' end
    if uses[U.FOOD_STORAGE] or uses[U.HEAVY_OBJECT_HAULING] or uses[U.TRACK_CART] then
        return nil
    end
    return 'LARGE'
end

-- The list and the vanilla row each place's rows sit beside.
local TOOL_PLACES = {
    GOODS = { category = 'GOODS_TYPE',     part_of = { group = 'FINISHED_GOODS_TYPE', key = 'TOOL' } },
    LARGE = { category = 'FURNITURE_TYPE', part_of = { group = 'FURNITURE_TYPE', key = 'OTHER_LARGE_TOOLS' } },
}

-- ---- WHAT THE FILES NAME THEMSELVES ----
-- named: 'TYPE:KIND' (an item token with a kind, upper case) -> { cats =
-- the categories of the entries naming it ('*' for an entry with no
-- category), label = the first such entry's label }. A kind a file names
-- in a list is left to that file there; a generated row for it in another
-- list takes the file's label (Making Fuel's "Straw bales" in Refuse too).
local function named_in(named, tok, cats)
    local n = named[tok]
    if not n then return false end
    for _, c in ipairs(cats) do if n.cats[c] then return true end end
    return false
end

-- A field an itemdef may not have (toys and siege ammo have no
-- adjective): its text, or '' when the struct has no such field.
local function field_text(def, name)
    local ok, v = pcall(function() return def[name] end)
    return ok and v and tostring(v) or ''
end

-- SAME NAME. Two rows sharing a label in one list (Making Fuel's fresh and
-- dried straw are both "bales") would show as two identical rows. Each
-- such row gets its adjective, or failing that its kind id, in brackets:
-- "Bales (making fuel straw dried)". A mod that wants a better name names
-- its kinds in its own file.
local function same_name(out)
    local count = {}
    local function key(e) return e.category .. '|' .. e.label end
    for _, e in ipairs(out) do count[key(e)] = (count[key(e)] or 0) + 1 end
    for _, e in ipairs(out) do
        if count[key(e)] > 1 then
            local tag = e.adjective ~= '' and e.adjective or e.kind_id:lower():gsub('_', ' ')
            e.label = ('%s (%s)'):format(e.label, tag)
        end
    end
end

-- ==========================================
-- ITEM KINDS
-- ==========================================
-- Item types DF lists only as a whole in a list whose group could tell
-- their kinds apart, as the Armor, Weapons and Ammo groups already do
-- (2026-11-02, in play: Finished goods lists clothing only by slot,
-- "Body wear", "Headwear" ..., where Armor lists every kind; Refuse:
-- items lists Tools, Weapons ... as one row each).
--   list: the category the rows go in; group: the FOLLOW group of the
--   vanilla type entry they are parts of; types: item type -> the
--   world.raws.itemdefs list holding its kinds.
-- Every kind is a VANILLA_ITEM part of its type's row, so DF's own check
-- still decides with the part's row standing in for that type's row
-- (stockhook_dll.cpp, PARTS ON EVERY AXIS): which piles take worn or
-- rotten things into Refuse at all stays DF's rule. A type with fewer than
-- two kinds left gets no rows (a lone part would only repeat its type).
-- Tools in Finished goods and Furniture come from TOOL_TYPES; instrument
-- pieces (GENERATED kinds) and instruments stay out, as there.
-- Item types: DFHack's own lists of what each list holds
-- (StockpileSerializer.cpp, finished_goods_type_is_allowed and
-- refuse_type_is_allowed).
local KIND_LISTS = {
    { prefix = 'GOODS', list = 'GOODS_TYPE', group = 'FINISHED_GOODS_TYPE', clothing_only = true,
      types = { { 'ARMOR', 'armor' }, { 'SHOES', 'shoes' }, { 'HELM', 'helms' },
                { 'GLOVES', 'gloves' }, { 'PANTS', 'pants' }, { 'TOY', 'toys' } } },
    { prefix = 'REFUSE', list = 'REFUSE_ITEMS', group = 'REFUSE_TYPE',
      types = { { 'WEAPON', 'weapons' }, { 'TRAPCOMP', 'trapcomps' }, { 'AMMO', 'ammo' },
                { 'SIEGEAMMO', 'siege_ammo' }, { 'ARMOR', 'armor' }, { 'SHOES', 'shoes' },
                { 'HELM', 'helms' }, { 'GLOVES', 'gloves' }, { 'PANTS', 'pants' },
                { 'SHIELD', 'shields' }, { 'TOY', 'toys' }, { 'TOOL', 'tools' } } },
}

-- CLOTHING ONLY. Finished goods takes clothing, never armor, and the line
-- is the kind, not the material (2026-11-02, in play: metal breastplates,
-- leggings and high boots stayed out with metal on, and so did leather
-- armor, leather high boots, leggings and helms, while leather robes went
-- in). Every kind that stayed out has an ARMORLEVEL above 0 in the raws,
-- and every kind that went in has none (vanilla item_armor.txt and the
-- rest), so a kind with an armor level gets no Finished goods row.
local function armor_level(def)
    local ok, v = pcall(function() return def.armorlevel end)
    return ok and tonumber(v) or 0
end

local function item_kinds(fname, named)
    local out = {}
    local defs = df.global.world.raws.itemdefs
    for _, l in ipairs(KIND_LISTS) do
        for _, t in ipairs(l.types) do
            local itype, rows = t[1], {}
            for _, def in ipairs(defs[t[2]]) do
                local id = tostring(def.id)
                local tok = itype .. ':' .. id:upper()
                if not def.base_flags.GENERATED and not named_in(named, tok, { l.list, '*' })
                        and not (l.clothing_only and armor_level(def) > 0) then
                    local n = named[tok]
                    local label = (n and n.label) or cap(field_text(def, 'name_plural'))
                    -- A kind named as its type (vanilla leather armor is
                    -- "armor") would read as a second "Armor" under
                    -- "Armor (all)" (2026-11-02, in play): its material
                    -- placeholder goes in front, "Leather armor".
                    local place = field_text(def, 'material_placeholder')
                    if not n and label:lower() == itype:lower() and place ~= '' then
                        label = cap(place .. ' ' .. label:lower())
                    end
                    rows[#rows + 1] = { id = ('%s_%s_%s'):format(l.prefix, itype, id:upper()),
                        label = label,
                        category = l.list, items = { itype .. ':' .. id }, materials = {},
                        part_of = { group = l.group, key = itype },
                        vanilla_item = true, file = fname, generated = true,
                        adjective = field_text(def, 'adjective'), kind_id = id }
                end
            end
            if #rows >= 2 then
                for _, r in ipairs(rows) do out[#out + 1] = r end
            end
        end
    end
    same_name(out)
    return out
end

-- ==========================================
-- CLOTHING OUT OF ARMOR
-- ==========================================
-- The Armor group's item lists (armor.body, .head, .feet, .hands, .legs)
-- show every kind, clothing included, but DF refuses clothing there
-- (2026-11-02, in play: metal robes went to Finished goods and were refused
-- by Armor; metal masks the same). So a kind with no armor level has its
-- DF row hidden in Armor (refinish-stockhook-rows.lua, HIDING), unless a
-- file keeps it ([STOCKHOOK_ARMOR_KEEP]: a cap is clothing, yet a METAL cap
-- goes to armor). Returns { field, index, list } per row to hide (list:
-- the settings list it shows in, a category name); free = true:
-- the byte decides nothing, so the rows file may set it to keep the
-- list's category colour true (HIDDEN BYTES).
local ARMOR_VECTORS = {
    { 'ARMOR', 'armor', 'armor.body', 'ARMOR_BODY' }, { 'HELM', 'helms', 'armor.head', 'ARMOR_HEAD' },
    { 'SHOES', 'shoes', 'armor.feet', 'ARMOR_FEET' }, { 'GLOVES', 'gloves', 'armor.hands', 'ARMOR_HANDS' },
    { 'PANTS', 'pants', 'armor.legs', 'ARMOR_LEGS' },
}
local function clothing_out_of_armor(keeps)
    local out = {}
    local defs = df.global.world.raws.itemdefs
    for _, v in ipairs(ARMOR_VECTORS) do
        for i, def in ipairs(defs[v[2]]) do
            if armor_level(def) == 0 and not keeps[v[1] .. ':' .. tostring(def.id):upper()] then
                out[#out + 1] = { field = v[3], index = i, free = true, list = v[4] }
            end
        end
    end
    return out
end

-- kind -> list of parsed entries. named: what the files name themselves
-- (WHAT THE FILES NAME THEMSELVES).
local function generate(kind, fname, named)
    local out = {}
    local raws = df.global.world.raws
    if kind == 'TOOL_TYPES' then
        for _, def in ipairs(raws.itemdefs.tools) do
            local id = tostring(def.id)
            -- Left to a file that names this tool in any list but Refuse
            -- (Refuse rows are ITEM_KINDS').
            local n = named['TOOL:' .. id:upper()]
            local skip = false
            if n then for c in pairs(n.cats) do if c ~= 'REFUSE_ITEMS' then skip = true end end end
            local place = not skip and tool_place(def)
            if place then
                local p = TOOL_PLACES[place]
                out[#out + 1] = { id = 'TOOL_' .. id:upper(), label = cap(def.name_plural),
                    category = p.category, items = { 'TOOL:' .. id }, materials = {},
                    part_of = { group = p.part_of.group, key = p.part_of.key },
                    vanilla_item = true, file = fname, generated = true,
                    adjective = field_text(def, 'adjective'), kind_id = id }
            end
        end
        same_name(out)
    elseif kind == 'ITEM_KINDS' then
        out = item_kinds(fname, named)
    elseif kind == 'WOODS' then
        local furn = furniture_types()
        for _, plant in ipairs(raws.plants.all) do
            local has_wood = false
            for _, mat in ipairs(plant.material) do if mat.id == 'WOOD' then has_wood = true end end
            if has_wood then
                for _, l in ipairs(WOOD_LISTS) do
                    out[#out + 1] = { id = ('WOOD_%s_%s'):format(tostring(plant.id):upper(), l.suffix),
                        label = cap(plant.name), category = l.category,
                        items = l.items == 'furniture' and furn or l.items,
                        materials = { 'PLANT_MAT:' .. plant.id .. ':WOOD' },
                        part_of = { group = l.follow, key = 'WOOD' },
                        vanilla_item = true, file = fname, generated = true }
                end
            end
        end
    end
    return out
end

-- ==========================================
-- READING THE FILES
-- ==========================================
local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

-- A folder path with exactly one '/' at the end. (A gsub on '[/\]?$' can
-- add a second: after replacing the last '/', the empty match at the very
-- end matches '$' again.)
local function as_dir(p)
    p = tostring(p):gsub('\\', '/')
    if p:sub(-1) ~= '/' then p = p .. '/' end
    return p
end

-- Every definition file, as { prefix, path }. With trace, also a line per
-- place looked in, for 'refinish-stockhook paths'.
local function sources(trace)
    local out = {}
    local function look(prefix, dir)
        local files = dfhack.filesystem.listdir(dir) or {}
        local n = 0
        for _, f in ipairs(files) do
            if f:lower():match('%.txt$') then
                out[#out + 1] = { prefix = prefix, path = dir .. f }
                n = n + 1
            end
        end
        if trace then
            trace[#trace + 1] = ('%-22s %s  (%d .txt of %d entries)'):format(prefix, dir, n, #files)
        end
    end
    -- scriptmanager.get_active_mods: the world's load order, each mod's id
    -- and the folder DF loaded it from (object_loader.object_load_order_src_dir).
    local ok, mods = pcall(scriptmanager.get_active_mods)
    if not ok then
        if trace then trace[#trace + 1] = 'get_active_mods FAILED: ' .. tostring(mods) end
    elseif not mods or #mods == 0 then
        if trace then trace[#trace + 1] = 'get_active_mods: no mods (is a world loaded?)' end
    else
        for _, m in ipairs(mods) do
            -- DF records a mod's folder relative to DFHack's base dir
            -- ("data/installed_mods/making_fuel (13)"), which is not the
            -- install folder unless DF runs in portable mode; DFHack's own
            -- script-manager prefixes getBaseDir() the same way
            -- (get_mod_paths). An absolute path is used as it is.
            if not m.vanilla then
                local p = tostring(m.path):gsub('\\', '/')
                if not (p:match('^%a:/') or p:sub(1, 1) == '/') then
                    p = as_dir(dfhack.filesystem.getBaseDir()) .. p
                end
                look(tostring(m.id):upper(), as_dir(p) .. 'stockhook/')
            end
        end
    end
    look('USER', USER_DIR)
    -- This world's own folder: <base dir>/save/<save folder>/stockhook/, as
    -- DFHack names a save's folder (Core.cpp: "save/" + cur_savegame.save_dir).
    local okw, save_dir = pcall(function() return df.global.world.cur_savegame.save_dir end)
    if okw and save_dir and save_dir ~= '' then
        look('WORLD', as_dir(dfhack.filesystem.getBaseDir()) .. 'save/' .. save_dir .. '/stockhook/')
    elseif trace then
        trace[#trace + 1] = 'WORLD: no save folder yet'
    end
    return out
end

-- Where definitions are looked for, and what was found: 'refinish-stockhook paths'.
function paths()
    local trace = {}
    local found = sources(trace)
    for _, line in ipairs(trace) do print('  ' .. line) end
    print(('  %d definition file(s) found.'):format(#found))
end

-- ==========================================
-- RELOAD
-- ==========================================
_G.stockhook_defs = _G.stockhook_defs or { pending = {}, problems = {}, loaded = 0, gen = 0 }
local D = _G.stockhook_defs
D.moves = D.moves or {}

-- Every [STOCKHOOK_MOVE] read at the last reload: { id, label }, label nil
-- for the material's own name. Read by refinish-stockhook-rows.lua.
function moves() return D.moves end

-- Every inorganic named by a [STOCKHOOK_FREE] at the last reload, as
-- material indexes (a trailing * read as a prefix). Read by
-- refinish-stockhook-rows.lua, HIDDEN BYTES.
function free_mats()
    local out, pats = {}, {}
    for _, f in ipairs(D.frees or {}) do
        local pre = f:match('^(.*)%*$')
        pats[#pats + 1] = pre and { pre = pre } or { id = f }
    end
    if #pats == 0 then return out end
    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        local id = tostring(mat.id)
        for _, p in ipairs(pats) do
            if (p.id and id == p.id) or (p.pre and id:sub(1, #p.pre) == p.pre) then
                out[#out + 1] = i
                break
            end
        end
    end
    return out
end

-- DF rows to hide that are not moved materials: { field, index, free }
-- (CLOTHING OUT OF ARMOR). Read by refinish-stockhook-rows.lua.
D.row_hides = D.row_hides or {}
function row_hides() return D.row_hides end

-- Empties the definition state in place and retires any retry in flight
-- (its generation no longer matches). Called by refinish-stockhook.lua at every
-- world unload (ONE WORLD ONLY).
function reset()
    D.pending, D.problems, D.loaded, D.moves = {}, {}, 0, {}
    D.row_hides = {}
    D.frees = {}
    D.gen = (D.gen or 0) + 1
end

-- Tries every pending entry; registers the ones that resolve. Returns how
-- many are still pending.
local function settle()
    local still = {}
    for _, p in ipairs(D.pending) do
        local spec, rows_or_missing = build(p.entry)
        if spec then
            sh.define(p.id, spec)
            -- seq: reading order, so a later mod (and the player) wins a tie
            -- (refinish-stockhook.lua, CLAIMS, the sort in commit).
            for _, r in ipairs(rows_or_missing) do r.entry = p.id; r.seq = p.seq end
            sh.claim(p.id, rows_or_missing)
            D.loaded = D.loaded + 1
        else
            p.missing = rows_or_missing
            still[#still + 1] = p
        end
    end
    D.pending = still
    return #still
end

-- ---- THE RETRY ----
-- Materials injected at map load may appear after the first read. Pending
-- entries are tried again every 100 frames, up to RETRIES times; each
-- success commits and nudges.
local RETRIES = 60
local function retry_loop(n, gen)
    -- Ends with its world, or when a newer reload starts its own retry.
    if gen ~= D.gen then return end
    if not dfhack.isMapLoaded() or #D.pending == 0 then return end
    local before = #D.pending
    local left = settle()
    if left < before then
        sh.init_parts()      -- new part rows start from their vanilla rows
        sh.commit()
        sh.ensure_all_types()
        sh.nudge()
    end
    if left > 0 and n < RETRIES then
        dfhack.timeout(100, 'frames', function() retry_loop(n + 1, gen) end)
    elseif left > 0 then
        report()
    end
end

function reload(verbose)
    -- Only definition-file entries carry a ':' in their id (MODID:ENTRY);
    -- entries other code made through the API are left alone.
    sh.undefine_where(function(id) return id:find(':', 1, true) ~= nil end)
    D.pending, D.problems, D.loaded = {}, {}, 0
    D.row_hides = {}
    D.gen = (D.gen or 0) + 1
    local gen = D.gen
    local seen, hidden, plant_aliases = {}, {}, {}
    local all_moves, moved_seen = {}, {}
    local all_frees = {}         -- [STOCKHOOK_FREE] ids and prefixes
    local armor_keeps = {}       -- 'TYPE:KIND' -> true ([STOCKHOOK_ARMOR_KEEP])
    local gen_requests = {}      -- { prefix, kind, file }
    -- The files, listed once: their count goes in the log line at the end
    -- (WHAT A READ FOUND).
    local srcs = sources()
    for _, src in ipairs(srcs) do
        local text = read_file(src.path)
        if text then
            local list, problems, hides, aliases, generates, moves_here, keeps_here, frees_here = parse(text, src.path)
            for _, f in ipairs(frees_here) do all_frees[#all_frees + 1] = f end
            for _, k in ipairs(keeps_here) do armor_keeps[k] = true end
            for _, m in ipairs(moves_here) do
                if not moved_seen[m.id] then moved_seen[m.id] = true; all_moves[#all_moves + 1] = m end
            end
            for _, g in ipairs(generates) do gen_requests[#gen_requests + 1] = { src.prefix, g, src.path } end
            for _, pr in ipairs(problems) do table.insert(D.problems, pr) end
            for _, h in ipairs(hides) do hidden[h] = src.path end
            for _, a in ipairs(aliases) do plant_aliases[#plant_aliases + 1] = a end
            for _, e in ipairs(list) do
                local id = src.prefix .. ':' .. e.id
                if seen[id] then
                    table.insert(D.problems, ('%s: %s defined twice (first in %s)'):format(src.path, id, seen[id]))
                else
                    seen[id] = src.path
                    table.insert(D.pending, { id = id, entry = e, seq = #D.pending + 1 })
                end
            end
        end
    end
    -- ---- GENERATED ROWS ----
    -- After every file is read, so a tool kind any file names itself (an
    -- ITEM:TOOL:<id> token anywhere) is skipped. Generated rows carry seq 0:
    -- any written entry wins a tie with them.
    if #gen_requests > 0 then
        -- Every item kind some file names itself, the lists it names it
        -- in, and its label there (WHAT THE FILES NAME THEMSELVES).
        local named = {}
        for _, p in ipairs(D.pending) do
            for _, tok in ipairs(p.entry.items or {}) do
                local up = tok:upper()
                if up:find(':', 1, true) then
                    local n = named[up] or { cats = {} }
                    named[up] = n
                    n.cats[p.entry.category or '*'] = true
                    if not n.label and p.entry.label and p.entry.category then n.label = p.entry.label end
                end
            end
        end
        for _, g in ipairs(gen_requests) do
            local ok, list
            if g[2] == 'ARMOR_CLOTHING' then
                -- Hides DF rows; makes no entries.
                local okh, hides_or_err = pcall(clothing_out_of_armor, armor_keeps)
                if okh then D.row_hides = hides_or_err; ok, list = true, {}
                else ok, list = false, hides_or_err end
            else
                ok, list = pcall(generate, g[2], g[3], named)
            end
            if not ok then
                table.insert(D.problems, ('%s: STOCKHOOK_GENERATE:%s failed: %s'):format(g[3], g[2], tostring(list)))
            else
                for _, e in ipairs(list) do
                    local id = g[1] .. ':' .. e.id
                    if not seen[id] then
                        seen[id] = g[3]
                        table.insert(D.pending, { id = id, entry = e, seq = 0 })
                    end
                end
            end
        end
    end

    -- Entries some file hid ([STOCKHOOK_HIDE]) are dropped before anything
    -- is registered.
    if next(hidden) then
        local keep = {}
        for _, p in ipairs(D.pending) do
            if not hidden[p.id] then keep[#keep + 1] = p end
        end
        D.pending = keep
    end
    D.moves = all_moves
    D.frees = all_frees
    -- Every file's material aliases, as one owner (replaced at each reload).
    sh.alias('definition files', #plant_aliases > 0 and { plant = plant_aliases } or nil)
    settle()
    sh.init_parts()      -- new part rows start from their vanilla rows
    sh.commit()
    -- Piles with module rows on get their vanilla type (refinish-stockhook.lua, THE
    -- PILE'S TYPE): piles saved before typing existed, and any DF untyped.
    sh.ensure_all_types()
    local nudged = sh.nudge()
    sh.start_watch()
    -- The rows in DF's pile settings screen (refinish-stockhook-rows.lua).
    reqscript('refinish-stockhook-rows').start()
    if #D.pending > 0 then
        dfhack.timeout(100, 'frames', function() retry_loop(1, gen) end)
    end
    -- ---- WHAT A READ FOUND (2026-11-03) ----
    -- One line in RM's log at every read, so a fort that came up with no
    -- rows says why. SEEN in play: a load with Stockhook active and 0
    -- entries, nothing in the log, and every row back after a typed
    -- reload. A read that found no file at all is a WARNING.
    sh.log(#srcs > 0 and 'INFO' or 'WARNING', ('definitions read: %d entr(ies) loaded from'
        .. ' %d file(s), %d waiting on tokens.'):format(D.loaded, #srcs, #D.pending), 'DEFS')
    if verbose then
        print(('loaded %d entr(ies) from %d file(s); %d waiting on tokens; %d item(s) nudged.')
            :format(D.loaded, #srcs, #D.pending, nudged))
        report(true)
    end
    return #srcs
end

-- Every problem and every entry still waiting, to RM's log (WARNING); to
-- the console as well when typed (verbose: refinish-stockhook reload).
function report(verbose)
    local function say(msg)
        sh.log('WARNING', msg, 'DEFS')
        if verbose then print(msg) end
    end
    for _, pr in ipairs(D.problems) do say('PROBLEM: ' .. pr) end
    for _, p in ipairs(D.pending) do
        say(('%s not loaded yet, missing: %s'):format(p.id,
            table.concat(p.missing or {}, ', ')))
    end
end

-- ---- MAP LOAD: read the files for every Stockhook fort ----
-- Registered once a session and kept (refinish-stockhook.lua, ONE WORLD ONLY): in a
-- world without RM in its load order it does nothing at all.
--
-- ---- THE MAP LOAD READ, MADE SURE OF (2026-11-03) ----
-- SEEN in play: a fort loaded with the hook active and no definitions at
-- all (refinish-stockhook status: 0 entries), nothing in RM's log, and a
-- typed reload brought all 888 back. Which step failed was not recorded,
-- so each one now leaves a trace and recovers:
--   * the read runs under a pcall, and an error goes to RM's log as an
--     ERROR instead of only to the console;
--   * a read that found no file at all (WHAT A READ FOUND) is tried again
--     every RETRY_EMPTY frames, up to EMPTY_TRIES times;
--   * a map already loaded when this file first runs (its handler missed
--     that SC_MAP_LOADED) is read now.
-- D.map_read: the map this read was for (its site id), so the catch-up
-- never reads a fort twice.
local RETRY_EMPTY, EMPTY_TRIES = 100, 10

local function site_id()
    local ok, id = pcall(function() return df.global.plotinfo.site_id end)
    return ok and id or -1
end

local function map_read(try)
    if not dfhack.isMapLoaded() or not sh.world_active() then return end
    D.map_read = site_id()
    local ok, n = pcall(reload, false)
    if not ok then
        sh.log('ERROR', 'definitions not read at map load: ' .. tostring(n), 'DEFS')
        return
    end
    if n == 0 and try < EMPTY_TRIES then
        dfhack.timeout(RETRY_EMPTY, 'frames', function() map_read(try + 1) end)
    end
end

if dfhack_flags and dfhack_flags.module then
    dfhack.onStateChange.stockhook_defs = function(code)
        if code == SC_MAP_LOADED and sh.world_active() then
            dfhack.timeout(1, 'frames', function() map_read(1) end)
        elseif code == SC_MAP_UNLOADED then
            D.map_read = nil
        end
    end
    -- The catch-up: this file first ran with a fort already up.
    if dfhack.isMapLoaded() and D.map_read ~= site_id() then
        dfhack.timeout(1, 'frames', function()
            if D.map_read ~= site_id() then
                sh.log('INFO', 'definitions read late: this file loaded after the fort did.', 'DEFS')
                map_read(1)
            end
        end)
    end
end