-- refinish-tool-wash.lua
-- ==========================================
-- TOOL SUBTYPE WASH AND RESTORE
-- ==========================================
-- WHAT THIS IS FOR
--
-- item_toolst.subtype holds a pointer to the itemdef, not an index.
-- Confirmed empirically: .subtype reads as userdata with its own .id
-- and .subtype fields.
--
-- clear_tools() unlinks the itemdef from the array but does not call
-- :delete() on it, so within a session the pointer stays valid and
-- nothing crashes. The exposure is at save and load. DF serialises the
-- itemdef's own subtype number, and on reload that number is resolved
-- against an array built from raws alone. An injected tool sat above
-- the vanilla count, so its number is out of range on the way back in,
-- and DF defaults it to 0, ITEM_TOOL_CAULDRON (the engine records this
-- at its restore call).
--
-- WHETHER YOU NEED THIS: YES, MEASURED 2026-09-29
--
-- This section used to leave that open. Settled with the wash switched
-- off: every tool definition cleared, no item touched, quicksave, full
-- recycle, reload. All 288 owned tool items came back as cauldrons,
-- none dangling, while every material came back on injection order
-- alone (refinish-save-census.lua before and after). DF resolves an
-- item's tool while it loads, before RM injects anything, so ordering
-- cannot bring a tool back. The record is the only thing that can.
--
-- RECORD, NOT REPOINT, 2026-09-29. wash() used to repoint every item
-- onto a jug as well as record it, so a failed restore left a working
-- container. That touched every tool item before every save, and at
-- the map unload, where site data can no longer be written, it turned
-- every tool into a jug with no record to bring it back (region2, that
-- day: burners, atomisers, branches). restore() finds each item by id
-- and never asks what it currently is, so the repoint bought nothing a
-- record does not: an item the record misses comes back a cauldron
-- either way. wash() now only reads and records. MEASURED WORKING the
-- same day: record only, 288 of 288 tools restored after both a save &
-- continue and a save & quit (refinish-save-hook.lua).
--
-- Cheap when unnecessary: wash() reads the itemdef array first and
-- returns before walking any item if no owned tool is present.
--
-- CALL ORDER
--
--   save     wash(prefixes) BEFORE any clear_tools, once for every
--                           prefix (clear_module_assets in the engine)
--   load     restore(run)   AFTER inject_tools has run, once per module
--   load     settle(run)    once, after the last module's tools are in
--   play     keep_step()    the kept record's build after a load, a slice
--                           a frame, from the save hook's monitor
--   play     keep_write()   the kept record written whenever it changes,
--                           from the same monitor (THE RECORD, KEPT
--                           WRITTEN)
--   play     menu_wash()    the options screen's own top up, from the
--                           save hook's refresh
--
-- run is the engine's table for one pipeline run, the same for every
-- call of that run (ONE READ A LOAD, at restore). Both still work
-- without it, each call on its own.
--
-- ONE RECORD, MANY OWNERS, 2026-09-25. Every prefix that owns tools
-- shares the one payload below. It used to be written as though one
-- prefix owned it: wash() replaced it with its own records, so of all
-- the prefixes with items only the last one washed kept its record,
-- and restore() consumed all of it on its first call, so every item
-- owned by a module injected after the first one lost its tool. Both
-- held while Making Fuel was the only module with tools. They broke
-- once RM carried tools of its own and its catalog forms were injected
-- ahead of the modules asking for them: see ONE CALL USED TO TAKE IT
-- ALL at restore() for what that cost, measured. The payload is now
-- merged by wash(), drained by restore() as each owner's tools arrive,
-- and consumed only by settle(). Since 2026-09-29 the engine calls
-- wash() once for every prefix, so one walk records every owner.
--
-- The ordering is the same rule materials follow and for the same
-- reason: wash while the injected itemdefs are still addressable,
-- restore once they are addressable again.
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside REFINISH_STEEL_PAYLOAD and
-- REFINISH_STEEL_TOOL_LEDGER.
local PAYLOAD_KEY = "REFINISH_STEEL_TOOL_WASH"

-- ---- THE RECORD'S STORAGE: ONE LAYER ----
-- Stored as plain JSON text through saveSiteDataString and read back
-- through getSiteDataString. It used to go through saveSiteData, which
-- JSON-encodes its value, so the record, already JSON, was stored as a
-- JSON string of JSON, and getSiteData read that outer string back
-- through DFHack's character-by-character JSON reader: the double
-- encoding that made the material ledger take a minute to read at 8,956
-- materials (refinish-ledger.lua, 2026-09-30). At 288 tools it cost
-- little, but the read grows with the square of the record. A record
-- written the old way still reads: unwrap_old strips its outer string
-- layer in one pass, as the ledger's does.
local UNESCAPE = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
                   f = '\f', n = '\n', r = '\r', t = '\t' }
local function unwrap_old(raw)
    if raw:sub(1, 1) ~= '"' then return nil end
    local body = raw:match('^"(.*)"%s*$')
    if not body then return nil end
    return (body:gsub('\\(.)', UNESCAPE))
end

-- The record as JSON text, or nil when there is none. An old empty
-- record, stored as the JSON string "", reads as none.
local function read_record()
    local raw = dfhack.persistent.getSiteDataString(PAYLOAD_KEY)
    if not raw or raw == "" then return nil end
    raw = unwrap_old(raw) or raw
    if raw == "" then return nil end
    return raw
end

-- ---- WHAT SITE DATA HOLDS ----
-- What a save written now would carry of the record: how many items its
-- last write held and the clock time of that write, or nil when site
-- data holds none (a load consumed it in settle, and nothing has been
-- written since). Every write and clear of the record goes through
-- store_text and clear_record, so this never falls out of step with
-- site data. known_n is how many owned tool items this session last
-- counted, so "nothing to carry" can be told from "nothing carried".
-- Both are read by stored_record() (WHAT A SAVE CARRIES, at the end).
local stored = nil
local known_n = 0

local function store_text(text, n)
    dfhack.persistent.saveSiteDataString(PAYLOAD_KEY, text)
    stored = { n = n, at = os.date('%H:%M:%S') }
end

local function write_record(tbl)
    store_text(json.encode(tbl, { pretty = false }), #tbl.items)
end

local function clear_record()
    if pcall(dfhack.persistent.deleteSiteData, PAYLOAD_KEY) then stored = nil end
end

-- The record kept in memory for the menu's wash (THE RECORD, KEPT
-- BETWEEN OPENINGS OF THE MENU, below), or nil. Declared up here because
-- wash() and restore(), which come before that section, drop it.
local kept = nil

-- Drops the kept record, and with it the list scripts add changed items
-- to: what follows is a data cycle, or the record being rewritten.
local function drop_kept()
    kept = nil
    _G.refinish_tool_wash_touched = nil
end

-- What an item the record misses is left as, for settle()'s lines.
-- Nothing is ever repointed onto it (RECORD, NOT REPOINT): after a load
-- it is DF's own default, the cauldron, and a jug if an older wash,
-- from before 2026-09-29, repointed it.
local LEFT_AS = "as it came back (a cauldron, or a jug from an older wash)"


-- ==========================================
-- HELPERS
-- ==========================================

local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM's own, and peripheral rather than pipeline. One subsystem: every
-- call site here was already TOOL_WASH.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TOOL_WASH'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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
-- SUBJECT is the correlation slot: WASH or RESTORE, the half of the
-- cycle a line comes from.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- This replaces a log() that took the subsystem as an argument and
-- let refinish-log guess TYPE from the words (read_type) unless a call
-- site said otherwise.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
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
-- OWNED ITEMDEF SET
-- ==========================================
-- Builds pointer identity to code for every owned tool.
--
-- Keyed on the itemdef's id string rather than on the wrapper object,
-- because DFHack returns a fresh Lua wrapper on every access and object
-- comparison fails. Same rule the entity dedup follows.
--
-- Returns the lookup and a count. A count of zero is the early-out
-- signal: nothing owned means nothing to wash.
-- ==========================================

local function owned_itemdefs(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    local owned = {}
    local n = 0

    for _, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and type(id) == "string" and has_prefix(id, prefix) then
            owned[id] = true
            n = n + 1
        end
    end

    return owned, n
end


-- ==========================================
-- READ AN ITEM'S TOOL CODE
-- ==========================================
-- Goes through the pointer to the id string, because the string is the
-- only stable identity. The numeric subtype is exactly the thing that
-- is about to stop meaning anything.
-- ==========================================

local function item_tool_code(item)
    local ok, raw = pcall(function() return item.subtype end)
    if not ok or raw == nil or type(raw) == "number" then return nil end

    local ok2, id = pcall(function() return raw.id end)
    if ok2 and type(id) == "string" then return id end
    return nil
end


-- ==========================================
-- WASH: RECORD EVERY OWNED TOOL ITEM
-- ==========================================
-- Records every item carrying one of the owned tools, by item id and
-- tool code, so restore() can put it back after a load. Reads only; no
-- item is touched (RECORD, NOT REPOINT in the header).
--
-- prefixes is a list of owner prefixes, or a single prefix. The engine
-- calls this once for every prefix before it clears any tool.
--
-- ONE WALK, TYPE FIRST. It used to walk every item once per prefix,
-- fifteen walks a save with RM's catalog in, paying two pcalls per
-- item each time. Now one walk, with getType() asked first (a virtual
-- every item class implements), so item_tool_code's pcalls are paid on
-- tools only. world.items.all rather than the TOOL list, because
-- nothing on record says that list holds a fort's offloaded items, and
-- a save carries those too.
--
-- Returns the number of items recorded. If site data cannot be written
-- (at the map unload it cannot) this throws, and nothing has changed.
-- ==========================================
function wash(prefixes)
    if type(prefixes) == 'string' then prefixes = { prefixes } end
    -- The save's own wash (the engine's, before clear_tools): a data
    -- cycle follows, so the menu's kept record goes (THE RECORD, KEPT).
    drop_kept()

    -- ---- EARLY OUT ----
    -- One pass over the itemdef array, a few hundred entries, against a
    -- pass over every item in the fortress, tens of thousands.
    local owned, owned_count = {}, 0
    for _, prefix in ipairs(prefixes or {}) do
        local o, n = owned_itemdefs(prefix)
        for id in pairs(o) do owned[id] = true end
        owned_count = owned_count + n
    end
    if owned_count == 0 then
        return 0
    end

    -- ---- THE WALK ----
    -- item.id is stable across the save cycle, which is what makes
    -- restore possible.
    local TOOL = df.item_type.TOOL
    local records = {}
    for _, item in ipairs(df.global.world.items.all) do
        if item:getType() == TOOL then
            local code = item_tool_code(item)
            if code and owned[code] then
                local ok_id, item_id = pcall(function() return item.id end)
                if ok_id then
                    records[#records + 1] = { id = item_id, code = code }
                end
            end
        end
    end
    known_n = #records
    if #records == 0 then
        return 0
    end

    -- ---- ONE PAYLOAD FOR EVERY PREFIX ----
    -- Every owner shares this one key. Until 2026-09-25 each prefix's
    -- wash replaced the record with its own, so only the last prefix
    -- washed could ever get its items back (read from the code that
    -- day; the log that found ONE CALL USED TO TAKE IT ALL had only
    -- Making Fuel items at its save, so it never showed). Merged
    -- instead, keyed on item id. That also keeps the records of a
    -- restore that never ran: those items came back as cauldrons,
    -- carry no owned tool, and this walk would not find them again.
    local merged, order = {}, {}
    local raw_old = read_record()
    if raw_old then
        local ok_old, old = pcall(json.decode, raw_old)
        if not ok_old or type(old) ~= 'table' or type(old.items) ~= 'table' then
            -- ERROR: the items those records describe stay as they
            -- came back.
            log('ERROR', "earlier payload could not be decoded and is"
                .. " replaced; the items it recorded stay as they came"
                .. " back.", 'WASH')
        elseif old.site_id and old.site_id ~= df.global.plotinfo.site_id then
            -- Same anti-ghosting gate restore() keeps: another
            -- fortress's records describe other items.
            log('INFO', string.format(
                "discarded payload from a different Site ID (%s).",
                tostring(old.site_id)), 'WASH')
        else
            for _, rec in ipairs(old.items) do
                -- A record without both fields describes nothing a
                -- restore could act on, and a nil id would throw here
                -- and cost this save its record.
                if type(rec) == 'table' and rec.id ~= nil and rec.code ~= nil then
                    if merged[rec.id] == nil then order[#order + 1] = rec.id end
                    merged[rec.id] = rec.code
                end
            end
        end
    end
    for _, rec in ipairs(records) do
        if merged[rec.id] == nil then order[#order + 1] = rec.id end
        merged[rec.id] = rec.code
    end
    local all = {}
    for _, id in ipairs(order) do
        all[#all + 1] = { id = id, code = merged[id] }
    end

    write_record({
        site_id = df.global.plotinfo.site_id,
        items   = all,
    })
    -- DETAIL: runs on every save, and the save reports it.
    log('DETAIL', string.format(
        "%d tool items recorded (%d on record); none repointed.",
        #records, #all), 'WASH')
    return #records
end


-- ==========================================
-- THE RECORD, KEPT BETWEEN OPENINGS OF THE MENU
-- ==========================================
-- MEASURED 2026-10-02 (section probe, save hook: records refreshed (menu
-- opened)): 273 to 279 ms an opening of the options screen, 386 at
-- worst. The ledger's own check was 31 to 62 ms of it (its log line).
-- The rest was wash() at every opening: a walk of every item in the
-- fort for its 9,914 owned tools, a decode of the stored record before
-- it and an encode of the whole record after, for a record that had
-- grown by four tools since the opening before.
--
-- So the menu's wash (menu_wash) works from a record kept in memory:
--   * built once a data cycle, in the background after a load
--     (keep_step, KEEP_SLICE items a frame, driven by the save hook's
--     monitor), by the walk and merge wash() makes, the stored record
--     merged first. It reads items.all by item id rather than by place,
--     so an item removed meanwhile cannot make it pass one over:
--     items.all is in id order (DFHack finds an item by id with a binary
--     search over it, df.item.xml).
--   * finished at once by an opening that comes before its build has.
--   * then brought up to date at each opening with only the items made
--     since, read off the end of items.all, and the items a script
--     changed from one owned tool to another since the last opening,
--     which that script lists in _G.refinish_tool_wash_touched.
--   * written only when that changed it, or it has not been written this
--     data cycle, as text joined from one string per item kept beside
--     it, rather than by json.encode over the whole record.
--
-- That is the record wash() would write at that moment, but for entries
-- of items that are gone: the same items, the same tools, the entries
-- wash()'s merge keeps for items since gone, and an order that differs
-- only where an item reached the record by another route. The one
-- difference: an owned tool the build read and that was used up before
-- the record's first write this data cycle keeps an entry wash() would
-- not have listed. restore() finds each item by id, never reads the
-- order, and counts an entry whose item is gone as no longer in the
-- world, as it already does for the ones wash()'s merge keeps
-- (measured in the mock, 2026-10-02: 17 such entries after a data
-- cycle, every one an item gone, nothing missing, no tool different).
--
-- THE RULE IT RESTS ON. An item becomes an owned tool by being made; an
-- item that already is one changes which tool it is only by a script,
-- and every such script lists the item in _G.refinish_tool_wash_touched
-- (when that table exists: the build opens it). Today that is air-dry
-- alone (making-fuel-air-dry.lua, convert). restore() changes items too,
-- but only during a load, before the record is kept. A script that ever
-- turns some other existing item into an owned tool, or changes an owned
-- one, without listing it, leaves the kept record short of it until the
-- next data cycle: then that save would bring the item back as it came,
-- a cauldron.
--
-- wash(), the save's own, stays the full walk. It, restore() and settle()
-- drop the kept record (drop_kept): each comes with a data cycle, or
-- rewrites the stored record.
--
-- THE RECORD, KEPT WRITTEN, 2026-10-27. Until this date the kept record
-- reached site data only when the save hook saw the options screen open
-- (menu_wash), and every load consumes the stored record (settle), so
-- from each load until that sighting a save carried no record at all.
-- SEEN in play 2026-10-27: a save & quit came back with every owned tool
-- a cauldron, and the session that wrote it had logged no refresh from
-- its load to its map unload. The save hook had not seen the screen
-- (refinish-save-hook.lua, THE RECORD NO LONGER WAITS FOR THE OPTIONS
-- SCREEN), and nothing said so.
-- So the record no longer waits for anything to be seen. The save hook's
-- monitor, on every frame it runs while nothing else is under way,
-- drives:
--   * keep_step, the build, a slice a frame after each load, as before;
--   * keep_write, from the frame the build is done: the record brought
--     up to date (top_up) and written if that changed it, at once, then
--     every KEEP_WRITE_FRAMES frames (refinish-save-hook.lua), and at
--     once on the frame the options screen's own flag rises, finishing
--     a build still under way.
-- Site data then holds the record from about a second after each load,
-- never more than KEEP_WRITE_FRAMES frames behind the fort, and up to
-- date while the options screen is up: the game is halted there (the
-- save hook, THE PAUSE, HELD FROM UNLOAD TO RELOAD), so nothing changes
-- between its opening and a save made from it. A save by any path
-- carries it, whether or not anything saw the screen or a request. The
-- write is the one an opening already made, 1.5 ms an opening in region4
-- (rm/save-system.md, 2026-10-02), and it is made only when something
-- changed.
-- menu_wash stays, the options screen's own top up and its log line,
-- which counts the writes made since the opening before.
-- Not covered: the first second or so after a load, before the build is
-- done, unless the options screen opens in it.
-- ==========================================

-- One frame's share of the background build, in items read. About a
-- second, after a load, for a fort of a couple of hundred thousand items.
local KEEP_SLICE = 3000

-- The module prefixes, as the save hook's refresh reads them.
local function registry_prefixes()
    local out = {}
    for prefix in pairs(_G.refinish_module_registry or {}) do out[#out + 1] = prefix end
    return out
end

-- Every owned tool's code under any of these prefixes, in one walk of the
-- itemdef array (owned_itemdefs walks it once a prefix).
local function owned_codes(prefixes)
    local owned, n = {}, 0
    for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
        local ok, id = pcall(function() return td.id end)
        if ok and type(id) == 'string' then
            for _, prefix in ipairs(prefixes) do
                if has_prefix(id, prefix) then
                    if not owned[id] then
                        owned[id] = true
                        n = n + 1
                    end
                    break
                end
            end
        end
    end
    return owned, n
end

-- The first position in items.all holding an item id of at least id.
local function first_at_or_after(all, id)
    local lo, hi = 0, #all
    while lo < hi do
        local mid = (lo + hi) // 2
        if all[mid].id < id then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- One item's entry: the JSON json.encode makes of { id = id, code = code },
-- built here for a plain tool id, by json.encode for anything else.
local function entry_text(id, code)
    if not code:find('[^%w_%-%.: ]') then
        return '{"id":' .. tostring(id) .. ',"code":"' .. code .. '"}'
    end
    return json.encode({ id = id, code = code }, { pretty = false })
end

-- One item's tool onto the kept record, as wash()'s merge puts it: a new
-- item at the end, a changed tool in its place.
local function put(k, id, code)
    id = math.tointeger(id) or id
    code = tostring(code)
    local at = k.pos[id]
    if at == nil then
        at = #k.text + 1
        k.pos[id] = at
    elseif k.code[id] == code then
        return
    end
    k.code[id] = code
    k.text[at] = entry_text(id, code)
    k.dirty = true
end

-- A new kept record: the owned tools of this data cycle, and the stored
-- record merged in first, as wash() merges it. With nothing owned it is
-- marked none, so nothing is built or written until the next data cycle.
local function begin_build(prefixes)
    local reg = _G.refinish_module_registry
    local owned, n = owned_codes(prefixes)
    if n == 0 then return { registry = reg, none = true } end
    local k = { registry = reg, owned = owned, site_id = df.global.plotinfo.site_id,
                code = {}, pos = {}, text = {}, next_id = 0, mark = nil, dirty = true }
    local raw_old = read_record()
    if raw_old then
        local ok_old, old = pcall(json.decode, raw_old)
        if not ok_old or type(old) ~= 'table' or type(old.items) ~= 'table' then
            -- ERROR: the items those records describe stay as they
            -- came back.
            log('ERROR', "earlier payload could not be decoded and is"
                .. " replaced; the items it recorded stay as they came"
                .. " back.", 'WASH')
        elseif old.site_id and old.site_id ~= k.site_id then
            -- Same anti-ghosting gate wash() and restore() keep.
            log('INFO', string.format(
                "discarded payload from a different Site ID (%s).",
                tostring(old.site_id)), 'WASH')
        else
            for _, rec in ipairs(old.items) do
                if type(rec) == 'table' and rec.id ~= nil and rec.code ~= nil then
                    put(k, rec.id, rec.code)
                end
            end
        end
    end
    return k
end

-- Reads up to budget items of the build's walk, all the rest with no
-- budget. By item id: an item removed meanwhile moves nothing it has
-- not read. Once at the end, the read of new items starts at the next id
-- DF will give (mark).
local function build_step(k, budget)
    local all = df.global.world.items.all
    local TOOL = df.item_type.TOOL
    local n = #all
    local i = first_at_or_after(all, k.next_id)
    local stop = budget and math.min(n, i + budget) or n
    while i < stop do
        local item = all[i]
        if item:getType() == TOOL then
            local code = item_tool_code(item)
            if code and k.owned[code] then
                local ok_id, item_id = pcall(function() return item.id end)
                if ok_id then put(k, item_id, code) end
            end
        end
        i = i + 1
    end
    if i >= n then
        k.next_id = nil
        k.mark = df.global.item_next_id
    else
        k.next_id = all[i].id
    end
end

-- A kept record for this data cycle, begun if there is none.
local function current(prefixes)
    local reg = _G.refinish_module_registry
    if not kept or kept.registry ~= reg then
        kept = begin_build(prefixes or registry_prefixes())
        if kept.none then
            _G.refinish_tool_wash_touched = nil
        else
            _G.refinish_tool_wash_touched = {}
        end
    end
    return kept
end

-- ---- THE BACKGROUND BUILD ----
-- One frame's share, from the save hook's monitor (refinish-save-hook.lua,
-- THE MENU'S RECORD, BUILT AHEAD). True once the record is kept for this
-- data cycle, or there is nothing owned to keep.
function keep_step(prefixes)
    if not _G.refinish_active or not _G.refinish_module_registry then return false end
    local k = current(prefixes)
    if k.none then return true end
    if k.next_id then build_step(k, KEEP_SLICE) end
    return k.next_id == nil
end

-- ---- BROUGHT UP TO DATE ----
-- The kept record caught up with the fort: the items made since it last
-- looked, read off the end of items.all, and the items a script changed
-- (THE RULE IT RESTS ON). One function for the writer and the menu's wash
-- alike, so the two cannot bring it up to date differently. known_n
-- follows it (WHAT SITE DATA HOLDS).
local function top_up(k)
    local TOOL = df.item_type.TOOL

    -- ---- THE ITEMS MADE SINCE ----
    local top = df.global.item_next_id
    if k.mark < top then
        local all = df.global.world.items.all
        for i = first_at_or_after(all, k.mark), #all - 1 do
            local item = all[i]
            local id = item.id
            if id >= top then break end
            if item:getType() == TOOL then
                local code = item_tool_code(item)
                if code and k.owned[code] then put(k, id, code) end
            end
        end
        k.mark = top
    end

    -- ---- THE ITEMS A SCRIPT CHANGED ----
    -- Listed by the script (THE RULE IT RESTS ON), read again by id. One
    -- that is gone, or no longer an owned tool, keeps its entry, as the
    -- merge in wash() keeps it.
    local touched = _G.refinish_tool_wash_touched
    if touched and next(touched) then
        _G.refinish_tool_wash_touched = {}
        for id in pairs(touched) do
            local item = df.item.find(id)
            if item and item:getType() == TOOL then
                local code = item_tool_code(item)
                if code and k.owned[code] then put(k, id, code) end
            end
        end
    end
    known_n = #k.text
end

-- ---- WRITTEN ONLY WHEN IT CHANGED ----
-- The kept record into site data when anything has changed it since its
-- last write, as text joined from one string per item kept beside it,
-- rather than by json.encode over the whole record. An empty record is
-- never written, as wash() writes none. True when it wrote.
local function write_kept(k)
    local n = #k.text
    if not k.dirty or n == 0 then return false end
    store_text('{"site_id":' .. tostring(k.site_id) .. ',"items":['
        .. table.concat(k.text, ',') .. ']}', n)
    k.dirty = false
    k.writes = (k.writes or 0) + 1
    return true
end

-- ---- THE RECORD, KEPT WRITTEN ----
-- From the save hook's monitor (refinish-save-hook.lua, THE MENU'S RECORD,
-- BUILT AHEAD, AND KEPT WRITTEN): the kept record brought up to date and
-- written if that changed it (THE RECORD, KEPT WRITTEN, above). A record
-- still being built is left to keep_step, unless now is set (the options
-- screen's flag rising): then its build is finished here, at once.
-- Returns the number of items on record. Quiet but for the first write of
-- each data cycle, the moment from which every save carries the record;
-- the options screen's line (menu_wash) counts the writes in between.
function keep_write(prefixes, now)
    if not _G.refinish_active or not _G.refinish_module_registry then return 0 end
    local k = current(prefixes)
    if k.none then return 0 end
    if k.next_id then
        if not now then return 0 end
        build_step(k, nil)
    end
    top_up(k)
    if write_kept(k) then
        k.between = (k.between or 0) + 1
        if k.writes == 1 then
            -- DETAIL: once a data cycle, when saves start carrying it.
            log('DETAIL', string.format("%d tool items on record, written ahead of"
                .. " any save; from here on it is written again whenever it"
                .. " changes.", #k.text), 'WASH')
        end
    end
    return #k.text
end

-- ---- THE MENU'S WASH ----
-- At the opening of the options screen (refinish-save-hook.lua,
-- refresh_records): the kept record, its build finished if it has not,
-- brought up to date, and written only if that changed it. Returns the
-- number of items on record. Since 2026-10-27 the writer above has
-- normally written it already (THE RECORD, KEPT WRITTEN), so this is a
-- top up, and its line says how many writes came since the last opening.
function menu_wash(prefixes)
    local k = current(prefixes)
    if k.none then return 0 end
    local built_now = k.next_id ~= nil
    if built_now then build_step(k, nil) end
    top_up(k)
    local between = k.between or 0
    k.between = 0
    local tail = between > 0 and string.format('; written %d time(s) as it changed'
        .. ' since the last opening', between) or ''
    local n = #k.text
    if write_kept(k) then
        -- DETAIL: runs at every opening that changed the record.
        log('DETAIL', string.format("%d tool items on record, written%s%s.", n,
            built_now and ' (its build finished at this opening)' or '', tail), 'WASH')
    else
        log('DETAIL', string.format("%d tool items on record; nothing has"
            .. " changed since the last write, so it stands%s.", n, tail), 'WASH')
    end
    return n
end


-- ==========================================
-- RESTORE
-- ==========================================
-- Puts every washed item whose tool is injected back onto that tool.
--
-- MUST run after inject_tools, because the itemdef has to be back in
-- the array before anything can point at it.
--
-- The engine calls this after EACH module's tools, so an item comes
-- back as soon as its own tool is in. A record whose tool is not in
-- yet stays on record for a later call; settle() closes the cycle.
--
-- ONE CALL USED TO TAKE IT ALL, 2026-09-25. This consumed the whole
-- payload on its first call, putting back what it could and dropping
-- the rest. That held while Making Fuel was the first module with
-- tools. Once RM's catalog forms were injected ahead of the modules
-- that ask for them, the first call came straight after RM's bark tool
-- (REFINISH_BARK_, first in the order), and every item on record was
-- dropped and left a jug. Measured in refinish_session.log: "0 items
-- restored, 176 skipped" at the map load, then, after an autosave whose
-- wash recorded 6 Making Fuel items, "0 items restored, 6 skipped".
--
-- Returns restored, still waiting, gone (no longer in the world).
-- ==========================================

-- What this cycle's calls have done, for settle() to report. refused
-- is keyed on tool code.
local tally = { restored = 0, gone = 0, refused = {} }

-- ---- ONE READ A LOAD ----
-- MEASURED 2026-10-01, the load clock (refinish-startup.lua), region4:
-- restore() ran 15 times a load, once per module with tools, 2,002 ms
-- together, 133 ms a call and 236 at worst (REFINISH_BARK_). Every call
-- read and decoded the whole record (9,849 items) and rebuilt the
-- itemdef lookup, and every call that had a tool to restore walked every
-- item in the world into its dictionary, then encoded and wrote back
-- the rest of the record.
--
-- So the engine hands every call of one pipeline run the same table,
-- run. The first call reads, decodes and gates the record into
-- run.tool_record. The item dictionary is built by the first call with
-- a tool to restore and kept there, and what is still waiting stays
-- there too, until settle(run) clears the stored record, once. Nothing
-- is written in between, so a run that dies before settle() leaves the
-- stored record as it was read, and the next load applies it again: a
-- subtype written twice is the same subtype. A record that was missing
-- or refused (undecodable, another site's) is said once and left alone.
-- Called without a run, each call reads and writes on its own, as
-- before.

-- The record decoded and gated, as { items, site_id }, or nil once
-- whatever stops a restore has been said.
local function open_record()
    local raw = read_record()
    if not raw then
        return nil
    end

    local ok, payload = pcall(json.decode, raw)
    if not ok or type(payload) ~= 'table' or type(payload.items) ~= 'table' then
        -- ERROR: every recorded item stays as it came back, a cauldron,
        -- which the player will notice.
        log('ERROR', "payload could not be decoded. Restore skipped.", 'RESTORE')
        return nil
    end

    -- Same anti-ghosting gate the material payload and the ledger both
    -- use. A payload from another fortress describes other items.
    local current_site = df.global.plotinfo.site_id
    if payload.site_id and payload.site_id ~= current_site then
        log('INFO', string.format(
            "discarded payload from a different Site ID (%s). Restore skipped.",
            tostring(payload.site_id)), 'RESTORE')
        return nil
    end

    return { items = payload.items, site_id = current_site }
end

function restore(run)
    -- A load rewrites the stored record, and settle() consumes it: the
    -- menu's kept record goes (THE RECORD, KEPT), rebuilt after the load.
    -- settle() calls this first, so it drops it too.
    drop_kept()
    -- ONE READ A LOAD: a run's first call opens the record into the run,
    -- and its later calls work on what is kept there. A record that was
    -- missing or refused is marked so, and was said only that once.
    local open
    if run then
        open = run.tool_record
        if not open then
            open = open_record() or { missing = true }
            run.tool_record = open
        end
    else
        open = open_record()
    end
    if not open or open.missing then
        return 0, 0, 0
    end
    local items, current_site = open.items, open.site_id

    if #items == 0 then
        return 0, 0, 0
    end

    -- ---- ITEMDEF LOOKUP ----
    -- Also built once, for the same reason as the item dictionary
    -- below. Built FIRST now, because it is a few hundred itemdefs:
    -- when no record's tool is in yet, which is every call before the
    -- module that owns them, the walk of every item is skipped.
    local by_code = {}
    for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
        local ok_c, id = pcall(function() return td.id end)
        if ok_c and type(id) == "string" then by_code[id] = td end
    end
    local any = false
    for _, rec in ipairs(items) do
        if by_code[rec.code] then
            any = true
            break
        end
    end
    if not any then
        return 0, #items, 0
    end

    -- ---- ITEM LOOKUP DICTIONARY ----
    -- Built once. df.item.find() inside the loop would be O(N times M)
    -- across every item in the fortress for every record, which is the
    -- same mistake the material restore already had to fix. With a run,
    -- once a load: the first call with a tool to restore builds it and
    -- the run keeps it (ONE READ A LOAD). No item can leave the world
    -- between two calls of one run: the startup pipeline is one call,
    -- with no tick inside it.
    local by_item_id = open.by_item_id
    if not by_item_id then
        by_item_id = {}
        for _, item in ipairs(df.global.world.items.all) do
            local ok_id, id = pcall(function() return item.id end)
            if ok_id then by_item_id[id] = item end
        end
        if run then open.by_item_id = by_item_id end
    end

    local restored, gone = 0, 0
    local waiting = {}

    for _, rec in ipairs(items) do
        local item = by_item_id[rec.id]
        local def  = by_code[rec.code]

        if not item then
            -- Item destroyed since the save: nothing to put back, and
            -- nothing to keep a record for.
            gone = gone + 1
        elseif def then
            local ok_w = pcall(function() item.subtype = def end)
            if ok_w then
                restored = restored + 1
            else
                -- The write refused, with the tool in the array. A
                -- later call could do nothing differently, so it is not
                -- kept; settle() names it.
                tally.refused[rec.code] = (tally.refused[rec.code] or 0) + 1
            end
        else
            -- Its tool is not injected yet: a module later in the order
            -- owns it, or nothing does this session. Kept for the next
            -- call. If the module that owned the tool was uninstalled
            -- the item stays as it came back, a cauldron, rather than a
            -- broken reference. No sentinel is written,
            -- matching the material restore. settle() makes that call.
            waiting[#waiting + 1] = rec
        end
    end

    tally.restored = tally.restored + restored
    tally.gone     = tally.gone + gone

    -- Only what is still waiting stays on record. The payload is
    -- consumed by settle(), never here (ONE CALL USED TO TAKE IT ALL).
    -- With a run, the record is the run's table until settle(run), and
    -- nothing is written in between (ONE READ A LOAD).
    if run then
        open.items = waiting
    elseif #waiting > 0 then
        write_record({
            site_id = current_site,
            items   = waiting,
        })
    else
        clear_record()
    end

    return restored, #waiting, gone
end


-- ==========================================
-- SETTLE
-- ==========================================
-- Closes a load's restore, once, after every module's tools are in:
-- the engine calls it after its per-module loop. One last restore()
-- catches anything a failed per-module call missed. Whatever is still
-- on record after that belongs to a tool nothing injected this
-- session: its module was removed, or its form moved to RM under a new
-- id (MAKING_FUEL_SAWDUST became REFINISH_SAWDUST_TOOL). Those items
-- stay as they came back.
--
-- Payload consumed here, and only here. Leaving it would re-apply
-- stale records on the next load against items that have since
-- changed. A payload restore() refused (undecodable, or another
-- site's) is left exactly as restore() left it; restore() has already
-- said why.
--
-- One line per cycle, as restore() used to write. DETAIL as a rule.
-- WARNING when items were left unrestored: they stay as they came
-- back, the expected result of removing the module that owned their
-- tool, as the
-- ledger treats materials that are no longer present. The line names
-- the tools, so what was left behind and why reads straight off it.
-- ==========================================
function settle(run)
    restore(run)

    local left, by_code = 0, {}
    if run then
        -- ONE READ A LOAD: what is still waiting is in the run's table. A
        -- record that was missing or refused was never opened and stays
        -- as it is; an opened one is consumed here, as below.
        local open = run.tool_record
        run.tool_record = nil
        if open and not open.missing then
            for _, rec in ipairs(open.items) do
                left = left + 1
                local code = tostring(rec.code)
                by_code[code] = (by_code[code] or 0) + 1
            end
            clear_record()
        end
    else
        local raw = read_record()
        if raw then
            local ok, payload = pcall(json.decode, raw)
            if ok and type(payload) == 'table' and type(payload.items) == 'table'
               and (not payload.site_id
                    or payload.site_id == df.global.plotinfo.site_id) then
                for _, rec in ipairs(payload.items) do
                    left = left + 1
                    local code = tostring(rec.code)
                    by_code[code] = (by_code[code] or 0) + 1
                end
                clear_record()
            end
        end
    end

    local restored, gone, refused = tally.restored, tally.gone, tally.refused
    tally.restored, tally.gone, tally.refused = 0, 0, {}
    -- WHAT SITE DATA HOLDS: the record is consumed above, and the owned
    -- tools this load put back are what the session knows of until the
    -- kept record is built.
    known_n = restored

    local n_refused, refused_names = 0, {}
    for code, n in pairs(refused) do
        n_refused = n_refused + n
        refused_names[#refused_names + 1] = string.format('%s x%d', tostring(code), n)
    end
    if n_refused > 0 then
        table.sort(refused_names)
        -- ERROR: their tool IS injected and would not take them back.
        -- They stay as they are, and nothing about a removed module
        -- explains it.
        log('ERROR', string.format("%d items could not be written back to"
            .. " their tools and stay as they are: %s.", n_refused,
            table.concat(refused_names, ', ')), 'RESTORE')
    end

    if restored == 0 and left == 0 and gone == 0 and n_refused == 0 then
        -- DETAIL: said once, so a load with nothing on record reads as
        -- that and not as a restore that never ran.
        log('DETAIL', "No washed items on record; nothing to restore.", 'RESTORE')
        return 0, 0, 0
    end

    local tail = ''
    if gone > 0 then
        tail = string.format(' %d no longer in the world.', gone)
    end
    if left > 0 then
        local names = {}
        for code, n in pairs(by_code) do
            names[#names + 1] = string.format('%s x%d', code, n)
        end
        table.sort(names)
        -- WARNING: those items are cauldrons now, which the player will
        -- see, and expected when a module or a form went away.
        log('WARNING', string.format(
            "%d items restored; %d left %s, their tools not injected"
            .. " this session: %s.%s", restored, left, LEFT_AS,
            table.concat(names, ', '), tail), 'RESTORE')
    else
        log('DETAIL', string.format(
            "%d items restored.%s", restored, tail), 'RESTORE')
    end

    return restored, left, gone
end


-- ==========================================
-- IS ANYTHING OUTSTANDING
-- ==========================================
-- True when a wash payload is sitting unconsumed, which means a restore
-- was expected and did not happen. Worth surfacing in the status panel:
-- it is the shape of bug that stays silent until a player notices their
-- tools turned into cauldrons.
-- ==========================================
function has_pending_payload()
    return read_record() ~= nil
end


-- ==========================================
-- WHAT A SAVE CARRIES
-- ==========================================
-- What site data holds of the record right now (WHAT SITE DATA HOLDS, at
-- the top): its item count and the clock time of its write, or nil and
-- nil when it holds none, then how many owned tool items this session
-- last counted (known_n). For the save hook's line as a save & continue
-- is asked for (refinish-save-hook.lua, WHAT A SAVE & CONTINUE CARRIES)
-- and the map unload's below.
-- ==========================================
function stored_record()
    if not stored then return nil, nil, known_n end
    return stored.n, stored.at, known_n
end

-- ---- AT EVERY MAP UNLOAD ----
-- A save & quit writes after the map unload, with whatever site data
-- holds by then, and nothing can be written there any more
-- (refinish-save-hook.lua, SAVE & QUIT). So every map unload says what
-- that is. SEEN 2026-10-27: the save & quit that brought every owned tool
-- back a cauldron left no line anywhere saying it went out without a
-- record; the next load's "No washed items on record" was the first word
-- of it. A WARNING when site data holds no record and this session has
-- owned tools to lose. Read from this file's own memory only: DFHack calls
-- state change handlers in an arbitrary order (Lua API, Event type), and
-- nothing here depends on whether refinish_steel.lua's unload ran first.
-- Keyed, so a reload of this file replaces the handler rather than adding
-- a second one.
dfhack.onStateChange.refinish_tool_wash = function(code)
    if code ~= SC_MAP_UNLOADED then return end
    pcall(function()
        local n, at, known = stored_record()
        if n then
            -- DETAIL: at every map unload.
            log('DETAIL', string.format("map unloaded: site data holds the tool"
                .. " record written at %s, %d tool item(s); a save written now"
                .. " carries it.", at, n), 'UNLOAD')
        elseif known > 0 then
            -- WARNING: a save written now brings every owned tool back as a
            -- cauldron, and the player should keep an earlier save.
            log('WARNING', string.format("map unloaded with no tool record in"
                .. " site data while this session counted %d owned tool"
                .. " item(s): a save written now brings them back as"
                .. " cauldrons.", known), 'UNLOAD')
        end
    end)
end


return _ENV