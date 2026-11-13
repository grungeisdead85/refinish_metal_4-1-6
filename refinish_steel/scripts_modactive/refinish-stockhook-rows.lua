--@ module = true
-- refinish-stockhook-rows.lua
-- ==========================================
-- STOCKHOOK ROWS: module entries as native rows in DF's pile settings
-- ==========================================
-- WHAT: puts every module entry (a mod's own stockpile row, e.g. Cinders)
-- into DF's own settings list for a pile, in the list its CATEGORY names:
-- "Cinders" sits in Bars: other materials beside Coal and Soap. DF draws it,
-- clicks it and lists it like its own rows. Each click is saved for that
-- pile and applied at once (stockhook.set: save, commit, bins, nudge).
-- No overlay: the rows ARE DF's rows.
--
-- HOW A ROW WORKS (df.d_interface.xml, custom_stockpile_itemst): a row is a
-- name plus set_pointer, the byte a click flips. A Stockhook row's
-- set_pointer aims at a byte in BUF (below), one per module entry, loaded
-- from the pile's saved state when its settings open.
--
-- MEASURED (stockhook-rows-probe, 2026-11-01):
--   * custom_stockpile.spec_item is a POOL of DF-allocated rows (3346 in
--     that fort). A list switch reorders it so the list's rows come first
--     and sets cur_spec_item_sz. Rows are BORROWED from the spare part of
--     the pool (past cur_spec_item_sz) and the count raised. When the pool
--     has no spare row (it can be exactly as long as the list, test 17), one
--     more DF row is made and added to its end (insert_rows, NO SPARE ROW);
--     DF frees it with the rest of the pool. A list switch drops the rows;
--     they are put back the frame the list is seen again.
--   * a click flips the byte (confirmed in play); search typing never
--     rebuilds the list, it only sets each live row's 'on' and sets
--     counted_cur_spec_item_sz. DF's filter does NOT read a borrowed row's
--     name (filter "C" kept Coal and hid "Cinders"), so after DF, this file
--     sets its rows' 'on' by name and corrects the count. The filter string
--     is held upper-cased (spec_filter "CIN").
--   * all / none on the list itself reaches the rows (it goes through
--     them); all / none on a whole category or the top level writes DF's
--     settings directly and does not. GROUP ALL / NONE, below, makes the
--     rows follow those buttons.
--
-- RUNS while a pile's settings are open, every frame, on 'frames' timeouts
-- (raw frames: they run while the game is paused, as it is on this screen).
--
-- API: start(), stop()

local sh = reqscript('refinish-stockhook')

local MAX_ROWS = 4096              -- one byte per module entry, at most (DLL MAX_ENTRIES)
-- ---- RM'S LOG ----
-- Through refinish-stockhook.lua's log (RM'S LOG there): RM's session
-- log, no console prints.
local function log_line(msg, typ)
    sh.log(typ or 'INFO', msg, 'ROWS')
end

-- The bytes the rows toggle: allocated once, kept on _G, never freed, so a
-- row's set_pointer can never point at released memory.
_G.stockhook_rows = _G.stockhook_rows or { buf = df.new('int8_t', MAX_ROWS), running = false }
local R = _G.stockhook_rows

local function addr_of(ref) local _, a = ref:sizeof(); return a end
local BUF_LO = addr_of(R.buf)
local BUF_HI = BUF_LO + MAX_ROWS

-- ==========================================
-- CATEGORY -> DF LIST
-- ==========================================
-- [CATEGORY:...] names one of DF's settings lists (df.stockpile_list), the
-- way DF names them, with case and underscores ignored: BARS_OTHER and
-- BarsOther are the same list.
local function norm(s) return tostring(s or ''):upper():gsub('_', '') end

local LIST_BY_NAME = {}
for i = df.stockpile_list._first_item, df.stockpile_list._last_item do
    local n = df.stockpile_list[i]
    if n then LIST_BY_NAME[norm(n)] = i end
end

-- The settings group a list belongs to, for GROUP ALL / NONE and the pile's
-- type: the group whose name starts its list name (BarsOther ->
-- bars_blocks). One table, in refinish-stockhook.lua (group_of_category).
local function group_of_list(list)
    return sh.group_of_category(df.stockpile_list[list])
end

-- ==========================================
-- THE ROWS FOR ONE PILE
-- ==========================================
-- slots: one per module entry that has a list. Rebuilt when the entries
-- change (a reload) or another pile is opened.
--
-- ORDER. Slots are sorted by label (case ignored, then id for a tie), so
-- rows of ours go in alphabetically whatever order the files and the raws
-- gave them in; place_rows then moves each among DF's own rows
-- (ALPHABETICAL PLACE). A slot's byte is given after the sort; bytes are
-- only buffer places, loaded from the pile by id (load_pile).
local slots, slot_sig = {}, nil
local function build_slots()
    local out, sig = {}, {}
    for _, e in ipairs(sh.entries()) do
        if e.kind == 'module' and #out < MAX_ROWS then
            local list = e.category and LIST_BY_NAME[norm(e.category)]
            if list then
                out[#out + 1] = { id = e.id, label = e.label, list = list,
                                  group = group_of_list(list),
                                  part_of = e.part_of }
            end
        end
    end
    table.sort(out, function(a, b)
        local la, lb = tostring(a.label):lower(), tostring(b.label):lower()
        if la ~= lb then return la < lb end
        return tostring(a.id) < tostring(b.id)
    end)
    -- The signature: every slot's id and label in shown order, so a renamed
    -- row (a label changed in a file) also rebuilds the slots.
    for i, s in ipairs(out) do
        s.byte = i - 1
        sig[#sig + 1] = s.id .. '=' .. tostring(s.label)
    end
    return out, table.concat(sig, ',')
end

-- ==========================================
-- THE LOOP
-- ==========================================
local open_pile = nil       -- building id of the pile whose bytes are loaded
local last_bytes = {}       -- slot.byte -> value as last seen
-- CLICKS, ONLY WHEN A BYTE MOVED (apply_bytes): a raw copy of the row
-- bytes as apply_bytes last read them, and whether it may be trusted.
local BC = { buf = nil, valid = false }
local group_snap = {}       -- group -> its bytes as last seen (GROUP ALL / NONE)
local warned_full = false

-- Load the open pile's saved state into the bytes.
local master_seen = {}      -- part slot byte -> its vanilla row's value as last seen

local function load_pile(pile)
    -- A pile made since the last pile watch: its part rows start from its
    -- vanilla rows before they are shown (refinish-stockhook.lua, PART ROWS).
    sh.init_parts()
    master_seen = {}
    -- One read of the saved state for every slot (refinish-stockhook.lua,
    -- getter): sh.get read the whole site data once PER SLOT, and with
    -- hundreds of generated rows that held the settings screen up as it
    -- opened (2026-11-02, in play: the button hung before the menu came up).
    local get = sh.getter(pile)
    for _, s in ipairs(slots) do
        local v = get(s.id) and 1 or 0
        R.buf[s.byte] = v
        last_bytes[s.byte] = v
    end
    BC.valid = false        -- CLICKS, ONLY WHEN A BYTE MOVED: read afresh
    open_pile = pile.id
    group_snap = {}
    -- A pile whose rows were on before pile types existed gets its type now
    -- (refinish-stockhook.lua, THE PILE'S TYPE).
    sh.ensure_types(pile)
end

-- Whether a live row is one of ours, and which byte.
local function our_byte(row)
    local p = row.set_pointer
    if not p then return nil end
    local a = addr_of(p)
    if a >= BUF_LO and a < BUF_HI then return a - BUF_LO end
end

-- ---- PUT THE ROWS IN ----
-- Every slot for the shown list that is not among the live rows is put
-- into a borrowed spare pool row, with its siblings' fields copied (so
-- anything DF draws from them looks like theirs).
--
-- borrow_row: one spare pool row made live, named label, its click
-- flipping the byte pointer (an int8_t ref) aims at. Returns the row, or
-- nil when no row could be had (logged once).
local function borrow_row(cs, label, pointer, first)
    local n = cs.cur_spec_item_sz
    -- ---- NO SPARE ROW: GROW THE POOL ----
    -- MEASURED (test 17, refinish-stockhook rows): the pool is not always
    -- large. DF sizes it to the lists built since the screen opened,
    -- so in a fresh session Furniture: type had a pool of exactly its
    -- own 35 rows and Oak beds had nowhere to go; it appeared only
    -- after a long list (Food: fat, 2408 rows) had grown the pool.
    -- So when no spare row is left, one more is made and added to
    -- the pool's end. It is a DF struct made through its type
    -- (df.custom_stockpile_itemst:new(), allocated as DF's own are,
    -- through the runtime both DF and DFHack link), so DF can free
    -- it with the rest of the pool when the screen is done with it.
    if n >= #cs.spec_item then
        local ok, err = pcall(function()
            cs.spec_item:insert('#', df.custom_stockpile_itemst:new())
        end)
        if not ok or n >= #cs.spec_item then
            if not warned_full then
                log_line('no spare settings row for ' .. label .. ': ' .. tostring(err))
                warned_full = true
            end
            return nil
        end
    end
    local row = cs.spec_item[n]
    row.name = label
    row.simple_name = label
    row.set_pointer = pointer
    row.on = true
    if first then
        row.race, row.itype, row.istype = first.race, first.itype, first.istype
        row.isc1, row.isc2 = first.isc1, first.isc2
    end
    cs.cur_spec_item_sz = n + 1
    return row
end

local function insert_rows(cs, list)
    local added = 0
    -- A list holding no rows of ours needs no walk (2026-11-03).
    local mine = false
    for _, s in ipairs(slots) do if s.list == list then mine = true; break end end
    if not mine then return 0 end
    local present = {}
    for i = 0, cs.cur_spec_item_sz - 1 do
        local b = our_byte(cs.spec_item[i])
        if b then present[b] = true end
    end
    local first = cs.cur_spec_item_sz > 0 and cs.spec_item[0] or nil
    for _, s in ipairs(slots) do
        if s.list == list and not present[s.byte] then
            if not borrow_row(cs, s.label, R.buf:_displace(s.byte), first) then return added end
            added = added + 1
        end
    end
    return added
end

-- ==========================================
-- MOVED MATERIALS
-- ==========================================
-- [STOCKHOOK_MOVE:INORGANIC_ID] (refinish-stockhook-defs.lua): a material DF lists
-- in every stone list only because it was made IS_STONE so it would
-- stockpile at all (Making Fuel's dung, straw, papers, soaps...,
-- 2026-11-02). Its DF rows leave those lists, and in each group with an
-- other materials list it shows there instead, as "Dried dung" beside
-- Wood and Bone.
--
-- THE SETTING IS STILL DF'S. A moved row's set_pointer is DF's own entry
-- for the material in that group's inorganic list (finished_goods.mats
-- [index], ...), the byte DF's hidden row flipped, so DF files the items
-- with its own check: no claim, no DLL, nothing saved by Stockhook. Only
-- where the row is drawn changes.
--
-- WHERE. INORG_LISTS is every settings list indexed by inorganic material,
-- and the group's other materials list where its moved rows go. Stone and
-- gems have no such list: their rows of the material are only hidden.
--
-- HIDING. A DF row is hidden by moving it past the live count
-- (cur_spec_item_sz), the part of the pool DF neither draws nor clicks
-- nor searches, and the shown count recounted. DF puts it back only when
-- it builds the list again (a list switch), and it is hidden again then.
local INORG_LISTS = {
    { field = 'stone.mats' },
    { field = 'finished_goods.mats',     other = 'GOODS_OTHER' },
    { field = 'furniture.mats',          other = 'FURNITURE_OTHER_MATERIALS' },
    { field = 'bars_blocks.blocks_mats', other = 'BLOCKS_OTHER' },
    { field = 'ammo.mats',               other = 'AMMO_OTHER' },
    { field = 'weapons.mats',            other = 'WEAPONS_OTHER' },
    { field = 'armor.mats',              other = 'ARMOR_OTHER' },
    { field = 'gems.rough_mats' },
    { field = 'gems.cut_mats' },
}

local moved, moved_mis = {}, {}   -- one per material per target list; the material indexes
local moved_here = {}             -- entry address -> moved row, for the list on screen
local extra_hides = {}            -- other DF rows to hide (refinish-stockhook-defs.lua, row_hides)

-- The definition files' other row hides, with each one's list as a
-- df.stockpile_list value (CLOTHING OUT OF ARMOR in the defs file).
local function build_extra_hides()
    local out = {}
    local ok, defs = pcall(reqscript, 'refinish-stockhook-defs')
    if not ok or not defs.row_hides then return out end
    for _, h in ipairs(defs.row_hides()) do
        out[#out + 1] = { field = h.field, index = h.index, free = h.free,
                          list = h.list and LIST_BY_NAME[norm(h.list)] }
    end
    return out
end

-- The address of entry mi of the settings vector at field, or nil when the
-- vector is shorter (a group never filled). The vector's data pointer is
-- offset 0 of a std::vector, as name_masters reads it.
--
-- VECTORS FOUND ONCE (2026-11-03): this ran a pcall, a closure and a
-- gmatch over the field path at every call, and it is called per material
-- per list (MEASURED, test 41: moved rows found at 3 ms/sec with the menu
-- idle, and the twin set worked out again at every list switch). The
-- vector ref for a field is now found once per settings object (EA.owner,
-- the settings' address) and kept; its data pointer and length are read
-- at each call, so a vector DF grows is still read where it now is.
local EA = { owner = nil, vecs = {} }
local function vec_at(sp, field)
    local owner = addr_of(sp)
    if EA.owner ~= owner then EA.owner, EA.vecs = owner, {} end
    local v = EA.vecs[field]
    if v == nil then
        local ok, got = pcall(function()
            local vec = sp
            for f in field:gmatch('[^%.]+') do vec = vec[f] end
            return vec
        end)
        v = ok and got or false
        EA.vecs[field] = v
    end
    return v or nil
end

-- A field's vector as its data pointer and length, or nil.
local function vec_base(sp, field)
    local vec = vec_at(sp, field)
    if not vec then return nil end
    local n = #vec
    if n == 0 then return nil end
    return df.reinterpret_cast('uint64_t', addr_of(vec)).value, n
end

local function entry_addr(sp, field, mi)
    local base, n = vec_base(sp, field)
    if not base or mi >= n then return nil end
    return base + mi
end

-- From the definition files' moves: the rows, the indexes and a signature.
-- A material not in this world's raws is skipped.
local function build_moved()
    local out, mis, sig = {}, {}, {}
    local ok, defs = pcall(reqscript, 'refinish-stockhook-defs')
    if not ok or not defs.moves then return out, mis, '' end
    local inorg = df.global.world.raws.inorganics.all
    for _, m in ipairs(defs.moves()) do
        local mi = nil
        for i, mat in ipairs(inorg) do
            if mat.id == m.id then mi = i; break end
        end
        if mi then
            local label = m.label
            if not label or label == '' then
                local name = ''
                pcall(function() name = tostring(inorg[mi].material.state_name.Solid) end)
                label = name:sub(1, 1):upper() .. name:sub(2)
            end
            mis[#mis + 1] = mi
            for _, l in ipairs(INORG_LISTS) do
                local list = l.other and LIST_BY_NAME[norm(l.other)]
                if list then out[#out + 1] = { mi = mi, label = label, field = l.field, list = list } end
            end
            sig[#sig + 1] = m.id .. '=' .. label
        end
    end
    return out, mis, table.concat(sig, ',')
end

-- moved_here for the list on screen, from the open settings, every frame:
-- a vector DF grows moves its entries, so addresses are never kept.
local function find_moved_here(cs)
    moved_here = {}
    for _, m in ipairs(moved) do
        if m.list == cs.cur_sub_mode then
            local a = entry_addr(cs.sp, m.field, m.mi)
            if a then moved_here[a] = m end
        end
    end
end

-- DF's rows of moved materials, and the other hidden rows, out of the live
-- list.
local function hide_rows(cs)
    if #moved_mis == 0 and #extra_hides == 0 then return end
    local hidden = {}
    -- Each list's vector read once, not once per material (VECTORS FOUND ONCE).
    for _, l in ipairs(INORG_LISTS) do
        local base, n = vec_base(cs.sp, l.field)
        if base then
            for _, mi in ipairs(moved_mis) do
                if mi < n then hidden[base + mi] = true end
            end
        end
    end
    for _, h in ipairs(extra_hides) do
        if h.list == cs.cur_sub_mode then
            local a = entry_addr(cs.sp, h.field, h.index)
            if a then hidden[a] = true end
        end
    end
    local keep, gone = {}, {}
    for i = 0, cs.cur_spec_item_sz - 1 do
        local row = cs.spec_item[i]
        local p = row.set_pointer
        local a = p and addr_of(p)
        if a and hidden[a] and not moved_here[a] and not our_byte(row) then
            gone[#gone + 1] = row
        else
            keep[#keep + 1] = row
        end
    end
    if #gone == 0 then return end
    -- Every row is in keep or gone, so rewriting the pointers loses none.
    local order = {}
    for _, r in ipairs(keep) do order[#order + 1] = r end
    for _, r in ipairs(gone) do order[#order + 1] = r end
    for i = 1, #order do
        if addr_of(cs.spec_item[i - 1]) ~= addr_of(order[i]) then cs.spec_item[i - 1] = order[i] end
    end
    cs.cur_spec_item_sz = #keep
    local shown = 0
    for i = 0, #keep - 1 do if cs.spec_item[i].on then shown = shown + 1 end end
    cs.counted_cur_spec_item_sz = shown
end

-- The moved rows for the list on screen that are not live yet.
local function insert_moved(cs)
    if not next(moved_here) then return 0 end
    local present = {}
    for i = 0, cs.cur_spec_item_sz - 1 do
        local p = cs.spec_item[i].set_pointer
        if p then present[addr_of(p)] = true end
    end
    local first = cs.cur_spec_item_sz > 0 and cs.spec_item[0] or nil
    local added = 0
    for a, m in pairs(moved_here) do
        if not present[a] then
            if not borrow_row(cs, m.label, df.reinterpret_cast('int8_t', a), first) then return added end
            added = added + 1
        end
    end
    return added
end

-- A live row that is ours: a module row (its byte in BUF) or a moved row.
local function is_ours(row)
    if our_byte(row) then return true end
    local p = row.set_pointer
    return p ~= nil and moved_here[addr_of(p)] ~= nil
end

-- ---- HIDDEN BYTES ----
-- A hidden row whose byte decides nothing (free: clothing in Armor, which
-- DF refuses there whatever the byte says) is set to keep its list's
-- category colour true. DF colours a category from every byte of its
-- lists, hidden ones too, so a hidden byte left off turned the category
-- grey after the list's own ALL. So every free hidden byte in the list on
-- screen is on when every shown DF row of that list is on, and off
-- otherwise (which leaves a mixed list mixed and an empty one empty).
--
-- TWINS. RM's hidden twins (aggregate, binder) are another such byte while
-- Stockhook is live: a twin files as its source (MATERIAL ALIASES in
-- refinish-stockhook.lua), so its own entry decides nothing. RM's stockpile
-- windows edit their rows out (row.on false, the way DF's search hides a
-- row), so they stay live in the pool. Each one hidden there gets the same
-- value. Not while the player is searching: 'on' then means the search.
-- (Without the hook, RM's windows mirror each twin's entry from its stone
-- at every scan, so a value set here is overwritten there.)
--
-- FREE MATERIALS. A material a definition file names with
-- [STOCKHOOK_FREE] (Making Fuel's binders: tools only, so no stone, coin
-- or furniture setting of theirs ever decides anything) is treated as a
-- twin here: hidden, it gets the same value.
--
-- COINS. DF mints coins from metal bars only, so the Coins entry of any
-- material that is not a metal decides nothing, and every hidden row of one
-- in Coins gets the same value too (2026-11-02, in play: bone meal and
-- Making Fuel's keys held Coins grey).
local TWIN_FIELDS = { 'stone.mats', 'coins.mats', 'finished_goods.mats', 'furniture.mats',
    'bars_blocks.blocks_mats', 'ammo.mats', 'weapons.mats', 'armor.mats',
    'gems.rough_mats', 'gems.cut_mats' }
local twin_addrs, twin_here = {}, nil

-- Every settings byte of an inorganic twin, as addresses, for the list on
-- screen. Worked out once per list: here is the pile and list (step).
--
-- KEPT ACROSS LISTS (2026-11-03): the set was worked out again at every
-- list switch (twin_here was the pile and list), each address through its
-- own entry_addr: twins times ten fields. The addresses do not depend on
-- the list on screen, only on the settings, their vectors and the twins,
-- so the set is now kept under a key of exactly those: the settings'
-- address, each field's data pointer and length, and the twin and free
-- materials themselves. Any change to one of them works it out afresh.
-- here is no longer read; it stays in the call for its callers.
local function twin_set(cs, here)
    local ok, mis = pcall(sh.inorganic_twins)
    if not ok or not mis then mis = {} end
    local okd, defs = pcall(reqscript, 'refinish-stockhook-defs')
    if okd and defs.free_mats then
        local okf, frees = pcall(defs.free_mats)
        if okf and frees then for _, mi in ipairs(frees) do mis[#mis + 1] = mi end end
    end
    local bases, key = {}, { ('%x'):format(addr_of(cs.sp)) }
    for i, field in ipairs(TWIN_FIELDS) do
        local base, n = vec_base(cs.sp, field)
        bases[i] = base and { base = base, n = n } or false
        key[#key + 1] = base and ('%x:%d'):format(base, n) or '-'
    end
    key[#key + 1] = table.concat(mis, ',')
    key = table.concat(key, '|')
    if twin_here == key then return twin_addrs end
    twin_here, twin_addrs = key, {}
    for _, b in ipairs(bases) do
        if b then
            for _, mi in ipairs(mis) do
                if mi < b.n then twin_addrs[b.base + mi] = true end
            end
        end
    end
    return twin_addrs
end

-- The Coins list's material vector, for COINS above: the address of
-- entry 0 and the count, or nil when this is not the Coins list.
local COINS_LIST = df.stockpile_list.Coins
local function coins_span(cs)
    if cs.cur_sub_mode ~= COINS_LIST then return nil end
    local a0 = entry_addr(cs.sp, 'coins.mats', 0)
    if not a0 then return nil end
    return a0, #df.global.world.raws.inorganics.all
end

-- ---- THE ROWS IT COUNTS, KEPT (2026-11-03) ----
-- MEASURED (test 40): a click in a long list cost up to 95 ms here, the
-- whole list walked again because one byte moved. A click changes bytes,
-- never which rows the list holds, so the whole walk keeps what it found
-- for this list (here) and this search state: each counted row's byte (as
-- its primitive ref, the row's own pointer) and the twin rows' addresses.
-- mirror_quick reads those alone. Which rows count is decided by the whole
-- walk only.
local MF = { here = nil, searching = nil, refs = nil, twins = nil }

-- The value, written to every hidden twin row and every free extra hide of
-- this list (HIDDEN BYTES); a byte already right is left alone.
local function mirror_write(cs, list, want, twin_rows)
    for _, a in ipairs(twin_rows) do
        local b = df.reinterpret_cast('int8_t', a)
        if b.value ~= want then b.value = want end
    end
    for _, h in ipairs(extra_hides) do
        if h.free and h.list == list then
            local a = entry_addr(cs.sp, h.field, h.index)
            if a then
                local b = df.reinterpret_cast('int8_t', a)
                if b.value ~= want then b.value = want end
            end
        end
    end
end

local function mirror_free(cs, here)
    local list = cs.cur_sub_mode
    local twins_here = twin_set(cs, here)
    local c0, cn = coins_span(cs)
    local inorg = df.global.world.raws.inorganics.all
    -- A Coins row whose material is not a metal (COINS).
    local function free_coin(a)
        if not c0 then return false end
        local mi = a - c0
        if mi < 0 or mi >= cn then return false end
        local okm, metal = pcall(function() return inorg[mi].material.flags.IS_METAL end)
        return okm and not metal
    end
    local searching = tostring(cs.spec_filter or '') ~= ''
    local all_on, any = true, false
    local twin_rows = {}
    local refs = {}         -- THE ROWS IT COUNTS, KEPT: each counted row's byte
    -- ONE READ PER ROW (2026-11-03): each row's entry address is read once
    -- and tested for ours here (what is_ours tests: a module row's byte in
    -- BUF, or a moved row), and its byte read through the row's own pointer
    -- (p.value, a primitive ref: Lua API.txt) instead of a new ref made per
    -- row. The same test and the same byte as before, at less cost.
    for i = 0, cs.cur_spec_item_sz - 1 do
        local row = cs.spec_item[i]
        local p = row.set_pointer
        if p then
            local a = addr_of(p)
            if not ((a >= BUF_LO and a < BUF_HI) or moved_here[a]) then
                local on = row.on
                if twins_here[a] or (not on and not searching and free_coin(a)) then
                    if not searching and not on then twin_rows[#twin_rows + 1] = a end
                elseif searching or on then
                    -- Only rows the player can see set the value: a row
                    -- hidden for another reason (RM's hidden materials,
                    -- Making Fuel's keys and binders) keeps its own byte,
                    -- and counting it held every twin off (2026-11-02, in
                    -- play: Coins ALL left all 106 hidden rows off).
                    any = true
                    refs[#refs + 1] = p
                    if all_on and p.value == 0 then all_on = false end
                end
            end
        end
    end
    MF.here, MF.searching, MF.refs, MF.twins = here, searching, refs, twin_rows
    if not any then return end
    mirror_write(cs, list, all_on and 1 or 0, twin_rows)
end

-- The quick look, for a frame in which only bytes changed (THE LIST,
-- UNCHANGED, in step): the rows mirror_free counted on this list are read
-- again from their kept bytes, stopping at the first one off, and the same
-- value written. The whole walk runs instead whenever the kept rows are
-- not this list's or the search has started or ended since.
local function mirror_quick(cs, here)
    local searching = tostring(cs.spec_filter or '') ~= ''
    if MF.here ~= here or MF.searching ~= searching or not MF.refs then
        return mirror_free(cs, here)
    end
    if #MF.refs == 0 then return end        -- nothing counted: as mirror_free
    local all_on = true
    for _, p in ipairs(MF.refs) do
        if p.value == 0 then all_on = false; break end
    end
    mirror_write(cs, cs.cur_sub_mode, all_on and 1 or 0, MF.twins)
end

-- ---- ALPHABETICAL PLACE ----
-- insert_rows adds our rows after DF's. Once they are in, the live part of
-- the pool (rows 0 .. cur_spec_item_sz - 1, a vector of row pointers) is
-- put in order. DF builds its lists alphabetically (in play, test 23:
-- Finished goods: type reads Amulets, Armor, Backpacks...), so DF's rows
-- keep their own order and each row of ours goes in just before the first
-- DF row whose name sorts after it (case ignored): one alphabetical list.
-- A vanilla row renamed by name_masters ("Coal (all)") no longer sits
-- where DF put it, so it is placed the same way as ours, by its name less
-- " (all)", ahead of a part of the same name (Making Fuel's "Coal").
--
-- WHY THIS IS SAFE: only pointers move, within the rows DF already shows;
-- no row is made, freed or changed. DF itself reorders this pool on every
-- list switch (MEASURED, see the top of this file), and a click acts
-- through the row's own set_pointer, not its place. Run only in a frame
-- where rows were added, so the list is ordered once each time it is
-- built.
local renamed = {}          -- vanilla byte address -> name shown (name_masters)

local function sort_key(name)
    local n = tostring(name or ''):lower()
    return (n:gsub(' %(all%)$', ''))
end

local function place_rows(cs)
    local n = cs.cur_spec_item_sz
    local theirs, mobile = {}, {}
    for i = 0, n - 1 do
        local row = cs.spec_item[i]
        local master = false
        if not is_ours(row) and row.set_pointer then
            local shown = renamed[addr_of(row.set_pointer)]
            master = shown ~= nil and shown == row.name
        end
        local e = { row = row, key = sort_key(row.name), name = tostring(row.name), master = master }
        if is_ours(row) or master then mobile[#mobile + 1] = e else theirs[#theirs + 1] = e end
    end
    if #mobile == 0 then return end
    table.sort(mobile, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        if a.master ~= b.master then return a.master end
        return a.name < b.name
    end)
    local merged, j = {}, 1
    for _, t in ipairs(theirs) do
        while j <= #mobile and mobile[j].key < t.key do
            merged[#merged + 1] = mobile[j].row; j = j + 1
        end
        merged[#merged + 1] = t.row
    end
    while j <= #mobile do merged[#merged + 1] = mobile[j].row; j = j + 1 end
    for i = 1, #merged do
        -- Compared by address: two refs to one row are not the same Lua value.
        if addr_of(cs.spec_item[i - 1]) ~= addr_of(merged[i]) then cs.spec_item[i - 1] = merged[i] end
    end
end

-- ---- SEARCH ----
-- DF's filter hides borrowed rows whatever their name, so after DF has run
-- it, each of ours is shown by its own name, and the shown count is
-- recounted. DF holds the filter upper-cased; matching ignores case.
--
-- A vanilla row renamed by name_masters ("Headwear (all)") is filtered here
-- too: DF's own filter missed it (2026-11-02, in play: "HEAD" left
-- "Headwear (all)" out, "EAD" found it), so its 'on' is set by the name
-- shown, as for our rows.
--
-- ONE WALK (2026-11-03): the filter and the shown count were two walks,
-- and each row's entry was read up to four times (is_ours, then the
-- renamed test). Now each row's entry is read once, tested for ours (a
-- module row's byte in BUF, a moved row) and renamed, and the shown count
-- kept in the same walk. The count is still written only in a list holding
-- rows of ours. MEASURED (test 41): up to 82 ms in a long list.
local function apply_filter(cs)
    local f = tostring(cs.spec_filter or ''):upper()
    local ours, n = false, 0
    for i = 0, cs.cur_spec_item_sz - 1 do
        local row = cs.spec_item[i]
        local p = row.set_pointer
        local a = p and addr_of(p)
        local on
        if a and ((a >= BUF_LO and a < BUF_HI) or moved_here[a] or renamed[a]) then
            ours = true
            local want = f == '' or row.name:upper():find(f, 1, true) ~= nil
            if row.on ~= want then row.on = want end
            on = want
        else
            on = row.on
        end
        if on then n = n + 1 end
    end
    -- The shown count: every live row that is on.
    if ours and cs.counted_cur_spec_item_sz ~= n then cs.counted_cur_spec_item_sz = n end
end

-- ---- GROUP ALL / NONE ----
-- The category and top-level all / none buttons write DF's settings
-- directly. A frame in which MORE THAN ONE byte of a group changed, all the
-- same way, across two or more of the group's lists, is a bulk button: the
-- group's rows follow (all on, or all off). A single click changes one byte
-- and is the player's own; one list's own all / none changes one list; and
-- neither moves the rows (check_groups).
--
-- Changes are counted byte by byte, not as "everything is now 1 / 0":
-- DF keeps 1 in the slots a group cannot hold (an item type that is never a
-- finished good, a stone in a metal list; DFHack's importer fills them the
-- same way), so after "none" a group is not all 0.
--
-- A pile typed by Stockhook (refinish-stockhook.lua, THE PILE'S TYPE) has its
-- group's bytes written by the importer; when stockhook_type_gen moves, the
-- bytes are looked at afresh instead of read as a button.
local function group_bytes(settings, group)
    local g = settings[group]
    local out, nfields = {}, 0
    -- Every byte VECTOR of the group's settings struct, by field name
    -- (pairs over a DF struct walks its fields; vectors and arrays are
    -- 'container' refs). Left out: plain bool fields (dyed, undyed) and the
    -- quality arrays (test 17: switching quality on is one list's button,
    -- and was read as the whole group's "all", turning Oak beds on).
    for name, v in pairs(g) do
        if type(v) == 'userdata' and v._kind == 'container'
                and not tostring(name):match('^quality') then
            local bytes = {}
            for i = 0, #v - 1 do
                local x = v[i]
                if type(x) == 'boolean' then x = x and 1 or 0 end
                if type(x) == 'number' then bytes[#bytes + 1] = x ~= 0 and 1 or 0 end
            end
            out[name] = bytes
            nfields = nfields + 1
        end
    end
    return out, nfields
end

-- A moved material's DF row is shown in its group's other materials list
-- (MOVED MATERIALS), but its byte is in the group's material vector
-- (furniture.mats). So that list's own all / none changes two vectors and
-- read as the whole group's (2026-11-02, in play: all on Furniture: other
-- materials switched every row of ours in Furniture: type on). Those bytes
-- are left out of the count: field name -> { [1-based byte] = true }.
local function moved_skip(group)
    local out = {}
    for _, l in ipairs(INORG_LISTS) do
        local g, name = l.field:match('^([^%.]+)%.(.+)$')
        if g == group then
            local set = out[name] or {}
            out[name] = set
            for _, mi in ipairs(moved_mis) do set[mi + 1] = true end
        end
    end
    return out
end

-- ---- RAW COPIES: HAS ANYTHING CHANGED? (2026-11-03) ----
-- MEASURED in play (2026-11-03, RM's loop cost panel): this file's loop
-- at 8.96 ms a call, 62 calls a second, 560 ms/sec, 56% of the machine's
-- time, with a pile selected. Every frame, group_bytes read every byte of
-- every group holding rows of ours, one DFHack read each (about 9,000:
-- the log counted 2,420 in Bars and Blocks alone), for check_groups in the
-- settings menu and for check_sheet on the stockpile sheet.
--
-- Nearly every frame nothing has changed. So each byte vector is also kept
-- as a raw copy (a buffer of its own, df.new), and each frame compared
-- with one dfhack.internal.memcmp per vector (Lua API.txt, wraps the
-- standard memcmp), and copied again with one memmove only when it
-- differs. The vectors are DF's bool vectors, one byte per entry, from
-- the address in the vector's first word (as the DLL's vec_byte reads
-- them). group_bytes, and everything after it, runs only on a frame where
-- some vector changed.
--
-- ctx keeps the settings menu's copies apart from the sheet's. A copy is
-- for one settings object: another pile (another address) starts afresh,
-- its buffers freed.

-- The byte vectors of a group, by name, as group_bytes picks them; the
-- same for every pile, so worked out once per group.
local group_fields_cache = {}
local function group_fields(settings, group)
    local f = group_fields_cache[group]
    if f then return f end
    f = {}
    for name, v in pairs(settings[group]) do
        if type(v) == 'userdata' and v._kind == 'container'
                and not tostring(name):match('^quality') then
            f[#f + 1] = name
        end
    end
    group_fields_cache[group] = f
    return f
end

local raw = {}       -- ctx -> { owner = settings address, groups = { group = { name = copy } } }

local function free_raw(r)
    if not r then return end
    for _, fs in pairs(r.groups) do
        for _, c in pairs(fs) do pcall(df.delete, c.buf) end
    end
end

-- True when no byte vector of these groups changed since the last call
-- with this ctx and these settings. Brings the copies up to date either way.
local function raw_unchanged(ctx, settings, groups)
    local owner = addr_of(settings)
    local r = raw[ctx]
    local same = r ~= nil and r.owner == owner
    if not same then
        free_raw(r)
        r = { owner = owner, groups = {} }
        raw[ctx] = r
    end
    local unchanged = same
    for g in pairs(groups) do
        local fs = r.groups[g]
        if not fs then fs = {}; r.groups[g] = fs; unchanged = false end
        local gs = settings[g]
        for _, name in ipairs(group_fields(settings, g)) do
            local v = gs[name]
            local n = #v
            local ptr = n > 0 and df.reinterpret_cast('uint64_t', addr_of(v)).value or 0
            local c = fs[name]
            if not c or c.n ~= n or (n > 0 and dfhack.internal.memcmp(c.buf, ptr, n) ~= 0) then
                unchanged = false
                if not c or c.cap < n then
                    if c then pcall(df.delete, c.buf) end
                    c = { buf = df.new('uint8_t', math.max(n, 1)), cap = math.max(n, 1) }
                    fs[name] = c
                end
                c.n = n
                if n > 0 then dfhack.internal.memmove(c.buf, ptr, n) end
            end
        end
    end
    return unchanged
end

-- ---- THE GROUPS HOLDING ROWS OF OURS, KEPT (2026-11-03) ----
-- check_groups and check_sheet each walked every slot (888 in test 38)
-- every frame to learn which groups hold rows of ours, building two
-- tables a frame. The answer changes only when the slots do (slot_sig,
-- set with them in refresh_slots), so it is worked out once per set of
-- slots: a list in slot order and a set. Read only, by both callers.
local sg_sig, sg_list, sg_set = nil, {}, {}
local function slot_groups()
    if sg_sig == slot_sig and sg_sig ~= nil then return sg_list, sg_set end
    sg_sig, sg_list, sg_set = slot_sig, {}, {}
    for _, s in ipairs(slots) do
        local g = s.group
        if g and not sg_set[g] then
            sg_set[g] = true
            sg_list[#sg_list + 1] = g
        end
    end
    return sg_list, sg_set
end

local type_gen_seen = nil
local function check_groups(cs, pile)
    if type_gen_seen ~= _G.stockhook_type_gen then
        type_gen_seen = _G.stockhook_type_gen
        group_snap = {}
    end
    -- THE GROUPS HOLDING ROWS OF OURS, KEPT: read only here.
    local _, groups = slot_groups()
    -- RAW COPIES: nothing changed and every group already recorded, so
    -- there is nothing to count this frame.
    local unchanged = raw_unchanged('menu', cs.sp, groups)
    if unchanged then
        local all = true
        for group in pairs(groups) do if not group_snap[group] then all = false end end
        if all then return end
    end
    for group in pairs(groups) do
        local ok, now, nfields = pcall(group_bytes, cs.sp, group)
        if ok then
            local prev = group_snap[group]
            if prev then
                -- Count changes by direction, and how many of the group's
                -- lists changed. A list whose length changed (DF filling
                -- it) is a fresh look, never a button.
                local up, down, lists, fresh = 0, 0, 0, false
                local skip = moved_skip(group)
                for name, bytes in pairs(now) do
                    local was = prev[name]
                    if not was or #was ~= #bytes then
                        fresh = true
                    else
                        local changed = false
                        local sk = skip[name] or {}
                        for i = 1, #bytes do
                            if sk[i] then
                                -- a moved material's byte: not counted
                            elseif bytes[i] > was[i] then up = up + 1; changed = true
                            elseif bytes[i] < was[i] then down = down + 1; changed = true end
                        end
                        if changed then lists = lists + 1 end
                    end
                end
                -- A category or top-level all / none writes EVERY list of
                -- the group; one list's own all / none writes one. So the
                -- rows follow only when two or more lists changed the same
                -- way, or the group has a single list. (In a single-list
                -- group, stone or wood, one of its sub-lists' all / none
                -- still reads as the group's: a known edge.)
                local bulk = lists >= 2 or (nfields == 1 and lists == 1)
                local to = nil
                if not fresh and bulk then
                    if up > 1 and down == 0 then to = 1 elseif down > 1 and up == 0 then to = 0 end
                end
                if to then
                    for _, s in ipairs(slots) do
                        if s.group == group and R.buf[s.byte] ~= to then R.buf[s.byte] = to end
                    end
                end
            end
            group_snap[group] = now
        end
    end
end

-- ---- THE VANILLA ROW'S NAME ----
-- A vanilla row with two or more parts (Coal, with Coke, Charcoal and so
-- on) is no longer one kind of item: it is the wildcard and the switch for
-- all its parts. Shown as "Coal (all)" (2026-11-02: the tag after the
-- name, as RM's "(binder)" and "(aggregate)", so the row stays under its
-- own letter), and a mod's part named "Coal" never reads as a second
-- "Coal". "Other large tools" stays an O row: "Other large tools (all)"
-- (test 24). A row with a single part
-- keeps its own name (test 17: "All dog tallow" read wrongly for a row that
-- is one species' tallow). The row is found by the byte it
-- flips: its set_pointer is the vanilla entry's byte in the open settings,
-- the vector's data pointer (offset 0 of a std::vector, as the DLL reads
-- it) plus the entry's index. DF's search keeps matching the row by its own
-- name; only what is drawn changes. renamed is declared above place_rows,
-- which reads it.
local function master_name(base)
    base = tostring(base)
    if base:match(' %(all%)$') then return base end
    return base .. ' (all)'
end

local function name_masters(cs, list)
    local want, count = {}, {}
    for _, s in ipairs(slots) do
        if s.part_of and s.list == list then
            local ok, a = pcall(function()
                local vec = cs.sp
                for field in s.part_of.vector:gmatch('[^%.]+') do vec = vec[field] end
                if s.part_of.index >= #vec then return nil end
                return df.reinterpret_cast('uint64_t', addr_of(vec)).value + s.part_of.index
            end)
            if ok and a then count[a] = (count[a] or 0) + 1 end
        end
    end
    for a, n in pairs(count) do if n >= 2 then want[a] = true end end
    if not next(want) then return end
    for i = 0, cs.cur_spec_item_sz - 1 do
        local row = cs.spec_item[i]
        local p = row.set_pointer
        if p and not is_ours(row) then
            local a = addr_of(p)
            if want[a] then
                local shown = renamed[a]
                if not shown or row.name ~= shown then
                    -- "Coal" -> "Coal (all)" (master_name).
                    shown = master_name(row.name)
                    renamed[a] = shown
                    row.name = shown
                    row.simple_name = shown
                end
            end
        end
    end
end

-- ---- VANILLA ROW CLICKS ----
-- A part row's vanilla row (Coal, for Coke and Charcoal) is the wildcard and
-- the switch for all its parts: when its value changes, every part of it
-- takes the new value. The first look after a pile opens only records it.
local function check_masters(cs, pile)
    local unset = {}
    for _, s in ipairs(slots) do
        -- A part sits in its vanilla row's own list, so only the list on
        -- screen can have had its vanilla row clicked.
        if s.part_of and s.list == cs.cur_sub_mode then
            local ok, v = pcall(sh.part_vanilla, { settings = cs.sp }, s.part_of)
            if ok then
                local was = master_seen[s.byte]
                if was ~= nil and was ~= v then
                    -- The part goes back to following its vanilla row: its
                    -- stored value is dropped (refinish-stockhook.lua, unset), and
                    -- its byte shows the new value. last_bytes moves with
                    -- it, so the change is not read as a click.
                    local to = v and 1 or 0
                    R.buf[s.byte] = to
                    last_bytes[s.byte] = to
                    unset[#unset + 1] = s.id
                end
                master_seen[s.byte] = v
            end
        end
    end
    if #unset > 0 then sh.unset(pile, unset) end
end

-- ---- CLICKS ----
-- A byte that changed since last frame is a click (or a group button):
-- saved for the pile and applied. Every byte that changed this frame goes
-- in ONE stockhook.set_many (one save, one commit, one nudge): a group's
-- all / none moves hundreds of rows at once (test 22: over five seconds
-- when they were set one at a time).
--
-- CLICKS, ONLY WHEN A BYTE MOVED (2026-11-03): MEASURED (test 40) at 15
-- to 17 ms/sec with the menu open and nothing clicked, a read of every
-- slot's byte every frame. The row bytes are one buffer (R.buf), so one
-- memcmp against a raw copy (BC) says whether any byte moved since the
-- last look, and the slots are read only when one did. The copy is
-- dropped (BC.valid) whenever last_bytes is set elsewhere (load_pile,
-- stop), so the next frame reads every slot.
local function apply_bytes(pile)
    if not BC.buf then BC.buf = df.new('uint8_t', MAX_ROWS) end
    if BC.valid and dfhack.internal.memcmp(BC.buf, R.buf, MAX_ROWS) == 0 then return end
    dfhack.internal.memmove(BC.buf, R.buf, MAX_ROWS)
    BC.valid = true
    local changes, any = {}, false
    for _, s in ipairs(slots) do
        local v = R.buf[s.byte]
        if v ~= last_bytes[s.byte] then
            last_bytes[s.byte] = v
            changes[s.id] = v ~= 0
            any = true
        end
    end
    if any then sh.set_many(pile, changes) end
end

-- ---- THE STONE FLAG, WHILE STOPPED ----
-- A moved material (MOVED MATERIALS) is still IS_STONE, so DF counts its
-- entry when it colours a group's stone list, and a stone list's own ALL,
-- which cannot reach the hidden row, left the category grey (2026-11-02, in
-- play: Furniture: stone/clay after ALL had exactly the 21 moved
-- materials off). So while a pile's settings are open AND the game has
-- stopped, each moved material's IS_STONE is taken off: DF then neither
-- lists it in a stone list nor counts it there. Its rows in the other
-- materials lists are this file's own and aim at the entry directly, so
-- they keep working. The flag goes back the frame the game runs or the
-- screen closes, and at stop(); nothing is hauled or dug while the game is
-- stopped, so nothing that files by the flag can see it gone. RM's windows
-- took the twins' flags back the same way, open and stopped (refinish-
-- stockpile-windows.lua, THE STOCKPILE SETTINGS SCREEN).
--
-- STOPPED: the year tick unchanged for HALT_FRAMES frames, measured, not
-- read from a pause flag (as RM's windows measure it).
local HALT_FRAMES = 2
local halt_tick, halt_still = nil, 0
local stone_off = {}        -- material index -> true while its flag is off

local function game_stopped()
    local tk = df.global.cur_year_tick
    if tk == halt_tick then halt_still = halt_still + 1 else halt_still = 0 end
    halt_tick = tk
    return halt_still >= HALT_FRAMES
end

-- Every flag taken off, put back.
local function stone_back()
    if not next(stone_off) then return end
    local inorg = df.global.world.raws.inorganics.all
    for mi in pairs(stone_off) do
        pcall(function() inorg[mi].material.flags.IS_STONE = true end)
    end
    stone_off = {}
end

-- Each moved material that is IS_STONE has the flag taken off, and is
-- remembered, so only flags this file took are ever put back.
local function stone_take()
    local inorg = df.global.world.raws.inorganics.all
    for _, mi in ipairs(moved_mis) do
        if not stone_off[mi] then
            local ok = pcall(function()
                local f = inorg[mi].material.flags
                if f.IS_STONE then f.IS_STONE = false; stone_off[mi] = true end
            end)
            if not ok then stone_off[mi] = nil end
        end
    end
end

-- The live pool as it stands: its count and the first and last live rows
-- (the row objects themselves, which DF reorders when it builds a list).
-- POOL CHANGED, in step.
local function pool_sig(cs)
    local n = cs.cur_spec_item_sz
    if n <= 0 then return '0' end
    return ('%d:%x:%x'):format(n, addr_of(cs.spec_item[0]), addr_of(cs.spec_item[n - 1]))
end

-- ---- THE ROWS, REBUILT WHEN THE ENTRIES CHANGE ----
-- Only when the entries changed (a reload, generated rows included:
-- hundreds of them, so not every frame). Called by step while a pile's
-- settings are open, and by check_sheet while the stockpile sheet is, so
-- the slots exist before the settings menu has ever been opened.
local function refresh_slots()
    if R.slot_ver == sh.version() then return end
    R.slot_ver = sh.version()
    local s2, sig = build_slots()
    local m2, mis2, msig = build_moved()
    extra_hides = build_extra_hides()
    twin_here = nil      -- the twins worked out afresh (twin_set)
    sig = sig .. '|' .. msig
    if sig ~= slot_sig then
        slots, slot_sig, open_pile = s2, sig, nil
        moved, moved_mis = m2, mis2
        -- The moved rows count toward their list's category
        -- colour too (refinish-stockhook.lua, THE COLOUR ROWS):
        -- handed over and committed whenever they change.
        local extra = {}
        for _, m in ipairs(moved) do
            extra[#extra + 1] = { list = m.list, field = m.field, index = m.mi }
        end
        sh.colour_extra(extra)
        pcall(sh.commit)
    end
end

-- ==========================================
-- THE STOCKPILE SHEET'S BUTTONS (2026-11-03)
-- ==========================================
-- The stockpile sheet (game.main_interface.stockpile.cur_bld, the pile
-- selected on the map, df.d_interface.xml stockpile_interfacest) has its
-- own category buttons, All among them, outside the settings menu. They
-- write DF's settings directly, and nothing above runs there, so rows of
-- ours were left as they were. SEEN in play: All on a pile switched every
-- vanilla entry and the parts that follow them on, while Cinders, Coke
-- breeze and Green coke (rows of their own, parts of nothing) stayed off,
-- so Bars and Bars: other materials read grey and the pile was named
-- Custom instead of All.
--
-- So while the sheet is open (and the settings menu is not), the selected
-- pile's group switches and group bytes are kept from frame to frame, for
-- every group holding rows of ours, and a group the buttons switched
-- whole takes all its rows with it:
--   ON  the group's switch went on with its entries all on (allowing a
--       few off: SHEET_SLACK), or the switch stayed on and more than one
--       entry went on with none going off and the entries all on;
--   OFF the switch was on, and more than one entry went off with none
--       going on, in a frame where the lists kept their lengths.
-- A switch going off on its own changes nothing: DF switches off a group
-- with nothing on when the settings menu closes, and a pile holding only
-- rows of ours looks that way to DF (THE SCREEN CLOSED, in step). A pile
-- Stockhook types (stockhook_type_gen moves) is looked at afresh, as in
-- check_groups. The moved materials' bytes are left out of the count
-- (moved_skip), as there. Every change goes in one set_many.
local SHEET_SLACK = 0.02     -- share of a group's entries allowed off in "all on"
local SHEET_EVERY = 6        -- frames between looks (EVERY FEW FRAMES, in step)
local sheet = nil            -- { id, gen, flags = { group = on }, bytes = { group = group_bytes } }

-- The pile selected on the map: DFHack's own answer
-- (dfhack.gui.getSelectedStockpile, Lua API.txt), and nothing else.
--
-- NEVER READ cur_bld RAW (2026-11-05). This used to fall back to
-- game.main_interface.stockpile.cur_bld whenever DFHack gave no pile, which
-- is every frame with no pile selected. DF does not clear cur_bld when the
-- sheet closes or the fort unloads; it keeps the last pile's address.
--   * Same fort: a pile no longer on screen was watched as if its sheet
--     were open (SEEN: "watching pile #1" after hotsaves with nothing
--     selected, sheet: watch about 11 ms/sec).
--   * After the fort unloads and a save loads without restarting DF:
--     MEASURED (session log, 2026-11-05), idle: sheet looked for at 750
--     to 966 ms/sec, 136 to 175 ms a look, from the first frame after the
--     load until DF was closed, with no menu open.
-- WHY IT COST SO MUCH, read from the DFHack 53.16-r3 source and inferred
-- from the log's shape (idle state, nothing in stderr, only after an
-- unload): cur_bld then holds a building freed with the old map. Reading
-- a class pointer from Lua makes DFHack name the object's class from its
-- vtable (virtual_identity::find, DataDefs.cpp). Freed memory holds no
-- vtable there, so readClassName runs checkValidAddress, which walks the
-- whole process memory map (getMemRanges, VirtualQueryEx, Process.cpp),
-- then throws. A throw is never cached, so every look paid the whole walk
-- again, and the pcall here swallowed the error, so nothing was logged.
-- getSelectedStockpile reads cur_bld only while DF shows the stockpile
-- sheet (bottom_mode_selected STOCKPILE: Gui.cpp, getAnyStockpile), when
-- DF has just set it to the pile on screen. So its answer alone is right,
-- and nil means no sheet is open.
local function sheet_pile()
    local ok, p = pcall(dfhack.gui.getSelectedStockpile, true)
    if ok then return p end
end

local function check_sheet()
    local pile = sheet_pile()
    if not pile or not df.building_stockpilest:is_instance(pile) then
        sheet = nil
        return
    end
    refresh_slots()
    if #slots == 0 then sheet = nil; return end
    local st = pile.settings
    -- The group switches first: one read each.
    -- THE GROUPS HOLDING ROWS OF OURS, KEPT: the set is read only here.
    local glist, groups = slot_groups()
    local flags = {}
    for _, g in ipairs(glist) do flags[g] = st.flags[g] and true or false end
    -- RAW COPIES: the same pile, the same switches and no byte changed is
    -- the frame almost every frame is, and needs nothing more.
    local unchanged = raw_unchanged('sheet', st, groups)
    if unchanged and sheet and sheet.id == pile.id and sheet.gen == _G.stockhook_type_gen then
        local same = true
        for g, on in pairs(flags) do if sheet.flags[g] ~= on then same = false end end
        if same then return end
    end
    local now = { id = pile.id, gen = _G.stockhook_type_gen, flags = flags, bytes = {} }
    for g in pairs(groups) do
        local okg, b = pcall(group_bytes, st, g)
        now.bytes[g] = okg and b or {}
    end
    local prev = sheet
    sheet = now
    -- The first frame on this pile, or after Stockhook typed a pile, only
    -- records. A pile newly selected is said once, so the log shows the
    -- sheet was seen at all.
    if not prev or prev.id ~= now.id then
        log_line(('stockpile sheet: watching pile #%s.'):format(tostring(pile.stockpile_number)),
            'DETAIL')
    end
    if not prev or prev.id ~= now.id or prev.gen ~= now.gen then return end
    local get = sh.getter(pile)
    local changes, n_on, n_off = {}, 0, 0
    for g, is_on in pairs(now.flags) do
        local was_on = prev.flags[g]
        local nb, pb = now.bytes[g] or {}, prev.bytes[g] or {}
        local skip = moved_skip(g)
        local up, down, total, off, same_len = 0, 0, 0, 0, true
        for name, bytes in pairs(nb) do
            local was = pb[name]
            local kept = was ~= nil and #was == #bytes
            if not kept then same_len = false end
            local sk = skip[name] or {}
            for i = 1, #bytes do
                if not sk[i] then
                    total = total + 1
                    if bytes[i] == 0 then off = off + 1 end
                    if kept then
                        if bytes[i] > was[i] then up = up + 1
                        elseif bytes[i] < was[i] then down = down + 1 end
                    end
                end
            end
        end
        local all_on = total > 0 and off <= math.max(2, total * SHEET_SLACK)
        local to = nil
        if is_on and not was_on and all_on then
            to = true
        elseif is_on and was_on and same_len and up > 1 and down == 0 and all_on then
            to = true
        elseif was_on and same_len and down > 1 and up == 0 then
            to = false
        end
        -- What the buttons did to this group, and what followed, at Debug
        -- detail: the record to read if a button is ever not followed.
        if was_on ~= is_on or up + down > 0 or not same_len then
            log_line(('stockpile sheet: pile #%s %s: switch %s -> %s, entries %d on, %d off'
                .. ' this frame, %d of %d off now, lists %s; rows %s.'):format(
                tostring(pile.stockpile_number), g, tostring(was_on), tostring(is_on), up, down,
                off, total, same_len and 'kept their lengths' or 'were filled',
                to == nil and 'left alone' or (to and 'all on' or 'all off')), 'DETAIL')
        end
        if to ~= nil then
            for _, s in ipairs(slots) do
                if s.group == g and (get(s.id) and true or false) ~= to then
                    changes[s.id] = to
                    if to then n_on = n_on + 1 else n_off = n_off + 1 end
                end
            end
        end
    end
    if n_on + n_off > 0 then
        sh.set_many(pile, changes)
        log_line(('stockpile sheet: %d row(s) on, %d off in pile #%s, following its category'
            .. ' buttons.'):format(n_on, n_off, tostring(pile.stockpile_number)), 'DETAIL')
        -- set_many may type the pile (stockhook_type_gen): the next frame
        -- records afresh.
    end
end

-- ==========================================
-- THE LOOP'S OWN TIMING (2026-11-03)
-- ==========================================
-- RM's loop cost panel names this loop but not what inside it is slow.
-- SEEN 2026-11-03: the loop at 150 to 560 ms/sec in some minutes and
-- about 30 in others, and nothing in RM's log to say which part or which
-- screen. So step times its own sections, always (os.clock, a few calls
-- a frame), and every PERF_EVERY_S seconds of clock, if the whole step
-- cost PERF_WARM_MS ms per second or more, RM's log gets the figures:
-- the cost, how many frames ran in each state (menu: a pile's settings
-- open; sheet: a pile selected on the map; idle: neither; closing: the
-- frame the menu shut), and the costliest sections, a few to a line (RM's
-- log cuts a line at 400 characters). Below that, nothing is logged. With
-- refinish-section-probe on, each section is handed to its clock too.
--
-- TWO LEVELS, THE LOOP COST PANEL'S OWN (2026-11-06). The figures were a
-- WARNING from 5 ms/sec, so a pile's settings opened in ordinary play
-- filled the log's Quiet view, where a player looks for faults, with
-- yellow WARNINGs. SEEN (session log, 2026-11-05): 6.8 to 27.5 ms/sec in
-- 101 reports of ordinary play, and up to 966.5 only in the cur_bld fault
-- (NEVER READ cur_bld RAW). RM's loop cost panel paints a loop warm from
-- 20 ms/sec (2% of the machine's time) and hot from 100 (10%)
-- (refinish-panel-status.lua, WARM_MS_S and HOT_MS_S), and the report
-- keeps to the same two levels:
--   warm  the figures, at DETAIL: debugging material, shown in Debug;
--   hot   a WARNING first, one line in plain words for the player (the
--         share of the game's time, and that it is not normal), then the
--         same figures at DETAIL, kept in RM's session log for a report.
-- The figures' lines open with "timing", not "slow": a warm report is
-- not a fault. Timing below the warm level is refinish-section-probe's.
local PERF_EVERY_S = 10
local PERF_WARM_MS = 20     -- the figures, at DETAIL (the panel's WARM_MS_S)
local PERF_HOT_MS = 100     -- and a WARNING before them (the panel's HOT_MS_S)
-- why: what made the list read as changed, counted (WHAT CHANGED THE LIST).
local perf = { t = {}, n = {}, max = {}, frames = {}, why = {}, since = os.clock() }
local function pnow() return os.clock() * 1000 end
local function plap(name, t0)
    local t = pnow()
    local d = t - t0
    perf.t[name] = (perf.t[name] or 0) + d
    perf.n[name] = (perf.n[name] or 0) + 1
    -- >=, so a section whose every lap read 0 ms (os.clock counts whole
    -- milliseconds on Windows) still has a max for the report.
    if d >= (perf.max[name] or 0) then perf.max[name] = d end
    local sc = _G.refinish_section_clock
    if sc then pcall(sc.lap, 'stockhook rows: ' .. name, t0) end
    return t
end
local function pstate(name) perf.frames[name] = (perf.frames[name] or 0) + 1 end

local function perf_report()
    local secs = os.clock() - perf.since
    if secs < PERF_EVERY_S then return end
    local whole = perf.t['whole step'] or 0
    local per_s = whole / secs      -- ms of the whole step per second of clock
    if per_s >= PERF_WARM_MS then
        -- HOT (TWO LEVELS, above): the player's line, in plain words, before
        -- the figures. ms/sec over ten is the percentage of the time, as the
        -- loop cost panel writes it.
        if per_s >= PERF_HOT_MS then
            log_line(("Stockhook's stockpile rows took %.0f%% of the game's time over the last"
                .. " %.0f seconds, which slows the game. That is not normal; please report it"
                .. " with refinish_session.log, in DF's folder, which holds the details.")
                :format(per_s / 10, secs), 'WARNING')
        end
        local states = {}
        for k, v in pairs(perf.frames) do states[#states + 1] = k .. ' ' .. v end
        table.sort(states)
        log_line(('timing: %.1f ms/sec over the last %.0f s, %d frame(s), %.2f ms at worst; frames'
            .. ' by state: %s; Lua heap %.0f KB.'):format(per_s, secs, perf.n['whole step'] or 0,
            perf.max['whole step'] or 0, table.concat(states, ', '), collectgarbage('count')), 'DETAIL')
        -- WHAT CHANGED THE LIST: frames whose walks ran, by cause.
        local why = {}
        for k, v in pairs(perf.why) do why[#why + 1] = k .. ' ' .. v end
        if #why > 0 then
            table.sort(why)
            log_line('timing, list walks run by cause (frames): ' .. table.concat(why, ', ') .. '.',
                'DETAIL')
        end
        local rows = {}
        for name, t in pairs(perf.t) do
            if name ~= 'whole step' then rows[#rows + 1] = { name = name, t = t } end
        end
        table.sort(rows, function(a, b) return a.t > b.t end)
        local line = {}
        for i = 1, math.min(#rows, 9) do
            local r = rows[i]
            line[#line + 1] = ('%s %.1f ms/sec, %.2f max'):format(r.name, r.t / secs, perf.max[r.name] or 0)
            if #line == 3 or i == math.min(#rows, 9) then
                log_line('timing, by section: ' .. table.concat(line, '; ') .. '.', 'DETAIL')
                line = {}
            end
        end
    end
    perf.t, perf.n, perf.max, perf.frames, perf.why, perf.since = {}, {}, {}, {}, {}, os.clock()
end

-- ==========================================
-- THE LIST, UNCHANGED (2026-11-03)
-- ==========================================
-- MEASURED (test 38, 2026-11-03, THE LOOP'S OWN TIMING above): with a
-- pile's settings open this loop cost up to 375 ms/sec, 165 ms in the
-- worst frame, and DF fell to about 12 frames a second (clicks slow,
-- scroll bars choppy). Rows hidden, hidden bytes kept, search filter and
-- rows put in each walk every live row of the list, and they ran every
-- frame, though nearly every frame the list is exactly as the last pass
-- left it.
--
-- So the list on screen is kept three ways:
--   * a signature: the pile and list, the live and shown counts, the
--     pool's length, the search text, the entries' version, the typed pile
--     generation, and the entries of the first and last live rows;
--   * the live row pointers, compared with one memcmp: DF reorders and
--     swaps rows when it builds a list;
--   * the bytes of the group on screen, through RAW COPIES (the group is
--     named by cur_main_mode_flag, whose bits are named as the settings'
--     groups: df.building.xml, stockpile_group_set). A click or a button
--     changes them.
-- What changed decides what runs:
--   the list (signature or row pointers)  every pass, as before;
--   only the bytes                        hidden bytes kept alone: a click
--                                         may change the list's colour;
--   nothing                               nothing that walks the rows.
-- Scrolling changes none of these (scroll_position_spec is not read), so
-- it costs nothing.
--
-- Recorded after the frame's passes, so this loop's own writes are not
-- read as a change. Another script's write (RM's windows edit rows out)
-- costs one pass, and both are settled after it. A frame that waited for
-- DF to build the list records nothing, so the next frame runs every pass.
local GROUP_NAMES = { 'animals', 'food', 'furniture', 'corpses', 'refuse', 'stone', 'ammo',
    'coins', 'bars_blocks', 'gems', 'finished_goods', 'leather', 'cloth', 'wood', 'weapons',
    'armor', 'sheet' }
-- sig: the signature; buf, cap, n: the row pointer copy, its size in
-- bytes and the rows it holds; groups_w, groups: the group flag last read
-- and its group set.
local LS = { sig = nil, buf = nil, cap = 0, n = 0, groups_w = nil, groups = {} }

-- The groups of the list on screen, worked out again only when the flag
-- changes.
local function screen_groups(cs)
    local w = cs.cur_main_mode_flag.whole
    if w == LS.groups_w then return LS.groups end
    local g = {}
    for _, name in ipairs(GROUP_NAMES) do
        if cs.cur_main_mode_flag[name] then g[name] = true end
    end
    LS.groups_w, LS.groups = w, g
    return g
end

local function list_sig(cs, here)
    local n = cs.cur_spec_item_sz
    local a0, a1 = 0, 0
    if n > 0 then
        local p0, p1 = cs.spec_item[0].set_pointer, cs.spec_item[n - 1].set_pointer
        a0 = p0 and addr_of(p0) or 0
        a1 = p1 and addr_of(p1) or 0
    end
    return ('%s|%d|%d|%d|%s|%s|%s|%x|%x'):format(here, n, cs.counted_cur_spec_item_sz,
        #cs.spec_item, tostring(cs.spec_filter or ''), tostring(sh.version()),
        tostring(_G.stockhook_type_gen), a0, a1)
end

-- The pool's row pointer array: the data pointer, the vector's first word
-- (as RAW COPIES reads a byte vector's). Eight bytes a row.
local function rows_data(cs)
    return df.reinterpret_cast('uint64_t', addr_of(cs.spec_item)).value
end

-- True when the live row pointers are those of the last record.
local function rows_same(cs)
    local n = cs.cur_spec_item_sz
    if not LS.buf or LS.n ~= n then return false end
    if n == 0 then return true end
    return dfhack.internal.memcmp(LS.buf, rows_data(cs), n * 8) == 0
end

-- The list as this frame leaves it.
local function list_record(cs, here)
    local n = cs.cur_spec_item_sz
    local bytes = math.max(n * 8, 8)
    if not LS.buf or LS.cap < bytes then
        if LS.buf then pcall(df.delete, LS.buf) end
        LS.buf, LS.cap = df.new('uint8_t', bytes), bytes
    end
    if n > 0 then dfhack.internal.memmove(LS.buf, rows_data(cs), n * 8) end
    LS.n = n
    LS.sig = list_sig(cs, here)
    raw_unchanged('list', cs.sp, screen_groups(cs))
end

-- gen: the loop's generation. stop() and start() each begin a new one, so
-- a chain left from before ends instead of running beside the new one.
local function step(gen)
    if not R.running or gen ~= R.gen then return end
    local t_step = pnow()
    local ok, err = pcall(function()
        local t = t_step
        local cs = df.global.game.main_interface.custom_stockpile
        local pile = cs.open and cs.abd or nil
        -- THE STONE FLAG, WHILE STOPPED: every frame, open or not, so the
        -- stopped count stays true and the flag is back the moment it must be.
        local stopped = game_stopped()
        local is_pile = pile and df.building_stockpilest:is_instance(pile)
        if is_pile and stopped and #moved_mis > 0 then stone_take() else stone_back() end
        t = plap('stone flag', t)
        if is_pile then
            pstate('menu')
            -- THE ROWS, REBUILT WHEN THE ENTRIES CHANGE.
            refresh_slots()
            -- The sheet's record goes: it is taken afresh once the menu
            -- closes (THE STOCKPILE SHEET'S BUTTONS).
            sheet = nil
            if open_pile ~= pile.id then load_pile(pile) end
            t = plap('menu: slots, pile load', t)
            if #slots > 0 or #moved_mis > 0 or #extra_hides > 0 then
                -- ---- WAIT FOR DF TO BUILD THE LIST ----
                -- Measured in play (test 5): DF fills a newly selected list
                -- a moment after selecting it, and apparently only while it
                -- is still empty. A row put in first made DF skip the build
                -- (an empty list on first open, "only Cinders" after a
                -- switch). So rows go in only once the list has DF's own
                -- rows, and never in the frame the list or pile changed.
                --
                -- SEEN EMPTY. That wait cost one drawn frame: DF's list
                -- showed without our rows, then with them, a visible
                -- shuffle once rows sat among DF's (test 23). So when this
                -- list was seen EMPTY (DF cleared it, about to build), rows
                -- go in the first frame it has rows: DF has built it then.
                --
                -- POOL CHANGED. Most lists are never seen empty: DF clears
                -- and builds them within one frame, so the wait still drew
                -- one frame without our rows, or with the moved rows still
                -- in place (2026-11-02, in play: rows moving in Furniture,
                -- Weapons, Armor and Ammo: other materials, Stone: other
                -- stone). The pool as this loop left it last frame is kept
                -- (pool_sig); when the list changed and the pool is no
                -- longer as left, DF has rebuilt it, so rows go in now. A
                -- pool still as left is the old list's, and is waited on.
                local here = ('%d:%d'):format(pile.id, cs.cur_sub_mode)
                if cs.cur_spec_item_sz == 0 then R.empty_seen = here end
                local rebuilt = here ~= R.last_list and R.pool_sig ~= nil
                    and pool_sig(cs) ~= R.pool_sig
                local built = cs.cur_spec_item_sz > 0
                    and (here == R.last_list or here == R.empty_seen or rebuilt)
                R.last_list = here
                -- THE LIST, UNCHANGED: what changed decides what runs. Only
                -- a list DF has built is ever taken as unchanged.
                local list_same = built and LS.sig ~= nil and LS.sig == list_sig(cs, here)
                    and rows_same(cs)
                local bytes_same = list_same and raw_unchanged('list', cs.sp, screen_groups(cs))
                -- ---- WHAT CHANGED THE LIST (2026-11-03) ----
                -- SEEN (test 42): after a group's all, the walks ran nearly
                -- every frame for ten seconds (hidden bytes kept at 488
                -- ms/sec, 521 frames), so something kept changing the list.
                -- Each frame that walks is counted under what changed: the
                -- parts of the signature that differ (live, shown, pool,
                -- search, version, typed, first, last), rows (the pointers
                -- alone), new (no record: a list just opened or built),
                -- waiting (DF has not built it), or bytes. The report names
                -- them, so the cause is read, not guessed.
                local cause = nil
                if not built then
                    cause = 'waiting'
                elseif LS.sig == nil then
                    cause = 'new'
                elseif not list_same then
                    local now = list_sig(cs, here)
                    if now == LS.sig then
                        cause = 'rows'
                    else
                        local a, b = {}, {}
                        for x in (LS.sig .. '|'):gmatch('(.-)|') do a[#a + 1] = x end
                        for x in (now .. '|'):gmatch('(.-)|') do b[#b + 1] = x end
                        local names = { 'list', 'live', 'shown', 'pool', 'search', 'version',
                            'typed', 'first', 'last' }
                        local diff = {}
                        for i, nm in ipairs(names) do
                            if a[i] ~= b[i] then diff[#diff + 1] = nm end
                        end
                        cause = #diff > 0 and table.concat(diff, '+') or 'signature'
                        -- THE SHOWN COUNT ALONE: who wrote it, and was it right?
                        -- The first SHOWN_SAY of a session are logged with the
                        -- count recorded, the count now, and the live rows that
                        -- are actually on. At DETAIL (2026-11-06): a record for
                        -- debugging, not a fault, and as a WARNING it showed in
                        -- the log's Quiet view (SEEN twice, session log
                        -- 2026-11-05: 166 -> 157 with 157 rows on, the new
                        -- count right both times).
                        if cause == 'shown' and (R.shown_said or 0) < 5 then
                            R.shown_said = (R.shown_said or 0) + 1
                            local on = 0
                            for i = 0, cs.cur_spec_item_sz - 1 do
                                if cs.spec_item[i].on then on = on + 1 end
                            end
                            log_line(('list %s: the shown count alone moved, %s -> %s; live rows'
                                .. ' on: %d of %d.'):format(here, tostring(a[3]), tostring(b[3]), on,
                                cs.cur_spec_item_sz), 'DETAIL')
                        end
                    end
                elseif not bytes_same then
                    cause = 'bytes'
                end
                if cause then perf.why[cause] = (perf.why[cause] or 0) + 1 end
                t = plap('menu: list unchanged?', t)
                -- The moved rows of this list: read by the walks below, which
                -- run only when the list changed; otherwise those found for
                -- this same list are still right.
                if not list_same then
                    find_moved_here(cs)
                    -- ROWS STOCKHOOK OWNS, FOR RM'S WINDOWS (2026-11-03): the
                    -- moved rows of this list by entry address, so RM's windows
                    -- leave them alone (refinish-stockpile-windows.lua,
                    -- settings_rows). A moved row aims at DF's own entry, so a
                    -- hide RM's windows keep for the material read it as one of
                    -- theirs, turned it off and lowered the shown count, and
                    -- the search filter here turned it back on: suspected as
                    -- the shown count ping-pong (test 43, WHAT CHANGED THE LIST).
                    _G.stockhook_rows_owned = moved_here
                end
                t = plap('menu: moved rows found', t)
                if built and not list_same then
                    hide_rows(cs)
                    t = plap('menu: rows hidden', t)
                    mirror_free(cs, here)
                    t = plap('menu: hidden bytes kept', t)
                    local added = insert_rows(cs, cs.cur_sub_mode) + insert_moved(cs)
                    t = plap('menu: rows put in', t)
                    name_masters(cs, cs.cur_sub_mode)
                    if added > 0 then place_rows(cs) end
                    t = plap('menu: (all) names, order', t)
                elseif built and not bytes_same then
                    mirror_quick(cs, here)     -- THE ROWS IT COUNTS, KEPT
                    t = plap('menu: hidden bytes kept', t)
                end
                if not list_same then apply_filter(cs) end
                R.pool_sig = pool_sig(cs)
                t = plap('menu: search filter', t)
                check_groups(cs, pile)
                t = plap('menu: group all/none', t)
                -- VANILLA ROW CLICKS: a vanilla row's byte is in the group
                -- on screen (check_masters), so with the list and its bytes
                -- unchanged no vanilla row was clicked. MEASURED (test 40):
                -- 17 to 26 ms/sec run every frame regardless.
                if not (list_same and bytes_same) then check_masters(cs, pile) end
                t = plap('menu: (all) row clicks', t)
                apply_bytes(pile)
                t = plap('menu: row clicks', t)
                -- Recorded last, after every write of this frame. A frame
                -- in which nothing changed has nothing new to record.
                if not built then
                    LS.sig = nil
                elseif not (list_same and bytes_same) then
                    list_record(cs, here)
                    t = plap('menu: list recorded', t)
                end
            end
        elseif open_pile then
            pstate('closing')
            LS.sig = nil        -- THE LIST, UNCHANGED: taken afresh at the next opening
            _G.stockhook_rows_owned = nil   -- ROWS STOCKHOOK OWNS: the menu is shut
            -- ---- THE SCREEN CLOSED: TYPE THE PILE AGAIN ----
            -- Measured (2026-11-01, pile 7140): with Cinders on, the group
            -- switches read 320 while the screen was open and 0 once it
            -- closed. On close DF switches off every group whose vanilla
            -- entries are all off, and a module-only group looks that way
            -- to DF. So the pile is typed again once DF is done: now, and
            -- again a few frames later in case DF's clean-up lands late.
            local id = open_pile
            open_pile, warned_full = nil, false
            local function retype()
                local p = df.building.find(id)
                if p then
                    local ok2, err2 = pcall(sh.ensure_types, p)
                    if not ok2 then log_line('pile type: ' .. tostring(err2)) end
                end
            end
            retype()
            dfhack.timeout(10, 'frames', retype)
        else
            -- THE STOCKPILE SHEET'S BUTTONS: the settings menu is shut.
            -- EVERY FEW FRAMES (2026-11-03): MEASURED (test 43) at 10 to 18
            -- ms/sec for as long as a pile is selected, every frame. A button
            -- is found by comparing the pile now with the pile last looked at,
            -- so looking every SHEET_EVERY frames finds the same press, a
            -- tenth of a second later at most, at a fraction of the cost.
            R.sheet_wait = (R.sheet_wait or 0) - 1
            if R.sheet_wait <= 0 then
                R.sheet_wait = SHEET_EVERY
                check_sheet()
            end
            pstate(sheet and 'sheet' or 'idle')
            t = plap(sheet and 'sheet: watch' or 'idle: sheet looked for', t)
        end
    end)
    plap('whole step', t_step)
    -- THE REPORT NEVER STOPS THE LOOP (2026-11-03): SEEN in play (test
    -- 39, stderr.log), a section with no max made this format throw; the
    -- error left step before it scheduled its next frame, and the loop
    -- died: no rows of ours in the settings, the sheet's All not followed.
    -- So the report runs under a pcall, and a failure is logged once.
    local okr, errr = pcall(perf_report)
    if not okr then
        perf.t, perf.n, perf.max, perf.frames, perf.why, perf.since = {}, {}, {}, {}, {}, os.clock()
        if not R.perf_err_said then
            R.perf_err_said = true
            log_line('rows: the timing report failed: ' .. tostring(errr), 'ERROR')
        end
    end
    if not ok then log_line('rows: ' .. tostring(err)) end
    dfhack.timeout(1, 'frames', function() step(gen) end)
end

-- ---- DIAGNOSTIC: THE LIVE ROWS ----
-- refinish-stockhook rows (console, with a pile's settings open): every live row of
-- the list on screen, with the fields DF may draw a row from. For finding
-- why a row does not show in a list (test 17: Oak beds in Furniture: type).
function dump()
    local cs = df.global.game.main_interface.custom_stockpile
    if not cs.open then print('open a pile\'s settings first'); return end
    print(('list %s (%d): %d live row(s), %d shown, pool %d'):format(
        tostring(df.stockpile_list[cs.cur_sub_mode]), cs.cur_sub_mode,
        cs.cur_spec_item_sz, cs.counted_cur_spec_item_sz, #cs.spec_item))
    for i = 0, cs.cur_spec_item_sz - 1 do
        local r = cs.spec_item[i]
        print(('  %3d %-28s ours %-5s on %-5s race %d itype %d istype %d isc1 %d isc2 %d'):format(
            i, tostring(r.name), tostring(our_byte(r) ~= nil), tostring(r.on),
            r.race, r.itype, r.istype, r.isc1, r.isc2))
    end
    local mine = {}
    for _, s in ipairs(slots) do mine[#mine + 1] = ('%s -> %s'):format(s.label, tostring(df.stockpile_list[s.list])) end
    print('  Stockhook rows and their lists: ' .. (#mine > 0 and table.concat(mine, '; ') or '(none)'))
end

function start()
    if R.running then return end
    R.running = true
    R.gen = (R.gen or 0) + 1
    local gen = R.gen
    dfhack.timeout(1, 'frames', function() step(gen) end)
end

-- Ends the loop (refinish-stockhook.lua, ONE WORLD ONLY). The pile whose bytes were
-- loaded is forgotten, so the next start loads afresh.
function stop()
    R.running = false
    R.gen = (R.gen or 0) + 1
    open_pile, slot_sig, R.last_list, R.slot_ver, R.empty_seen = nil, nil, nil, nil, nil
    R.pool_sig = nil
    twin_here = nil
    sheet = nil         -- THE STOCKPILE SHEET'S BUTTONS, taken afresh
    BC.valid = false    -- CLICKS, ONLY WHEN A BYTE MOVED
    MF.here, MF.refs, MF.twins = nil, nil, nil   -- THE ROWS IT COUNTS, KEPT
    EA.owner, EA.vecs = nil, {}                  -- VECTORS FOUND ONCE
    _G.stockhook_rows_owned = nil                -- ROWS STOCKHOOK OWNS
    for ctx, r in pairs(raw) do free_raw(r); raw[ctx] = nil end   -- RAW COPIES
    -- THE LIST, UNCHANGED: forgotten, its row pointer copy freed.
    if LS.buf then pcall(df.delete, LS.buf) end
    LS.sig, LS.buf, LS.cap, LS.n, LS.groups_w, LS.groups = nil, nil, 0, 0, nil, {}
    stone_back()        -- THE STONE FLAG: never left off past the loop
end