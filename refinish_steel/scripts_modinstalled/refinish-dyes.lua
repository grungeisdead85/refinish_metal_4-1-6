--@ module = true
-- refinish-dyes.lua
-- ==========================================
-- RM MINERAL DYES: A DYE FOR EVERY COLOUR DUST COMES IN
-- ==========================================
-- WHAT
-- Dust of any stone, gem or metal makes a dye of its own colour at the
-- dyer's shop: two dust of that material and an empty bag make one dye,
-- as vanilla's own dyes take a material and a bag, named "make
-- <material> mineral dye": the row's swatch shows the colour, so the
-- name does not (2026-10-04). One dye per colour; one reaction per
-- material, all in a subcategory of their own, Make mineral dye, under Make
-- dye (THE SUBCATEGORY, below). A dust outlet that needs no module
-- (decided 2026-10-03, in RM core 2026-10-04).
--
-- NO BINDER (decided 2026-10-04). For part of that day a cake of glue
-- went in too, as if the dye were a paint. A mineral colour is the
-- mineral itself, ground fine and washed or sieved down to its fines;
-- a binder only fixes a pigment to a surface, and a dye is fixed to cloth
-- later, by the dyer. The glue went back to Making Fuel as a briquette
-- binder.
--
-- EVERY COLOUR, READ LIVE. No list of colours lives here. At RM's token
-- call this reads the colour of every stone, gem and metal in the world
-- the way refinish-scan.lua reads them (a material's state_color is a
-- PATTERN; its first colour is the one it shows), so a mod's colours, and
-- a mod giving its stones colours vanilla leaves unused, come in with
-- nothing written for them. RM's own materials are skipped: a finish
-- takes its colour from the dust that finished it (refinish-scan.lua,
-- THE CONDENSED COLOR FINISH), so the finishes add no colour of their own.
-- Vanilla's stones, gems and metals come in 77 colours.
--   KNOWN LIMITS: a module's materials are injected after the token call,
--   so a module's stone has no reaction of its own, and a colour only a
--   module's stone wears has no dye. A finish is minted after it too, so
--   finish dust makes no dye; its colour's dye is made from the dust that
--   finished it.
--
-- WHERE THEY LIVE. Plant materials on a host plant of their own, the only
-- way a powder is both listed by name and hauled (RM_Organic_Category_
-- Registration.md), claimed for Milled Plants by refinish-stockpile-
-- organic at start. A plant holds at most 200 materials (types 419 to
-- 618), so a world with more colours gets a second host.
--
-- WHICH DUST: ONE REACTION PER MATERIAL (decided 2026-10-04). A reaction
-- cannot ask for a colour, so each stone, gem and metal with a colour gets
-- a reaction of its own, naming its dust by token: no class on anything.
-- Until 2026-10-04 one reaction per colour asked for a class,
-- REFINISH_DYE_<colour id>, given at start to every material with dust.
-- A material that carries a reaction class is economic
-- (RM_MODULE_ENGINE_README.md, 6.8), so that made every stone in the
-- world economic while RM ran: never again. The reactions sort by
-- material name, the name each row shows.
--
-- THE SUBCATEGORY. Every mineral dye is filed under REFINISH_DYE_CAT_
-- MINERAL, "Make mineral dye", whose parent is MAKE_DYE: vanilla's Make dye,
-- or RM's own where a mod has cut it (the module engine resolves a
-- category's parent as it does a reaction's category, refinish-module-
-- react.lua, WHEN A MOD CUTS MAKE DYE).
--
-- ALL OF THEM, AT LOAD. Every reaction is injected and permitted at load
-- like any module reaction (permissions AUTO, the module evaluator), and
-- nothing is held back until a fort has the dust (decided 2026-10-04).
-- For a few hours they were permitted just in time instead, and showed in
-- no menu with the permits in place, so the permits were not why.
--
-- THE MEASURE. A dye is 150 of powder and two dust are 200: the quarter
-- lost is what washing and sieving throw away to leave the fines.
--
-- Registered by refinish-core-payload.lua, which calls payload() at the
-- token call; the engine runs start and stop with the other lifecycles.
-- ==========================================



-- ==========================================
-- LOG FUNNEL
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'DYES'
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

-- ==========================================
-- SETTINGS
-- ==========================================
local PREFIX       = 'REFINISH_DYE_'
local CLAIM_OWNER  = 'REFINISH_DYES'          -- the stockpile claim's owner
local PER_HOST     = 200                      -- materials a plant can hold
local DUST_PER_DYE = 2                        -- 200 of dust into a 150 dye (THE MEASURE)
local DUST_TOOL    = 'REFINISH_CORE_DUST'
local CATEGORY     = PREFIX .. 'CAT_MINERAL'   -- the subcategory (THE SUBCATEGORY)


-- ==========================================
-- STATE
-- ==========================================
--   colours       the dye colours, ordered: { id, name } each
--   by_id         [colour id] = that entry
--   sources       the materials with dust, one reaction each: { id, name, colour }
local S = { colours = {}, by_id = {}, sources = {} }

-- ==========================================
-- A MATERIAL'S COLOUR
-- ==========================================
-- The colour a pattern shows, its first (refinish-scan.lua,
-- color_of_pattern): read off the colour list a modded colour would show
-- its terminal colour instead. nil when the pattern resolves to nothing.
local function colour_of_pattern(pidx)
    local colours = df.global.world.raws.descriptors.colors
    local patterns = df.global.world.raws.descriptors.patterns
    if type(pidx) ~= 'number' or pidx < 0 or pidx >= #patterns then return nil end
    local p = patterns[pidx]
    if not p or #p.colors == 0 then return nil end
    local ci = p.colors[0]
    if ci < 0 or ci >= #colours then return nil end
    return colours[ci]
end

-- A material's colour: its solid colour, else its powder, paste and
-- pressed colours, the order the scan falls back in. A descriptor colour
-- (id, name) or nil. Also used by refinish-mint-finish.lua for a finish.
function colour_of(material)
    local c = nil
    pcall(function()
        c = colour_of_pattern(material.state_color[0])
        if not c then
            for _, s in ipairs({ 3, 5, 4 }) do
                c = colour_of_pattern(material.state_color[s])
                if c then return end
            end
        end
    end)
    return c
end

-- A material that has dust: a stone, a gem or a metal, not one of RM's
-- own (a finish's colour is its dust's, and finishes are minted later).
local function has_dust(inorg)
    if tostring(inorg.id):find('REFINISH_', 1, true) == 1 then return false end
    local f = inorg.material.flags
    return f.IS_STONE or f.IS_GEM or f.IS_METAL
end

-- ==========================================
-- THE DYES, BUILT AT THE TOKEN CALL
-- ==========================================
-- A material's name as DF shows its solid ("granite", "emerald",
-- "iron"), else its id in lower case.
local function material_name(inorg)
    local n = nil
    pcall(function() n = inorg.material.state_name.Solid end)
    n = n and tostring(n) or ''
    if n == '' then n = tostring(inorg.id):lower():gsub('_', ' ') end
    return n
end

-- Every material with dust and a colour, and every colour among them.
-- Colours ordered by id, and sources by name, then id, so the layout and
-- the menu are the same every load.
local function dust_sources()
    local order, by, sources = {}, {}, {}
    for _, inorg in ipairs(df.global.world.raws.inorganics.all) do
        local ok, yes = pcall(has_dust, inorg)
        if ok and yes then
            local c = colour_of(inorg.material)
            if c then
                if not by[c.id] then
                    local e = { id = c.id, name = c.name }
                    by[c.id] = e
                    order[#order + 1] = e
                end
                sources[#sources + 1] = { id = tostring(inorg.id), name = material_name(inorg),
                                          colour = by[c.id] }
            end
        end
    end
    table.sort(order, function(a, b) return a.id < b.id end)
    table.sort(sources, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return order, by, sources
end

-- A reaction key from a material id: DF accepts nearly anything in an id
-- (vanilla's gems have spaces: LACE AGATE), a key only letters, digits
-- and underscores. Kept unique, so two ids that read the same differ.
local function key_for(id, used)
    local base = 'MAKE_' .. id:upper():gsub('[^%w]', '_')
    local key, n = base, 1
    while used[key] do
        n = n + 1
        key = base .. '_' .. n
    end
    used[key] = true
    return key
end

-- A mineral dye: Making Fuel's dye materials, the template (vanilla's
-- dyes' properties, through the module engine's DYE class). It looks like
-- its colour and dyes with it.
local STRENGTH = {
    yield    = { IMPACT = 10000, COMPRESSIVE = 10000, TENSILE = 10000,
                 TORSION = 10000, SHEAR = 10000, BENDING = 10000 },
    fracture = { IMPACT = 20000, COMPRESSIVE = 20000, TENSILE = 20000,
                 TORSION = 20000, SHEAR = 20000, BENDING = 20000 },
    max_edge = 0,
}
local function dye_material(c)
    return {
        key              = c.id,
        name             = c.name .. ' mineral dye',
        material_class   = 'DYE',
        color            = c.id,
        fallback_colors  = {},
        dye_color        = c.id,
        -- 20, vanilla's dye value (71 of its 72 dyes; redroot is 10),
        -- since 2026-10-28; 8 before. A dyed item adds its dye's value
        -- (the thread dye value DFHack's Items::getValue adds), so at 8
        -- a mineral dye added less than any vanilla dye. Two dust of a
        -- common stone are worth 2. Dust of a dear metal or gem is worth
        -- more than the dye it makes: a dye is priced for what it does,
        -- as vanilla's are.
        value            = 20,
        heat             = { spec_heat = 1400, melting_point = 10480 },
        strength         = STRENGTH,
        solid_density    = 600,
    }
end

-- One material's reaction: its dust, by token, and a bag into its
-- colour's dye.
local function dye_reaction(src, plant_id, key)
    local c = src.colour
    return {
        key         = key,
        name        = 'make ' .. src.name .. ' mineral dye',
        building    = 'DYER',
        category    = CATEGORY,
        skill       = 'PROCESSPLANTS',
        fuel        = false,
        permissions = { mode = 'AUTO' },
        description = ('Two %s dust, washed down to its fines and bagged: a %s dye.'
            .. ' A quarter of the dust is lost.'):format(src.name, c.name),
        reagents    = {
            { code = 'dust', type = 'TOOL', tool_id = DUST_TOOL,
              mat_token = 'INORGANIC:' .. src.id, quantity = DUST_PER_DYE },
            { code = 'bag', type = 'BAG', quantity = 1, flags = { empty = true, preserve = true } },
        },
        products    = {
            { type = 'POWDER_MISC', mat_token = 'PLANT_MAT:' .. plant_id .. ':' .. c.id,
              to_container = 'bag', count = 1, dimension = 150 },
        },
    }
end

local start_dyes, stop_dyes

-- The registration, for refinish-core-payload.lua's listener.
function payload()
    local order, by, sources = dust_sources()
    S.colours, S.by_id, S.sources = order, by, sources
    -- The dyes: one per colour, a host per 200.
    local plants, host, host_of = {}, nil, {}
    for i, c in ipairs(order) do
        if (i - 1) % PER_HOST == 0 then
            local n = (i - 1) // PER_HOST + 1
            host = { key = (n == 1) and 'HOST' or ('HOST_' .. n),
                     name = 'mineral dye host', name_plural = 'mineral dye hosts',
                     plant_class = 'BASIC_CROP', plant_flags = {}, materials = {} }
            plants[#plants + 1] = host
        end
        host.materials[#host.materials + 1] = dye_material(c)
        host_of[c.id] = PREFIX .. host.key
    end
    -- The reactions: one per material with dust (WHICH DUST).
    local reactions, used = {}, {}
    for _, src in ipairs(sources) do
        reactions[#reactions + 1] = dye_reaction(src, host_of[src.colour.id], key_for(src.id, used))
    end
    log('DETAIL', ('%d colour(s) of dust in this world: %d mineral dye(s) on %d host(s), made'
        .. ' by %d reaction(s), one per stone, gem and metal.')
        :format(#order, #order, #plants, #reactions), 'BUILD')
    return {
        module = {
            id         = 'REFINISH_DYE',
            prefix     = PREFIX,
            name       = 'Refinish Dyes',
            version    = '1.0',
            -- The dust is another registration's tool, and
            -- REFINISH_DYE_ sorts ahead of it.
            depends_on = { 'REFINISH_CORE_' },
        },
        plants     = plants,
        -- THE SUBCATEGORY: parent MAKE_DYE, resolved by the engine.
        categories = { { key = 'MINERAL', name = 'Make mineral dye', parent = 'MAKE_DYE',
                         description = 'Make dyes from stone, gem and metal dust.' } },
        reactions  = reactions,
        start     = function() return start_dyes() end,
        stop      = function() return stop_dyes() end,
    }
end

-- ==========================================
-- AT START
-- ==========================================
-- Nothing is given to any material (WHICH DUST): the stockpile claim is
-- all there is to do.
-- The dyes, claimed for Milled Plants, as Making Fuel claims its own
-- (making-fuel-stockpile-organic.lua, dyes). The claim takes a FUNCTION
-- that lists them, called when the stockpile service settles, not a list:
-- handed a list it refuses the claim ("select must be a function", seen
-- in play 2026-10-04).
local function dye_list()
    local list = {}
    pcall(function()
        for _, p in ipairs(df.global.world.raws.plants.all) do
            local pid = tostring(p.id)
            if pid:find(PREFIX, 1, true) == 1 then
                for _, m in ipairs(p.material) do
                    if m.flags.IS_DYE then
                        local token = 'PLANT_MAT:' .. pid .. ':' .. tostring(m.id)
                        local info = dfhack.matinfo.find(token)
                        if info then
                            list[#list + 1] = { mt = info.type, mi = info.index,
                                                mat = m, label = token }
                        end
                    end
                end
            end
        end
    end)
    return list
end

local function claim_dyes()
    local api = _G.refinish_organic_api
    if not (api and api.claim) then
        -- ERROR: the mineral dyes have no stockpile slot.
        log('ERROR', 'refinish-stockpile-organic is not loaded; mineral dyes are not'
            .. ' registered for stockpiles this session.', 'CLAIM')
        return
    end
    local ok, why = api.claim(CLAIM_OWNER, 'PlantPowder', dye_list)
    if not ok then log('ERROR', 'dye claim refused: ' .. tostring(why), 'CLAIM') end
end

start_dyes = function()
    claim_dyes()
    log('DETAIL', ('%d mineral dye colour(s) from %d material(s), every reaction permitted at'
        .. ' the dyer.'):format(#S.colours, #S.sources), 'START')
end

stop_dyes = function()
    pcall(function()
        local api = _G.refinish_organic_api
        if api and api.unclaim then api.unclaim(CLAIM_OWNER) end
    end)
end