--@ module = true
-- refinish-persist-banks.lua
-- ==========================================
-- RM BANKS
-- ==========================================
-- A bank is a table of running balances a module keeps between jobs:
-- fractional value carried forward until it makes a whole product,
-- liquid held in a furnace until it is drained, anything a module
-- measures in and pays out later. This file gives a module a bank that
-- SURVIVES THE SAVE.
--
-- WHY. Making Fuel's bank lived on a plain global, which survives RM's
-- data cycles and nothing more: making_fuel.lua dropped it on every map
-- unload, and a relaunch starts Lua empty. The ghost's own note called
-- that loss at most one payout unit per reaction, not worth persistence,
-- which held while the bank carried fractional charcoal. Since banks
-- are kept per building, a retort or still holds its liquids here as
-- 'BANK_<currency>@<building id>', and a quit and reload threw away
-- every package not yet drained. Nothing saved it: no saveSiteData
-- anywhere the bank is written or read (checked 2026-09-24).
--
-- HOW. open(name) returns a table that reads and writes like a plain
-- one and is written through to the save's site data on every change,
-- the pattern the fuel tank's job records already use: whatever
-- protocol saves the world, the save carries the current balances.
-- The balances sit in a plain table behind it; the table handed out is
-- a proxy in front (__index, __newindex, __pairs), so every existing
-- `bank[k]`, `bank[k] = v` and `pairs(bank)` works unchanged. What does
-- NOT work on a proxy is next(bank) and #bank, and nothing in the
-- modules uses either on a bank (checked).
--
-- ONE BANK PER NAME PER SITE. Restored from the save the first time it
-- is opened on a map, handed back as the same table on every later
-- open, and forgotten at map unload, so the next fort opens its own
-- from its own save and a balance can never leak between forts.
--
-- VALUES must be what a save can hold: numbers, strings and booleans
-- under string keys. Every bank in the modules already is.
--
-- A write that changes nothing saves nothing. Writes happen when jobs
-- settle, which is event scale, so a save per change is cheap.
--
--   local banks = reqscript('refinish-persist-banks')
--   local B = banks.open('MAKING_FUEL_BANK')
--   B['BANK_TAR@12'] = (B['BANK_TAR@12'] or 0) + 0.5   -- saved at once
--
-- CLEARING ONE BY HAND, through the proxy so the save follows:
--   :lua for k in pairs(refinish_fuel_bank) do refinish_fuel_bank[k] = nil end
-- ==========================================

local KEY_PREFIX = 'refinish_bank:'

-- name -> the proxy handed out this map. Forgotten at map unload.
_G.refinish_banks = _G.refinish_banks or {}

local function persist(name, raw)
    pcall(dfhack.persistent.saveSiteData, KEY_PREFIX .. name, raw)
end

function open(name)
    local b = _G.refinish_banks[name]
    if b then return b end

    local raw = {}
    local ok, stored = pcall(dfhack.persistent.getSiteData, KEY_PREFIX .. name, {})
    if ok and type(stored) == 'table' then
        for k, v in pairs(stored) do raw[k] = v end
    end

    local proxy = setmetatable({}, {
        __index    = raw,
        __newindex = function(_, k, v)
            if raw[k] == v then return end
            raw[k] = v
            persist(name, raw)
        end,
        __pairs    = function() return next, raw, nil end,
    })
    _G.refinish_banks[name] = proxy
    return proxy
end

-- The next fort opens its own. The balances themselves stay in the save
-- that was just written.
dfhack.onStateChange.refinish_banks = function(sc)
    if sc == SC_MAP_UNLOADED then _G.refinish_banks = {} end
end
