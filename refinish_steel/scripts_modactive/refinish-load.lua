-- refinish-load.lua
-- ==========================================
-- REFINISH METAL: LEGACY PAYLOAD MIGRATION
-- ==========================================
-- The save wash (refinish-save.lua, the AUTOSAVE protocol) was retired
-- 2026-09-29. Before every save it rewrote finished objects to their
-- base metals and kept their finishes in a JSON payload in site data
-- (REFINISH_STEEL_PAYLOAD), which this script restored after every load.
-- Saves no longer touch objects: they keep their materials, and the
-- ledger remap (refinish-startup, Step 6.5) moves them by name.
--
-- What is left is a save the old line wrote last: its finished objects
-- are still sitting on their base metals. Startup (Step 7) runs this
-- only when a payload is present. It restores every entry whose finish
-- is loaded, then DELETES the payload, so each save migrates once. The
-- deletion reaches the file with the next save; a load quit without
-- saving simply migrates again, to the same result.
--
-- The v3.x key migration lives on here. Its gate forced this restore
-- when a payload's ids were in an older format, and an id that no longer
-- exists matched nothing then, as now. Entries like that, and entries
-- whose finish is not loaded this session (its base metal not selected,
-- Material Finishes off), are dropped with the payload: their objects
-- stay on their base metal. The count is logged.
--
-- Safe on a stale payload. A save switched to HOTSAVE before the
-- retirement still carries the last payload the old line wrote, while
-- its objects already wear their finishes:
--   items, buildings  keyed by id, which DF never reuses. Writing the
--                     recorded finish onto an object already wearing it
--                     changes nothing, and is counted apart.
--   constructions     keyed by tile, and a tile can have been rebuilt in
--                     something else since. Only a tile still on the base
--                     metal its finish was washed to is restored: the test
--                     the Amnesia Sync below always used.
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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'PAYLOAD_MIGRATION'
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

local json = require('json')

-- The site data key the retired wash wrote. Nothing writes it now.
local PAYLOAD_KEY = "REFINISH_STEEL_PAYLOAD"

-- ==========================================
-- FINISHES LOADED?
-- ==========================================
-- Restoring by name needs the finishes injected. Without them no entry
-- resolves, and retiring the payload would drop every one, so the run
-- stops and leaves the payload for a load that has them. The flag is
-- set by the boot state check and by startup's injection; run by hand
-- before either, the array is asked directly.
local function finishes_loaded()
    if _G.refinish_ram_loaded ~= nil then return _G.refinish_ram_loaded end
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if string.find(mat.id, "REFINISH_STEEL_", 1, true) then return true end
    end
    return false
end

-- Removes the payload from site data. deleteSiteData returns true on
-- success; a failure only means the next load migrates again.
local function retire()
    local ok, gone = pcall(dfhack.persistent.deleteSiteData, PAYLOAD_KEY)
    if not (ok and gone) then
        log('WARNING', 'The legacy payload could not be deleted; the next'
            .. ' load migrates it again.', 'RETIRE')
    end
end

-- ==========================================
-- THE MIGRATION
-- ==========================================
local function migrate()
    local payload = dfhack.persistent.getSiteData(PAYLOAD_KEY)
    if not payload or payload == "" then
        log('DETAIL', 'No legacy payload on this fortress.', 'PAYLOAD')
        return
    end

    -- Unreadable now means unreadable on every load, so it goes.
    local ok_d, data = pcall(json.decode, payload)
    if not ok_d or type(data) ~= 'table' then
        log('ERROR', 'The legacy payload could not be decoded; the finishes'
            .. ' it held stay on their base metals.', 'PAYLOAD')
        retire()
        return
    end

    -- ---- SITE ID GATE (ANTI-GHOSTING) ----
    -- A payload stamped with another site describes another fort's
    -- objects. A very old payload carries no stamp and is trusted, as
    -- the old line did.
    local current_site_id = df.global.plotinfo.site_id
    if data.site_id and data.site_id ~= current_site_id then
        log('INFO', string.format('Discarded a legacy payload from another'
            .. ' fortress (site %s).', tostring(data.site_id)), 'PAYLOAD')
        retire()
        return
    end

    -- ---- LOOKUPS, BUILT ONCE ----
    -- name -> current index, for every inorganic.
    local mat_lookup = {}
    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        mat_lookup[mat.id] = i
    end

    -- ---- FINISHES MINTED ON DEMAND ----
    -- A finish is minted only once the fort can make it
    -- (refinish-mint-finish.lua), so one this payload names may not be in
    -- the array yet. Each one the blueprint can make is minted here,
    -- before any entry resolves, so no object stays on its base metal for
    -- want of it.
    local mint = _G.refinish_mint_finish_on_demand
    if mint then
        for _, key in ipairs({ 'items', 'buildings', 'constructions' }) do
            for _, saved in ipairs(data[key] or {}) do
                local id = saved.mat
                if type(id) == 'string' and not mat_lookup[id] then
                    local ok_m, idx = pcall(mint, id)
                    if ok_m and idx then mat_lookup[id] = idx end
                end
            end
        end
    end

    -- finish name -> the base metal index the wash wrote it to. Steel
    -- when the blueprint does not know the finish: the wash's own
    -- fallback for a finish missing from the blueprint.
    local wash_idx = {}
    if _G.refinish_blueprint and _G.refinish_blueprint.materials then
        for custom_id, b_data in pairs(_G.refinish_blueprint.materials) do
            local b_idx = mat_lookup[b_data.base_metal_id]
            if b_idx then wash_idx[custom_id] = b_idx end
        end
    end
    local FALLBACK_SAFE_INDEX = mat_lookup["STEEL"] or 0
    local function washed_to(name) return wash_idx[name] or FALLBACK_SAFE_INDEX end

    -- restored  written onto its finish
    -- already   wearing its finish already (a stale payload)
    -- synced    construction tiles moved by the Amnesia Sync
    -- unloaded  the finish is not loaded this session, or no longer
    --           exists: the object stays on its base metal
    -- gone      the object no longer exists
    local restored, already, synced, unloaded, gone = 0, 0, 0, 0, 0

    -- ---- ITEMS ----
    -- One pass to index the items array by id, one to consume it.
    -- df.item.find per entry searched the whole array every time.
    local item_by_id = {}
    for _, item in ipairs(df.global.world.items.all) do
        item_by_id[item.id] = item
    end

    for _, saved in ipairs(data.items or {}) do
        local item = item_by_id[saved.id]
        local target = mat_lookup[saved.mat]
        if not item then
            gone = gone + 1
        elseif not target then
            unloaded = unloaded + 1
        elseif item:getActualMaterial() == 0 then
            if item.mat_index == target then
                already = already + 1
            else
                item.mat_index = target
                restored = restored + 1
            end

            -- ---- AMNESIA SYNC ----
            -- A wall built from this item while the data was unloaded
            -- took the base metal the item had been washed to, and so
            -- did the floor it makes above. Only a tile still on that
            -- base metal moves.
            if item.flags.construction then
                local expected = washed_to(saved.mat)
                pcall(function()
                    local pos = item.pos
                    local cons = dfhack.constructions.findAtTile(pos)
                    if cons and cons.mat_type == 0 and cons.mat_index == expected then
                        cons.mat_type = 0
                        cons.mat_index = target
                        synced = synced + 1

                        local above = dfhack.constructions.findAtTile(
                            { x = pos.x, y = pos.y, z = pos.z + 1 })
                        if above and above.mat_type == 0 and above.mat_index == expected then
                            above.mat_type = 0
                            above.mat_index = target
                            synced = synced + 1
                        end
                    end
                end)
            end
        end
    end

    -- ---- BUILDINGS ----
    local bld_by_id = {}
    for _, bld in ipairs(df.global.world.buildings.all) do
        bld_by_id[bld.id] = bld
    end

    for _, saved in ipairs(data.buildings or {}) do
        local bld = bld_by_id[saved.id]
        local target = mat_lookup[saved.mat]
        if not bld then
            gone = gone + 1
        elseif not target then
            unloaded = unloaded + 1
        elseif bld.mat_type == 0 then
            if bld.mat_index == target then
                already = already + 1
            else
                bld.mat_index = target
                restored = restored + 1
            end
        end
    end

    -- ---- CONSTRUCTIONS ----
    -- Keyed by tile, so only a tile still on the base metal its finish
    -- was washed to is restored. A tile the Amnesia Sync above already
    -- moved no longer matches and is left alone. Wrapped so a fault
    -- here cannot stop the payload being retired.
    local ok_c, err_c = pcall(function()
        for _, saved in ipairs(data.constructions or {}) do
            local target = mat_lookup[saved.mat]
            local c = dfhack.constructions.findAtTile({
                x = tonumber(saved.x), y = tonumber(saved.y), z = tonumber(saved.z) })
            if not c then
                gone = gone + 1
            elseif not target then
                unloaded = unloaded + 1
            elseif c.mat_type == 0 and c.mat_index == washed_to(saved.mat) then
                c.mat_type = 0
                c.mat_index = target
                restored = restored + 1
            end
        end
    end)
    if not ok_c then
        log('WARNING', 'Constructions skipped: ' .. tostring(err_c),
            'CONSTRUCTIONS')
    end

    -- ---- RETIRE THE PAYLOAD ----
    -- Everything it can still do is done.
    retire()

    -- INFO: a one-time event on a save the old line wrote, the line a
    -- player would look for after the first load of an old save.
    log('INFO', string.format('Legacy payload migrated and retired: %d'
        .. ' object(s) restored, %d already in their finish, %d'
        .. ' construction tile(s) synced, %d no longer exist.',
        restored, already, synced, gone), 'SEQUENCE')

    -- WARNING: these finishes are gone for good. Nothing records them
    -- once the payload is deleted.
    if unloaded > 0 then
        log('WARNING', string.format('%d legacy payload entr%s named a'
            .. ' finish not loaded this session (its base metal not'
            .. ' selected, Material Finishes off, or an id from an older'
            .. ' version); those objects stay on their base metal.',
            unloaded, unloaded == 1 and 'y' or 'ies'), 'UNLOADED')
    end
end

-- ==========================================
-- ENTRY
-- ==========================================
if not finishes_loaded() then
    log('ERROR', 'Cannot migrate the legacy payload: no finishes are'
        .. ' loaded. It stays for a load that has them.', 'PAYLOAD')
    return
end

migrate()