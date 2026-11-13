-- refinish-resolve.lua
-- ==========================================
-- SCRIPT LOGIC: REFINISH RESOLVE
-- ==========================================
-- One place to turn a material TOKEN or an itemdef CODE into the
-- number the engine wants, under one invalidation rule.
--
-- ---- WHY THIS EXISTS ----
-- Five scripts each carried their own version of this: a
-- matinfo.find on every use, or a walk of world.raws.itemdefs.tools
-- that tostring'd every definition it passed. Two of them ran it
-- once per frame, which was part of the 885 ms/sec the profiler
-- measured before the rot and cremate hotfix.
--
-- ---- WHY A NUMBER CANNOT BE CACHED FOREVER ----
-- Injected materials and itemdefs are appended at startup and
-- removed again on the save protocol, so a number cached before a
-- clear points at whatever has since moved into that slot.
--
-- A STALE HIT LOOKS EXACTLY LIKE A GOOD ONE. The miss branch only
-- fires when a token is ABSENT, never when a cached number is wrong.
-- Same failure shape as the ghost reaction use after free and the
-- itemdef cache staleness that refinish-module-react already
-- documents.
--
-- ---- SO INVALIDATION IS A HANDSHAKE, NOT A GUESS ----
-- Anything that adds or removes assets raises a global, and every
-- lookup checks it first for the price of one table read.
--
-- THIS IS DELIBERATELY NOT AN EPOCH COMPARED AGAINST
-- _G.refinish_ram_loaded. That flag is a BOOLEAN. A script whose
-- poll is gated on _G.refinish_active never observes the false
-- window during a wash, so it reads true before the cycle and true
-- after it and concludes nothing changed, keeping a stale index.
-- The first version of the rot and cremate hotfix did exactly that.
-- A dirty flag has no such blind spot, because the party that
-- invalidates is the party that changed something.
--
-- ---- A MISS IS NEVER CACHED ----
-- Injection lands after the module scripts start, so a stored nil
-- would defer forever. Only hits are kept.
--
-- ---- NO DF POINTER IS RETAINED ----
-- material() answers with a plain Lua table of numbers, not the
-- matinfo object, because matinfo carries a pointer to the material
-- struct and holding one across a clear is the use after free this
-- file exists to prevent.
-- ==========================================

--@ module = true

-- token -> { type = <mat_type>, index = <mat_index> }
local mat_cache = {}

-- The reaction index (REACTIONS, below): code -> position, how much of
-- the array is indexed, the code at its last indexed position, and the
-- code lists kept for each prefix asked for.
local rx_pos, rx_len, rx_last, rx_prefix = {}, 0, nil, {}

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
-- Console prints only where they answer a typed command. A print only
-- appears as the direct answer to a command typed into the DFHack
-- console, and nowhere else. The CONSOLE section at the bottom is
-- exactly that, so its prints stay.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'RESOLVE'
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

-- ==========================================
-- INVALIDATION
-- ==========================================
-- Raised by whoever injects or clears; lowered here on the next
-- lookup. Two globals rather than one because the itemdef cache
-- lives in refinish-module-react and already has its own handshake
-- with the tool injector. Materials get the matching one.
local function check_dirty()
    if _G.refinish_material_cache_dirty then
        mat_cache = {}
        _G.refinish_material_cache_dirty = false
    end
end

-- Drops everything this file knows and asks module-react to drop the
-- itemdef side too. Call after any change to injected assets that
-- does not already raise the globals.
function invalidate()
    mat_cache = {}
    rx_pos, rx_len, rx_last, rx_prefix = {}, 0, nil, {}
    _G.refinish_material_cache_dirty = false
    _G.refinish_itemdef_cache_dirty = true
    log('DETAIL', 'Caches dropped.', 'CACHE')
end

-- ==========================================
-- MATERIALS
-- ==========================================
-- token is the FULL token, because callers do not agree on the
-- branch: the key watchers ask INORGANIC:X and the coal watcher asks
-- a plant host. Prefixing here would hide that difference and get
-- one of them wrong.
--
-- Returns { type = n, index = n } or nil.
function material(token)
    check_dirty()

    local hit = mat_cache[token]
    if hit then return hit end

    local mi = nil
    pcall(function() mi = dfhack.matinfo.find(token) end)
    if not mi then return nil end

    -- Copied out of the matinfo immediately. See NO DF POINTER above.
    local rec = { type = mi.type, index = mi.index }
    mat_cache[token] = rec
    return rec
end

-- The common case by a wide margin: callers compare against an
-- item's mat_index and test mat_type separately.
function material_index(token)
    local rec = material(token)
    return rec and rec.index or nil
end

-- ==========================================
-- ITEMDEFS
-- ==========================================
-- Delegated rather than duplicated. refinish-module-react owns the
-- itemdef cache, the tool injector already calls its invalidator on
-- both ends of every injection and every clear, and a second cache
-- of the same thing would be a second thing to keep correct.
--
-- QUIET. The react resolver logs "slot left unrestricted" on a miss,
-- which is true when it is building a reagent and nonsense when a
-- key watcher is simply polling before injection has landed. The
-- quiet flag suppresses that line; the caller says its own piece
-- once through its own state logging.
--
-- Returns the subtype integer, or nil when absent. react answers -1
-- for absent, which is a valid-looking number in the wrong hands.
-- ---- ONE TABLE READ ON THE NORMAL PATH ----
-- This is called once per poll by watchers running at one frame, so
-- what it costs is multiplied by the frame rate. The first version
-- called reqscript here, which is a script name resolution and
-- therefore filesystem work: about 2 ms a call, 407 ms of every wall
-- second once two watchers were doing it.
--
-- module-react publishes its resolver on load, so the steady state
-- is reading one global. reqscript survives only as the cold start
-- path, for the window before module-react has been loaded at all,
-- and it stops being taken the moment it succeeds once.
--
-- No closure is built for the pcall either. pcall(fn, args) passes
-- the arguments straight through; wrapping it in an anonymous
-- function allocates one per call for nothing.
function tool_subtype(code, item_type)
    local fn = _G.refinish_resolve_tool_subtype

    if not fn then
        -- Cold start. Loading module-react is what publishes the
        -- global, so this is asked for once and then never again.
        pcall(reqscript, 'refinish-module-react')
        fn = _G.refinish_resolve_tool_subtype
        if not fn then return nil end
    end

    local ok, sub = pcall(fn, code, item_type, true)
    if not ok or type(sub) ~= 'number' or sub < 0 then return nil end
    return sub
end

-- ==========================================
-- REACTIONS
-- ==========================================
-- ---- WHY ----
-- MEASURED 2026-09-30 (walk probe, 103,543 reactions with every base
-- metal on): one lookup by code, walking the reactions array, cost
-- 38 ms, and fifteen places in the runtime scripts looked reactions up
-- that way. Making Fuel's tank fuel made several in a row when a
-- workshop sheet opened, and the lag probe caught sheets taking 281 to
-- 407 ms to open in the same seconds tank fuel logged its clone cuts.
--
-- ---- AN INDEX BY CODE, CHECKED ON EVERY USE ----
-- One walk records where each code sits. A lookup reads the reaction at
-- that position and answers with it only if its code still matches, so
-- a stale position can never answer as a good one: the check reads the
-- thing itself, not a flag about it. The array changes only by appends
-- (a clone cut in play, a ghost) and erases (the sweeps at shutdown, in
-- refinish-clear-reaction and the module engine), and one cheap test
-- tells them apart before any lookup that misses or fails its check:
--   * the array got shorter, or the code at the last indexed position
--     changed: something was erased and positions shifted. Rebuild.
--   * the array got longer: only the new tail is read.
-- A code that is simply absent costs that test and nothing more. As
-- with materials, a miss is never kept.
--
-- ---- FIRST FOUND WINS ----
-- A walk stopped at the first reaction with the code, so the index keeps
-- the first position a code is seen at. Codes are unique in practice;
-- this only keeps the answers the same if they are not.
--
-- ---- NOTHING IS HELD ACROSS A CALL ----
-- The index holds codes and numbers. The reaction a lookup returns is
-- the caller's to use there and then, as it used the one its own walk
-- found; holding it across ticks is the use after free the header
-- describes. The index costs one walk the first time it is asked each
-- session (about one old lookup's 38 ms, plus building the table), and
-- a Lua table of every code while it lives.
--
-- ---- PUBLISHED AS GLOBALS ----
-- Like the itemdef resolver, both lookups are published on load, so a
-- caller reads one global instead of paying reqscript (about 2 ms) on a
-- poll path, and a reload of this file replaces them rather than
-- leaving callers on an old copy with an index of its own.
-- ==========================================
local function rx_array() return df.global.world.raws.reactions.reactions end
local function read_code(r) return r.code end

-- The code at position i, or nil past either end or on a bad read.
local function code_at(arr, i)
    if i < 0 or i >= #arr then return nil end
    local ok, c = pcall(read_code, arr[i])
    return ok and c or nil
end

local function rx_rebuild()
    local arr = rx_array()
    local t0 = dfhack.getTickCount()
    local pos, n = {}, #arr
    -- One pcall for the walk, none per reaction.
    local ok, err = pcall(function()
        for i = 0, n - 1 do
            local c = arr[i].code
            if pos[c] == nil then pos[c] = i end
        end
    end)
    rx_pos, rx_len, rx_prefix = pos, n, {}
    rx_last = code_at(arr, n - 1)
    if not ok then
        -- WARNING: what was read still answers; a zero length makes the
        -- next miss walk again. The error is the thing to read.
        rx_len = 0
        log('WARNING', 'reaction index walk failed: ' .. tostring(err), 'REACTIONS')
        return
    end
    log('DETAIL', ('reaction index built: %d reaction(s) in %d ms.'):format(n,
        dfhack.getTickCount() - t0), 'REACTIONS')
end

-- Brings the index up to date: a rebuild when something was erased, the
-- new tail when something was appended, and one length read and one
-- code read when neither.
local function rx_sync()
    local arr = rx_array()
    local n = #arr
    if rx_len == 0 or n < rx_len or code_at(arr, rx_len - 1) ~= rx_last then
        rx_rebuild()
        return
    end
    if n == rx_len then return end
    local done = rx_len
    pcall(function()
        for i = rx_len, n - 1 do
            local c = arr[i].code
            if rx_pos[c] == nil then
                rx_pos[c] = i
                for p, list in pairs(rx_prefix) do
                    if c:sub(1, #p) == p then list[#list + 1] = c end
                end
            end
            done = i + 1
        end
    end)
    rx_len = done
    rx_last = code_at(arr, done - 1)
end

-- The index's answer for a code, checked against the live array: the
-- reaction and its position, or nil.
local function checked(arr, code)
    local pos = rx_pos[code]
    if pos and pos < #arr then
        local r = arr[pos]
        local ok, c = pcall(read_code, r)
        if ok and c == code then return r, pos end
    end
    return nil
end

-- The live reaction with this code and its position in the array, or
-- nil. The position is for a caller that remembers where a reaction sat
-- and checks the code there before trusting it (the drain key).
function reaction(code)
    if type(code) ~= 'string' then return nil end
    local arr = rx_array()
    local r, pos = checked(arr, code)
    if r then return r, pos end
    rx_sync()
    r, pos = checked(arr, code)
    if r or rx_pos[code] == nil then return r, pos end
    -- Known, yet not where the index says after a sync: a change the
    -- sync's test cannot see. One rebuild settles it.
    rx_rebuild()
    return checked(arr, code)
end

-- Every live reaction whose code starts with prefix, in array order.
-- The list of codes for a prefix is made the first time it is asked
-- (one pass over the index, no DF reads) and kept up to date by the
-- tail read; a rebuild drops the lists, to be made again when asked.
function reactions_prefixed(prefix)
    if type(prefix) ~= 'string' or prefix == '' then return {} end
    for attempt = 1, 2 do
        rx_sync()
        local list = rx_prefix[prefix]
        if not list then
            list = {}
            for c in pairs(rx_pos) do
                if c:sub(1, #prefix) == prefix then list[#list + 1] = c end
            end
            table.sort(list, function(a, b) return rx_pos[a] < rx_pos[b] end)
            rx_prefix[prefix] = list
        end
        local arr, out, stale = rx_array(), {}, false
        for _, c in ipairs(list) do
            local r = checked(arr, c)
            if r then out[#out + 1] = r else stale = true end
        end
        if not stale or attempt == 2 then return out end
        -- One of them moved or went: rebuild, and answer once more.
        rx_rebuild()
    end
    return {}
end

-- Brings the index up to date now, for a caller that has just grown the
-- array by a lot: refinish-index-reaction calls it after its inject, so
-- RM's own ~100,000 new reactions are read during startup instead of on
-- the first lookup in play. MEASURED 2026-09-30: the index was first
-- built during the module pipeline (3,955 reactions, 15 ms), and the
-- first lookup after RM's inject, tank fuel's on the smelter's sheet,
-- read the rest; that sheet took 281 ms to open.
function reactions_sync()
    local before = rx_len
    rx_sync()
    if rx_len ~= before then
        log('DETAIL', ('reaction index brought up to date: %d reaction(s), %d before.')
            :format(rx_len, before), 'REACTIONS')
    end
end

_G.refinish_find_reaction = reaction
_G.refinish_reactions_prefixed = reactions_prefixed
_G.refinish_reactions_sync = reactions_sync

-- ==========================================
-- CONSOLE
-- ==========================================
local args = {...}
if args[1] == 'test' and args[2] then
    local rec = material(args[2])
    if rec then
        print(('%s -> type %d index %d'):format(args[2], rec.type, rec.index))
    else
        print(('%s -> not found'):format(args[2]))
    end
elseif args[1] == 'tool' and args[2] then
    print(('%s -> subtype %s'):format(args[2], tostring(tool_subtype(args[2]))))
elseif args[1] == 'rx' and args[2] then
    local r = reaction(args[2])
    print(('%s -> %s'):format(args[2], r and ('position ' .. tostring(rx_pos[args[2]])) or 'not found'))
elseif args[1] == 'invalidate' then
    invalidate()
    print('refinish-resolve: caches dropped.')
elseif args[1] then
    print('refinish-resolve: test <TOKEN> | tool <CODE> | rx <REACTION CODE> | invalidate')
end

return _ENV