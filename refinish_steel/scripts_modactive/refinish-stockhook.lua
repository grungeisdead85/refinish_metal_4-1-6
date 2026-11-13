--@ module = true
-- refinish-stockhook.lua
-- ==========================================
-- RM STOCKHOOK: module-defined stockpile entries (Lua side)
-- ==========================================
-- PART OF RM (2026-11-02). Stockhook was built as a mod of its own and
-- moved into RM: these four scripts in RM's scripts_modactive (so they
-- run only in a world with RM in its load order), the DLL, its targets
-- file and its source in RM's root. Definition files keep their name and
-- place: any mod's stockhook/*.txt. RM's own are in RM's stockhook/.
-- WHAT: the Lua half of Stockhook. Mods describe which items they want to
-- decide for (CLAIMS) and how a pile decides for them (ENTRIES); this file
-- writes it all into the block the Stockhook DLL owns, and the DLL answers
-- DF's stockpile check from it. DF's own answer is kept for every item no
-- claim covers.
--
-- MOST MODS NEVER CALL THIS FILE: they write definition files instead
-- (stockhook/*.txt, read by refinish-stockhook-defs.lua; see STOCKHOOK_DEFINITIONS.md).
-- This API is for mods that build their entries at run time.
--
-- WHY: DF files an item only through fixed settings entries keyed by
-- material flags, so a mod's items (plant-material coal, branches,
-- twins) either cannot be filed or cannot be told apart. The DLL hooks
-- DF's master stockpile check (RM_Notes/RM_Stockpile_Filing_Disassembly.md)
-- and this file tells it what to answer.
--
-- THE BLOCK: the DLL publishes its address in the environment variable
-- STOCKHOOK_BLOCK. Its layout is in OFF below and must match the DLL's
-- struct Block byte for byte; LAYOUT is checked before anything is read.
-- With no DLL, or a mismatch, available() says why and nothing is written:
-- the caller keeps its own fallback (RM's windows and soap switch).
--
-- ENTRIES, three kinds:
--   follow  a byte of DF's own pile settings decides. Coal follows the
--           bars Coal entry; a stone twin can follow its stone's entry.
--   module  a per-pile bit this file keeps decides: a mod's own row
--           ("Cinders", "Branches"). Saved per fort. Needs no vanilla group
--           switched on (test 3b: DF asks about every pile).
--   never   no pile takes it (items that must never be hauled).
--
-- CLAIMS: { item_type, subtype, mat_type, mat_index, entry }, -1 meaning
-- "any" for subtype and both material fields. The first match wins, and
-- claims are ordered most specific first, so an exact material beats a
-- wildcard.
--
-- API (reqscript('refinish-stockhook')):
--   available()                         -> true, or false and the reason
--   define(id, spec)                    an entry; spec as in ENTRY SPECS
--   undefine_where(drop)                drop every entry drop(id) picks
--   claim(owner, rows) / unclaim(owner) the items an owner decides for
--   set(pile, id, on) / get(pile, id)   a module entry's per-pile bit
--   set_many(pile, changes)             many bits at once ({ [id] = on })
--   entries()                           every entry: id, kind, label, ...
--   commit()                            write everything to the block
--   nudge(id)                           make DF look again at items
--                                       (id: one id, a set of ids, or nil)
--   stats(), inspect_pile(pile, id)     diagnostics
-- Commit happens on its own when piles appear or vanish (THE PILE WATCH).
--
-- COMMANDS (the console):
--   refinish-stockhook status             is it active, what is defined, counters
--   refinish-stockhook reload             re-read every definition file
--   refinish-stockhook piles              every pile's number and its rows that are on
--   refinish-stockhook set <pile number> <entry id> on|off
--     The pile number is the one DF shows ("Stockpile #12" is 12).
--   refinish-stockhook type <pile number> <group>   test: type a pile in any group
--   refinish-stockhook rows               with a pile's settings open: the live rows
--   refinish-stockhook install            copy the DLL into DF's folder now
--   refinish-stockhook uninstall          stop DF loading the DLL from the next launch

-- ==========================================
-- RM'S LOG
-- ==========================================
-- Every line goes to RM's session log, in its grammar (SYSTEM SUBSYSTEM
-- SUBJECT TYPE | body), as every RM file writes it. No console prints: a
-- print only answers a command typed into the console (COMMANDS, below).
-- log(typ, msg, subject) is shared: the other refinish-stockhook files
-- write through it. typ: DETAIL, INFO, WARNING, ERROR.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'STOCKHOOK'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

function log(typ, msg, subject)
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

-- This file's own lines. typ defaults to INFO.
local function log_line(msg, typ)
    log(typ or 'INFO', msg, 'CORE')
end

-- ==========================================
-- THE BLOCK LAYOUT (mirrors stockhook_dll.cpp, struct Block)
-- ==========================================
local LAYOUT = 6   -- 2: EF_PART, CF_EXACT_INDEX; 3: material aliases; 4: larger tables; 5: colour rows (2026-11-02); 6: automatic target, list count (2026-11-09); must match the DLL
local OFF = {
    magic = 0, layout = 8, enabled = 12, n_claims = 16, n_entries = 20,
    n_piles = 24, hooked = 28, calls = 32, yes = 40, no = 48, passed = 56,
    type_start = 64, type_count = 1088,
    claims = 2112, entries = 526400, piles = 591936,
    mat_off = 2705472, n_alias = 2706496, aliases = 2706512,
    -- layout 5: THE COLOUR ROWS (stockhook_dll.cpp, THE SECOND TARGET)
    list_info = 2772048, n_colour = 2772560, colour_hooked = 2772564,
    colour_calls = 2772568, colour = 2772576,
    -- layout 6: THE AUTOMATIC TARGET and THE LIST COUNT (stockhook_dll.cpp),
    -- appended after the colour rows so every offset above is unchanged.
    automatic = 2903648, list_max = 2903652, colour_ok = 2903656,
}
local MAX_COLOUR, COLOUR_SZ, N_LISTS = 8192, 16, 128
local CR_ENTRY, CR_BYTE = 0, 1
local MAX_CLAIMS, MAX_ENTRIES, MAX_PILES = 32768, 4096, 2048
local ALIAS_SLOTS, ALIAS_SZ = 4096, 16
local CLAIM_SZ, ENTRY_SZ, PILE_SZ, PILE_BYTES = 16, 16, 1032, 512
-- A pile record: settings address (8), then the value bits (PILE_BYTES),
-- then the "set" bits (PILE_BYTES): which part rows the player set in this
-- pile (stockhook_dll.cpp, struct Pile and part_value).
local PILE_SET = 8 + PILE_BYTES
local KIND = { follow = 1, module = 2, never = 3 }
local EF_ALSO_VANILLA, EF_PART, EF_VANILLA_ITEM = 0x01, 0x02, 0x04

-- Raw memory, through DFHack's typed views (as devel/visualize-structure
-- does): df.reinterpret_cast(type, address).value reads or writes one value.
local function peek(t, a) return df.reinterpret_cast(t, a).value end
local function poke(t, a, v) df.reinterpret_cast(t, a).value = v end

-- A DF object's address: the second value of :sizeof().
local function addr_of(ref) local _, a = ref:sizeof(); return a end

-- ==========================================
-- STATE (on _G: survives this file being reloaded)
-- ==========================================
_G.stockhook_state = _G.stockhook_state or {
    entries = {},      -- id -> { index, kind, spec }, index 0-based
    entry_order = {},  -- index + 1 -> id
    claims = {},       -- owner -> list of claim rows
    next_bit = 0,      -- next free module bit
    bits = {},         -- module entry id -> bit
    aliases = {},      -- owner -> { plant = { {from, to} }, pairs = { {fmt, fmi, tmt, tmi} } }
}
local S = _G.stockhook_state
S.aliases = S.aliases or {}

-- Empties the state IN PLACE. The table itself is kept, because this file's
-- S (and anything else holding it) must go on pointing at the live state:
-- DFHack runs this file's top level only once a session (ONE WORLD ONLY).
local function reset_state()
    S.entries, S.entry_order, S.claims, S.next_bit, S.bits = {}, {}, {}, 0, {}
    S.aliases = {}
end

local PERSIST_KEY = 'stockhook-piles'

-- ==========================================
-- IS STOCKHOOK IN THIS WORLD?
-- ==========================================
-- True only while a world is loaded whose load order holds RM
-- (script-manager get_active_mods: the world's object_load_order, each
-- mod's info.txt ID). Kept although the scripts sit in RM's
-- scripts_modactive: handlers outlive a world (ONE WORLD ONLY). Every Stockhook state handler asks this first and
-- does nothing when it is false (ONE WORLD ONLY).
local MOD_ID = 'refinish_steel'   -- RM's own id: Stockhook runs where RM does
local scriptmanager = require('script-manager')
function world_active()
    local ok, mods = pcall(scriptmanager.get_active_mods)
    if not ok or not mods then return false end
    for _, m in ipairs(mods) do
        if tostring(m.id):lower() == MOD_ID then return true end
    end
    return false
end

-- ==========================================
-- FINDING THE BLOCK
-- ==========================================
-- WHY THE HOOK IS NOT LIVE: the DLL writes its reason to stockhook.log in
-- DF's folder (a DF build it does not know, a signature not found,
-- stockhook.disable present). The last such line is handed back with the
-- reason, so a caller (RM's log) can say why without the player opening
-- that file.
local function dll_reason()
    local f = io.open('stockhook.log', 'r')
    if not f then return nil end
    -- The last NOT HOOKING line carries the reason; "hook not installed."
    -- comes after it and says only that, so it is the answer only when no
    -- NOT HOOKING line was written (2026-11-09: after the 53.17 update RM's
    -- log gave "hook not installed." and no reason).
    local reason, fallback = nil, nil
    for line in f:lines() do
        if line:find('NOT HOOKING', 1, true) then reason = line
        elseif line:find('not installed', 1, true) then fallback = line end
    end
    f:close()
    return reason or fallback
end

local function block()
    local s = os.getenv('STOCKHOOK_BLOCK')
    if not s or s == '' then return nil, 'no Stockhook DLL loaded (STOCKHOOK_BLOCK not set)' end
    local base = tonumber(s, 16)
    if not base then return nil, 'STOCKHOOK_BLOCK unreadable: ' .. s end
    local magic = {}
    for i = 0, 7 do magic[#magic + 1] = string.char(peek('uint8_t', base + i)) end
    if table.concat(magic) ~= 'STKHOOK1' then return nil, 'block magic wrong' end
    local layout = peek('uint32_t', base + OFF.layout)
    if layout ~= LAYOUT then
        return nil, ('block layout %d, this file speaks %d: update both together'):format(layout, LAYOUT)
    end
    if peek('uint32_t', base + OFF.hooked) ~= 1 then
        local why = dll_reason()
        return nil, 'DLL loaded but not hooked: ' .. (why or 'see stockhook.log in DF\'s folder')
    end
    return base
end

function available()
    local b, why = block()
    if b then return true end
    return false, why
end

-- ==========================================
-- MEASURING DF'S SETTINGS LAYOUT
-- ==========================================
-- Offsets inside stockpile_settings are taken from DFHack's own layout, on
-- a scratch settings object, never hard-coded: a DF update that DFHack has
-- caught up with moves them here too.
local layout_cache = nil
local function settings_layout()
    if layout_cache then return layout_cache end
    -- A DF struct is made through its type object; df.new(name) takes
    -- only DFHack's primitive type names.
    local tmp = df.stockpile_settings:new()
    local base = addr_of(tmp)
    local flags_off = addr_of(tmp.flags) - base
    local function vec_off(path)
        local ref = tmp
        for part in path:gmatch('[^%.]+') do ref = ref[part] end
        return addr_of(ref) - base
    end
    -- A group's bit: set it alone on the scratch object, read the dword.
    local function group_mask(name)
        tmp.flags.whole = 0
        tmp.flags[name] = true
        local m = peek('uint32_t', base + flags_off)
        tmp.flags.whole = 0
        return m
    end
    layout_cache = { flags_off = flags_off, vec_off = vec_off, group_mask = group_mask, tmp = tmp }
    return layout_cache
end

-- ==========================================
-- ENTRY SPECS
-- ==========================================
-- define('coal', { kind = 'follow', group = 'bars_blocks',
--                  vector = 'bars_blocks.bars_other_mats',
--                  index = df.stockpile_bar_mat.Coal })
-- define('cinders', { kind = 'module', label = 'Cinders',
--                     category = 'BARS', container = 'BIN' })
-- define('keys', { kind = 'never' })
-- also_vanilla = true: when the entry says no, DF's own answer is asked.
-- label, category, container: what the settings screen shows and where,
-- and which container a pile needs once the row is on (BIN, BARREL).
function define(id, spec)
    assert(type(id) == 'string' and KIND[spec.kind], 'define: bad id or kind')
    local e = S.entries[id]
    if not e then
        if #S.entry_order >= MAX_ENTRIES then error('stockhook: entry table full') end
        S.entry_order[#S.entry_order + 1] = id
        e = { index = #S.entry_order - 1 }
        S.entries[id] = e
    end
    e.kind, e.spec = spec.kind, spec
    S.version = (S.version or 0) + 1
    if spec.kind == 'module' and not S.bits[id] then
        if S.next_bit >= PILE_BYTES * 8 then error('stockhook: module bits exhausted') end
        S.bits[id] = S.next_bit
        S.next_bit = S.next_bit + 1
    end
end

-- Every entry for which drop(id) is true goes, with the claims owned under
-- the same id, so a reload of definition files starts clean. Entry slots
-- are renumbered in order and claims refer to entries by id, so nothing is
-- left pointing at a dropped one. Module bits are kept: a row that comes
-- back keeps its bit, and so its saved per-pile settings.
function undefine_where(drop)
    local keep = {}
    for _, id in ipairs(S.entry_order) do
        if drop(id) then
            S.entries[id] = nil
            S.claims[id] = nil
        else
            keep[#keep + 1] = id
        end
    end
    S.entry_order = keep
    for i, id in ipairs(keep) do S.entries[id].index = i - 1 end
    S.version = (S.version or 0) + 1
end

-- Moves whenever an entry is defined or dropped: refinish-stockhook-rows.lua rebuilds
-- its rows only then, not every frame.
function version() return S.version or 0 end

-- Every entry, in order, for screens and commands.
function entries()
    local out = {}
    for _, id in ipairs(S.entry_order) do
        local e = S.entries[id]
        out[#out + 1] = { id = id, kind = e.kind, label = e.spec.label or id,
                          category = e.spec.category, container = e.spec.container,
                          source = e.spec.source, part_of = e.spec.part_of }
    end
    return out
end

-- ==========================================
-- CLAIMS
-- ==========================================
-- rows: list of { item_type = n, subtype = n or -1, mat_type = n or -1,
--                 mat_index = n or -1, entry = 'id',
--                 exact_index = true (mat_index -1 means exactly -1),
--                 seq = n (reading order; higher wins a tie) }
function claim(owner, rows) S.claims[owner] = rows end
function unclaim(owner) S.claims[owner] = nil end

-- ==========================================
-- NUDGE: make DF look again
-- ==========================================
-- DF lengthens an item's storage delay every time it looks at it and
-- cannot store it (RM_Stockpile_Mechanics.md section 11). Items that sat
-- unfileable for a long time are then not looked at again for ages, which
-- test 3 saw: cinders did not move until their timers were reset. So
-- whenever a change makes items fileable (a row switched on, definitions
-- loaded), the items it covers get a fresh item's timers (countdown 1,
-- delay 13, from the haul probe's capture). id nil: every claimed item.
local function claim_matches(r, it)
    if (r.subtype or -1) ~= -1 and it:getSubtype() ~= r.subtype then return false end
    if (r.mat_type or -1) ~= -1 and it:getMaterial() ~= r.mat_type then return false end
    if (r.mat_index or -1) ~= -1 and it:getMaterialIndex() ~= r.mat_index then return false end
    return true
end

-- id: one entry id, a set of them ({ [id] = true }, from set_many), or nil
-- for every claimed item.
function nudge(id)
    local want = id
    if type(id) ~= 'table' and id ~= nil then want = { [id] = true } end
    local by_type = {}
    for _, rows in pairs(S.claims) do
        for _, r in ipairs(rows) do
            if not want or want[r.entry] then
                by_type[r.item_type] = by_type[r.item_type] or {}
                table.insert(by_type[r.item_type], r)
            end
        end
    end
    -- ---- ONE LOOK PER ITEM (2026-11-03) ----
    -- Every item was tested against every row of its type, each test up to
    -- three of the item's virtual calls: a group's all with hundreds of rows
    -- on hundreds of items made this the slow part of set_many (test 42:
    -- row clicks up to 123 ms). The rows of a type are now split once: a
    -- row naming all three (subtype, mat_type, mat_index) goes in a lookup
    -- under that key, the rest in a short wildcard list. Each item is read
    -- once (its three values) and found in the lookup or the list: the same
    -- answer claim_matches gives, at one look per item.
    local done = 0
    for t, rows in pairs(by_type) do
        local key = df.item_type[t]
        local ok, vec = pcall(function() return df.global.world.items.other[key] end)
        if ok and vec then
            local exact, wild = {}, {}
            for _, r in ipairs(rows) do
                local st, mt, mi = r.subtype or -1, r.mat_type or -1, r.mat_index or -1
                if st ~= -1 and mt ~= -1 and mi ~= -1 then
                    exact[st .. ':' .. mt .. ':' .. mi] = true
                else
                    wild[#wild + 1] = { st, mt, mi }
                end
            end
            for _, it in ipairs(vec) do
                if not it.flags.in_job and not it.flags.garbage_collect then
                    local ist, imt, imi = it:getSubtype(), it:getMaterial(), it:getMaterialIndex()
                    local hit = exact[ist .. ':' .. imt .. ':' .. imi] or false
                    if not hit then
                        for _, w in ipairs(wild) do
                            if (w[1] == -1 or w[1] == ist) and (w[2] == -1 or w[2] == imt)
                                    and (w[3] == -1 or w[3] == imi) then
                                hit = true
                                break
                            end
                        end
                    end
                    if hit then
                        it.stockpile_countdown = 1
                        it.stockpile_delay = 13
                        done = done + 1
                    end
                end
            end
        end
    end
    return done
end

-- ==========================================
-- PER-PILE MODULE BITS, SAVED WITH THE FORT
-- ==========================================
-- Keyed by entry id (not bit number), so a bit renumbered between
-- sessions cannot flip a different row.
--
-- READ ONCE, NOT AT EVERY CALL (2026-11-03): getSiteData decodes the whole
-- saved state, every pile's rows, through DFHack's JSON reader, whose cost
-- grows with the length of the text (PROTECTED BASES, CACHED in
-- refinish_steel.lua measured the same reader). set_many, commit, get and
-- getter each read it. The raw text is read without decoding
-- (getSiteDataString, Lua API.txt) and the table decoded again only when
-- that text has changed. Every write goes through pile_state_save, which
-- keeps the table it wrote and the text it left, so a write costs no
-- decode either. Callers that change the table save it (set_many, unset).
local PS = { raw = nil, tbl = nil }
local function pile_state()
    local raw = dfhack.persistent.getSiteDataString(PERSIST_KEY)
    if PS.tbl and raw == PS.raw then return PS.tbl end
    PS.raw = raw
    PS.tbl = dfhack.persistent.getSiteData(PERSIST_KEY, {})
    return PS.tbl
end

local function pile_state_save(st)
    dfhack.persistent.saveSiteData(PERSIST_KEY, st)
    PS.tbl, PS.raw = st, dfhack.persistent.getSiteDataString(PERSIST_KEY)
end

-- ==========================================
-- ONE PILE'S BITS
-- ==========================================
-- A pile record's value bits and "set" bits, from its saved row (true: on;
-- false: a part the player switched off; absent: a module row off, or a
-- part following its vanilla entry, which the DLL reads live). A part with
-- a value of its own gets its "set" bit. Built in Lua first and written a
-- byte at a time: before 2026-11-03 every on bit was a peek and a poke.
-- a: the record's address in the block.
local function write_pile_bits(a, row)
    local nbytes = math.min(PILE_BYTES, (S.next_bit + 7) // 8)
    local val, set = {}, {}
    for i = 0, nbytes - 1 do val[i], set[i] = 0, 0 end
    for id, on in pairs(row or {}) do
        local bit = S.bits[id]
        if bit and bit // 8 < nbytes then
            local i, m = bit // 8, 1 << (bit % 8)
            if on then val[i] = val[i] | m end
            local e = S.entries[id]
            if e and e.spec.part_of then set[i] = set[i] | m end
        end
    end
    for i = 0, nbytes - 1 do
        poke('uint8_t', a + 8 + i, val[i])
        poke('uint8_t', a + PILE_SET + i, set[i])
    end
end

-- ---- ONE PILE, NOT EVERYTHING (2026-11-03) ----
-- set_many and unset change one pile's saved row and nothing else the
-- block holds: entries, claims, aliases and colour rows stay as they are.
-- The full commit rewrote all of it, thousands of writes, at every click
-- (test 42: a group's all up to 123 ms with the item walk). So only the
-- pile's own record is written, found by its settings address as
-- inspect_pile finds it. False when the pile is not listed (a pile made
-- since the last pile watch): the caller then commits everything. Runs on
-- the game thread like the hook, so the hook never sees it half written.
local function commit_pile(pile, st)
    local base = block()
    if not base then return false end
    local want = addr_of(pile.settings)
    local n = peek('uint32_t', base + OFF.n_piles)
    for i = 0, n - 1 do
        local a = base + OFF.piles + i * PILE_SZ
        if peek('uint64_t', a) == want then
            write_pile_bits(a, st[tostring(pile.id)])
            return true
        end
    end
    return false
end

-- ---- CONTAINERS ----
-- DF sets a pile's bin and barrel counts from its presets when vanilla
-- entries are chosen; a pile holding only module rows never gets them
-- (seen in play: the cinders pile stayed at 0 bins until set by hand, then
-- binned). So a row that asks for a container sets the count when it is
-- switched on, if the pile has none. The count is the pile's footprint, one
-- per tile: an upper bound (an irregular pile has fewer usable tiles), and
-- the player can lower it as usual.
local function ensure_containers(pile, container)
    if container ~= 'BIN' and container ~= 'BARREL' then return end
    local field = container == 'BIN' and 'max_bins' or 'max_barrels'
    if pile.storage[field] > 0 then return end
    local tiles = (pile.x2 - pile.x1 + 1) * (pile.y2 - pile.y1 + 1)
    pile.storage[field] = math.min(tiles, 32767)
end

-- ---- THE PILE'S TYPE ----
-- DF labels and names a pile by its vanilla settings alone: a pile holding
-- nothing but module rows reads "None" with "stockpile has no type". To look
-- like any vanilla pile, a pile with a module row on gets that row's group
-- switched on, with every vanilla entry of the group OFF: the state DF itself
-- leaves after the group's "none" (pile 7137, 2026-11-01: Bars/Blocks on,
-- every bar entry off). Vanilla filing is unchanged, nothing being on.
--
-- SAFE ONLY WITH FILLED LISTS. DF reads a group's fixed "other materials"
-- list without a bounds check when the group is on: switched on over lists
-- that were never created, DF crashed (+0x5AFBA8, the crash rule in
-- RM_Notes/Stockhook_Design.md).
--
-- HOW: DFHack's own stockpile importer does it, for any of the 17 groups
-- (DFHack 53.16-r3, plugins/stockpiles/StockpileSerializer.cpp):
--   * read_category sets the group's flag, then every list of the group is
--     resized to its full length (unserialize_list_*), with the slots DF
--     itself keeps at 1 (item types and materials the group cannot hold)
--     filled the same way. DFHack keeps those lengths right across DF
--     updates, so Stockhook keeps no table of its own.
--   * 'enable' mode with a filter nothing matches: matches_filter refuses
--     every element, flags and quality arrays included, so the group comes
--     on with every vanilla entry off.
--   * DFHack's library has one file per group, library/cat_<group>
--     (docs/tools/stockpiles.txt); the sheet group's is cat_sheets.
--   * The importer also applies containers and general settings when a file
--     holds them (read_containers, read_general), so those are read before
--     and written back after.
-- Lists are never shrunk or cleared: enable mode only adds.
local LIBRARY_FILE = { sheet = 'cat_sheets' }        -- otherwise cat_<group>
local NO_MATCH = '\31stockhook no match\31'           -- in no entry's name

-- Bumped whenever a pile is typed. refinish-stockhook-rows.lua takes a fresh look at
-- the group's bytes when it changes, so the importer's own writes are never
-- read as the player pressing all / none.
_G.stockhook_type_gen = _G.stockhook_type_gen or 0

local type_failed = {}
-- Switches group on for pile through the importer. Returns true, or false
-- and why.
local function import_group(pile, group)
    local st, misc = pile.storage, pile.settings.misc
    local keep = {
        bins = st.max_bins, barrels = st.max_barrels, wheelbarrows = st.max_wheelbarrows,
        organic = misc.allow_organic, inorganic = misc.allow_inorganic,
        links = pile.stockpile_flag.whole,
    }
    local ok, err = pcall(function()
        require('plugins.stockpiles').import_settings(
            'library/' .. (LIBRARY_FILE[group] or ('cat_' .. group)),
            { id = pile.id, mode = 'enable', filters = { NO_MATCH } })
    end)
    st.max_bins, st.max_barrels, st.max_wheelbarrows = keep.bins, keep.barrels, keep.wheelbarrows
    misc.allow_organic, misc.allow_inorganic = keep.organic, keep.inorganic
    pile.stockpile_flag.whole = keep.links
    _G.stockhook_type_gen = _G.stockhook_type_gen + 1
    if not ok then return false, tostring(err) end
    if not pile.settings.flags[group] then return false, 'importer left the group off' end
    return true
end

-- The settings group a CATEGORY belongs to: the group whose name starts the
-- list name (BARS_OTHER -> bars_blocks). The same table as refinish-stockhook-rows.lua
-- uses for its all / none.
local GROUP_OF_PREFIX = {
    { 'BARS', 'bars_blocks' }, { 'BLOCKS', 'bars_blocks' }, { 'GOODS', 'finished_goods' },
    { 'FURNITURE', 'furniture' }, { 'STONE', 'stone' }, { 'AMMO', 'ammo' },
    { 'WEAPONS', 'weapons' }, { 'ARMOR', 'armor' }, { 'FOOD', 'food' },
    { 'REFUSE', 'refuse' }, { 'LEATHER', 'leather' }, { 'THREAD', 'cloth' },
    { 'CLOTH', 'cloth' }, { 'SHEET', 'sheet' }, { 'GEMS', 'gems' }, { 'ROUGH', 'gems' },
    { 'CUT', 'gems' }, { 'WOOD', 'wood' }, { 'CORPSES', 'corpses' }, { 'COINS', 'coins' },
    { 'ANIMALS', 'animals' },
}
-- ---- THE COLOUR ROWS: LISTS ----
-- A category or list name to its df.stockpile_list value, matched as
-- refinish-stockhook-rows.lua matches them (case and underscores ignored).
local function norm_list(n) return tostring(n or ''):upper():gsub('_', '') end
local LIST_BY_NAME = {}
for i = df.stockpile_list._first_item, df.stockpile_list._last_item do
    local n = df.stockpile_list[i]
    if n then LIST_BY_NAME[norm_list(n)] = i end
end
function list_of_category(cat) return cat and LIST_BY_NAME[norm_list(cat)] end

-- The lists that are a whole group (the left column of the settings
-- screen): DF colours them from every list of the group, and so does the
-- colour hook with every Stockhook row of the group.
local WHOLE_GROUP = {
    ANIMALS = true, FOOD = true, FURNITURE = true, CORPSES = true, REFUSE = true,
    STONE = true, AMMO = true, COINS = true, BARSBLOCKS = true, GEMS = true,
    GOODS = true, LEATHER = true, CLOTH = true, WOOD = true, WEAPONS = true,
    ARMOR = true, SHEET = true,
}

-- Rows the colour hook counts that are not entries: refinish-stockhook-rows.lua
-- hands over its moved materials' rows, each { list = <stockpile_list>,
-- field = 'furniture.mats', index = <material index> }. commit() writes them.
S.colour_extra = S.colour_extra or {}
function colour_extra(rows) S.colour_extra = rows or {} end

function group_of_category(cat)
    local n = tostring(cat or ''):upper():gsub('_', '')
    for _, pg in ipairs(GROUP_OF_PREFIX) do
        if n:sub(1, #pg[1]) == pg[1] then return pg[2] end
    end
end

-- Types pile in group, unless it already is. A failure is logged once per
-- group and the pile left as it is (it still files: module rows need no
-- group, test 3b).
local function ensure_group(pile, group)
    if not group or pile.settings.flags[group] then return end
    local ok, why = import_group(pile, group)
    if not ok and not type_failed[group] then
        log_line('pile type: ' .. group .. ' not set: ' .. tostring(why))
        type_failed[group] = true
    end
end

-- Exposed for the 'refinish-stockhook type' test command.
function type_pile(pile, group) return import_group(pile, group) end

-- Every module row on for the pile gets its group typed. Called when a row
-- is switched on, and by refinish-stockhook-rows.lua when a pile's settings open (for
-- piles whose rows were on before this existed).
function ensure_types(pile)
    local row = pile_state()[tostring(pile.id)]
    if not row then return end
    for id, on in pairs(row) do
        local e = on and S.entries[id]
        if e and e.kind == 'module' then ensure_group(pile, group_of_category(e.spec.category)) end
    end
end

-- Every pile with a module row on, typed at once. Run on map load (after the
-- definitions are read, so every entry is known) and when a late entry
-- resolves, so a pile shows its type without its settings ever being opened.
-- A pile id in the saved state whose building is gone is skipped.
function ensure_all_types()
    for k in pairs(pile_state()) do
        local p = df.building.find(tonumber(k))
        if p and df.building_stockpilest:is_instance(p) then ensure_types(p) end
    end
end

-- ---- SETTING ROWS ----
-- set_many: every change in one pass, then ONE save, ONE commit and ONE
-- nudge. MEASURED (test 22, 2026-11-02): with the generated rows a group's
-- all / none changes hundreds of rows at once, and setting them one by one
-- (a save of every pile's state, a full commit and an item walk EACH) took
-- over five seconds at the top level. changes: { [entry id] = true/false }.
--
-- TIMED (2026-11-03): each part is timed (os.clock), and a call costing
-- SLOW_SET_MS or more says in RM's log which part it was, so a slow all /
-- none is never a guess again.
local SLOW_SET_MS = 20
function set_many(pile, changes)
    if type(pile) == 'number' then pile = df.building.find(pile) end
    assert(pile and df.building_stockpilest:is_instance(pile), 'set: not a stockpile')
    local t0 = os.clock()
    local st = pile_state()
    local t_read = os.clock()
    local k = tostring(pile.id)
    st[k] = st[k] or {}
    local turned_on = {}
    for id, on in pairs(changes) do
        local e = S.entries[id]
        -- A part row switched off is kept as false, not dropped: an absent
        -- part row is one PART ROWS has yet to start from the vanilla row.
        if on then st[k][id] = true
        elseif e and e.spec.part_of then st[k][id] = false
        else st[k][id] = nil end
        if on and e then
            turned_on[id] = true
            ensure_containers(pile, e.spec.container)
            if e.kind == 'module' then ensure_group(pile, group_of_category(e.spec.category)) end
        end
    end
    local t_rows = os.clock()
    pile_state_save(st)          -- READ ONCE, NOT AT EVERY CALL
    local t_save = os.clock()
    -- ONE PILE, NOT EVERYTHING; everything when the pile is not listed yet.
    local whole = not commit_pile(pile, st)
    if whole then commit() end
    local t_write = os.clock()
    local nudged = next(turned_on) and nudge(turned_on) or 0
    local t_end = os.clock()
    local n = 0
    for _ in pairs(changes) do n = n + 1 end
    if (t_end - t0) * 1000 >= SLOW_SET_MS then
        log('WARNING', ('set_many: %d change(s) in pile #%s took %.0f ms: state read %.0f, rows and'
            .. ' types %.0f, save %.0f, %s %.0f, nudge %.0f (%d item(s)).'):format(n,
            tostring(pile.stockpile_number), (t_end - t0) * 1000, (t_read - t0) * 1000,
            (t_rows - t_read) * 1000, (t_save - t_rows) * 1000,
            whole and 'full commit' or 'pile written', (t_write - t_save) * 1000,
            (t_end - t_write) * 1000, nudged), 'PERF')
    end
end

-- One row: set_many with one change.
function set(pile, id, on)
    set_many(pile, { [id] = on and true or false })
end

-- A row's value in a pile. A part the player never set follows its vanilla
-- entry (PART ROWS), so its value is read from the pile's own settings.
function get(pile, id)
    if type(pile) == 'number' then pile = df.building.find(pile) end
    local st = pile_state()
    local row = st[tostring(pile.id)]
    local v = row and row[id]
    if v ~= nil then return v end
    local e = S.entries[id]
    if e and e.spec.part_of then return part_vanilla(pile, e.spec.part_of) end
    return false
end

-- get for many entries of one pile: the saved state is read ONCE, and the
-- function returned answers each id as get does. For the settings screen
-- opening, which asks for every row (refinish-stockhook-rows.lua, load_pile).
function getter(pile)
    if type(pile) == 'number' then pile = df.building.find(pile) end
    local row = pile_state()[tostring(pile.id)]
    return function(id)
        local v = row and row[id]
        if v ~= nil then return v end
        local e = S.entries[id]
        if e and e.spec.part_of then return part_vanilla(pile, e.spec.part_of) end
        return false
    end
end

-- Parts back to following their vanilla entry in a pile (their stored
-- values dropped), then one commit. Used when the vanilla row is clicked:
-- every part takes its value from then on (refinish-stockhook-rows.lua, VANILLA ROW
-- CLICKS).
function unset(pile, ids)
    local st = pile_state()
    local row = st[tostring(pile.id)]
    if row then
        for _, id in ipairs(ids) do row[id] = nil end
        pile_state_save(st)      -- READ ONCE, NOT AT EVERY CALL
    end
    -- ONE PILE, NOT EVERYTHING; everything when the pile is not listed yet.
    if not commit_pile(pile, st) then commit() end
end

-- ==========================================
-- MATERIAL ALIASES
-- ==========================================
-- A material that files as another, for one stockpile check at a time:
-- a hidden twin as its source (Making Fuel's fuel wood twin of oak as oak
-- WOOD; RM's stone twins as their stones). The DLL gives the item its source
-- material while claims are matched and DF's own check runs, and puts the
-- item's fields back before it returns (stockhook_dll.cpp, MATERIAL ALIAS).
-- So oak kindling is "kindling" (its type row) of "oak" (DF's own Wood
-- entry, or any material row), with no material row of its own and no flag
-- windows.
--   alias(owner, { plant = { { from = 'MAKING_FUEL_FUELWOOD', to = 'WOOD' } } })
--       on every plant that has both, material `from` files as `to`
--   alias(owner, { pairs = { { fmt, fmi, tmt, tmi } } })
--       explicit material pairs (type, index)
--   alias(owner, nil) removes an owner's aliases.
-- Rules are expanded at every commit, so twins made at load are found.
function alias(owner, spec) S.aliases[owner] = spec end

-- The inorganic materials some owner aliases away (RM's stone twins), as
-- material indexes: their own settings entries decide nothing while the
-- hook is live (refinish-stockhook-rows.lua, HIDDEN BYTES).
function inorganic_twins()
    local out, seen = {}, {}
    for _, spec in pairs(S.aliases) do
        for _, p in ipairs(spec.pairs or {}) do
            if p[1] == 0 and p[2] and not seen[p[2]] then seen[p[2]] = true; out[#out + 1] = p[2] end
        end
    end
    return out
end

-- The slot a pair starts probing at: the DLL's alias_hash, exactly.
local function alias_hash(mt, mi)
    local a = ((mt & 0xFFFF) * 2654435761) & 0xFFFFFFFF
    local b = ((mi & 0xFFFFFFFF) * 40503) & 0xFFFFFFFF
    return (a ~ b) & (ALIAS_SLOTS - 1)
end

-- Every from -> to pair the rules name, as { fmt, fmi, tmt, tmi }.
local function alias_pairs()
    local out = {}
    local plant_rules = {}
    for _, spec in pairs(S.aliases) do
        for _, r in ipairs(spec.plant or {}) do plant_rules[#plant_rules + 1] = r end
        for _, p in ipairs(spec.pairs or {}) do out[#out + 1] = p end
    end
    if #plant_rules > 0 then
        -- A plant material's type is 419 + its index in plant.material, and
        -- its index is the plant's (DF's material numbering for plants, as
        -- Making Fuel's twin push and RM's window claims use it).
        for pi, plant in ipairs(df.global.world.raws.plants.all) do
            local by_id = {}
            for mi, mat in ipairs(plant.material) do by_id[mat.id] = mi end
            for _, r in ipairs(plant_rules) do
                local f, t = by_id[r.from], by_id[r.to]
                if f and t then out[#out + 1] = { 419 + f, pi, 419 + t, pi } end
            end
        end
    end
    return out
end

-- Per item type, where its class keeps mat_type and mat_index: DFHack's
-- field table for the item class (item_toolst for TOOL), which lists
-- inherited fields with their offsets in the object (LuaTypes.cpp,
-- IndexFields walks the parents). 0 when a type has no such fields.
local mat_off_cache = nil
local function mat_offsets()
    if mat_off_cache then return mat_off_cache end
    mat_off_cache = {}
    for t = 0, df.item_type._last_item do
        local name = df.item_type[t]
        if name then
            pcall(function()
                local cls = df['item_' .. name:lower() .. 'st']
                local f1, f2 = cls._fields.mat_type, cls._fields.mat_index
                if f1 and f2 and f1.offset and f2.offset then
                    mat_off_cache[t] = { f1.offset, f2.offset }
                end
            end)
        end
    end
    return mat_off_cache
end

-- ==========================================
-- PART ROWS
-- ==========================================
-- A part row ([PART_OF:BARS:COAL] in a definition file) splits a vanilla
-- entry: Coke and Charcoal rows as parts of the vanilla Coal row. spec.
-- part_of = { group, vector, index }: the vanilla entry's byte, found as a
-- FOLLOW target is (refinish-stockhook-defs.lua).
--   * An item a part claims is decided by the part's row alone (it is a
--     module row): Coal on, Green coke off excludes green coke.
--   * The vanilla row stays the wildcard: every coal no part claims still
--     follows it, whatever mod made it.
--   * Clicking the vanilla row sets all its parts to its new value
--     (refinish-stockhook-rows.lua, VANILLA ROW CLICKS).
--   * A part the player never set FOLLOWS its vanilla row, read live by the
--     DLL (part_value): a new part changes nothing a pile already takes,
--     and a pile stores nothing for the many generated parts it never
--     touched. Only parts the player set are stored (true or false).

-- The vanilla entry's value in a pile: true or false.
local function vanilla_value(pile, part)
    local ref = pile.settings
    for field in part.vector:gmatch('[^%.]+') do ref = ref[field] end
    if part.index < 0 or part.index >= #ref then return false end
    local v = ref[part.index]
    return v == true or (type(v) == 'number' and v ~= 0)
end
function part_vanilla(pile, part) return vanilla_value(pile, part) end

-- Formerly wrote every pile's part rows from their vanilla rows. Parts now
-- follow their vanilla entry until the player sets them (the DLL reads the
-- vanilla byte live: part_value), so nothing is written; kept so callers
-- need no change.
function init_parts() end

-- ==========================================
-- COMMIT: everything into the block
-- ==========================================
-- Runs on the game thread, as the hook does, so the hook never sees a half
-- written table. 'enabled' is dropped first and raised last anyway.
local last_err = nil
function commit()
    local base, why = block()
    if not base then
        if why ~= last_err then log_line('not active: ' .. why, 'WARNING'); last_err = why end
        return false, why
    end
    last_err = nil
    poke('uint32_t', base + OFF.enabled, 0)
    local L = settings_layout()

    -- ---- ENTRIES ----
    for i, id in ipairs(S.entry_order) do
        local e, a = S.entries[id], base + OFF.entries + (i - 1) * ENTRY_SZ
        local sp = e.spec
        poke('uint8_t',  a + 0, KIND[sp.kind])
        -- A part row carries its vanilla entry's byte and group, for
        -- settings that are not a listed pile (stockhook_dll.cpp, EF_PART).
        local part = sp.part_of
        local group = part and part.group or sp.group
        local vector = part and part.vector or sp.vector
        local index = part and part.index or sp.index
        -- part.vanilla_item: DF itself files these items under the vanilla
        -- entry; the pile's other settings still apply (EF_VANILLA_ITEM).
        poke('uint8_t',  a + 1, (sp.also_vanilla and EF_ALSO_VANILLA or 0) | (part and EF_PART or 0)
                                | ((part and part.vanilla_item) and EF_VANILLA_ITEM or 0))
        poke('uint16_t', a + 2, S.bits[id] or 0)
        poke('uint32_t', a + 4, group and L.group_mask(group) or 0)
        poke('uint32_t', a + 8, vector and L.vec_off(vector) or 0)
        poke('uint32_t', a + 12, index or 0)
    end
    poke('uint32_t', base + OFF.n_entries, #S.entry_order)

    -- ---- CLAIMS, grouped by item type, most specific first ----
    local by_type = {}
    for _, rows in pairs(S.claims) do
        for _, r in ipairs(rows) do
            local e = S.entries[r.entry]
            if e and r.item_type and r.item_type >= 0 and r.item_type < 256 then
                local t = by_type[r.item_type] or {}
                by_type[r.item_type] = t
                t[#t + 1] = r
            end
        end
    end
    -- Fewer wildcards = more specific = earlier. A mat_index of -1 with
    -- exact_index set means "exactly -1" (refined coal), not "any", and is
    -- no wildcard. Between claims equally specific, the higher seq wins:
    -- seq is the definition's place in reading order (refinish-stockhook-defs.lua:
    -- mods in load order, then the player's files, then the world's), so a
    -- later mod overrides an earlier one, and the player overrides mods,
    -- as in DF's own load order. Claims made through the API carry seq 0.
    local function wild(r)
        return ((r.subtype or -1) == -1 and 1 or 0) + ((r.mat_type or -1) == -1 and 1 or 0)
            + (((r.mat_index or -1) == -1 and not r.exact_index) and 1 or 0)
    end
    local function before(x, y)
        local wx, wy = wild(x), wild(y)
        if wx ~= wy then return wx < wy end
        return (x.seq or 0) > (y.seq or 0)
    end
    local n = 0
    for t = 0, 255 do
        local list = by_type[t]
        local start = n
        if list then
            table.sort(list, before)
            for _, r in ipairs(list) do
                if n >= MAX_CLAIMS then error('stockhook: claim table full') end
                local a = base + OFF.claims + n * CLAIM_SZ
                poke('int16_t',  a + 0, t)
                poke('int16_t',  a + 2, r.subtype or -1)
                poke('int16_t',  a + 4, r.mat_type or -1)
                poke('uint16_t', a + 6, S.entries[r.entry].index)
                poke('int32_t',  a + 8, r.mat_index or -1)
                poke('int32_t',  a + 12, r.exact_index and 1 or 0)   -- CF_EXACT_INDEX
                n = n + 1
            end
        end
        poke('uint32_t', base + OFF.type_start + t * 4, start)
        poke('uint32_t', base + OFF.type_count + t * 4, n - start)
    end
    poke('uint32_t', base + OFF.n_claims, n)

    -- ---- PILES: settings address and module bits ----
    local st = pile_state()
    local np = 0
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
        if np >= MAX_PILES then break end
        local a = base + OFF.piles + np * PILE_SZ
        poke('uint64_t', a, addr_of(b.settings))
        -- Only the bytes module bits are in use are written (ONE PILE'S BITS).
        write_pile_bits(a, st[tostring(b.id)])
        np = np + 1
    end
    poke('uint32_t', base + OFF.n_piles, np)

    -- ---- MATERIAL ALIASES ----
    -- The hash is cleared and refilled; the DLL reads it only while
    -- 'enabled' is 1, and enabled is still 0 here.
    for i = 0, ALIAS_SLOTS - 1 do poke('uint32_t', base + OFF.aliases + i * ALIAS_SZ + 12, 0) end
    local na = 0
    local pairs_list = alias_pairs()
    if #pairs_list > 0 then
        local mo = mat_offsets()
        for t = 0, 255 do
            local o = mo[t]
            poke('uint16_t', base + OFF.mat_off + t * 4, o and o[1] or 0)
            poke('uint16_t', base + OFF.mat_off + t * 4 + 2, o and o[2] or 0)
        end
        for _, p in ipairs(pairs_list) do
            if na >= ALIAS_SLOTS // 2 then break end   -- keep the table half empty
            local h = alias_hash(p[1], p[2])
            while peek('uint32_t', base + OFF.aliases + h * ALIAS_SZ + 12) ~= 0 do
                h = (h + 1) & (ALIAS_SLOTS - 1)
            end
            local a = base + OFF.aliases + h * ALIAS_SZ
            poke('int16_t', a + 0, p[1]); poke('int16_t', a + 2, p[3])
            poke('int32_t', a + 4, p[2]); poke('int32_t', a + 8, p[4])
            poke('uint32_t', a + 12, 1)
            na = na + 1
        end
    end
    poke('uint32_t', base + OFF.n_alias, na)

    -- ---- THE COLOUR ROWS ----
    -- Each list's group flag (bit 31 for a whole group), then one row per
    -- Stockhook row shown in a list: every module entry with a category,
    -- and the moved materials' rows (colour_extra). The DLL folds them into
    -- DF's category colour (stockhook_dll.cpp, THE COLOUR HOOK).
    for i = 0, N_LISTS - 1 do
        local name = df.stockpile_list[i]
        local info = 0
        if name then
            local g = group_of_category(name)
            if g then
                local okm, m = pcall(L.group_mask, g)
                if okm and m then info = m end
            end
            if WHOLE_GROUP[norm_list(name)] then info = info | 0x80000000 end
        end
        poke('uint32_t', base + OFF.list_info + i * 4, info)
    end
    local nc = 0
    local function colour_row(list, kind, entry, gmask, voff, vidx)
        if nc >= MAX_COLOUR or not list or list < 0 or list >= N_LISTS then return end
        local a = base + OFF.colour + nc * COLOUR_SZ
        poke('uint8_t',  a + 0, list)
        poke('uint8_t',  a + 1, kind)
        poke('uint16_t', a + 2, entry or 0)
        poke('uint32_t', a + 4, gmask or 0)
        poke('uint32_t', a + 8, voff or 0)
        poke('uint32_t', a + 12, vidx or 0)
        nc = nc + 1
    end
    for _, id in ipairs(S.entry_order) do
        local e = S.entries[id]
        local cat = e.kind == 'module' and e.spec.category
        local list = cat and list_of_category(cat)
        if list then
            local g = group_of_category(cat)
            local okm, m = pcall(function() return g and L.group_mask(g) or 0 end)
            colour_row(list, CR_ENTRY, e.index, okm and m or 0, 0, 0)
        end
    end
    for _, r in ipairs(S.colour_extra or {}) do
        local okv, voff = pcall(L.vec_off, r.field)
        local g = group_of_category(df.stockpile_list[r.list])
        local okm, m = pcall(function() return g and L.group_mask(g) or 0 end)
        if okv and voff then colour_row(r.list, CR_BYTE, 0, okm and m or 0, voff, r.index) end
    end
    poke('uint32_t', base + OFF.n_colour, nc)

    -- ---- THE LIST COUNT (layout 6) ----
    -- The DLL read the highest list DF's colour function handles
    -- (list_max: 108 in 53.16 and 53.17). list_info and the colour rows are
    -- numbered by DFHack's stockpile_list, so they mean what DF means only
    -- if DFHack knows every list DF handles: list_max may not pass
    -- df.stockpile_list._last_item. It is a bound, not an equality:
    -- DFHack's enum runs one further than DF's switch (AdditionalOptions,
    -- 109, which the colour function does not colour). 0: the colour hook
    -- is not in place. The DLL's colour hook folds nothing while colour_ok
    -- is 0.
    local list_max = peek('uint32_t', base + OFF.list_max)
    local colour_ok = list_max > 0 and list_max <= df.stockpile_list._last_item
    poke('uint32_t', base + OFF.colour_ok, colour_ok and 1 or 0)
    if list_max > 0 and not colour_ok and not S.list_warned then
        S.list_warned = true
        log_line(("DF colours stockpile lists up to %d, DFHack knows lists up to %d: categories"
            .. " keep DF's own colours for Stockhook rows until the two agree.")
            :format(list_max, df.stockpile_list._last_item), 'WARNING')
    end

    poke('uint32_t', base + OFF.enabled, 1)
    return true
end

-- ==========================================
-- DIAGNOSTICS
-- ==========================================
function stats()
    local base = block()
    if not base then return nil end
    return {
        calls = peek('int64_t', base + OFF.calls), yes = peek('int64_t', base + OFF.yes),
        no = peek('int64_t', base + OFF.no), passed = peek('int64_t', base + OFF.passed),
        claims = peek('uint32_t', base + OFF.n_claims), entries = peek('uint32_t', base + OFF.n_entries),
        piles = peek('uint32_t', base + OFF.n_piles), enabled = peek('uint32_t', base + OFF.enabled),
        aliases = peek('uint32_t', base + OFF.n_alias),
        colour_hooked = peek('uint32_t', base + OFF.colour_hooked),
        colour_calls = peek('int64_t', base + OFF.colour_calls),
        colour_rows = peek('uint32_t', base + OFF.n_colour),
        -- layout 6: THE AUTOMATIC TARGET and THE LIST COUNT
        automatic = peek('uint32_t', base + OFF.automatic),
        list_max = peek('uint32_t', base + OFF.list_max),
        colour_ok = peek('uint32_t', base + OFF.colour_ok),
    }
end

-- What the DLL will see for one pile: whether its settings address is
-- listed in the block, and the module bit for entry id as committed there.
function inspect_pile(pile, id)
    local base, why = block()
    if not base then return nil, why end
    local want = addr_of(pile.settings)
    local n = peek('uint32_t', base + OFF.n_piles)
    local out = { settings = want, listed = false, bit_index = S.bits[id], bit = nil }
    for i = 0, n - 1 do
        local a = base + OFF.piles + i * PILE_SZ
        if peek('uint64_t', a) == want then
            out.listed = true
            local bit = S.bits[id]
            if bit then
                out.bit = (peek('uint8_t', a + 8 + (bit // 8)) >> (bit % 8)) & 1
            end
            break
        end
    end
    return out
end

-- ==========================================
-- THE PILE WATCH
-- ==========================================
-- A pile made or removed changes the pile table, so the set of pile ids is
-- compared every 100 frames and a change recommits. Self-chained
-- dfhack.timeout, as RM's loops are.
local function pile_sig()
    local ids = {}
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do ids[#ids + 1] = b.id end
    return table.concat(ids, ',')
end

-- gen: the watch's generation. A chain whose generation is not the current
-- one ends: a world unload, or a second start, retires every older chain.
-- The raws the definitions were resolved against. RM's save cycle removes
-- and re-appends its injected tools and materials, which can move their
-- positions (refinish-module-react.lua, ITEMDEF CACHE INVALIDATION); a
-- claim holds positions, so when these counts change the definition files
-- are read again (refinish-stockhook-defs.lua reload).
local function raws_sig()
    local r = df.global.world.raws
    return ('%d:%d:%d'):format(#r.itemdefs.tools, #r.inorganics.all, #r.plants.all)
end

local function watch(gen)
    if gen ~= _G.stockhook_watch_gen then return end
    if dfhack.isMapLoaded() then
        local rs = raws_sig()
        if _G.stockhook_raws_sig and rs ~= _G.stockhook_raws_sig then
            _G.stockhook_raws_sig = rs
            pcall(function() reqscript('refinish-stockhook-defs').reload(false) end)
        end
        _G.stockhook_raws_sig = rs
        local sig = pile_sig()
        if sig ~= _G.stockhook_pile_sig then
            _G.stockhook_pile_sig = sig
            commit()
        end
    end
    dfhack.timeout(100, 'frames', function() watch(gen) end)
end

function start_watch()
    if _G.stockhook_watching then return end
    _G.stockhook_watching = true
    _G.stockhook_watch_gen = (_G.stockhook_watch_gen or 0) + 1
    _G.stockhook_pile_sig = nil
    local gen = _G.stockhook_watch_gen
    dfhack.timeout(1, 'frames', function() watch(gen) end)
end

-- ==========================================
-- ONE WORLD ONLY: STOCKHOOK LEAVES NOTHING BEHIND
-- ==========================================
-- Stockhook works only in a world that has RM in its load order.
--
-- MEASURED (test 11, stockhook-sc-probe, 2026-11-01): DFHack runs a
-- module script's top level ONCE A SESSION. Its scripts load at the first
-- world load that has Stockhook (script-manager reload at
-- SC_WORLD_LOADED); at a later world load in the same session they were
-- on the path again but were not run again, so handlers removed at an
-- unload never came back. Handlers therefore stay for the whole session
-- once registered, and every one of them asks world_active() first and
-- does nothing in a world without Stockhook: no loops start, nothing is
-- read, the hook stays disabled. In a session that never loads a Stockhook
-- world, none of this is ever loaded.
--
-- What must not outlive a world goes at every unload:
--   * the hook is disabled first (DF answers every pile check itself; the
--     DLL stays loaded for the session, costing one compare per check);
--   * the pile watch, the rows loop and the definition retry end (each
--     checks its generation number and stops);
--   * entries, claims and bits are emptied (reset_state), and the
--     definition files' state with them.
-- The next Stockhook world reads its own definitions and its own saved
-- pile settings (site data, kept inside the save).
local function stop_all()
    local base = block()
    if base then poke('uint32_t', base + OFF.enabled, 0) end
    _G.stockhook_watching = false
    _G.stockhook_watch_gen = (_G.stockhook_watch_gen or 0) + 1
    _G.stockhook_pile_sig = nil
    _G.stockhook_raws_sig = nil
    pcall(function() reqscript('refinish-stockhook-rows').stop() end)
end

if dfhack_flags and dfhack_flags.module then
    dfhack.onStateChange.stockhook = function(code)
        if code == SC_MAP_UNLOADED then
            -- The fort is gone: the hook decides nothing, the loops end.
            stop_all()
        elseif code == SC_WORLD_UNLOADED then
            stop_all()
            reset_state()                  -- entries, claims, bits
            PS.raw, PS.tbl = nil, nil      -- READ ONCE: the next world reads its own
            pcall(function() reqscript('refinish-stockhook-defs').reset() end)
        end
    end
    return
end

-- ==========================================
-- COMMANDS (run from the console, not as a module)
-- ==========================================
local args = { ... }

-- A pile by the number DF shows ("Stockpile #12"), or by building id.
local function find_pile(n)
    n = tonumber(n)
    if not n then return nil end
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
        if b.stockpile_number == n then return b end
    end
    local b = df.building.find(n)
    if b and df.building_stockpilest:is_instance(b) then return b end
end

local function cmd_status()
    local ok, why = available()
    print(ok and 'Stockhook is active.' or ('Stockhook is NOT active: ' .. why))
    local st = stats()
    if st then
        print(('  %d entr(ies), %d claim(s), %d pile(s) listed, %d material alias(es); hook enabled %d'):format(
            st.entries, st.claims, st.piles, st.aliases, st.enabled))
        print(('  calls %d: answered yes %d, no %d; passed to DF %d'):format(st.calls, st.yes, st.no, st.passed))
        print(('  colour hook %s: %d row(s), %d call(s); DF colours lists 0 to %d, list count %s'):format(
            st.colour_hooked == 1 and 'installed' or 'NOT installed', st.colour_rows, st.colour_calls,
            st.list_max, st.colour_ok == 1 and 'agreed with DFHack' or 'NOT agreed with DFHack'))
        print(st.automatic == 1
            and ("  this DF build is not listed in stockhook_targets.txt: the DLL verified it and hooked"
                .. " it (stockhook.log, in DF's folder, has the line that lists it)")
            or '  this DF build is listed (built in, or a line in stockhook_targets.txt)')
    end
    for _, e in ipairs(entries()) do
        print(('  %-32s %-6s %s%s'):format(e.id, e.kind, e.label,
            e.category and (' [' .. e.category .. ']') or ''))
    end
end

local function cmd_piles()
    local st = pile_state()
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
        local on = {}
        for id, v in pairs(st[tostring(b.id)] or {}) do if v then on[#on + 1] = id end end
        table.sort(on)
        print(('  Stockpile #%d: %s'):format(b.stockpile_number,
            #on > 0 and table.concat(on, ', ') or '(no rows on)'))
    end
end

local function cmd_set(n, id, onoff)
    local b = find_pile(n)
    if not b or not id or (onoff ~= 'on' and onoff ~= 'off') then
        qerror('usage: refinish-stockhook set <pile number> <entry id> on|off')
    end
    id = id:upper()
    local e = S.entries[id]
    if not e then qerror('no entry ' .. id .. ' (see "refinish-stockhook status")') end
    if e.kind ~= 'module' then qerror(id .. ' is a ' .. e.kind .. ' entry: piles have no row for it') end
    set(b, id, onoff == 'on')
    print(('Stockpile #%d: %s %s'):format(b.stockpile_number, id, onoff))
end

-- ---- TEST: TYPE A PILE IN ANY GROUP ----
-- refinish-stockhook type <pile number> <group>: switches the group on through
-- DFHack's importer (THE PILE'S TYPE) and reports what changed. For a
-- throwaway pile: the group stays on afterwards, every vanilla entry off.
-- refinish-stockhook type <pile number> none: switches every group of the pile off
-- again (only the flags; switching a group off is always safe, the crash
-- rule is about switching one on).
local GROUPS = { 'animals', 'food', 'furniture', 'corpses', 'refuse', 'stone', 'ammo',
    'coins', 'bars_blocks', 'gems', 'finished_goods', 'leather', 'cloth', 'wood',
    'weapons', 'armor', 'sheet' }
local function cmd_type(n, group)
    local b = find_pile(n)
    if b and group == 'none' then
        b.settings.flags.whole = 0
        print(('Stockpile #%d: every group off'):format(b.stockpile_number))
        return
    end
    local known = false
    for _, g in ipairs(GROUPS) do if g == group then known = true end end
    if not b or not known then
        qerror('usage: refinish-stockhook type <pile number> <group>|none; groups: ' .. table.concat(GROUPS, ' '))
    end
    local function snap()
        local st, misc = b.storage, b.settings.misc
        return ('bins %d barrels %d wheelbarrows %d organic %s inorganic %s links %d'):format(
            st.max_bins, st.max_barrels, st.max_wheelbarrows, tostring(misc.allow_organic),
            tostring(misc.allow_inorganic), b.stockpile_flag.whole)
    end
    local before, flags_before = snap(), b.settings.flags.whole
    local ok, why = type_pile(b, group)
    print(('Stockpile #%d, %s: %s'):format(b.stockpile_number, group, ok and 'typed' or ('FAILED: ' .. tostring(why))))
    print(('  group flags %d -> %d'):format(flags_before, b.settings.flags.whole))
    local after = snap()
    print('  containers and general ' .. (after == before and 'unchanged' or ('CHANGED: ' .. before .. ' -> ' .. after)))
    -- Each list of the group: its length, and how many slots read 1 (DF
    -- keeps 1 in slots the group cannot hold, so 1s here are not entries
    -- switched on; the settings screen shows what is on).
    for k, v in pairs(b.settings[group]) do
        if type(v) == 'userdata' and v._kind == 'container' then
            local ones = 0
            for i = 0, #v - 1 do
                local x = v[i]
                if x == true or (type(x) == 'number' and x ~= 0) then ones = ones + 1 end
            end
            print(('  %-18s length %6d, ones %6d'):format(k, #v, ones))
        end
    end
end

local cmd = args[1]
if cmd == 'status' or not cmd then cmd_status()
elseif cmd == 'reload' then reqscript('refinish-stockhook-defs').reload(true)
elseif cmd == 'paths' then reqscript('refinish-stockhook-defs').paths()
elseif cmd == 'piles' then cmd_piles()
elseif cmd == 'set' then cmd_set(args[2], args[3], args[4])
elseif cmd == 'type' then cmd_type(args[2], args[3])
elseif cmd == 'rows' then reqscript('refinish-stockhook-rows').dump()
elseif cmd == 'install' then
    -- Copy the DLL from the mod folder now (refinish-stockhook-install.lua); the
    -- same check runs on its own at every map load.
    local what, why = reqscript('refinish-stockhook-install').check(false)
    print(what and ('DLL ' .. what .. (what == 'current' and '' or '; close DF completely and start it again to finish.'))
               or ('Not installed: ' .. tostring(why)))
elseif cmd == 'uninstall' then
    -- DF stops loading the DLL from the next launch. Loading a fort with
    -- RM in its load order installs it again.
    local ok, why = reqscript('refinish-stockhook-install').uninstall()
    print(ok and 'DLL removed; DF no longer loads it from the next launch. Loading an RM fort installs it again.'
             or ('Nothing removed: ' .. tostring(why)))
else print('refinish-stockhook status | reload | paths | piles | set <pile number> <entry id> on|off | type <pile number> <group> | rows | install | uninstall') end