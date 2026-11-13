--@ module = true
-- refinish-stockpile-organic.lua
-- ==========================================
-- RM ORGANIC CATEGORIES
-- ==========================================
-- DF stores some things by ORGANIC CATEGORY rather than by material. A
-- stockpile's Food / Globs and Food / Milled Plants settings are lists of
-- positions in world.raws.mat_table.organic_types[cat] and
-- organic_indexes[cat], built from the raws at load. A module material
-- that belongs in one of those categories (Making Fuel's hide globs, its
-- dyes) is in neither list, so no stockpile setting can address it and
-- nothing will ever store it there. This gives it a position.
--
-- WHERE IT CAME FROM. Making Fuel's hide-stock and dye-stock each carried
-- a copy of the recipe below. RM owns it now; a module only says which
-- materials go in which category. RM_Organic_Category_Registration.md
-- has the long form of the recipe and how it was found. The notes below
-- are theirs, carried over.
--
-- ---- WHY ONLY THESE MATERIALS NEED IT (measured) ----
-- Every other injected material in every RM module hauls correctly,
-- because every other one is an inorganic stored in a category whose
-- settings vector is indexed by INORGANIC index. Measured on a live
-- fort: stone.mats, bars_mats, coins.mats, gems.cut_mats and armor.mats
-- all read 767, and the hide material sat at inorganic index 765. Those
-- vectors already cover every module inorganic.
--
-- The food categories are different. They are indexed by position in a
-- per category ORGANIC enumeration, world.raws.mat_table.organic_types
-- and organic_indexes, built from the raws at world load. Measured:
--
--   Glob   len=2416   ours=ABSENT   fat=372
--
-- Vanilla llama fat is at position 372. The hide material was absent
-- from all forty categories, because it did not exist when the
-- enumeration was built. There was therefore no position for a
-- stockpile setting to switch on, which is why STOCKPILE_GLOB on the
-- material did nothing and why clearing IS_STONE changed nothing. A
-- plant material made at run time is missing from the list DF builds
-- at load in exactly the same way.
--
-- ---- WHAT THIS WRITES, AND THE ONE HAZARD ----
-- Two appends per material, to organic_types[cat] and
-- organic_indexes[cat]. Those live in raws, are rebuilt from the mod
-- files every load, and are not saved, so the append is redone every
-- load. That is safe and self correcting.
--
-- The stockpile settings vectors ARE saved. Growing one writes into fort
-- data that outlives the module. The consequences, stated rather than
-- assumed:
--   - Every load re-appends the same materials, so the enumeration
--     length is stable and the resize is idempotent. It grows to a
--     target, never by a delta, so it cannot creep.
--   - If a module is later removed, a stockpile carries a few trailing
--     bytes DF's own enumeration does not reach. DF indexes by position
--     and stops at its own list length, so the tail should be ignored.
--     UNTESTED, and it is the one thing here that touches data RM does
--     not own.
-- Nothing is ever removed from either vector. Shrinking a saved settings
-- vector would shift every position after the cut, which would silently
-- re-point the player's choices at other materials.
--
-- ---- BOTH DIRECTIONS ARE REQUIRED ----
-- Appending builds one direction only: position to material. DF also
-- has to go material to position, and it will not linearly search 2420
-- entries every time a hauler considers an item. That reverse lookup
-- lives on the material, food_mat_index[cat]. A material can be in the
-- enumeration, have an enabled settings slot, and still never be hauled,
-- because the lookup that would reach the settings never resolves a
-- position. That was the state measured after the first sync:
-- registered, enabled, inert. Either direction alone hauls nothing (O5).
--
-- Registration makes a material ADDRESSABLE. Which category DF files the
-- item under is a separate gate (O8).
--
-- ---- LIFECYCLE, AS MEASURED (session log 2026-09-23) ----
-- START. A module claims during RM's token call, BEFORE RM injects its
-- materials: dye-stock's start found 0 dyes at 13:53:48 and RM injected
-- them at 13:53:49. So a claim arms a short frame poll (SETTLE) that
-- syncs until the materials are there, then drops out. Frames advance
-- while paused; game days do not. The daily poll carries on after.
--
-- RE-INJECTION. An in-session hotsave re-runs RM's token call, and RM
-- rebuilds the module's materials as new objects with no reverse index.
-- The module claims again in that token call, which re-arms the settle
-- poll, so the reverse index is back within a few frames instead of a
-- day.
--
-- STOP. Cancels the polls and removes nothing. The enumeration is rebuilt
-- from raws at load (PlantPowder read 109 before a hotsave, 101 after
-- it), an in-session hotsave re-injects at the same indices so the
-- entries stay true, and RM's rule is one prefix sweep rather than every
-- script cleaning up after itself. The stockpile settings vectors are
-- the one thing carried in a save: they are the player's data, grown
-- only, never shrunk.
--
-- ---- THE RECIPE ----
--   1. Append (mat_type, mat_index) to organic_types[cat] and
--      organic_indexes[cat], once. A material already there is found
--      again by position_of and never appended twice.
--   2. Set the material's food_mat_index[cat] to that position, the
--      reverse index DF reads, and read it back.
--   3. Grow every stockpile's settings vector for the category to the
--      new length, the new slots filled the way that pile already treats
--      the category (see CATEGORIES).
-- NOTHING IS EVER REMOVED. The lists are rebuilt from the raws on load.
--
-- ---- CLAIMING ----
--   a) In a module's materials JSON: "organic_category": "Glob" on an
--      inorganic material. RM finds it in the module registry and claims
--      it; nothing else to write.
--   b) From Lua, for materials made at run time or on plant hosts:
--        _G.refinish_organic_api.claim(owner, category, select, opts)
--      select() returns a list of { mt, mi, mat, label }. Claiming again
--      under the same owner replaces it; unclaim(owner) drops it.
--      opts.may_be_empty = true says finding nothing is normal for this
--      claim (materials made only as play needs them), so the settle
--      poll neither waits on it nor warns about it.
--
-- ---- COMPARTMENTS ----
-- Each claim is on its own: a selector that throws costs that claim,
-- named once, and every other claim still registers. Each category is
-- synced on its own the same way. An unknown category is named once and
-- skipped.
--
-- ---- WHEN ----
-- A sync every POLL_DAYS; and a SETTLE poll every SETTLE_FRAMES after a
-- start or a claim, up to SETTLE_TRIES, until every claim has found its
-- materials, since some are injected a little after their owner starts.
--
-- ---- COMMANDS ----
--   refinish-stockpile-organic status    claims, categories, lengths
-- ==========================================

local repeatUtil = require('repeat-util')
local POLL_KEY   = 'refinish-stockpile-organic'
local SETTLE_KEY = 'refinish-stockpile-organic-settle'
-- Daily. The set of materials changes rarely (a creature butchered for
-- the first time, a stockpile built mid session), and a day's delay only
-- means an item waits where it was made.
local POLL_DAYS     = 1
-- The settle poll after a claim. RM's whole pipeline took under two
-- seconds in the measured session; 100 tries of 10 frames is far past
-- that, and the poll stops as soon as every claim finds its materials.
-- Frame timers survive a world unload, so stop() cancels it and the try
-- cap ends it regardless.
local SETTLE_FRAMES = 10
local SETTLE_TRIES  = 100

-- ---- CATEGORIES ----
-- The stockpile settings vector each category is addressed by, and how a
-- pile's new slots are filled. New slots inherit the pile's existing
-- intent:
--   any   GLOBS. If any glob is already enabled on a pile, a new one is
--         enabled too. A player who switched globs on for that pile meant
--         globs, and a new one appearing switched off would read as the
--         feature not working. A pile with no globs enabled gets a
--         disabled slot.
--   all   MILLED PLANTS. A new slot is on only when EVERY existing slot on
--         that pile is on: that pile takes all milled plants, so it takes
--         ours too. A pile taking some and not others made a choice this
--         cannot read, so ours start off there and the player can switch
--         them on by name. Milled plants mix flour with dye, and a flour
--         pile should not start filling with dye.
-- A category not listed here cannot be claimed until it is.
--
-- CreatureCheese was added 2026-09-26 for making-fuel-cheese-probe, and
-- for any module after it: DF crashed in its own food code about seven
-- minutes after two cheese items of an unregistered material appeared,
-- and an unregistered material is one whose food_mat_index is -1 (read
-- off every inorganic in the path maps). A cheese item whose material
-- has no position here is not safe to make. Filled 'all', the careful
-- rule: a pile that takes every animal cheese takes a new one too, any
-- other pile starts with it off. The path is read at sync; if DF names
-- the vector differently the sync says so once and skips the category.
local CATEGORIES = {
    Glob           = { path = { 'food', 'glob' },          fill = 'any' },
    PlantPowder    = { path = { 'food', 'powder_plant' },  fill = 'all' },
    CreatureCheese = { path = { 'food', 'cheese_animal' }, fill = 'all' },
}

-- ==========================================
-- LOG FUNNEL
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'ORGANIC'
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

-- ---- FAULTS, ONCE EACH ----
-- The sync runs every in game day, about twelve real seconds, and a
-- structural fault fails the same way on every pass. Each distinct fault
-- is logged once per session under its own key; start() clears the set.
local said = {}
local function fault_once(key, typ, msg, subject)
    if said[key] then return end
    said[key] = true
    log(typ, msg, subject)
end

local function try(fn, dflt)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return dflt
end

-- The "switched on" test for a settings element. They read back as
-- numbers on this build (see grow_settings); a boolean is accepted too,
-- so the test holds whichever DFHack hands back.
local function is_on(v)
    return v == true or (type(v) == 'number' and v ~= 0)
end

-- ==========================================
-- CLAIMS
-- ==========================================
-- owner -> { category, select }. On _G so a reload of this file keeps
-- them. Dropped at map unload; the next world's modules claim again.
_G.refinish_organic_claims = _G.refinish_organic_claims or {}
local CLAIMS = _G.refinish_organic_claims

local settle_tries = 0
local function arm_settle()
    settle_tries = 0
    local ok = pcall(function()
        repeatUtil.scheduleEvery(SETTLE_KEY, SETTLE_FRAMES, 'frames', function()
            pcall(settle)
        end)
    end)
    return ok
end

function claim(owner, category, select, opts)
    if type(owner) ~= 'string' or owner == '' then return false, 'no owner' end
    if not CATEGORIES[category] then
        return false, 'unknown category ' .. tostring(category)
    end
    if type(select) ~= 'function' then return false, 'select must be a function' end
    CLAIMS[owner] = { category = category, select = select,
                      may_be_empty = type(opts) == 'table' and opts.may_be_empty == true }
    said['claim:' .. owner] = nil
    arm_settle()
    return true
end

function unclaim(owner)
    CLAIMS[owner] = nil
end

-- Materials a module's JSON marked with organic_category, from the
-- registry. Inorganics only: the field sits on a materials JSON entry.
local function json_claims(by_cat)
    for prefix, entry in pairs(_G.refinish_module_registry or {}) do
        for _, m in ipairs(entry.materials or {}) do
            local cat = type(m) == 'table' and m.organic_category
            if type(cat) == 'string' then
                if not CATEGORIES[cat] then
                    fault_once('jsoncat:' .. prefix .. tostring(m.key), 'ERROR',
                        ('%s%s asks for organic category %s, which RM does not'
                        .. ' address; left out.'):format(prefix, tostring(m.key), cat),
                        'CLAIM')
                else
                    local id = prefix .. tostring(m.key)
                    local info = try(function() return dfhack.matinfo.find('INORGANIC:' .. id) end)
                    if info and info.material then
                        local list = by_cat[cat] or {}
                        by_cat[cat] = list
                        list[#list + 1] = { mt = info.type, mi = info.index,
                                            mat = info.material, label = id }
                    end
                end
            end
        end
    end
end

-- Every claimed material, grouped by category. Returns the groups and,
-- per owner, how many materials its selector found.
local function collect()
    local by_cat, found = {}, {}
    for owner, c in pairs(CLAIMS) do
        local ok, list = pcall(c.select)
        if not ok or type(list) ~= 'table' then
            -- ERROR: this owner's materials are not registered.
            fault_once('claim:' .. owner, 'ERROR', ('%s\'s selector failed: %s;'
                .. ' its materials are not registered, every other claim is.'):format(
                owner, tostring(list)), 'CLAIM')
            found[owner] = 0
        else
            local group = by_cat[c.category] or {}
            by_cat[c.category] = group
            for _, e in ipairs(list) do
                if type(e) == 'table' and e.mt ~= nil and e.mi ~= nil and e.mat then
                    group[#group + 1] = e
                end
            end
            found[owner] = #list
        end
    end
    pcall(json_claims, by_cat)
    return by_cat, found
end

-- ==========================================
-- ONE CATEGORY
-- ==========================================
local function vectors(cat)
    local mt = try(function() return df.global.world.raws.mat_table end)
    if not mt then return nil end
    local types = try(function() return mt.organic_types[cat] end)
    local idxs  = try(function() return mt.organic_indexes[cat] end)
    if not types or not idxs then return nil end
    return types, idxs
end

local function length(types, idxs)
    return math.min(try(function() return #types end, 0), try(function() return #idxs end, 0))
end

local function position_of(types, idxs, mt, mi)
    local n = length(types, idxs)
    for k = 0, n - 1 do
        if try(function() return types[k] end) == mt
           and try(function() return idxs[k] end) == mi then
            return k
        end
    end
    return nil
end

-- The reverse index: material to position (see BOTH DIRECTIONS ARE
-- REQUIRED). Written and read back, so a build without the field, or one
-- that ignores the write, says so.
local function set_reverse(mat, cat, pos)
    if not pcall(function() mat.food_mat_index[cat] = pos end) then
        return false, 'no food_mat_index on this build'
    end
    local back = try(function() return mat.food_mat_index[cat] end)
    if back ~= pos then
        return false, string.format('wrote %d, reads back %s', pos, tostring(back))
    end
    return true
end

-- The settings vector for this category on one stockpile, or nil.
local function settings_vector(b, path)
    return try(function()
        local v = b.settings
        for _, key in ipairs(path) do v = v[key] end
        return v
    end)
end

-- ---- GROWING A SETTINGS VECTOR: NUMBERS, NOT BOOLEANS ----
-- df-structures declares settings.food.* as vectors of bool, but at run
-- time DFHack exposes them as vector<char>. Its own error says so:
-- "Cannot write field vector<char>.101: integer expected" (session log
-- 2026-09-23 15:10:04). So an element is a NUMBER, 0 or 1, and must be
-- written as one; a Lua boolean is refused, which is what failed both
-- early grows in dye-stock. insert('#', n) works on a char vector and is
-- the form hide-stock used successfully from the start. Each grow is
-- read back.
--
-- To a target, never by a delta and never shrunk (see WHAT THIS WRITES).
-- A zero length vector is a pile that does not carry food settings at
-- all; it is left alone, because growing it would hand it a food
-- category it never had.
local function grow_settings(cat_name, spec, target)
    local bld = try(function() return df.global.world.buildings.all end)
    local nb = bld and try(function() return #bld end, 0) or 0
    local grown = 0
    for i = 0, nb - 1 do
        local b = try(function() return bld[i] end)
        if b and df.building_stockpilest:is_instance(b) then
            local vec = settings_vector(b, spec.path)
            local len = vec and try(function() return #vec end)
            if vec and len and len > 0 and len < target then
                -- The fill: see CATEGORIES.
                local any_on, all_on = false, true
                for k = 0, len - 1 do
                    if is_on(try(function() return vec[k] end)) then any_on = true
                    else all_on = false end
                end
                local fill = (spec.fill == 'all') and all_on or any_on
                local ok = pcall(function()
                    for _ = len, target - 1 do vec:insert('#', fill and 1 or 0) end
                end)
                -- Read back: the length reached, and every new slot holds
                -- what was written.
                if ok then
                    ok = try(function() return #vec end, -1) == target
                    for k = len, target - 1 do
                        if ok and is_on(try(function() return vec[k] end)) ~= fill then
                            ok = false
                        end
                    end
                end
                local id = tostring(try(function() return b.id end))
                if ok then
                    grown = grown + 1
                    log('DETAIL', ('stockpile %s: %s %d -> %d, new slots %s.'):format(
                        id, table.concat(spec.path, '.'), len, target,
                        fill and 'on' or 'off'), 'STOCKPILE')
                else
                    -- ERROR, once per pile: that pile cannot take the new
                    -- slots, so those materials never reach it.
                    fault_once('grow:' .. id .. ':' .. cat_name, 'ERROR', ('stockpile %s:'
                        .. ' could not grow %s from %d to %d.'):format(id,
                        table.concat(spec.path, '.'), len, target), 'STOCKPILE')
                end
            end
        end
    end
    return grown
end

-- ---- WHAT WAS LAST SAID ----
-- The sync runs daily forever, so an unconditional line is a line
-- repeated for the life of the fort. This holds the last reported length
-- per category so the log carries state CHANGES rather than a heartbeat.
-- Reset in start(), because a recycle should report once.
local said_len = {}
local function sync_category(cat_name, list)
    local spec = CATEGORIES[cat_name]
    local cat = try(function() return df.organic_mat_category[cat_name] end)
    if cat == nil then
        fault_once('cat:' .. cat_name, 'ERROR', ('df.organic_mat_category.%s'
            .. ' did not resolve; nothing registers there.'):format(cat_name), 'SYNC')
        return 0
    end
    local types, idxs = vectors(cat)
    if not types then
        fault_once('vec:' .. cat_name, 'ERROR', ('organic_types / organic_indexes'
            .. ' unreadable for %s.'):format(cat_name), 'SYNC')
        return 0
    end
    local added = 0
    for _, e in ipairs(list) do
        if not position_of(types, idxs, e.mt, e.mi) then
            local ok, err = pcall(function()
                types:insert('#', e.mt)
                idxs:insert('#', e.mi)
            end)
            if ok then
                added = added + 1
            else
                fault_once('append:' .. tostring(e.label), 'ERROR', ('could not append'
                    .. ' %s to %s: %s'):format(tostring(e.label), cat_name,
                    tostring(err)), 'SYNC')
            end
        end
    end
    -- ---- REVERSE INDEX, EVERY MATERIAL, EVERY SYNC ----
    -- Not only the newly appended ones: the enumeration is rebuilt from
    -- raws each load while positions can land differently, and a stale
    -- reverse index pointing at another material is worse than an absent
    -- one. The write happens every sync; only the log line is
    -- conditional.
    local fixed, failed = 0, nil
    for _, e in ipairs(list) do
        local pos = position_of(types, idxs, e.mt, e.mi)
        if pos then
            local ok, why = set_reverse(e.mat, cat, pos)
            if ok then fixed = fixed + 1 else failed = why end
        end
    end
    if failed then
        fault_once('reverse:' .. cat_name, 'ERROR', ('%s: reverse index NOT set: %s')
            :format(cat_name, tostring(failed)), 'SYNC')
    end
    local target = length(types, idxs)
    grow_settings(cat_name, spec, target)
    if added > 0 or target ~= said_len[cat_name] then
        log('DETAIL', ('%s: %d claimed material(s), %d appended now, reverse index'
            .. ' on %d, length %d.'):format(cat_name, #list, added, fixed, target), 'SYNC')
        said_len[cat_name] = target
    end
    return #list
end

-- ==========================================
-- SYNC AND SETTLE
-- ==========================================
function sync()
    if not dfhack.isMapLoaded() then return 0, {} end
    local by_cat, found = collect()
    local total = 0
    for cat_name, list in pairs(by_cat) do
        local ok, n = pcall(sync_category, cat_name, list)
        if ok then
            total = total + (n or 0)
        else
            fault_once('sync:' .. cat_name, 'ERROR', ('%s did not sync: %s'):format(
                cat_name, tostring(n)), 'SYNC')
        end
    end
    return total, found
end

-- Until every claim has found something, or the tries run out.
function settle()
    settle_tries = settle_tries + 1
    local _, found = sync()
    local waiting = {}
    for owner in pairs(CLAIMS) do
        if (found[owner] or 0) == 0 and not CLAIMS[owner].may_be_empty then
            waiting[#waiting + 1] = owner
        end
    end
    if #waiting == 0 or settle_tries >= SETTLE_TRIES then
        pcall(function() repeatUtil.cancel(SETTLE_KEY) end)
        if #waiting > 0 then
            table.sort(waiting)
            -- WARNING: the daily sync keeps looking, so nothing is lost.
            log('WARNING', ('%s found nothing after %d tries; the daily sync keeps'
                .. ' looking.'):format(table.concat(waiting, ', '), settle_tries), 'SETTLE')
        end
    end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- Started by refinish_steel once the pipeline is up, stopped at map
-- unload, which drops every claim. Claims made during the pipeline
-- (modules claim in their own start) are already waiting.
-- start() carries no running guard, on purpose. reqscript re-executes a
-- file's body and makes a new one; a world load does not. hide-stock
-- learned that the two obvious guards both fail, in opposite directions:
-- a file local
-- running flag resets on a reloaded body and knows nothing about the
-- world, and a _G flag gets the world right and then refuses to rebind,
-- so repeat-util keeps calling the PREVIOUS body's closure while manual
-- commands run the new code. Rescheduling under the same key every time
-- replaces the old closure, which is the rebinding both guards were
-- trying to protect.
function start()
    said, said_len = {}, {}
    repeatUtil.scheduleEvery(POLL_KEY, POLL_DAYS, 'days', function() pcall(sync) end)
    arm_settle()
    log('DETAIL', 'started.', 'START')
end

function stop()
    pcall(function() repeatUtil.cancel(POLL_KEY) end)
    pcall(function() repeatUtil.cancel(SETTLE_KEY) end)
    for owner in pairs(CLAIMS) do CLAIMS[owner] = nil end
    log('DETAIL', 'stopped. Nothing removed: DF rebuilds these lists from the raws.', 'STOP')
end

-- ---- THE HANDLE ----
-- Published at load: modules claim during the pipeline, before start().
_G.refinish_organic_api = { claim = claim, unclaim = unclaim }

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
-- status reads the claims and each category's length. dye-stock's status
-- went further, and its reasoning is worth keeping for whoever rebuilds
-- it: it listed every dye ITEM on the map, ours and vanilla, with the
-- container it sat in, the building on its tile and the flags that decide
-- whether a hauler may take it. A vanilla dye stuck the same way as ours
-- points at the pile; a vanilla dye hauled while ours sits points at how
-- DF files ours.
if args[1] == 'status' then
    local by_cat, found = collect()
    for owner, c in pairs(CLAIMS) do
        print(('claim %-24s %-12s %d material(s)'):format(owner, c.category, found[owner] or 0))
    end
    for cat_name, list in pairs(by_cat) do
        local cat = try(function() return df.organic_mat_category[cat_name] end)
        local types, idxs = cat and vectors(cat)
        print(('%-12s %d claimed, enumeration length %s'):format(cat_name, #list,
            types and tostring(length(types, idxs)) or '?'))
    end
else
    print('refinish-stockpile-organic status')
end