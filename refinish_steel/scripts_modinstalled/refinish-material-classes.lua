--@ module = true
-- refinish-material-classes.lua
-- ==========================================
-- RM MATERIAL CLASSES: REACTION CLASSES GIVEN AT RUN TIME
-- ==========================================
-- WHY
-- A reaction asks for a kind of material through a reaction class, as
-- vanilla asks for FLUX and GYPSUM. Some kinds a module needs have no
-- class in the raws: no vanilla stone says it is volcanic, so no reagent
-- could ask for volcanic dust (rhyolite, basalt, andesite, dacite and
-- obsidian carry no REACTION_CLASS, checked 2026-10-03 in the vanilla
-- raws). This lets a module name a class and the materials that should
-- carry it, and RM gives it to them while RM's data is in RAM. It is the
-- first piece of RM's runtime editor: reaction classes on existing
-- materials.
--
-- ECONOMIC. A stone with a legitimate class is an economic stone, as
-- flux and gypsum are, and the fort's stone settings can still mark it
-- otherwise. Accepted, 2026-10-03.
--
-- HOW, from a module's start hook, which RM runs once the module's
-- assets are injected (refinish-module-engine.lua, MODULE LIFECYCLE):
--   _G.refinish_class_api.grant(owner, {
--       class = 'POZZOLAN',                        -- the class to give
--       inorganic_flags = { 'IGNEOUS_EXTRUSIVE' }, -- every inorganic with any of these
--       ids = { 'OBSIDIAN' },                      -- and these, by id
--   })
-- It returns how many materials it gave the class to. A material that
-- already carries the class keeps its own and is not recorded, so taking
-- grants back never removes a class the raws gave. RM's own materials
-- (REFINISH_ ids) are never given one. Only inorganics, for now. Aliases
-- (ALIASES, below) reach plant and creature materials as well.
--
-- TAKEN BACK by stop(), which RM runs first thing at every shutdown with
-- its other services (refinish_steel.lua, RM'S SERVICES FOLLOW THE
-- DATA): before every save, at a data cycle and at map unload, so a
-- given class never reaches a save (the save integrity rule: the raws in
-- RAM hold nothing of RM's or a module's when a save is written). The
-- module's start hook gives it again after the next injection. One
-- record and one sweep for every module, so no module cleans up after
-- itself.
--
-- ERASED, NOT FREED. reaction_class is a vector of string pointers, so a
-- class given is a string allocated for it, its text on .value (the
-- metal grinder's class does the same, refinish-index-reaction.lua). On
-- the way back the entry is erased from the material it was given to and
-- the string is left allocated: a material copied while it carried the
-- class (a twin) may hold the same pointer, and freeing it under that
-- copy would crash. A few bytes a data cycle.
-- ==========================================

local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CLASSES'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. SUBJECT is the owner asking, or the step. No console
-- prints: nothing here answers a typed command.
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

-- ==========================================
-- THE RECORD
-- ==========================================
-- On _G, so a reload of this file never loses what is still to be taken
-- back. granted: one entry per class this file put on a material,
-- { index, id, class, owner, ptr }.
_G.refinish_class_grants = _G.refinish_class_grants or { granted = {} }
local G = _G.refinish_class_grants

local function new_string_ptr(s)
    local p = df.new('string')
    p.value = s
    return p
end

local function has_class(m, cls)
    for _, rc in ipairs(m.reaction_class) do
        if rc and rc.value == cls then return true end
    end
    return false
end

-- ==========================================
-- GIVING
-- ==========================================
function grant(owner, spec)
    if type(owner) ~= 'string' or owner == '' then error('grant needs an owner') end
    if type(spec) ~= 'table' or type(spec.class) ~= 'string' or spec.class == '' then
        error('grant needs a class')
    end
    local cls = spec.class
    local flags = {}
    for _, f in ipairs(spec.inorganic_flags or {}) do
        -- A flag DF does not have is named in the log and skipped, so a
        -- typo cannot silently grant nothing or everything.
        if df.inorganic_flags and df.inorganic_flags[f] == nil then
            log('WARNING', ('%s asked for inorganic flag %s, which DF does not have;'
                .. ' it is skipped.'):format(owner, tostring(f)), owner)
        else
            flags[#flags + 1] = f
        end
    end
    local ids = {}
    for _, id in ipairs(spec.ids or {}) do ids[tostring(id)] = true end

    local given, had = 0, 0
    for i, inorg in ipairs(df.global.world.raws.inorganics.all) do
        pcall(function()
            local id = tostring(inorg.id)
            if id:sub(1, 9) == 'REFINISH_' then return end
            local hit = ids[id] or false
            if not hit then
                for _, f in ipairs(flags) do
                    if inorg.flags[f] then hit = true break end
                end
            end
            if not hit then return end
            if has_class(inorg.material, cls) then
                had = had + 1
                return
            end
            local p = new_string_ptr(cls)
            inorg.material.reaction_class:insert('#', p)
            G.granted[#G.granted + 1] = { index = i, id = id, class = cls,
                                         owner = owner, ptr = p }
            given = given + 1
        end)
    end
    log('DETAIL', ('%s: %s given to %d material(s); %d already carried it.')
        :format(owner, cls, given, had), owner)
    return given
end

-- ==========================================
-- TAKING BACK
-- ==========================================
-- Every class this file gave, off the material it gave it to, by the
-- pointer it gave, so a class the raws or another copy holds is never
-- touched. An inorganic found elsewhere than recorded is looked up by
-- id; one gone is skipped (its material went with it).
-- The material a record was given to, found again: by its recorded
-- position first, and by id when something moved. nil when it is gone.
-- A grant names an inorganic; an alias may name a plant's or a creature's
-- material, recorded as its host and the material's own id (ALIASES).
local function find_by(vec, field, id)
    for _, x in ipairs(vec) do
        if tostring(x[field]) == id then return x end
    end
    return nil
end

local function material_of(g)
    if g.kind == 'plant' or g.kind == 'creature' then
        local plant = (g.kind == 'plant')
        local vec   = plant and df.global.world.raws.plants.all or df.global.world.raws.creatures.all
        local field = plant and 'id' or 'creature_id'
        local host  = (g.index < #vec) and vec[g.index] or nil
        if not (host and tostring(host[field]) == g.id) then host = find_by(vec, field, g.id) end
        if not host then return nil end
        local mats = host.material
        local m = (g.mi < #mats) and mats[g.mi] or nil
        if m and tostring(m.id) == g.mid then return m end
        return find_by(mats, 'id', g.mid)
    end
    local inorgs = df.global.world.raws.inorganics.all
    local inorg = (g.index < #inorgs) and inorgs[g.index] or nil
    if not (inorg and tostring(inorg.id) == g.id) then
        inorg = nil
        local info = dfhack.matinfo.find('INORGANIC:' .. g.id)
        if info and info.inorganic then inorg = info.inorganic end
    end
    return inorg and inorg.material or nil
end

local function revoke_all()
    local taken, missing = 0, 0
    for _, g in ipairs(G.granted) do
        pcall(function()
            local m = material_of(g)
            if not m then
                missing = missing + 1
                return
            end
            local v = m.reaction_class
            for k = #v - 1, 0, -1 do
                if v[k] and tostring(v[k]) == tostring(g.ptr) then
                    v:erase(k)
                    taken = taken + 1
                    break
                end
            end
        end)
    end
    if #G.granted > 0 then
        log('DETAIL', ('%d class(es) taken back%s.'):format(taken,
            missing > 0 and (', ' .. missing .. ' material(s) already gone') or ''), 'REVOKE')
    end
    G.granted = {}
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- ==========================================
-- ALIASES (2026-10-05)
-- ==========================================
-- A reagent that declares reads (READS, refinish-module-react.lua) asks
-- for its words as its class, so DF's hover and objection print the words
-- rather than the token. Every material carrying the old class must carry
-- the words too, or it stops matching: the reaction builder records each
-- pair in _G.refinish_class_aliases as it builds, and start() gives them,
-- once every material of the cycle is in RAM, twins included (the engine
-- pushes those during the injection, STEP 2.5). They are recorded with
-- every other class given here, so stop() takes them back before any save.
-- Searched: inorganics, every plant's materials and every creature's
-- (a class can live on any of them: FAT is on each creature's fat, the
-- coal host's classes on plant materials). RM's finishes, REFINISH_STEEL_,
-- are skipped: tens of thousands of copies of base metals, carrying no
-- module's class. RM's other materials are searched (the slag's SLAG and
-- AGGREGATE, the gall's ALKALI), unlike a grant.
-- A product gate turned into words (PRODUCT_KEY, below) is found the same
-- way, by the material's reaction products: SEED_MAT on a plant's
-- structural material, FIRED_MAT on a clay.
-- A material made after start that carries an aliased class would miss
-- its words. None is today: the finishes minted in play copy base metals.
-- Anything that begins minting such materials must give them the words.
local FINISH_PREFIX = 'REFINISH_STEEL_'

-- A product gate turned into words (READS, PRODUCT GATED, in
-- refinish-module-react.lua): its entry in _G.refinish_class_aliases is
-- this prefix and the product id, and every material having that
-- reaction product is given the words as a class. The builder writes the
-- same prefix. alias_products: some gate was, this cycle (apply_aliases).
local PRODUCT_KEY = '@product:'
local alias_products = false

-- One material: the words each of its classes asks for, given beside them.
local function alias_material(m, rec, want, counts)
    local adds = nil
    for _, rc in ipairs(m.reaction_class) do
        local by = rc and want[rc.value]
        if by then
            adds = adds or {}
            for words, owner in pairs(by) do adds[words] = owner end
        end
    end
    -- Its reaction products, only when a product gate was turned into
    -- words this cycle: one more vector to read on every material.
    if alias_products then
        for _, pid in ipairs(m.reaction_product.id) do
            local by = pid and want[PRODUCT_KEY .. pid.value]
            if by then
                adds = adds or {}
                for words, owner in pairs(by) do adds[words] = owner end
            end
        end
    end
    if not adds then return end
    for words, owner in pairs(adds) do
        if has_class(m, words) then
            counts.had = counts.had + 1
        else
            local p = new_string_ptr(words)
            m.reaction_class:insert('#', p)
            local g = { class = words, owner = tostring(owner), ptr = p }
            for k, v in pairs(rec) do g[k] = v end
            G.granted[#G.granted + 1] = g
            counts.given = counts.given + 1
        end
    end
end

local function apply_aliases()
    local want = _G.refinish_class_aliases or {}
    if next(want) == nil then return end
    local counts = { given = 0, had = 0 }
    local t0 = dfhack.getTickCount()
    alias_products = false
    for key in pairs(want) do
        if key:sub(1, #PRODUCT_KEY) == PRODUCT_KEY then alias_products = true break end
    end
    for i, inorg in ipairs(df.global.world.raws.inorganics.all) do
        pcall(function()
            local id = tostring(inorg.id)
            if id:sub(1, #FINISH_PREFIX) == FINISH_PREFIX then return end
            alias_material(inorg.material, { index = i, id = id }, want, counts)
        end)
    end
    for i, plant in ipairs(df.global.world.raws.plants.all) do
        pcall(function()
            local pid = tostring(plant.id)
            for mi, m in ipairs(plant.material) do
                alias_material(m, { kind = 'plant', index = i, id = pid, mi = mi,
                                    mid = tostring(m.id) }, want, counts)
            end
        end)
    end
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        pcall(function()
            local cid = tostring(cr.creature_id)
            for mi, m in ipairs(cr.material) do
                alias_material(m, { kind = 'creature', index = i, id = cid, mi = mi,
                                    mid = tostring(m.id) }, want, counts)
            end
        end)
    end
    local n = 0
    for _, by in pairs(want) do for _ in pairs(by) do n = n + 1 end end
    log('DETAIL', ('aliases: %d set(s) of words given to %d material(s), %d already'
        .. ' carried them, in %d ms.'):format(n, counts.given, counts.had,
        dfhack.getTickCount() - t0), 'ALIAS')
end

-- The modules give their own classes from their start hooks, which run
-- before RM's services start; start() gives the aliases, now that every
-- material is in RAM, and says what is in place.
function start()
    apply_aliases()
    if #G.granted > 0 then
        log('DETAIL', ('active; %d class(es) given this cycle.'):format(#G.granted), 'START')
    end
end

function stop()
    revoke_all()
    -- The builders ask again at the next injection (READS,
    -- refinish-module-react.lua), so what they asked this cycle goes.
    _G.refinish_class_aliases = {}
end

-- ---- THE HANDLE ----
-- Published at load: modules grant from their start hooks, inside the
-- pipeline, before RM's services start.
_G.refinish_class_api = { grant = grant }
