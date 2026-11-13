-- refinish-index-entity.lua
-- ==========================================
-- SCRIPT LOGIC: GLOBAL ENTITY UNLOCKER
-- ==========================================
-- Grants every capable civilization permission for core RM's
-- reactions. Every log line is DETAIL: the startup that calls this
-- reports the outcome. The per-civ trace stays behind VERBOSE_DEBUG,
-- in its own file.

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INDEX_ENTITY'
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

local VERBOSE_DEBUG = false
local debug_file = nil

local function dprint(msg)
    if debug_file then debug_file:write(msg .. "\n") end
end

if VERBOSE_DEBUG then
    debug_file = io.open(dfhack.getDFPath() .. "/refinish_indexer_debug.txt", "w")
    dprint("==================================================")
    dprint("REFINISH STEEL: INDEXER DEBUG LOG")
    dprint("==================================================")
end

log('DETAIL', 'Civ reaction permission unlock initiated.')

-- STATE MANAGER: Deep RAM Verification (Using player civ as a proxy check)
if _G.refinish_entity_loaded == nil or _G.refinish_entity_loaded == false then
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if player_civ and player_civ.entity_raw then
        local permitted = player_civ.entity_raw.workshops.permitted_reaction_id
        local reactions = df.global.world.raws.reactions.reactions
        for _, pid in ipairs(permitted) do
            if pid >= 0 and pid < #reactions then
                local rxn = reactions[pid]
                if rxn and string.find(rxn.code, "REFINISH_STEEL_RXN_") then
                    _G.refinish_entity_loaded = true
                    break
                end
            end
        end
    end
end

if _G.refinish_entity_loaded then
    dprint("ABORTED: _G.refinish_entity_loaded is already true. UI previously unlocked.")
    log('DETAIL', 'Civ permissions already unlocked. Skipping.')
    if debug_file then debug_file:close(); debug_file = nil end
    return
end

-- 1. Categorize our payload
-- THE LOAD CLOCK (refinish-startup.lua): nil outside a pipeline run.
local LC = _G.refinish_load_clock
local t_en = LC and LC.now()
local reactions = df.global.world.raws.reactions.reactions
local rs_payloads = { FINISHES = {}, STONE_GRIND = {}, GEM_GRIND = {}, METAL_GRIND = {} }
local blueprint_rxns = _G.refinish_blueprint and _G.refinish_blueprint.reactions or {}

-- Each forge folder placeholder's code -> its base metal id, read off the
-- blueprint (refinish-scan.lua, THE FORGE'S FOLDERS). A placeholder
-- belongs to a kind folder inside its base's, and its code carries the
-- kind before the base id, so the base is looked up, never cut out of
-- the code.
local folder_base = {}
do
    local forge = _G.refinish_blueprint and _G.refinish_blueprint.forge
    if forge and forge.bases then
        for b_id, f in pairs(forge.bases) do
            for _, k in pairs(f.kinds or {}) do folder_base[k.rxn] = b_id end
        end
    end
end

dprint("\n--- PHASE 1: CATEGORIZING PAYLOADS ---")
-- ---- EACH REACTION READ ONCE ----
-- MEASURED 2026-10-01, the load clock, region4: this loop cost 289 ms
-- over 103,534 reactions. A finish read rxn.code seven times and
-- rxn.index twice, every read a crossing into DFHack (each code read
-- makes a new string), and was matched against five patterns. All five hold
-- REFINISH_STEEL_RXN_ (string.find was unanchored), so a code without it
-- takes no branch and is passed after one plain find. The rest are read
-- once each and tested with plain finds, which match exactly what the
-- patterns did: none holds a magic character. The index -> code table
-- this loop also built was read by nothing, and is gone.
local find = string.find

-- One RM reaction sorted by the walk's own rules: a grinder by its kind,
-- else a finish by its base metal.
local function sort_into(code, index)
    if find(code, "REFINISH_STEEL_RXN_LUA_GRIND_COMMON", 1, true)
       or find(code, "REFINISH_STEEL_RXN_LUA_GRIND_ANY", 1, true) then
        table.insert(rs_payloads.STONE_GRIND, index)
    elseif find(code, "REFINISH_STEEL_RXN_LUA_GRIND_GEMS", 1, true) then
        table.insert(rs_payloads.GEM_GRIND, index)
    elseif find(code, "REFINISH_STEEL_RXN_LUA_GRIND_METAL", 1, true) then
        table.insert(rs_payloads.METAL_GRIND, index)
    elseif find(code, "REFINISH_STEEL_RXN_LUA_GRIND_FIN_", 1, true) then
        -- A finished-metal grinder (refinish-mint-finish.lua, THE
        -- FINISHED-METAL GRINDERS) goes with its base metal's finishes,
        -- as the handover puts it; its base is the rest of its code.
        local b_id = code:sub(#"REFINISH_STEEL_RXN_LUA_GRIND_FIN_" + 1)
        if b_id ~= "" then
            if not rs_payloads.FINISHES[b_id] then rs_payloads.FINISHES[b_id] = {} end
            table.insert(rs_payloads.FINISHES[b_id], index)
        end
    elseif find(code, "REFINISH_STEEL_RXN_FORGE_FOLDER_", 1, true) then
        -- A forge folder's placeholder (refinish-index-reaction.lua, THE
        -- FORGE'S FOLDER PLACEHOLDERS) goes with its base metal's finishes,
        -- as the handover puts it; its base comes from folder_base, above.
        local b_id = folder_base[code]
        if b_id then
            if not rs_payloads.FINISHES[b_id] then rs_payloads.FINISHES[b_id] = {} end
            table.insert(rs_payloads.FINISHES[b_id], index)
        end
    else
        local bp_data = blueprint_rxns[code]
        if bp_data and bp_data.base_metal_id then
            local b_id = bp_data.base_metal_id
            if not rs_payloads.FINISHES[b_id] then rs_payloads.FINISHES[b_id] = {} end
            table.insert(rs_payloads.FINISHES[b_id], index)
        end
    end
end

-- ---- THE REACTION STAGE'S HANDOVER ----
-- refinish-index-reaction writes down where it put every finish reaction,
-- by base metal, and the four grinders, as it builds them, and publishes
-- the lists with the array's length (THE ENTITY STAGE'S HANDOVER there).
-- When that length is still the array's, and the first and last finish
-- of every base metal and every grinder still hold the codes written
-- down, the lists are the ones the walk below would make: RM takes its
-- own reactions off before it builds them again, so the ones in the
-- array are the ones that stage just built, and nothing outside RM's
-- namespace holds REFINISH_STEEL_RXN_. Taken off the global here, so a
-- run without a fresh handover walks. Otherwise the walk, as before.
local handover = _G.refinish_rxn_handover
_G.refinish_rxn_handover = nil
local from_handover = false
if handover and handover.len == #reactions then
    local function matches()
        for b_id, list in pairs(handover.finishes) do
            if reactions[list[1]].code ~= handover.first_code[b_id]
               or reactions[list[#list]].code ~= handover.last_code[b_id] then
                return false
            end
        end
        for _, g in ipairs(handover.grinders) do
            if reactions[g.index].code ~= g.code then return false end
        end
        return true
    end
    local ok_h, good = pcall(matches)
    from_handover = ok_h and good
end

if from_handover then
    rs_payloads.FINISHES = handover.finishes
    for _, g in ipairs(handover.grinders) do sort_into(g.code, g.index) end
else
    for _, rxn in ipairs(reactions) do
        local code = rxn.code
        if find(code, "REFINISH_STEEL_RXN_", 1, true) then
            sort_into(code, rxn.index)
        end
    end
end

if LC then
    t_en = LC.lap(from_handover and 'entities: phase 1, from the reaction handover'
        or 'entities: every reaction read and sorted (phase 1)', t_en)
end
dprint("Payloads Built:")
dprint("  Stone Grind Rxns: " .. #rs_payloads.STONE_GRIND)
dprint("  Gem Grind Rxns: " .. #rs_payloads.GEM_GRIND)
dprint("  Metal Grind Rxns: " .. #rs_payloads.METAL_GRIND)
local finish_metal_count = 0
for k, v in pairs(rs_payloads.FINISHES) do finish_metal_count = finish_metal_count + 1 end
dprint("  Finishes mapped for " .. finish_metal_count .. " distinct base metals.")

local processed_raws = {}
local entities_updated = 0
local count = 0

dprint("\n--- SWEEPING ENTITIES (VIA CACHE) ---")

-- THE FIX: Front-load the Player Civ so it permanently sets the tech cache for its shared entity_raw
local processing_queue = {}
local p_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
if p_civ then table.insert(processing_queue, p_civ) end

for _, civ in ipairs(df.global.world.entities.all) do
    if not p_civ or civ.id ~= p_civ.id then
        table.insert(processing_queue, civ)
    end
end

-- 2. Sweep Global Entities & Inject
for civ_idx, civ in ipairs(processing_queue) do
    if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
        
        -- ---- EACH RAW ONCE ----
        -- Keyed by the object it used to be, which never matched: DFHack
        -- makes a new userdata for every read of a field that points at
        -- an object (LuaWrapper.cpp push_object_ref), so two reads of one
        -- entity_raw are equal under == but are different table keys.
        -- Every civilization was processed, and every one after the first
        -- of its raw walked the raw's whole permitted list again only to
        -- find every reaction already there: what it granted never
        -- changed.
        --
        -- So the raws done are kept by code and told apart with ==, which
        -- compares what they point at. Not by code alone (2026-10-01, the
        -- first form of this fix): DF allows two distinct raws to declare
        -- one [ENTITY:...] code (refinish-module-evaluate-permissions.lua,
        -- ENTITY CODE COLLISION CHECK), and each has its own permitted
        -- list, which the old loop granted to and keyed by code would not.
        local raw = civ.entity_raw
        local raw_code = raw.code
        local done = processed_raws[raw_code]
        local seen = false
        if done then
            for _, r in ipairs(done) do
                if r == raw then
                    seen = true
                    break
                end
            end
        else
            done = {}
            processed_raws[raw_code] = done
        end
        if not seen then
            done[#done + 1] = raw
            dprint("\nEvaluating Entity Code: " .. tostring(civ.entity_raw.code) .. " (Queue Index: " .. civ_idx .. ")")
            
            -- FETCH EXACT PRE-CALCULATED LOGIC FROM CACHE
            local civ_cache = nil
            if _G.refinish_blueprint and _G.refinish_blueprint.civ_tech then
                civ_cache = _G.refinish_blueprint.civ_tech[civ.entity_raw.code]
            end
            
            if civ_cache then
                dprint("  Moods -> Forge: " .. tostring(civ_cache.has_forge) .. ", Mason: " .. tostring(civ_cache.has_mason) .. ", Gem: " .. tostring(civ_cache.has_gem))

                local permitted_rxns = civ.entity_raw.workshops.permitted_reaction_id
                local known_metals = civ_cache.known_metals or {}
                local metal_tech = civ_cache.metal_tech
                local stone_tech = civ_cache.stone_tech
                local gem_tech   = civ_cache.gem_tech

                -- Phase 3: The Cross-Reference & Injection
                if stone_tech or gem_tech or metal_tech then
                    local already_permitted = {}
                    for _, pid in ipairs(permitted_rxns) do already_permitted[pid] = true end
                    
                    local injected_count = 0
                    local valid_injections = {} 

                    local function queue_payload(payload_table, label)
                        local added = 0
                        for _, target_idx in ipairs(payload_table) do
                            if not already_permitted[target_idx] then
                                table.insert(valid_injections, target_idx)
                                added = added + 1
                            end
                        end
                        
                        -- THE FIX: Explicitly log successes and skips for every single payload
                        if added > 0 then
                            dprint("    [+] Queued " .. added .. " reactions for payload: " .. label)
                        else
                            dprint("    [-] Skipped payload: " .. label .. " (0 new reactions needed, or empty)")
                        end
                    end

                    if stone_tech then queue_payload(rs_payloads.STONE_GRIND, "STONE_GRIND") end
                    if gem_tech   then queue_payload(rs_payloads.GEM_GRIND, "GEM_GRIND") end
                    
                    if metal_tech then 
                        queue_payload(rs_payloads.METAL_GRIND, "METAL_GRIND")
                        
                        for base_metal_id, payload_array in pairs(rs_payloads.FINISHES) do
                            if known_metals[base_metal_id] then
                                queue_payload(payload_array, "FINISHES for " .. base_metal_id)
                            end
                        end
                    end
                    
                    table.sort(valid_injections)

                    local t_ins = LC and LC.now()
                    for _, target_idx in ipairs(valid_injections) do
                        permitted_rxns:insert('#', target_idx)
                        injected_count = injected_count + 1
                    end
                    if LC then
                        LC.add('entities: permission inserts', LC.now() - t_ins,
                            injected_count, civ.entity_raw.code)
                    end
                    
                    if injected_count > 0 then
                        entities_updated = entities_updated + 1
                        count = count + injected_count
                        dprint("  [SUCCESS] Injected " .. injected_count .. " custom reactions into " .. tostring(civ.entity_raw.code))
                    else
                        dprint("  [SKIP] 0 reactions injected (Already has them or no matching tech).")
                    end
                else
                    dprint("  [FAIL] Entity lacks required mood tech (Forge/Mason/Gem).")
                end
            else
                dprint("  [FAIL] Entity lacked a valid blueprint cache.")
            end
        end
    end
end

if LC then LC.lap('entities: civ sweep, inserts included', t_en) end
_G.refinish_entity_loaded = true

dprint("\n==================================================")
dprint(string.format("Global UI Unlock Complete: %d custom reactions injected across %d capable civilizations.", count, entities_updated))
dprint("==================================================")

if debug_file then
    debug_file:close()
    debug_file = nil
end

log('DETAIL', string.format('Civ permission unlock complete: %d reactions'
    .. ' granted across %d civilizations.', count, entities_updated))