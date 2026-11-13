--@ module = true
-- refinish-reaction-keys.lua
-- ==========================================
-- RM AVAILABILITY KEYS
-- ==========================================
-- The standard form for "this reaction reads red when X is not here".
-- A KEY is a hidden item a reaction asks for as a reagent. While one
-- stands where the reaction can see it the reaction reads available,
-- and when it is withdrawn the reaction reads red. The module decides
-- WHEN a key is owed (rot reachable, remains reachable, a bank holding a
-- package). This file owns what the rot, cremate and drain watchers
-- each carried in their own copy: the ledger of minted keys, finding
-- them again without walking the world, strays, keys a job was holding
-- across a data cycle, and the cached list of buildings that host keys.
--
-- WHY IT EXISTS. MEASURED 2026-09-24, before the ledger: the rot key
-- poll cost 9.85 ms a call, cremate 5.92 ms, drain 12.3 ms, all of it
-- walking the world to find keys the watchers had minted themselves.
-- After: 1.27, 0.25 and 0.27. The same code then sat in three files,
-- which is what this file ends.
--
-- ---- THE LEDGER ----
-- Every key in play this session was minted by the module that owns
-- it, so the module records the id at mint and finds the key again by
-- df.item.find, wherever a dwarf has carried it. A SLOT is whatever the
-- module keys its keys by: a building id (rot, drain) or a building and
-- a kind (cremate). One ledger per module, reset in its start().
--
--   local L = keys.ledger()
--   L.track(slot, id)     a key minted for slot
--   L.forget(id)          drop an id, whatever slot it is in
--   L.live(id)            the item, or nil and forgotten when it is gone
--   L.at(slot)            the slot's live keys, a key a job holds first
--   L.scrap(it)           remove the item; forgotten only when the
--                         remove took, so a key that would not go is
--                         still counted and tried again next poll
--   L.strays(present, f)  f(item) for every live key whose slot is not
--                         in present (slot -> true); empty slots dropped
--   L.pend(id)            a key from the last cycle a job was holding
--   L.settle(f)           f(item) for each pending key its job let go
--   L.reset()             everything dropped, in place
--
-- ---- THE SITES ----
-- The buildings a key can stand in, found without walking every
-- building on every poll:
--   local S = keys.sites(kind_fn)   kind_fn(b) -> truthy for a host
--   S.finished()                    the hosts standing and finished
--   S.reset()
-- A building's kind never changes, so the walk of every building that
-- finds the hosts is redone only when the building count moves or
-- RESCAN_POLLS calls have passed, which covers one built and one torn
-- down between two calls. Every other call finds each host by id.
--
-- ---- THE HELPERS ----
--   keys.busy(it)          a job holds it
--   keys.at_pos(it, p)     on tile p, and not in anyone's hands
--   keys.scrap(it)         remove it; true when the remove took
--   keys.key_tile(b)       the tile b's keys stand on: b's centre, or
--                          the first tile of the first pile b takes
--                          from (WHERE A KEY STANDS, below)
--   keys.linked_piles(b)   the piles b takes from, a list, empty for
--                          none (WHAT A LINKED BUILDING TAKES, below)
--   keys.may_take(piles, it)  whether a building with those linked
--                          piles may take item it
--
-- ---- WHAT STAYS IN THE MODULE ----
-- When a key is owed, how it is minted and dressed, where it goes, and
-- what a session start does with keys from the last cycle: a census for
-- a key whose material is declared in the JSON (it is still good), a
-- purge for one minted from a poll (its index cannot be trusted).
--
-- Everything here is hoisted: no closure is built per key or per
-- building, and every read that could throw runs under one pcall.
--
-- ---- WHAT THE KEY WATCHERS LEARNED (carried from rot, cremate and
-- drain, so any module keying a reaction starts from them) ----
--   * A KEY IS A TOOL. The rot key was first minted as a BOULDER, and a
--     boulder is what put the key in the building materials list. The
--     rot watcher still finds old boulder keys by material so it can
--     scrap them and mint a tool in their place.
--   * ONE KEY IS ONE MENU LIGHT. Never two at one site: the first wins
--     and the rest go, whatever they are.
--   * A KEY ANYWHERE ELSE SHOULD NOT EXIST. One left by a demolished
--     building, or one a dwarf carried off, would light a menu at a
--     building that cannot use it.
--   * MATCH BY SUBTYPE ALONE for purges and stray sweeps, so a key
--     whose material index went stale across a data cycle is still
--     found; match subtype AND material only to say which kind it is.
--   * COLLECT FIRST, REMOVE AFTER. Removing inside a walk of a DF
--     vector mutates the vector under the iterator and silently skips
--     the next entry, which a harness caught in the rot watcher: two
--     strays went in, one came out. DF defers the actual delete, so it
--     may never have bitten in play, but a sweep that depends on that
--     is a sweep that stops working the day it changes.
--   * dfhack.items.remove IS DEFERRED: the item is flagged and collected
--     later, so a walk keeps finding it for several polls. The first
--     live cremate run printed its "menu closes" line 96 times. The
--     removal is idempotent and harmless to repeat; the LINE is not,
--     which is why the ledger forgets a key only when its remove took
--     and why such lines are said once.
--   * NO pcall INSIDE AN ITEM LOOP. A pcall allocates a closure on
--     every call; once per item per walk it was the bulk of the cremate
--     watcher's 358 ms a second. Wrap the whole walk in one pcall
--     instead: nothing is less protected, the throw is caught one level
--     up, once per walk instead of once per item.
--   * A LINKED BUILDING SEES ONLY ITS PILES. A key on the building's
--     own tile lights nothing at a building that takes from linked
--     piles; one in a linked pile does (WHERE A KEY STANDS, below).
-- ==========================================

local RESCAN_POLLS = 10

-- ==========================================
-- THE HELPERS
-- ==========================================
local function read_in_job(it) return it.flags.in_job end
local function read_gc(it) return it.flags.garbage_collect end
local function read_on_tile(it, p)
    return not it.flags.in_inventory and it.pos.x == p.x
       and it.pos.y == p.y and it.pos.z == p.z
end
local function read_id(it) return it.id end

function busy(it)
    local ok, v = pcall(read_in_job, it)
    return ok and v or false
end

function at_pos(it, p)
    local ok, v = pcall(read_on_tile, it, p)
    return ok and v or false
end

function scrap(it)
    local ok, removed = pcall(dfhack.items.remove, it)
    return ok and removed ~= false
end

-- A key a job holds sorts first, so trimming extras never takes the one
-- a job is using.
local function in_job_first(a, b)
    local ja, jb = busy(a), busy(b)
    if ja ~= jb then return ja end
    local ok_a, ia = pcall(read_id, a)
    local ok_b, ib = pcall(read_id, b)
    return (ok_a and ia or 0) < (ok_b and ib or 0)
end

local function clear(t)
    for k in pairs(t) do t[k] = nil end
end

-- ==========================================
-- THE LEDGER
-- ==========================================
function ledger()
    local L = {}
    local by_slot = {}   -- slot -> { [item id] = true }
    local owner   = {}   -- item id -> slot, the same ledger read the other way
    local pending = {}   -- item id -> true

    function L.track(slot, id)
        local set = by_slot[slot]
        if not set then
            set = {}
            by_slot[slot] = set
        end
        set[id] = true
        owner[id] = slot
    end

    function L.forget(id)
        local slot = owner[id]
        if slot ~= nil and by_slot[slot] then by_slot[slot][id] = nil end
        owner[id] = nil
        pending[id] = nil
    end

    function L.live(id)
        local it = df.item.find(id)
        if it then
            local ok, gone = pcall(read_gc, it)
            if ok and not gone then return it end
        end
        L.forget(id)
        return nil
    end

    function L.at(slot)
        local list = {}
        for id in pairs(by_slot[slot] or {}) do
            local it = L.live(id)
            if it then list[#list + 1] = it end
        end
        if #list > 1 then table.sort(list, in_job_first) end
        return list
    end

    function L.scrap(it)
        local ok, id = pcall(read_id, it)
        if scrap(it) then
            if ok and id then L.forget(id) end
            return true
        end
        return false
    end

    function L.strays(present, f)
        for slot, set in pairs(by_slot) do
            if not present[slot] then
                for id in pairs(set) do
                    local it = L.live(id)
                    if it then f(it) end
                end
                if next(set) == nil then by_slot[slot] = nil end
            end
        end
    end

    function L.pend(id) pending[id] = true end

    function L.settle(f)
        for id in pairs(pending) do
            local it = df.item.find(id)
            if not it then
                pending[id] = nil
            elseif not busy(it) then
                pending[id] = nil
                f(it)
            end
        end
    end

    function L.reset()
        clear(by_slot)
        clear(owner)
        clear(pending)
    end

    return L
end

-- ==========================================
-- THE SITES
-- ==========================================
local function read_finished(b)
    return b:getBuildStage() == b:getMaxBuildStage()
end

function sites(kind_fn)
    local S = {}
    local ids, count, polls = nil, -1, 0

    function S.finished()
        local all = df.global.world.buildings.all
        polls = polls + 1
        if not ids or #all ~= count or polls >= RESCAN_POLLS then
            local fresh = {}
            for _, b in ipairs(all) do
                local ok, yes = pcall(kind_fn, b)
                if ok and yes then fresh[#fresh + 1] = b.id end
            end
            ids, count, polls = fresh, #all, 0
        end
        local out = {}
        for _, id in ipairs(ids) do
            local b = df.building.find(id)
            if b then
                local ok, done = pcall(read_finished, b)
                if ok and done then out[#out + 1] = b end
            end
        end
        return out
    end

    function S.reset()
        ids, count, polls = nil, -1, 0
    end

    return S
end

-- ==========================================
-- WHERE A KEY STANDS (2026-10-21)
-- ==========================================
-- A LINKED BUILDING SEES ONLY ITS PILES. MEASURED 2026-10-21 on Making
-- Fuel's pyres: a wood furnace that took from a linked stockpile read
-- every keyed row red while its keys lay on its own centre tile, and
-- white again once the link was removed, the pile left standing. Hidden
-- keys put IN its linked pile lit every keyed row (cremation and rot)
-- at two furnaces, from a pile 11 tiles off and from one 19 tiles off,
-- so the reagents' `nearby` did not stop a linked pile, and all 8 keys
-- were still where they were put after the game had run a while
-- (making-fuel-key-pile-probe). It is DF's rule for every workshop: "the
-- linked workshop will now only take from the stockpiles set to give to
-- that workshop" (DF wiki, Stockpile).
--
-- So key_tile(b) is b's centre while b takes from no pile, and when it
-- does, the first tile in reading order of the first pile it takes
-- from, the tile the measurement used. A pile need not fill its
-- bounding box, so containsTile decides (it reads the pile's extents).
-- A building with no stockpile links at all (no profile) gets its
-- centre. The module still decides when a key is owed and which items
-- count; this says only where DF will look. Two buildings linked to one
-- pile put their keys on the same tile, each in its own ledger, and DF
-- counts every key in a linked pile, so each still lights.
local function first_tile(pile)
    for y = pile.y1, pile.y2 do
        for x = pile.x1, pile.x2 do
            if dfhack.buildings.containsTile(pile, x, y) then
                return xyz2pos(x, y, pile.z)
            end
        end
    end
    return nil
end

local function read_pile_tile(b)
    local piles = b.profile.links.take_from_pile
    if #piles == 0 then return nil end
    return first_tile(piles[0])
end

function key_tile(b)
    local ok, p = pcall(read_pile_tile, b)
    if ok and p then return p end
    return xyz2pos(b.centerx, b.centery, b.z)
end

-- ==========================================
-- WHAT A LINKED BUILDING TAKES (2026-10-21)
-- ==========================================
-- The same rule from the other side: a building that takes from linked
-- piles takes only what lies in them, so a module choosing items for
-- such a building's jobs keeps to its piles, and a link means what it
-- means for DF's own jobs (decided 2026-10-21: the vanilla expectation).
--   linked_piles(b)     b's piles, a Lua list, empty when b takes from
--                       none or has no stockpile links at all
--   may_take(piles, it) true for any item when piles is empty, else only
--                       for an item lying loose on a tile of one of them;
--                       one in a container or in a dwarf's hands is not
-- A caller reads linked_piles once per building per poll and hands the
-- list to may_take for each item.
local function read_piles(b)
    local out = {}
    for _, pile in ipairs(b.profile.links.take_from_pile) do out[#out + 1] = pile end
    return out
end

function linked_piles(b)
    local ok, piles = pcall(read_piles, b)
    return ok and piles or {}
end

local function read_in_piles(piles, it)
    if it.flags.in_inventory then return false end
    local p = it.pos
    for _, pile in ipairs(piles) do
        if pile.z == p.z and dfhack.buildings.containsTile(pile, p.x, p.y) then
            return true
        end
    end
    return false
end

function may_take(piles, it)
    if #piles == 0 then return true end
    local ok, yes = pcall(read_in_piles, piles, it)
    return ok and yes or false
end
