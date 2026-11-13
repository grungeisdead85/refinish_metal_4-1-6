--@ module = true
-- refinish-mint-finish.lua
-- ==========================================
-- FINISHES, MINTED ONCE THE FORT CAN MAKE THEM
-- ==========================================
-- WHY
--
-- Until 2026-10-02 every finish in the blueprint was injected at load:
-- 61,392 materials and 99,574 reactions with all 81 base metals selected.
-- DF builds several lists over every metal it knows, and they grew with
-- the finishes. MEASURED that day:
--   * New work order: 4,922,677 templates with no finish reaction
--     permitted at all, 4,919,214 of them builtin jobs (about 80 per
--     metal), 13 to 16 s to open before RM's own passes over the list
--     (refinish-orders-probe).
--   * The material picker behind the magnifying glass: all 62,606
--     inorganics for a bar, block, rough gem, powder or liquid, about
--     5 s to open (refinish-picker-probe).
--   * The forge's item categories: 61,442 rows each.
--
-- A finish is made from bars of its base metal and one dust, in a
-- reaction that names that dust: a tool reagent gets no magnifying glass,
-- so the dust cannot be picked in the job, which is why there is one
-- reaction per base metal and dust. So a pair of base and dust is minted
-- once the fort has had both: the base metal's bars and the dust. What is
-- loaded then grows with what a fort works, not with what RM could make.
--
-- WHAT STAYS
--
-- refinish-scan still builds the whole blueprint every data cycle. It is
-- the catalog: every finish and reaction as data, minted from here.
--
-- THE ROSTER (site data, REFINISH_STEEL_FINISH_ROSTER)
--
-- One line per event, in the order it happened, never removed:
--   S B <base>     the fort has had bars of this base metal
--   S D <dust>     the fort has had dust of this material
--   M <finish>     a finish material minted
-- ORDER IS THE CONTRACT for materials. An item stores a mat_index, and
-- RM's materials are not in the save, so every load has to put them back
-- where they were. Step 4 mints the M lines in roster order, and every
-- mint since was appended to the array and to the roster alike, so the
-- replay rebuilds the session's layout and the ledger's fingerprint
-- finds nothing to move. When it cannot (another script's material
-- appended between two mints), the ledger moves objects by name, as it
-- does for everything else.
--
-- Reactions are not in the roster. Step 5 builds every pair the S lines
-- allow, grouped by category and sorted as the full set always was, so
-- a finishing menu reads the same. A pair minted in play is appended
-- instead, so a load can move it: the repoint at the end of
-- refinish-index-reaction.lua points saved jobs back at their reactions.
--
-- A line the blueprint cannot make this cycle (its base metal not
-- selected, Material Finishes off) is skipped, never dropped: the ledger
-- parks the objects that wear the finish, as before, and they get it back
-- when the finish is minted again.
--
-- WHO CALLS WHAT
--   Step 4    refinish-index           load_materials()
--   Step 5    refinish-index-reaction  set_shell(), minted_reactions(),
--                                      build_reaction(), folders(),
--                                      build_placeholder(), finish_load()
--   Step 6.5  refinish-ledger          _G.refinish_mint_finish_on_demand:
--   Step 7    refinish-load              a finish an object wears, minted
--                                        instead of the object parked
--   Step 6.7  refinish-startup         reconcile(): the bars and dusts in
--                                      the fort, and the pairs they make
--   in play   refinish-mint-finish-watch
--                                      notice(), dust_subtype(): a bar or
--                                      dust from the moment it exists
-- ==========================================

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, composed by refinish-log: SYSTEM SUBSYSTEM SUBJECT
-- TYPE | body. DETAIL is debugging material, INFO what a player might
-- check during play, WARNING and ERROR are faults. No console prints:
-- nothing here answers a typed command.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MINT_FINISH'
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
            tostring(subject or '-'), tostring(typ or 'UNTYPED'), tostring(msg))
    end
    _G.refinish_log_event(line)
end

-- ==========================================
-- SETTINGS
-- ==========================================
-- Site data key, beside the ledger's (REFINISH_STEEL_LEDGER). The first
-- line of the stored text names the format: any other first line is not
-- this format, and the roster starts again rather than being misread.
local ROSTER_KEY    = 'REFINISH_STEEL_FINISH_ROSTER'
local ROSTER_FORMAT = 'RM_FINISH_ROSTER 1'

-- The metal grinder's class, granted at Step 5 to the metals the grinder
-- may take (refinish-index-reaction.lua, THE METAL GRINDER'S CLASS) and
-- taken back at shutdown by refinish-clear-reaction.lua.
local GRIND_METAL_CLASS = 'unfinished metal'   -- words, as refinish-index-reaction.lua writes them

-- The finished-metal grinders (THE FINISHED-METAL GRINDERS): each one's
-- code is FIN_GRIND_CODE with the base metal's id on the end, the class
-- its input takes is FIN_GRIND_CLASS with the base's name (fin_words_of:
-- words, so DF's hover and objection read "150 finished steel bars"), and
-- all of them are filed under the one category.
local FIN_GRIND_CODE  = 'REFINISH_STEEL_RXN_LUA_GRIND_FIN_'
local FIN_GRIND_CLASS = 'finished '
local FIN_GRIND_CAT   = 'REFINISH_STEEL_CAT_GRIND_FINISHED'
local METAL_GRINDER   = 'REFINISH_STEEL_RXN_LUA_GRIND_METAL'

-- Where the forge folder placeholders are built (THE FORGE'S FOLDER
-- PLACEHOLDERS, below).
local WORKSHOP = df.building_type.Workshop
local FORGE_AT = { df.workshop_type.MetalsmithsForge, df.workshop_type.MagmaForge }

-- A finish's kind, read off its id: inside each base folder the forge
-- has a folder per kind (refinish-scan.lua, THE FORGE'S FOLDERS, THE
-- KINDS). nil for an id that is neither, which gets no folder.
local function finish_kind(id)
    if id:find('REFINISH_STEEL_MAT_COLOUR_', 1, true) == 1 then return 'COLOUR' end
    if id:find('REFINISH_STEEL_MAT_SPECIFIC_', 1, true) == 1 then return 'MATERIAL' end
    return nil
end

-- ==========================================
-- STATE
-- ==========================================
-- S is the roster as read at Step 4 and grown since, and what this data
-- cycle has built. load_materials() makes it new each cycle, so nothing
-- here outlives a cycle except what is written to site data. It belongs
-- to the blueprint it was made on: refinish-clear drops the blueprint at
-- shutdown, so a mint asked for after that finds S.bp is not the current
-- blueprint and does nothing.
-- ==========================================
local S = nil

local function fresh_state(bp)
    return {
        bp        = bp,
        cat       = nil,   -- THE CATALOG
        lines     = {},    -- every roster line, in order
        order_b   = {},    -- base metals, in the order the fort had their bars
        order_d   = {},    -- dust materials, in the order the fort had them
        seen_b    = {},    -- the same two, as sets
        seen_d    = {},
        m_line    = {},    -- finish id -> it has an M line
        built     = {},    -- pair key -> its reactions built this cycle
        placed    = {},    -- base id -> kind -> its folder's placeholder built this cycle
        fin_class = {},    -- base id -> its finished-metal grinder's class string
        fin_words = {},    -- base id -> the words that string holds (fin_words_of)
        fin_taken = {},    -- words -> the base holding them, so no two share
        fin_grind = {},    -- base id -> its finished-metal grinder built this cycle
        has_fin   = {},    -- base id -> kind -> a finish of that kind is in the array
        plans     = {},    -- base id -> what assign left to write
        bar_codes = {},    -- base id -> its bar reagent's code, "<id>_bar"
        shell     = nil,   -- set_shell(), Step 5
        live      = false, -- Step 5 is done: a mint may build placeholders
        dirty     = false, -- the roster changed since it was last saved
        s_rassign = 0,     -- the load clock's reaction new and assign, ms
        on_demand = 0,     -- finishes minted for objects that wear them
    }
end

-- The state for the current blueprint, or nil when there is none: before
-- Step 4 of this cycle, or after the shutdown dropped the blueprint.
local function current()
    local st = S
    if st and st.bp and st.bp == _G.refinish_blueprint then return st end
    return nil
end

-- ==========================================
-- THE ROSTER
-- ==========================================
-- Plain text, one event a line, read and written whole through the
-- String variants of site data. The ledger's SITE DATA TEXT explains why:
-- saveSiteData json-encodes what it is given, and reading a long string
-- back through DFHack's JSON.lua costs the square of its length.
-- An id is the rest of its line, spaces and all, because DF allows them
-- in vanilla ids.
-- ==========================================
local function pair_key(b, d) return b .. '\t' .. d end

-- One line applied to the sets. false for a line not understood.
local function apply_line(st, line)
    local kind, rest = line:sub(1, 2), line:sub(3)
    if rest == '' then return false end
    if kind == 'M ' then
        st.m_line[rest] = true
        return true
    elseif kind == 'S ' then
        local which, id = rest:sub(1, 2), rest:sub(3)
        if id == '' then return false end
        if which == 'B ' then
            if not st.seen_b[id] then
                st.seen_b[id] = true
                st.order_b[#st.order_b + 1] = id
            end
            return true
        elseif which == 'D ' then
            if not st.seen_d[id] then
                st.seen_d[id] = true
                st.order_d[#st.order_d + 1] = id
            end
            return true
        end
    end
    return false
end

-- The stored roster, read into st. Returns what was found: 'read' (with
-- the count of lines not understood), 'none', 'format', 'other site'
-- (with that site's id), or 'error' (with the message).
local function roster_read(st)
    local ok, raw = pcall(dfhack.persistent.getSiteDataString, ROSTER_KEY)
    if not ok then return 'error', tostring(raw) end
    if not raw or raw == '' then return 'none' end
    local n, bad = 0, 0
    for line in raw:gmatch('[^\n]+') do
        n = n + 1
        if n == 1 then
            if line ~= ROSTER_FORMAT then return 'format' end
        elseif n == 2 then
            -- ---- SITE ID GATE (ANTI-GHOSTING) ----
            -- The ledger's own rule: a roster from another fortress
            -- describes another fort's finishes.
            local site = tonumber(line:match('^site (%-?%d+)$') or '')
            if site ~= df.global.plotinfo.site_id then return 'other site', site end
        elseif apply_line(st, line) then
            st.lines[#st.lines + 1] = line
        else
            bad = bad + 1
        end
    end
    return 'read', bad
end

-- One new event: kept in order, applied, and the roster marked to save.
local function roster_add(st, line)
    if apply_line(st, line) then
        st.lines[#st.lines + 1] = line
        st.dirty = true
    end
end

-- Writes the roster when it changed. A failed write leaves this cycle's
-- arrays as they are; what it would have kept is minted again from the
-- fort's bars and dusts at the next load, and the ledger parks any
-- object whose finish that misses until the finish is minted again.
local function roster_save(st)
    if not st.dirty then return true end
    local text = ROSTER_FORMAT .. '\nsite ' .. tostring(df.global.plotinfo.site_id)
        .. '\n' .. table.concat(st.lines, '\n')
    local ok, err = pcall(dfhack.persistent.saveSiteDataString, ROSTER_KEY, text)
    if not ok then
        -- ERROR: see above for what a missed write costs.
        log('ERROR', 'Finish roster could not be saved: ' .. tostring(err), 'ROSTER')
        return false
    end
    st.dirty = false
    return true
end

-- ==========================================
-- THE CATALOG
-- ==========================================
-- What the blueprint can mint, indexed for the questions a mint asks:
--   bases   base metal ids with finishes this cycle (the selected ones)
--   dusts   dust material ids some finish reaction takes
--   pairs   base -> dust -> that pair's reaction ids, sorted
-- Built once per cycle from refinish-scan's own entries: each finish
-- reaction already names its base (base_metal_id) and its dust
-- (reagent_id).
--
-- ---- SORTED WITHOUT A LUA COMPARATOR ----
-- Kept from refinish-index-reaction.lua, which sorted all 99,574 finish
-- reactions. MEASURED 2026-10-01 (the load clock, region4): the old Lua
-- comparator, called about two million times, cost 523 ms in the
-- sandbox against 100 ms for the same order made by grouping on
-- category and sorting with table.sort's own <, which compares strings
-- in C. Every sort here uses that own <.
-- ==========================================
local function build_catalog(bp)
    local cat = { bases = {}, dusts = {}, pairs = {} }
    if bp.forge and bp.forge.bases then
        for b in pairs(bp.forge.bases) do cat.bases[b] = true end
    end
    for rxn_id, data in pairs(bp.reactions) do
        local b, d = data.base_metal_id, data.reagent_id
        if b and d then
            cat.bases[b] = true
            cat.dusts[d] = true
            local by_d = cat.pairs[b]
            if not by_d then
                by_d = {}
                cat.pairs[b] = by_d
            end
            local list = by_d[d]
            if not list then
                list = {}
                by_d[d] = list
            end
            list[#list + 1] = rxn_id
        end
    end
    for _, by_d in pairs(cat.pairs) do
        for _, list in pairs(by_d) do
            if #list > 1 then table.sort(list) end
        end
    end
    return cat
end

-- ==========================================
-- LOOKUPS
-- ==========================================
-- index_of(id): an inorganic's position, from a table checked against the
-- live array, so a hit is trusted only while that position still holds
-- the id. A miss walks the array once and rebuilds the table, unless the
-- array has kept the length of the last walk, in which case the id is
-- simply not there. A mint here writes its own entry.
-- ==========================================
local idx_of, idx_len = {}, -1

local function index_of(id)
    local arr = df.global.world.raws.inorganics.all
    local n = #arr
    local i = idx_of[id]
    if i and i < n and arr[i].id == id then return i end
    if i == nil and n == idx_len then return nil end
    local t = {}
    for k = 0, n - 1 do
        local kid = arr[k].id
        if t[kid] == nil then t[kid] = k end
    end
    idx_of, idx_len = t, n
    return t[id]
end

-- What a mint did, for its caller's log and for the permissions a mint
-- after Step 6 has to grant itself.
local function new_out()
    return { mats = 0, rxns = 0, folders = 0, grinders = 0, by_base = {}, new_b = {}, new_d = {} }
end

-- A log list of ids: the first few, then how many more.
local function some(ids, max)
    if #ids == 0 then return 'none' end
    if #ids <= max then return table.concat(ids, ', ') end
    return table.concat(ids, ', ', 1, max) .. (' and %d more'):format(#ids - max)
end

local function add_index(by_base, b, idx)
    local list = by_base[b]
    if not list then
        list = {}
        by_base[b] = list
    end
    list[#list + 1] = idx
end

-- ==========================================
-- THE MATERIAL BUILDER
-- ==========================================
-- Moved here from refinish-index.lua (2026-10-02), so the load and a mint
-- in play build a finish the same way. A finish is its base metal copied
-- whole (assign), then given its own id, names, colours and value.
--
-- ---- ONLY WHAT ASSIGN LEFT TO DO ----
-- assign copies the base metal whole: its flags, colours, tile and
-- symbol. So a flag below that the base metal already has, or a fixed
-- value it already holds, would be written as the value it already is.
-- Which of those writes change anything is read once per base metal,
-- off its first finish just after assign, and only those are made for
-- its finishes: every field ends with the same value as before.
-- MEASURED 2026-10-01 (the load clock, region4): this loop cost 624 ms
-- for 61,392 materials, new and assign 123 of it, and the eleven flags
-- and seven fixed values were 19 of a material's 43 reads and writes.
--
-- ---- EACH STRUCT READ ONCE ----
-- MEASURED 2026-10-01, the load clock, region4: this loop cost
-- 1,781 ms for 61,392 materials, and new and assign were 145 ms of
-- it. The rest was the writes below: each named m.material and
-- the struct under it again, so a flag write was three reads and
-- writes through DFHack and a material took about 90. Each struct
-- is now read once into a local and written through it: the same
-- fields, the same values, in the same order, about half the
-- crossings.
--
-- ---- THE GRINDER'S CLASS STAYS ON THE BASE ----
-- Step 5 grants GRIND_METAL_CLASS to the metals the metal grinder
-- may take, and a finish minted after it copies whatever its base metal
-- carries, so the entry is erased from the copy. The class keeps the
-- metal grinder's material picker to base metals: every material that
-- carries it is counted when the picker opens, and the finishes it was
-- put on for a day (2026-10-03) slowed it in play, few as they were.
-- Erased only, never freed: the string belongs to the base metal, and
-- refinish-clear-reaction.lua frees each one once. At Step 4 no metal
-- carries it yet, and this finds nothing. Finished bars are ground at
-- grinders of their own (THE FINISHED-METAL GRINDERS).
--
-- ---- THE FINISHED-METAL GRINDER'S CLASS ----
-- Every finish carries its base's words (fin_words_of) instead, the
-- class its base's finished-metal grinder takes, so that grinder's
-- picker counts that base's finishes and nothing else. One string per
-- base a cycle (fin_class_of), put on each finish of the base; the bases
-- it holds are the ones with a finish in the array. Erased and freed at
-- shutdown by refinish-clear-reaction.lua with the metal grinder's
-- class, before refinish-clear.lua deletes the finishes.
-- ==========================================
local FORCED_FLAGS = { 'IS_METAL', 'ITEMS_METAL', 'ITEMS_HARD', 'ITEMS_BARRED',
    'ITEMS_SCALED', 'ITEMS_WEAPON', 'ITEMS_WEAPON_RANGED', 'ITEMS_AMMO',
    'ITEMS_DIGGER', 'ITEMS_ARMOR', 'ITEMS_ANVIL' }

local function plan_for(mat)
    local flags, need = mat.flags, {}
    for _, f in ipairs(FORCED_FLAGS) do
        if not flags[f] then need[#need + 1] = f end
    end
    local bc, sc, tc = mat.build_color, mat.basic_color, mat.tile_color
    return {
        flags  = need,
        build1 = bc[1] ~= 0,
        build2 = bc[2] ~= 1,
        basic1 = sc[1] ~= 1,
        tile1  = tc[1] ~= 0,
        tile2  = tc[2] ~= 1,
        tile   = mat.tile ~= 219,
        symbol = mat.item_symbol ~= 7,
    }
end

-- Builds one finish and appends it to the inorganics. Returns its index,
-- and the ms new and assign took when the load clock (lc) is running.
-- The base's finished-metal grinder class, as the string every finish of
-- that base holds (THE FINISHED-METAL GRINDER'S CLASS): made the first
-- time a cycle asks, then the same pointer for the rest of the cycle.
-- reaction_class holds string pointers, so one is allocated for it, its
-- text on .value.
-- base_name is defined with the finished-metal grinders, below; declared
-- here so fin_words_of can call it.
local base_name

-- The words a base's finished-metal grinder takes, made once a cycle:
-- FIN_GRIND_CLASS and the base's name, as the grinder's own name reads.
-- The words ARE the class, so no two bases share them: a second base of
-- the same name gets its id after it. Each set is published on _G for
-- refinish-clear-reaction.lua, which takes the strings back by them.
local function fin_words_of(st, base_id)
    local w = st.fin_words[base_id]
    if w then return w end
    local name = string.lower(base_id)
    pcall(function() name = base_name(st, base_id) end)
    w = FIN_GRIND_CLASS .. name
    if st.fin_taken[w] and st.fin_taken[w] ~= base_id then
        w = w .. ' (' .. string.lower(base_id) .. ')'
    end
    st.fin_words[base_id] = w
    st.fin_taken[w] = base_id
    _G.refinish_grind_fin_words = _G.refinish_grind_fin_words or {}
    _G.refinish_grind_fin_words[w] = true
    return w
end

local function fin_class_of(st, base_id)
    local p = st.fin_class[base_id]
    if not p then
        p = df.new('string')
        p.value = fin_words_of(st, base_id)
        st.fin_class[base_id] = p
    end
    return p
end

-- No mineral dye class on a finish (2026-10-04). Until then each finish
-- was given REFINISH_DYE_<colour id> here, for dye reactions that asked
-- for a class; a material carrying a class is economic
-- (RM_MODULE_ENGINE_README.md, 6.8). The dyes now take each material's
-- dust by name, one reaction per material (refinish-dyes.lua, WHICH
-- DUST), and a finish is minted too late for one of its own.

local function build_material(st, mat_id, data, source_metal, lc)
    -- Create a blank object and deep-copy the base metal's integers into it
    local ta = lc and lc.now()
    local m = df.inorganic_raw:new()
    m:assign(source_metal)
    local s_assign = lc and (lc.now() - ta) or 0

    -- The Critical Missing Pointers
    local mat = m.material
    m.id = mat_id
    mat.id = mat_id

    -- Manually Re-Inject the BitArray Flags (Fixes the forge/anvil issue)
    -- Only the flags this base metal lacks (ONLY WHAT ASSIGN LEFT TO DO).
    local plan = st.plans[data.base_metal_id]
    if not plan then
        plan = plan_for(mat)
        st.plans[data.base_metal_id] = plan
    end
    local need = plan.flags
    if need[1] then
        local flags = mat.flags
        for i = 1, #need do flags[need[i]] = true end
    end

    -- Overwrite Colors and Names
    local adj = data.adj_name
    local state_name, state_adj = mat.state_name, mat.state_adj
    state_name.Solid = adj
    state_adj.Solid = adj
    state_name.Liquid = "molten " .. adj
    state_adj.Liquid = "molten " .. adj
    state_name.Gas = "boiling " .. adj
    state_adj.Gas = "boiling " .. adj

    -- Push the Steam Graphics State Colors
    local color = data.color_idx
    local state_color = mat.state_color
    state_color.Solid = color
    state_color.Liquid = color
    state_color.Gas = color

    -- Push the Classic ASCII fallback colors (using color_idx as the basic_id)
    local build_color, basic_color = mat.build_color, mat.basic_color
    build_color[0] = color
    if plan.build1 then build_color[1] = 0 end
    if plan.build2 then build_color[2] = 1 end
    basic_color[0] = color
    if plan.basic1 then basic_color[1] = 1 end

    -- Visual Hints for the Graphics Engine
    local tile_color = mat.tile_color
    tile_color[0] = color
    if plan.tile1 then tile_color[1] = 0 end
    if plan.tile2 then tile_color[2] = 1 end
    if plan.tile then mat.tile = 219 end
    if plan.symbol then mat.item_symbol = 7 end

    -- Final Material Value Math
    mat.material_value = data.mat_value

    -- THE GRINDER'S CLASS STAYS ON THE BASE
    local rc = mat.reaction_class
    for i = #rc - 1, 0, -1 do
        local s = rc[i]
        if s and s.value == GRIND_METAL_CLASS then rc:erase(i) end
    end
    -- THE FINISHED-METAL GRINDER'S CLASS
    rc:insert('#', fin_class_of(st, data.base_metal_id))

    -- Append to the absolute end of the raws ('#' appends). Its index is
    -- the length before the insert, written into the lookup table.
    local raws = df.global.world.raws.inorganics.all
    local n = #raws
    raws:insert('#', m)
    if idx_len == n then idx_len = n + 1 end
    idx_of[mat_id] = n
    -- Marked by kind: each kind of the base has its own forge folder
    -- (THE FORGE'S FOLDER PLACEHOLDERS).
    local kind = finish_kind(mat_id)
    if kind then
        local by_kind = st.has_fin[data.base_metal_id]
        if not by_kind then
            by_kind = {}
            st.has_fin[data.base_metal_id] = by_kind
        end
        by_kind[kind] = true
    end
    return n, s_assign
end

-- ==========================================
-- THE REACTION SHELL (refinish-index-reaction.lua, Step 5)
-- ==========================================
-- The template every finish reaction is copied from, and the evaluated
-- shells the placeholders are built on. Handed over at Step 5 every data
-- cycle, so a mint never uses a shell from before the last shutdown.
--   template      the virtual refinish template (a df.reaction of its own)
--   reagents      its reagents read once: { ref, code, type0 }
--   products      its products read once: { ref, is_bar, type0 }
--   fuel_set      the template's own FUEL flag
--   powder_rxn    the evaluated dust shell
--   metal_rgt     the evaluated metal reaction's bar reagent
--   dust_subtype  RM's dust tool's subtype
-- ==========================================
function set_shell(shell)
    local st = current()
    if not st then error('set_shell before load_materials this cycle') end
    st.shell = shell
    st.bar_codes = {}
    st.s_rassign = 0
end

-- The load clock's share of new and assign since the last call, in ms.
function assign_ms()
    local st = current()
    if not st then return 0 end
    local ms = st.s_rassign
    st.s_rassign = 0
    return ms
end

-- ==========================================
-- THE REACTION BUILDER
-- ==========================================
-- Moved here from refinish-index-reaction.lua (2026-10-02), so the load
-- and a mint in play build a finish reaction the same way.
--
-- ---- ONLY WHAT ASSIGN LEFT TO DO ----
-- assign copies the template's reagents, product and flags, so a write
-- below of a value the template already holds changes nothing: type0
-- marks a template reagent or product already on mat_type 0, and
-- fuel_set the template's own FUEL flag. Read once when the shell is
-- made, and those writes are skipped for every reaction. MEASURED
-- 2026-10-01 (the load clock, region4): the loop that built all 99,574
-- finish reactions cost 984 ms; 2,281 ms before the template was read
-- once and the sort lost its Lua comparator.
--
-- Returns the reaction's index, or nil when one of its materials is not
-- in the array.
-- ==========================================
function build_reaction(rxn_id)
    local st = current()
    if not (st and st.shell) then return nil end
    local data = st.bp.reactions[rxn_id]
    if not data then return nil end
    local sh = st.shell

    local reagent_idx = index_of(data.reagent_id)
    local output_idx = index_of(data.output_mat_id)
    -- The input bar is the selected base metal's.
    local base_idx = index_of(data.base_metal_id)
    if not (reagent_idx and output_idx and base_idx) then
        -- A finish option missing from the menu, so worth a WARNING. The
        -- reaction id is too long for the subject column, so it rides in
        -- the body and the base metal is the subject.
        log('WARNING', 'Reaction ' .. rxn_id .. ' not built: a material'
            .. ' index is missing (reagent ' .. tostring(data.reagent_id)
            .. ', output ' .. tostring(data.output_mat_id) .. ').',
            tostring(data.base_metal_id))
        return nil
    end

    local lc = _G.refinish_load_clock
    local ta = lc and lc.now()
    local m = df.reaction:new()
    m:assign(sh.template)
    if lc then st.s_rassign = st.s_rassign + (lc.now() - ta) end

    m.code = rxn_id
    m.name = data.name
    m.category = data.category

    local m_reagents = m.reagents
    m_reagents:resize(0)
    for _, t in ipairs(sh.reagents) do
        local new_rgt = df.reaction_reagent_itemst:new()
        new_rgt:assign(t.ref)

        -- The dust, by its code: it is a tool now, not a powder.
        -- t.code is the template reagent's code, which the assign
        -- just copied into new_rgt.
        if t.code == "dust" then
            if not t.type0 then new_rgt.mat_type = 0 end
            new_rgt.mat_index = reagent_idx
            new_rgt.code = data.dust_code or "dust"

        -- The input bar, swapped to the finish's base metal
        elseif t.code == "steel_bar" then
            new_rgt.mat_index = base_idx
            local bar = st.bar_codes[data.base_metal_id]
            if not bar then
                bar = string.lower(data.base_metal_id) .. "_bar"
                st.bar_codes[data.base_metal_id] = bar
            end
            new_rgt.code = bar
        end

        m_reagents:insert('#', new_rgt)
    end

    local m_products = m.products
    m_products:resize(0)
    for _, t in ipairs(sh.products) do
        local new_prod = df.reaction_product_itemst:new()
        new_prod:assign(t.ref)
        if t.is_bar then
            if not t.type0 then new_prod.mat_type = 0 end
            new_prod.mat_index = output_idx
        end
        m_products:insert('#', new_prod)
    end

    -- The array holds pointers (df.reaction.xml: reactions is a vector of
    -- reaction pointers), so the element just added is m itself: its index
    -- is the length before the insert, and its flag is set on m.
    local arr = df.global.world.raws.reactions.reactions
    local n = #arr
    arr:insert('#', m)
    m.index = n
    if not sh.fuel_set then m.flags.FUEL = true end
    -- Counted by base metal for the civs panel (load_materials).
    local counts = _G.refinish_finish_counts_minted
    if counts then
        local b = data.base_metal_id
        counts[b] = (counts[b] or 0) + 1
    end
    return n
end

-- ==========================================
-- THE FORGE'S FOLDER PLACEHOLDERS
-- ==========================================
-- Moved here from refinish-index-reaction.lua (2026-10-02).
-- refinish-menu-forge.lua files RM's finishes out of the forge's
-- category lists into one folder, refinished metals, holding a folder
-- per base metal, and in each a folder per kind of finish, colour or
-- material (the categories: refinish-scan.lua, THE FORGE'S FOLDERS).
-- MEASURED 2026-10-02 (refinish-forge-menu-probe): DF builds a
-- folder's rows from the reactions at the building filed under its
-- category, and a folder with none dumps the task panel, leaving Add
-- new task dead until the workshop is reopened. So each kind folder gets
-- one reaction, at the metalsmith's forge and the magma forge, filed
-- under it, which also opens the base folder and refinished metals above
-- it. Until 2026-10-03 the base folder had the one reaction and listed
-- all of the base's finishes itself.
-- refinish-menu-forge replaces the row with the kind's finishes, so it
-- is never seen. Should that script not be running, the row reads red
-- and cannot be done: its one reagent is a bar of a reaction class no
-- material carries, and it makes nothing.
--
-- Built on the evaluated shell, as the grinders are. A kind folder gets
-- one only once a finish of that kind is in the array: a folder holding
-- nothing would open on an empty list. Step 5 builds them last, sorted by
-- base id and kind, so positions repeat every cycle; a base's first
-- finish of a kind minted after Step 5 brings that kind's placeholder
-- with it (ensure_folder).
--
-- Returns the placeholder's index. Raises on a failed build, which the
-- caller logs.
-- ==========================================
function build_placeholder(base_id, kind)
    local st = current()
    if not (st and st.shell) then error('no reaction shell this cycle') end
    local base_f = st.bp.forge and st.bp.forge.bases[base_id]
    local f = base_f and base_f.kinds and base_f.kinds[kind]
    if not f then
        error(('no %s forge folder in the blueprint for %s'):format(tostring(kind), tostring(base_id)))
    end
    local sh = st.shell
    local arr = df.global.world.raws.reactions.reactions
    local rxn = df.reaction:new()
    rxn:assign(sh.powder_rxn)
    -- The shell's own descriptions and raw strings stay with it
    -- (refinish-index-reaction.lua, THE TEMPLATE'S IDENTITY, LEFT BEHIND).
    rxn.raw_strings:resize(0)
    rxn.descriptions:resize(0)
    rxn.source_hfid = -1
    rxn.source_enid = -1
    rxn.code = f.rxn
    rxn.name = "refinished " .. base_f.name .. ", " .. f.name
    rxn.skill = df.job_skill.METALCRAFT
    rxn.category = f.token
    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)
    rxn.flags.FUEL = false
    rxn.building.type:resize(0)
    rxn.building.subtype:resize(0)
    rxn.building.custom:resize(0)
    for _, sub in ipairs(FORGE_AT) do
        rxn.building.type:insert('#', WORKSHOP)
        rxn.building.subtype:insert('#', sub)
        rxn.building.custom:insert('#', -1)
    end
    -- The one reagent, which nothing can meet.
    rxn.reagents:resize(0)
    local r = df.reaction_reagent_itemst:new()
    r:assign(sh.metal_rgt)
    r.code = "folder"
    r.mat_type = -1
    r.mat_index = -1
    r.reaction_class = "REFINISH_STEEL_FORGE_FOLDER"
    rxn.reagents:insert('#', r)
    rxn.products:resize(0)
    rxn.index = #arr
    arr:insert('#', rxn)
    local placed = st.placed[base_id]
    if not placed then
        placed = {}
        st.placed[base_id] = placed
    end
    placed[kind] = true
    return rxn.index
end

-- ==========================================
-- THE FINISHED-METAL GRINDERS
-- ==========================================
-- Finished bars may be ground to dust (2026-10-03); the dust melts back
-- into bars of the finish through DF's own melt job (refinish-melt.lua)
-- and no finishing reaction ever takes it,
-- since refinish-scan never makes a finish a reagent. They are kept off
-- the metal grinder: its picker counts every material that carries its
-- class (THE GRINDER'S CLASS STAYS ON THE BASE). Each base metal with a
-- finish in the array gets a grinder of its own instead, at the quern
-- and the millstone, filed under Grind finished metals, taking a bar whose
-- material carries that base's class (THE FINISHED-METAL GRINDER'S
-- CLASS), so its picker counts that base's finishes alone.
--
-- A copy of the metal grinder, so it grinds as that one does: 150 of a
-- bar, the dust measured by refinish-reaction-outputs.lua (its code holds
-- REFINISH_STEEL_RXN_LUA_GRIND_). The JIT watcher in refinish_steel.lua
-- names each job by the bar grabbed, as for the other grinders. Granted
-- with the base's finishes: the handover at Step 6, permit() after it.
--
-- Built just in time, as the placeholders are: Step 5 builds one for each
-- base with a finish (fin_grinder_bases), sorted by base id, so positions
-- repeat every cycle; a base's first finish minted after Step 5 brings
-- its grinder with it (ensure_fin_grinder).
--
-- Returns the grinder's index and code. Raises on a failed build, which
-- the caller logs.
-- ==========================================

-- RM's reaction index answers by code (refinish-resolve.lua, REACTIONS);
-- a walk of the array is the fallback.
local function find_reaction(code)
    local f = _G.refinish_find_reaction
    if f then
        local ok, r = pcall(f, code)
        if ok and r then return r end
    end
    for _, r in ipairs(df.global.world.raws.reactions.reactions) do
        if r.code == code then return r end
    end
    return nil
end

-- The base metal's name: its forge folder's, else its solid state name.
-- Assigns the local declared above fin_words_of.
function base_name(st, base_id)
    local f = st.bp.forge and st.bp.forge.bases and st.bp.forge.bases[base_id]
    if f and f.name and f.name ~= '' then return f.name end
    local i = index_of(base_id)
    if i then
        local n = df.global.world.raws.inorganics.all[i].material.state_name[0]
        if n and n ~= '' then return string.lower(n) end
    end
    return string.lower(base_id)
end

function build_fin_grinder(base_id)
    local st = current()
    if not st then error('no blueprint this cycle') end
    local src = find_reaction(METAL_GRINDER)
    if not src then error('the metal grinder is not in the array') end
    local arr = df.global.world.raws.reactions.reactions
    local rxn = df.reaction:new()
    rxn:assign(src)
    rxn.raw_strings:resize(0)
    rxn.descriptions:resize(0)
    rxn.code = FIN_GRIND_CODE .. base_id
    rxn.name = 'grind finished ' .. base_name(st, base_id) .. ' into dust'
    rxn.category = FIN_GRIND_CAT
    -- The vectors hold pointers and assign copies the pointers, so the
    -- reagents and products are copied one by one: the class written
    -- below would otherwise be written on the metal grinder's reagent.
    rxn.reagents:resize(0)
    for _, orig in ipairs(src.reagents) do
        local r = orig._type:new()
        r:assign(orig)
        rxn.reagents:insert('#', r)
    end
    rxn.products:resize(0)
    for _, orig in ipairs(src.products) do
        local p = orig._type:new()
        p:assign(orig)
        rxn.products:insert('#', p)
    end
    rxn.reagents[0].reaction_class = fin_words_of(st, base_id)
    rxn.index = #arr
    arr:insert('#', rxn)
    st.fin_grind[base_id] = true
    return rxn.index, rxn.code
end

-- fin_grinder_bases: the bases that get a finished-metal grinder at Step
-- 5, sorted by id: every base with a finish in the array (each has its
-- class string by then) and no grinder yet this cycle.
function fin_grinder_bases()
    local st = current()
    if not st then return {} end
    local list = {}
    for b in pairs(st.fin_class) do
        if not st.fin_grind[b] then list[#list + 1] = b end
    end
    table.sort(list)
    return list
end

-- ==========================================
-- PERMISSIONS FOR A MINT AFTER STEP 6
-- ==========================================
-- refinish-index-entity.lua grants at Step 6 from the handover, so what
-- is built after it grants itself, by the same rule: once per entity raw
-- (told apart with ==, which compares what two reads point at), to a
-- civilization whose cached tech includes metal and which knows the base
-- metal. A placeholder goes with its base's finishes, as in the handover.
-- refinish-menu-forge.lua also grants placeholders to the fort's civ.
-- Returns how many permissions were added.
-- ==========================================
local function permit(st, by_base)
    if not next(by_base) then return 0 end
    local civ_tech = st.bp.civ_tech or {}
    local done, granted = {}, 0
    for _, civ in ipairs(df.global.world.entities.all) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            local raw = civ.entity_raw
            local code = raw.code
            local list = done[code]
            if not list then
                list = {}
                done[code] = list
            end
            local seen = false
            for _, r in ipairs(list) do
                if r == raw then
                    seen = true
                    break
                end
            end
            if not seen then
                list[#list + 1] = raw
                local cache = civ_tech[code]
                if cache and cache.metal_tech then
                    local known = cache.known_metals or {}
                    local permitted, have = raw.workshops.permitted_reaction_id, nil
                    for b, idxs in pairs(by_base) do
                        if known[b] then
                            if not have then
                                have = {}
                                for _, pid in ipairs(permitted) do have[pid] = true end
                            end
                            for _, i in ipairs(idxs) do
                                if not have[i] then
                                    permitted:insert('#', i)
                                    have[i] = true
                                    granted = granted + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return granted
end

-- ==========================================
-- MINTING
-- ==========================================
-- ensure_folder: a kind folder's placeholder, once Step 5 is done and the
-- base has a finish of that kind in the array (THE FORGE'S FOLDER
-- PLACEHOLDERS).
local function ensure_folder(st, b, kind, out)
    if not kind or not (st.live and st.shell) then return end
    if st.placed[b] and st.placed[b][kind] then return end
    if not (st.bp.forge and st.bp.forge.bases[b]) then return end
    local ok, idx = pcall(build_placeholder, b, kind)
    if ok and idx then
        add_index(out.by_base, b, idx)
        out.folders = out.folders + 1
    else
        -- ERROR: that kind's finishes stay in the forge's category lists;
        -- refinish-menu-forge files only finishes whose kind folder has
        -- its placeholder.
        log('ERROR', ('Forge folder placeholder for %s (%s) not built: %s'):format(
            tostring(b), tostring(kind), tostring(idx)), 'FORGE_FOLDERS')
    end
end

-- ensure_fin_grinder: a base's finished-metal grinder, once Step 5 is
-- done and the base has a finish in the array (THE FINISHED-METAL
-- GRINDERS).
local function ensure_fin_grinder(st, b, out)
    if not (st.live and st.fin_class[b]) or st.fin_grind[b] then return end
    local ok, idx = pcall(build_fin_grinder, b)
    if ok and idx then
        add_index(out.by_base, b, idx)
        out.grinders = out.grinders + 1
    else
        -- ERROR: that base's finished bars cannot be ground this cycle.
        log('ERROR', ('Finished-metal grinder for %s not built: %s'):format(
            tostring(b), tostring(idx)), 'FIN_GRINDERS')
    end
end

-- A finish in the array: its index, minting it first when the blueprint
-- has it this cycle and its base metal is there to copy. nil when the
-- blueprint cannot make it (base metal not selected, Material Finishes
-- off, or no such finish).
local function ensure_material(st, id, out)
    local i = index_of(id)
    if i then return i end
    local data = st.bp.materials[id]
    if not data then return nil end
    local b_idx = index_of(data.base_metal_id)
    if not b_idx then
        log('ERROR', 'Base metal ' .. tostring(data.base_metal_id)
            .. ' not found, so ' .. id .. ' was not minted.',
            tostring(data.base_metal_id))
        return nil
    end
    i = build_material(st, id, data, df.global.world.raws.inorganics.all[b_idx])
    if not st.m_line[id] then roster_add(st, 'M ' .. id) end
    out.mats = out.mats + 1
    out.last_idx = i
    -- refinish-resolve.lua drops its material cache on the next lookup.
    _G.refinish_material_cache_dirty = true
    ensure_folder(st, data.base_metal_id, finish_kind(id), out)
    ensure_fin_grinder(st, data.base_metal_id, out)
    return i
end

-- A pair's finishes, then its reactions, appended. A pair is built once
-- a cycle; one the blueprint has no reactions for is only marked.
local function mint_pair(st, b, d, out)
    local key = pair_key(b, d)
    if st.built[key] then return end
    st.built[key] = true
    local by_d = st.cat.pairs[b]
    local list = by_d and by_d[d]
    if not list then return end
    for _, rxn_id in ipairs(list) do
        local data = st.bp.reactions[rxn_id]
        if ensure_material(st, data.output_mat_id, out) then
            local idx = build_reaction(rxn_id)
            if idx then
                add_index(out.by_base, b, idx)
                out.rxns = out.rxns + 1
            end
        end
    end
end

-- A base metal or dust the fort has: when new, it joins the roster and
-- mints its pairs with every counterpart already seen, in the order
-- those were seen.
local function see(st, kind, id, out)
    if kind == 'B' then
        if st.seen_b[id] or not st.cat.bases[id] then return end
        roster_add(st, 'S B ' .. id)
        out.new_b[#out.new_b + 1] = id
        for _, d in ipairs(st.order_d) do mint_pair(st, id, d, out) end
    else
        if st.seen_d[id] or not st.cat.dusts[id] then return end
        roster_add(st, 'S D ' .. id)
        out.new_d[#out.new_d + 1] = id
        for _, b in ipairs(st.order_b) do mint_pair(st, b, id, out) end
    end
end

-- ==========================================
-- ON DEMAND (published as _G.refinish_mint_finish_on_demand)
-- ==========================================
-- refinish-ledger.lua (Step 6.5) and refinish-load.lua (Step 7) ask for a
-- finish an object wears that is not in the array. One the blueprint can
-- make is minted, with its base's folder and that folder's permission,
-- and the roster keeps it: the object moves onto it instead of being
-- parked. This is also how a save from before the roster comes over: its
-- first load mints exactly the finishes its objects wear.
-- Returns the finish's index, or nil.
-- ==========================================
local function on_demand(id)
    local st = current()
    if not st or type(id) ~= 'string' or not st.bp.materials[id] then return nil end
    local out = new_out()
    local i = ensure_material(st, id, out)
    if out.mats > 0 then
        st.on_demand = st.on_demand + out.mats
        permit(st, out.by_base)
        roster_save(st)
    end
    return i
end

-- ==========================================
-- STEP 4: THE ROSTER'S MATERIALS
-- ==========================================
-- Reads the roster afresh, builds the catalog, and mints every M line in
-- roster order (ORDER IS THE CONTRACT). Returns how many were built and
-- how many lines the blueprint could not make this cycle.
-- ==========================================
function load_materials()
    local bp = _G.refinish_blueprint
    if not (bp and bp.materials and bp.reactions) then
        error('no blueprint: refinish-scan has to run first')
    end
    local lc = _G.refinish_load_clock
    local t = lc and lc.now()
    local st = fresh_state(bp)
    S = st
    -- Finish reactions in the array by base metal this cycle, counted by
    -- build_reaction: what the civs panel shows a civ can make now.
    _G.refinish_finish_counts_minted = {}
    -- The lookup table starts fresh: the last cycle's positions are gone.
    idx_of, idx_len = {}, -1
    st.cat = build_catalog(bp)
    if lc then t = lc.lap('materials (finishes): catalog', t) end

    local what, info = roster_read(st)
    if what == 'other site' then
        log('INFO', ('Discarded a finish roster from another fortress (site %s).')
            :format(tostring(info)), 'ROSTER')
        st.dirty = true
    elseif what == 'format' then
        -- WARNING: the fort's finishes come back from its bars and dusts at
        -- Step 6.7, and objects wearing others from the ledger.
        log('WARNING', 'Finish roster is in a format this version does not'
            .. ' read; started again.', 'ROSTER')
        st.dirty = true
    elseif what == 'error' then
        log('ERROR', 'Finish roster could not be read: ' .. tostring(info), 'ROSTER')
    elseif what == 'read' and info > 0 then
        log('WARNING', ('%d finish roster line(s) not understood, skipped.')
            :format(info), 'ROSTER')
    end

    local raws = df.global.world.raws.inorganics.all
    local built, skipped, s_assign = 0, 0, 0
    for _, line in ipairs(st.lines) do
        if line:sub(1, 2) == 'M ' then
            local id = line:sub(3)
            local data = bp.materials[id]
            if not data then
                skipped = skipped + 1
            elseif not index_of(id) then
                local b_idx = index_of(data.base_metal_id)
                if b_idx then
                    local _, sa = build_material(st, id, data, raws[b_idx], lc)
                    s_assign = s_assign + sa
                    built = built + 1
                else
                    log('ERROR', 'Base metal ' .. tostring(data.base_metal_id)
                        .. ' not found, so ' .. id .. ' was not built.',
                        tostring(data.base_metal_id))
                    skipped = skipped + 1
                end
            end
        end
    end
    if lc then
        lc.add('materials (finishes): new and assign', s_assign, built)
        lc.lap('materials (finishes): build loop, all of it', t)
    end
    _G.refinish_material_cache_dirty = true
    _G.refinish_mint_finish_on_demand = on_demand
    log('DETAIL', ('Roster %s: %d line(s), bars of %d base metal(s) and %d dust(s)'
        .. ' seen; %d finish(es) built, %d not in this blueprint.'):format(what,
        #st.lines, #st.order_b, #st.order_d, built, skipped), 'ROSTER')
    return built, skipped
end

-- ==========================================
-- STEP 5: THE REACTIONS
-- ==========================================
-- minted_reactions: the reaction ids of every pair the fort has had both
-- sides of, each pair's finishes made sure of first (a pair the blueprint
-- has just come to allow, a base metal selected again or Material
-- Finishes turned on, mints them here), grouped by category and sorted
-- as the full set was (SORTED WITHOUT A LUA COMPARATOR).
function minted_reactions()
    local st = current()
    if not st then return {} end
    local out, by_cat = new_out(), {}
    for _, b in ipairs(st.order_b) do
        local by_d = st.cat.pairs[b]
        if by_d then
            for _, d in ipairs(st.order_d) do
                local list = by_d[d]
                if list then
                    for _, rxn_id in ipairs(list) do
                        local data = st.bp.reactions[rxn_id]
                        if ensure_material(st, data.output_mat_id, out) then
                            local c = data.category or ''
                            local l = by_cat[c]
                            if not l then
                                l = {}
                                by_cat[c] = l
                            end
                            l[#l + 1] = rxn_id
                        end
                    end
                    st.built[pair_key(b, d)] = true
                end
            end
        end
    end
    local cats, ids = {}, {}
    for c in pairs(by_cat) do cats[#cats + 1] = c end
    table.sort(cats)
    for _, c in ipairs(cats) do
        local l = by_cat[c]
        table.sort(l)
        for _, id in ipairs(l) do ids[#ids + 1] = id end
    end
    if out.mats > 0 then
        log('DETAIL', ('%d finish(es) newly allowed by this blueprint minted for'
            .. ' pairs already seen.'):format(out.mats), 'PAIRS')
    end
    return ids
end

-- folders: the kind folders that get a placeholder at Step 5, as
-- { base = id, kind = kind }, sorted by base id and then kind: each kind
-- with a finish in the array, of a base with a folder in the blueprint.
function folders()
    local st = current()
    if not st then return {} end
    local forge, keys, by_key = st.bp.forge, {}, {}
    if forge and forge.bases then
        for b, by_kind in pairs(st.has_fin) do
            if forge.bases[b] then
                for kind in pairs(by_kind) do
                    local key = pair_key(b, kind)
                    keys[#keys + 1] = key
                    by_key[key] = { base = b, kind = kind }
                end
            end
        end
    end
    -- One string per folder, base id then kind, joined as a pair's are
    -- (pair_key), sorted with table.sort's own < (SORTED WITHOUT A LUA
    -- COMPARATOR).
    table.sort(keys)
    local list = {}
    for i, key in ipairs(keys) do list[i] = by_key[key] end
    return list
end

-- finish_load: Step 5 is done. From here a mint builds its kind's folder
-- itself, and the roster holds whatever Step 5 minted.
function finish_load()
    local st = current()
    if not st then return end
    st.live = true
    roster_save(st)
end

-- ==========================================
-- IN PLAY (refinish-mint-finish-watch.lua)
-- ==========================================
-- settle: what a mint after Step 6 leaves to do: the permissions (Step 6
-- granted the load's own), the reaction index brought up to date, the
-- roster saved, and one INFO line naming what was new. reconcile and
-- notice both end here. Returns the permissions granted.
local function settle(st, out, subject)
    local granted = permit(st, out.by_base)
    if out.rxns > 0 or out.folders > 0 or out.grinders > 0 then
        -- refinish-resolve.lua reads the new reactions now, not on the
        -- first lookup in play.
        pcall(function()
            local sync = _G.refinish_reactions_sync
            if sync then sync() end
        end)
    end
    roster_save(st)
    if #out.new_b > 0 or #out.new_d > 0 then
        local what = {}
        if #out.new_b > 0 then what[#what + 1] = 'bars of ' .. some(out.new_b, 8) end
        if #out.new_d > 0 then what[#what + 1] = 'dust of ' .. some(out.new_d, 8) end
        -- INFO: new finishing options a player may go looking for.
        log('INFO', ('New in the fort: %s. Minted %d finish(es), %d reaction(s), %d'
            .. ' forge folder(s) and %d finished-metal grinder(s); %d permission(s)'
            .. ' granted.'):format(table.concat(what, '; '), out.mats, out.rxns,
            out.folders, out.grinders, granted), subject)
    end
    return granted
end

-- ---- THE PILES, AGAINST A FINISH MINTED IN PLAY ----
-- A stockpile's settings keep one entry per inorganic in several lists
-- (refinish-stockpile-windows.lua, INORG_LISTS), measured at the
-- inorganics' own length on a fort whose materials were all injected at
-- load (RM_Organic_Category_Registration.md). Whether a pile made before
-- a finish existed reaches that finish's index, and whether it takes it,
-- has not been measured: a finish minted in play is the first chance.
-- Read for bars (bars_blocks.bars_mats): the piles, the shortest and
-- longest list, how many reach the index and how many of those have it
-- on. One DETAIL line per mint in play.
local function truth(v) return v == true or (type(v) == 'number' and v ~= 0) end

local function pile_reach(idx)
    local n, reach, on, lo, hi = 0, 0, 0, nil, nil
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
        local ok, v = pcall(function() return b.settings.bars_blocks.bars_mats end)
        if ok and v then
            local len = #v
            n = n + 1
            lo = lo and math.min(lo, len) or len
            hi = hi and math.max(hi, len) or len
            if idx < len then
                reach = reach + 1
                if truth(v[idx]) then on = on + 1 end
            end
        end
    end
    return n, reach, on, lo or 0, hi or 0
end

-- notice: a bar (kind 'B') or a dust (kind 'D') the watcher saw, by its
-- material id. A base metal or dust new to the roster mints its pairs
-- here, as reconcile does at load. Returns nil while the minter is not
-- ready (before Step 5 of this cycle, or after a shutdown), so the
-- watcher asks again later; otherwise the number of finish materials
-- minted, 0 when the material was not new or is no base metal or dust
-- this cycle.
function notice(kind, id)
    local st = current()
    if not (st and st.live) then return nil end
    local out = new_out()
    see(st, kind, id, out)
    if #out.new_b == 0 and #out.new_d == 0 then return 0 end
    settle(st, out, 'IN_PLAY')
    -- The status panel's INJECTED numbers, counted again now that the
    -- arrays grew (refinish-startup.lua, THE INJECTED COUNTS).
    pcall(function()
        local count = _G.refinish_count_injected
        if count then count() end
    end)
    if out.last_idx then
        local n, reach, on, lo, hi = pile_reach(out.last_idx)
        log('DETAIL', ('Piles against the newest finish (inorganic %d of %d): %d'
            .. ' pile(s), bars lists %d to %d long; %d reach it, %d of them take it.')
            :format(out.last_idx, #df.global.world.raws.inorganics.all, n, lo, hi,
            reach, on), 'PILES')
    end
    return out.mats
end

-- RM's dust tool's subtype this cycle, for the watcher; nil before Step 5.
function dust_subtype()
    local st = current()
    return st and st.shell and st.shell.dust_subtype or nil
end

-- ==========================================
-- STEP 6.7: THE BARS AND DUSTS IN THE FORT
-- ==========================================
-- Reads the fort's bars and RM dusts by their materials, so it runs after
-- the ledger remap has put every stored index right. A base metal or
-- dust new to the roster mints its pairs (see). Caravan goods
-- (flags.trader) are not the fort's until bought, and items on their way
-- out of the world (removed, garbage_collect) are skipped.
-- Returns the number of finish materials minted, which refinish-startup
-- needs: a material minted after the remap changes the layout Step 8's
-- ledger write records.
-- ==========================================

-- The material index of a bar or dust the fort holds, or nil. One named
-- function under one pcall per item, so no closure is made per item.
local function held_index(it, sub, n)
    local f = it.flags
    if f.trader or f.removed or f.garbage_collect then return nil end
    if sub and it:getSubtype() ~= sub then return nil end
    if it.mat_type ~= 0 then return nil end
    local mi = it.mat_index
    if mi < 0 or mi >= n then return nil end
    return mi
end

function reconcile()
    local st = current()
    if not st then
        log('WARNING', "Reconcile asked before this cycle's finishes were"
            .. ' loaded; nothing minted.', 'RECONCILE')
        return 0
    end
    local t0 = dfhack.getTickCount()
    local out = new_out()
    local arr = df.global.world.raws.inorganics.all
    local n = #arr
    local id_at = {}   -- material index -> id, each read once

    local n_bars, n_dusts = 0, 0
    for _, it in ipairs(df.global.world.items.other.BAR) do
        local ok, mi = pcall(held_index, it, nil, n)
        if ok and mi then
            n_bars = n_bars + 1
            local id = id_at[mi]
            if id == nil then
                id = arr[mi].id
                id_at[mi] = id
            end
            see(st, 'B', id, out)
        end
    end
    local sub = st.shell and st.shell.dust_subtype
    if sub then
        for _, it in ipairs(df.global.world.items.other.TOOL) do
            local ok, mi = pcall(held_index, it, sub, n)
            if ok and mi then
                n_dusts = n_dusts + 1
                local id = id_at[mi]
                if id == nil then
                    id = arr[mi].id
                    id_at[mi] = id
                end
                see(st, 'D', id, out)
            end
        end
    else
        -- WARNING: no shell means Step 5 failed; its own ERROR says why.
        log('WARNING', 'No dust tool subtype this cycle, so the fort\'s dusts were'
            .. ' not read.', 'RECONCILE')
    end

    settle(st, out, 'RECONCILE')
    log('DETAIL', ('Read %d bar(s) and %d dust(s) in %d ms; %d base metal(s) and %d'
        .. ' dust(s) seen in all; %d finish(es) minted on demand this cycle.'):format(
        n_bars, n_dusts, dfhack.getTickCount() - t0, #st.order_b, #st.order_d,
        st.on_demand), 'RECONCILE')
    return out.mats
end
