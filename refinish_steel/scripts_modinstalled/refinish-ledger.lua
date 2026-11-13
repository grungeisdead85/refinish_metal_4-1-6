-- refinish-ledger.lua
-- ==========================================
-- MATERIAL INDEX LEDGER
-- ==========================================
-- THE PROBLEM
--
-- Items, buildings and constructions store mat_type and mat_index.
-- They do not store material names. An index is only meaningful
-- against the exact inorganics array that produced it.
--
-- The array is rebuilt from scratch every load, in three bands:
--
--   [0 .. V-1]    vanilla, read from the save's raw folder
--   [V .. ]       module materials, injected at startup Step 2
--   [.. end]      core RM materials, injected at startup Step 4
--
-- Vanilla never moves. The two injected bands do, whenever a
-- module is installed, removed, or updated with a different
-- material count. Because core RM injects after modules, a change
-- in the module band shifts core RM as well.
--
-- THE ONLY RECOVERY THERE IS
--
-- The save wash (refinish-save.lua, the AUTOSAVE protocol) washed
-- core RM objects to a vanilla index and recorded their names in a
-- JSON payload, so they could be restored without interpreting
-- anything. It never covered module materials, and it was retired
-- 2026-09-29, when both game saves were measured bringing every
-- finish back without it. Every save now keeps objects at their
-- injected indices, and this ledger is what moves them.
--
-- COVERAGE
--
--   every save   every object sits at an injected index, is in the
--                ledger, and is remapped here. An object in a finish
--                that is no longer generated (its base metal not
--                selected, Material Finishes off) goes to the base
--                metal the ledger recorded for that finish, and is
--                PARKED: the object and its finish are kept in site
--                data, and the remap puts the finish back once it is
--                generated again.
--
--   a save the   core RM objects were washed to vanilla indices,
--   old line     below the injected band and so absent from the
--   wrote        ledger. remap() skips them and the one-time legacy
--                migration (refinish-load.lua, startup Step 7)
--                restores them by name. Module objects were never
--                washed, so they are in the ledger and are remapped
--                here. The two passes touch disjoint sets.
--
-- DYE REFERENCES AND HISTORY
--
-- A dyed item stores its dye's material apart from its own, so a
-- cloth woven from plant fibre can carry a module dye's inorganic
-- index. World history stores materials too: a masterpiece and its
-- dye, the weapon in a death, a stolen item, the spike or rope in a
-- body abuse. All of these are references, like an item's own
-- index, not entries in a raws array. They may sit in the save
-- pointing at an injected index, and remap() moves them by name on
-- the next load, the same way. The fields are listed at DYE
-- REFERENCES and HISTORY EVENTS inside remap().
--
-- JOBS AND WORK ORDERS
--
-- A job names materials by index as well: what it makes its item of,
-- and the material each item it asks for must be. So does a standing
-- work order. remap() moves them by name the same way (JOBS AND WORK
-- ORDERS, inside it). Until 2026-10-02 it did not, and a job saved on a
-- finish came back on whatever its old index then pointed at.
--
-- TOOLS IN SAVED JOBS AND WORK ORDERS
--
-- A job's tool slot holds the tool's subtype NUMBER, and so does a job
-- that makes a tool, an order's items and its item conditions. An item
-- points at its tool itself and RM's tool wash carries it
-- (refinish-tool-wash.lua); a number is carried by nothing, and RM's and
-- the modules' tools are numbered in the order they are injected. A tool
-- added or removed ahead of others moves every one after it, and a saved
-- job then asks for whichever tool took its number. SEEN 2026-10-04: RM's
-- glue granules went in between cullet and gravel, and two saved branch
-- jobs fetched clay binders. So every owned tool is recorded by name with
-- its number (T lines), and remap() moves these numbers by name in the
-- jobs and work orders pass, as it moves materials. A tool no longer
-- injected leaves its number as it is, with a WARNING.
--
-- SMELTERS' PART BARS
--
-- A furnace keeps what a melt returns under a whole bar, per metal, in a
-- store indexed by material position. remap() moves those entries by name
-- as well, and every load fits each store to the array (SMELTERS' PART
-- BARS, above remap). Until 2026-10-04 nothing did.
--
-- PLANT MATERIALS
--
-- RM also injects PLANT materials: a module's host plant (Making
-- Fuel's COAL_HOST, DYE_HOST, TREE_DYE_HOST) and materials a module
-- appends to a vanilla plant (the MAKING_FUEL_FUELWOOD twin on every
-- tree). A plant material is addressed by a PAIR: mat_type is 419
-- plus its position on the plant, mat_index is the plant's position
-- in plants.all. Either half moves when a module's plant list, or a
-- host's material list, changes. So the ledger also records every
-- owned plant material by name, "PLANT_ID|MAT_ID", against its pair,
-- and remap() moves stored pairs by name exactly as it moves
-- inorganic indices, everywhere it looks: items, constructions,
-- buildings, dye references and history.
--
-- Owned means either a material on a plant whose id carries an owned
-- prefix (a host, all of whose materials are the module's), or a
-- material whose own id carries one, wherever it hangs (a twin on a
-- vanilla tree). Vanilla's own plant materials never move and are
-- never recorded. A ledger written before this has no plant section,
-- and plant pairs are left alone that once.
--
-- CALL ORDER (refinish-startup)
--
--   Step 4    material injection, indices become final
--   Step 6.5  remap()   must run BEFORE refinish-load; says when THE
--                       FINGERPRINT shows nothing to do
--   Step 7    refinish-load, payload restore
--   Step 8    write()   snapshot for the next session, kept as it is
--                       when remap() found the fingerprint unchanged
--
-- remap() runs before refinish-load because the payload restore
-- sets mat_index from names. Remapping afterwards would take
-- freshly correct indices and rewrite them against a stale ledger.
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside REFINISH_STEEL_PAYLOAD.
local LEDGER_KEY = "REFINISH_STEEL_LEDGER"

-- Objects sent to their base metal because their finish was not
-- generated, each with the finish it had, so it can go back. See
-- PARKED FINISHES in remap(). Deleted whenever it empties.
local PARKED_KEY = "REFINISH_STEEL_PARKED"

-- ==========================================
-- SITE DATA TEXT
-- ==========================================
-- Everything this file keeps in site data goes through the String
-- variants, stored as the text it is. saveSiteData json-encodes what
-- it is given, so a string that was already JSON gets wrapped a
-- second time, and getSiteData reads that back through DFHack's
-- JSON.lua string reader, whose cost grows with the SQUARE of the
-- string's length (STORAGE, below, has the measurements).
--
-- unwrap_old() reads what the old double way left: strips the outer
-- JSON string's quotes and unescapes it with one gsub, in C. nil when
-- raw is not in that form. JSON.lua writes only these escapes for the
-- ASCII RM stores.
local UNESCAPE = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
                   f = '\f', n = '\n', r = '\r', t = '\t' }
local function unwrap_old(raw)
    if raw:sub(1, 1) ~= '"' then return nil end
    local body = raw:match('^"(.*)"%s*$')
    if not body then return nil end
    return (body:gsub('\\(.)', UNESCAPE))
end

-- Core RM material id prefix. Module prefixes come from the live
-- registry at runtime.
local CORE_PREFIX = "REFINISH_STEEL_"

-- Plant material types: 419 plus the material's position on its plant,
-- 200 to a plant (DFHack MaterialInfo: PLANT_BASE, NUM_PLANT_MAT). Used
-- only to recognise a plant pair in a stored reference; every pair the
-- ledger RECORDS comes from dfhack.matinfo.find, never from this sum.
local PLANT_TYPE_LO, PLANT_TYPE_HI = 419, 618


-- ==========================================
-- HELPERS
-- ==========================================

-- Same test the module engine uses (refinish-module-engine.lua:81).
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

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
-- SUBJECT is the correlation slot: WRITE or REMAP, the half of the
-- ledger a line comes from.
--
-- Any failure that leaves saved objects unmoved is an ERROR: those
-- objects then point at whatever material now sits at their old
-- index, which a player will notice.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'LEDGER'
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

-- Every id prefix that RM or one of its modules owns. Core RM is
-- always included; module prefixes are the keys of the registry,
-- populated by the module pipeline at Step 2.
local function owned_prefixes()
    local list = { CORE_PREFIX }
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        table.insert(list, prefix)
    end
    return list
end

local function is_owned(mat_id, prefixes)
    for _, p in ipairs(prefixes) do
        if has_prefix(mat_id, p) then return true end
    end
    return false
end

local function is_plant_type(t)
    return type(t) == 'number' and t >= PLANT_TYPE_LO and t <= PLANT_TYPE_HI
end

-- Every owned plant material in the live raws, by name, with the pair
-- it sits at now: "PLANT_ID|MAT_ID" -> { mat_type, mat_index }. See
-- PLANT MATERIALS in the header for what counts as owned. Returns the
-- table and its count.
--
-- record, when given, makes each entry instead of the plain store: it
-- is collect()'s, which also writes the entry into the fingerprint's
-- text (WHAT A WRITE RECORDS, AND ITS FINGERPRINT).
--
-- lparts, when given, gets the layout's plant lines as the walk meets
-- them, the lines layout() writes, so collect's check can take the
-- layout from this same walk.
local function owned_plant_materials(prefixes, record, lparts)
    local out, n = {}, 0
    for _, p in ipairs(df.global.world.raws.plants.all) do
        local pid = p.id
        if lparts then lparts[#lparts + 1] = '|' .. pid end
        local host = is_owned(pid, prefixes)
        for _, m in ipairs(p.material) do
            -- Read once: every read through DFHack makes a new string.
            local mid = m.id
            if lparts then lparts[#lparts + 1] = mid end
            if host or is_owned(mid, prefixes) then
                local info = dfhack.matinfo.find('PLANT_MAT:' .. pid .. ':' .. mid)
                if info then
                    if record then
                        record(out, 'P', pid .. '|' .. mid, info.type, info.index)
                    else
                        out[pid .. '|' .. mid] = { info.type, info.index }
                    end
                    n = n + 1
                end
            end
        end
    end
    return out, n
end

-- ==========================================
-- PARKED FINISHES: STORE
-- ==========================================
-- The parked records for THIS site, or an empty list. A record is
-- { k, f, b } plus how to find the object again: k 'item' or 'bld'
-- with its id, 'con' with its tile x, y, z, or 'hist' with the event
-- id, the path of keys from the event to the struct holding the pair
-- (p, nil when the pair is on the event) and the pair's two field
-- names (tf, xf). f is the finish id, b the base metal id.
local function read_parked()
    local raw = dfhack.persistent.getSiteDataString(PARKED_KEY)
    if not raw or raw == "" then return {} end
    local ok, rec = pcall(json.decode, unwrap_old(raw) or raw)
    if not ok or type(rec) ~= 'table' or type(rec.list) ~= 'table' then
        -- ERROR: every record in it is lost, and with them the finishes
        -- those objects are waiting for.
        log('ERROR', 'Parked finishes could not be decoded; the objects'
            .. ' they held stay on their base metal.', 'PARKED')
        return {}
    end
    if rec.site_id and rec.site_id ~= df.global.plotinfo.site_id then
        return {}
    end
    return rec.list
end

-- Saves the list, or deletes the key once nothing is waiting.
local function write_parked(list)
    if #list == 0 then
        pcall(dfhack.persistent.deleteSiteData, PARKED_KEY)
        return
    end
    dfhack.persistent.saveSiteDataString(PARKED_KEY, json.encode({
        site_id = df.global.plotinfo.site_id,
        list    = list,
    }, { pretty = false }))
end

-- Puts one parked finish back: true when the object was found still
-- on the base metal it was parked on (b_idx) and now has its finish
-- (f_idx) again. mat_type is written alongside, as every RM write is.
local function restore_parked(r, b_idx, f_idx)
    if not b_idx then return false end
    local function back(obj, tf, xf)
        if obj and obj[tf] == 0 and obj[xf] == b_idx then
            obj[tf] = 0
            obj[xf] = f_idx
            return true
        end
        return false
    end
    if r.k == 'item' then
        local it = df.item.find(r.id)
        if it and it:getActualMaterial() == 0 and it.mat_index == b_idx then
            it.mat_type = 0
            it.mat_index = f_idx
            return true
        end
        return false
    elseif r.k == 'bld' then
        return back(df.building.find(r.id), 'mat_type', 'mat_index')
    elseif r.k == 'con' then
        return back(dfhack.constructions.findAtTile(
            { x = r.x, y = r.y, z = r.z }), 'mat_type', 'mat_index')
    elseif r.k == 'hist' then
        local obj = df.history_event.find(r.id)
        for _, key in ipairs(r.p or {}) do obj = obj and obj[key] end
        return back(obj, r.tf, r.xf)
    end
    return false
end

-- ==========================================
-- STORAGE
-- ==========================================
-- WHY NOT saveSiteData WITH A JSON STRING. That is how the ledger was
-- stored until 2026-09-29, and it wrapped it twice: json.encode made
-- the ledger one string, and saveSiteData json-encodes whatever it is
-- given again (persistent_saveData in DFHack's library/lua/dfhack.lua),
-- so the site data held ONE JSON string containing the whole ledger.
-- getSiteData reads that back through DFHack's JSON.lua (Jeffrey
-- Friedl's, pure Lua), whose string reader appends a character at a
-- time (VALUE = VALUE .. next_character), copying everything read so
-- far each time: the cost grows with the SQUARE of the ledger's size.
-- MEASURED with DFHack's own library: 1000 materials 0.44s, 2000
-- 2.23s, 4000 8.58s. Every metal on (8956 materials, each finish with
-- its base) put it near a minute, longer in DF's own process, and
-- every load hung at the remap.
--
-- NOW: plain text through the String variants, which store the text
-- as it is. One line per entry, written by table.concat and read by
-- gmatch, both in C:
--   LEDGER 2
--   S <site id>
--   M <material id> <index>
--   B <finish id> <base metal id>
--   P <plant material name> <mat_type> <mat_index>
--   T <tool id> <subtype number>
-- MEASURED at 8956 materials: written in 0.016s, read in 0.032s. The
-- same ledger as one-layer compact JSON takes 0.10s and 0.39s.
--
-- Ids may hold spaces. DF accepts nearly anything in an id, and
-- vanilla alone has 64 inorganics (gems: LACE AGATE, BLUE JADE) and 23
-- plants (HAIR GRASS) with one. Base metal ids reach the ledger inside
-- every finish id, and plant ids inside every owned plant material's
-- name. In the big test world (2026-09-29) one did, and that used to
-- send the whole ledger to compact JSON: 2,000 ms a read at 61,793
-- materials. Now a token with whitespace, or with the escape character
-- %, is written percent-escaped (%20 for a space) and unescaped on
-- reading. The ledger always stays lines, and nothing is dropped.
--
-- A ledger stored the old double way is still read, never through
-- getSiteData: its outer string is unwrapped by one gsub (0.02s for
-- 1.4 MB, measured) and only the ledger itself goes through JSON.lua,
-- which reads an object of short strings in linear time (0.39s).
-- ==========================================
local LEDGER_FORMAT = 'LEDGER 2'

-- Percent-escaping for tokens (see above). unesc_token is only run on
-- a ledger that holds a % at all.
local function esc_token(s)
    return (s:gsub('[%s%%]', function(c) return string.format('%%%02X', c:byte()) end))
end
local function unesc_token(s)
    return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

-- Said once a session, not on every write.
local escape_reported = false

-- Decodes what is stored under LEDGER_KEY, whichever form it is in.
-- Returns the ledger table and the form's name, or nil and a reason.
local function decode_ledger(raw)
    if raw:sub(1, #LEDGER_FORMAT) == LEDGER_FORMAT then
        local led = { mats = {}, bases = {}, plants = {}, tools = {} }
        -- Every record line follows a newline, so the format line is
        -- skipped by the pattern itself.
        local un = raw:find('%', 1, true) and unesc_token
            or function(s) return s end
        for tag, a, b, c in raw:gmatch('\n(%u) (%S+) ?(%S*) ?(%S*)') do
            if tag == 'M' then led.mats[un(a)] = tonumber(b)
            elseif tag == 'B' then led.bases[un(a)] = un(b)
            elseif tag == 'P' then led.plants[un(a)] = { tonumber(b), tonumber(c) }
            elseif tag == 'T' then led.tools[un(a)] = tonumber(b)
            elseif tag == 'S' then led.site_id = tonumber(a) end
        end
        return led, 'lines'
    end
    local text, form = raw, 'json'
    if raw:sub(1, 1) == '"' then
        text = unwrap_old(raw)
        if not text then return nil, 'undecodable' end
        form = 'old double-encoded json'
    end
    local ok, led = pcall(json.decode, text)
    if not ok or type(led) ~= 'table' then return nil, 'undecodable' end
    return led, form
end

-- Stores the ledger as lines. Returns the form written, how many
-- tokens needed escaping, and the first of them for write()'s log.
--
-- fingerprint, when given, is stored as the second line (F), inside the
-- ledger's own text, so the two are written together or not at all
-- (THE FINGERPRINT). decode_ledger reads only M, B, P and S lines, so a
-- reader that knows nothing of it passes over it.
local function store_ledger(led, fingerprint)
    local out = { LEDGER_FORMAT }
    if fingerprint then out[#out + 1] = 'F ' .. fingerprint end
    out[#out + 1] = 'S ' .. tostring(led.site_id)
    local escaped, first = 0, nil
    local function tok(s)
        s = tostring(s)
        if s:find('[%s%%]') then
            escaped = escaped + 1
            first = first or s
            return esc_token(s)
        end
        return s
    end
    for id, idx in pairs(led.mats) do
        out[#out + 1] = 'M ' .. tok(id) .. ' ' .. tostring(idx)
    end
    for id, base in pairs(led.bases) do
        out[#out + 1] = 'B ' .. tok(id) .. ' ' .. tok(base)
    end
    for name, pair in pairs(led.plants) do
        out[#out + 1] = 'P ' .. tok(name) .. ' ' .. tostring(pair[1])
            .. ' ' .. tostring(pair[2])
    end
    for id, idx in pairs(led.tools or {}) do
        out[#out + 1] = 'T ' .. tok(id) .. ' ' .. tostring(idx)
    end
    dfhack.persistent.saveSiteDataString(LEDGER_KEY, table.concat(out, '\n'))
    return 'lines', escaped, first
end

-- The stored ledger for THIS site. On success: the ledger, its form,
-- the read's time in ms and its size in bytes. Otherwise nil and a
-- reason, plus the other site's id when that is the reason. raw is the
-- stored text when the caller has already fetched it (remap() has).
local function read_ledger(raw)
    raw = raw or dfhack.persistent.getSiteDataString(LEDGER_KEY)
    if not raw or raw == "" then return nil, 'none' end
    local t0 = dfhack.getTickCount()
    local led, form = decode_ledger(raw)
    if not led or type(led.mats) ~= 'table' then return nil, 'undecodable' end
    if led.site_id and led.site_id ~= df.global.plotinfo.site_id then
        return nil, 'other site', led.site_id
    end
    return led, form, dfhack.getTickCount() - t0, #raw
end


-- ==========================================
-- UNCHANGED SINCE THE LAST WRITE
-- ==========================================
-- A write walks every inorganic and plant material, keeps the owned
-- ones and stores the whole record: 61,801 indices, 7.2 MB, about a
-- second in region4 (2026-09-30), most of it building the lines. The
-- save hook refreshes the ledger every time the options screen opens,
-- and the shutdown and the hotsave write before their clears, while
-- the arrays mostly stand exactly as the last write found them: one
-- session wrote three identical ledgers, at startup and at two menu
-- openings, each a second of lag outside any save.
--
-- layout() is the arrays' exact order: the site, then every id in
-- place, inorganics and then each plant with its materials, read
-- without the owned checks, the lines or the store. The ledger follows
-- from it (and from the module prefixes and the blueprint, which only
-- a data cycle changes, and every data cycle ends in startup's full
-- write), so when it matches the last write's, the stored ledger
-- already says what this write would, and a caller that asks
-- (opts.if_changed) keeps it. Exact, not sampled: a material minted in
-- play, a hotsave's rebuild in a different order, any id anywhere out
-- of place, and the ledger is written in full. A reloaded copy of this
-- file starts with no layout, so its first write is full, unless remap()
-- found THE FINGERPRINT unchanged and seeded the layout: then startup
-- makes no write at all (until 2026-10-01 it asked, and kept; before
-- that, it never asked).
local last_layout, last_count = nil, 0

-- ---- THE ARRAYS' SIZES, ASKED FIRST ----
-- MEASURED 2026-10-02: the layout check below cost 31 to 62 ms at each
-- opening of the options screen (its own DETAIL line), most of the
-- menu's pause once the tool wash stopped walking every item
-- (refinish-tool-wash.lua, THE RECORD, KEPT BETWEEN OPENINGS OF THE
-- MENU), because layout() reads every id in the arrays. In play a
-- material is only ever appended, at the end of its array: the tinder
-- twins (making-fuel-tinder-mat.lua) and the aggregate twins
-- (refinish-material-aggregate.lua). Everything else that moves one runs
-- inside a data cycle, and every data cycle sets the last layout afresh,
-- by startup's write or by remap()'s fingerprint match, and the sizes
-- with it. So the sizes are read first: the site and the same array
-- sizes as at the last layout read mean the same layout, and the stored
-- ledger stands without a read of every id. A material renamed or moved
-- in place during play, outside a data cycle, would get past this.
-- Nothing does so today; a script that ever does must set last_sig to
-- nil, and the next check reads every id.
local last_sig = nil

-- ---- PILE SETTINGS, CARRIED TO STARTUP'S END ----
-- The previous layout's id -> index (the stored ledger's mats), kept by
-- a remap that read the stored ledger, for remap_piles (PILE SETTINGS
-- FOLLOW THEIR MATERIALS, at the end) once Steps 6.7 and 7 have minted
-- what they mint. nil otherwise.
local pending_piles = nil

local function sizes_sig()
    local raws = df.global.world.raws
    local plants = raws.plants.all
    local n_mats = 0
    for _, p in ipairs(plants) do n_mats = n_mats + #p.material end
    return table.concat({ tostring(df.global.plotinfo.site_id),
        tostring(#raws.inorganics.all), tostring(#plants), tostring(n_mats),
        tostring(#raws.itemdefs.tools) }, ':')
end

local function layout()
    local parts = { tostring(df.global.plotinfo.site_id) }
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        parts[#parts + 1] = mat.id
    end
    for _, p in ipairs(df.global.world.raws.plants.all) do
        parts[#parts + 1] = '|' .. p.id
        for _, m in ipairs(p.material) do
            parts[#parts + 1] = m.id
        end
    end
    -- The tools, in their order, after the plants; collect() writes the
    -- same lines in the same place, so the two layouts compare.
    parts[#parts + 1] = '|TOOLS'
    for _, def in ipairs(df.global.world.raws.itemdefs.tools) do
        parts[#parts + 1] = def.id
    end
    return table.concat(parts, '\n')
end

-- ==========================================
-- WHAT A WRITE RECORDS, AND ITS FINGERPRINT
-- ==========================================
-- collect() is the only place the ledger's records are made: every
-- owned inorganic's index, every finish's base metal, every owned plant
-- material's pair, and the site. Each record goes through record(),
-- which stores it and also writes it as one line of a text, in the order
-- the walk meets it: array order, so the same records always give the
-- same text. A line's fields are joined by ':', which no DF id can hold
-- (the raws split their tokens on it), so different records never make
-- the same text. The fingerprint is the MD5 of that text, taken in C
-- (dfhack.internal.md5, Lua_API).
--
-- It is a hash of the records themselves, not of a list of what they
-- depend on, so nothing has to be kept in step with it by hand: every
-- array, the module prefixes and the blueprint are read live, whatever
-- they hold, and a record kind added here through record() is in the
-- fingerprint with no other change. LEDGER_FORMAT opens the text, so a
-- new format puts every stored fingerprint out of date.
--
-- ---- THE FINGERPRINT ----
-- MEASURED 2026-10-01, the load clock, region4, on loads where nothing
-- had moved: the remap took 627 to 787 ms, 437 to 484 of it reading the
-- ledger, to report "No objects needed remapping", and startup's write
-- then took 578 to 610 ms to store the same records again.
--
-- A full write stores the fingerprint of what it stores, in the ledger's
-- own text (store_ledger). At the next load remap() collects again and
-- compares. Equal fingerprints mean this load would record exactly what
-- the stored ledger holds: every stored index is still that material's
-- index, so the remap would move and park nothing and the write would
-- store the same records. remap() then says so and seeds the last
-- layout from its own walk, and startup makes no write. Until
-- 2026-10-01 startup asked the write to keep it (opts.if_changed), and
-- the write walked the layout again only to find it unchanged.
--
-- Every other case takes the full path, as before:
--   no fingerprint   a ledger written before 2026-10-01; a write that
--                    stood last session's records in for an empty
--                    half; a write whose plant walk failed;
--   parked finishes  on record: only the full remap brings them back;
--   a mismatch       another site, a module or a metal added or
--                    removed, a material minted in play that sits
--                    somewhere else at this load.
--
-- Returns { site_id, mats, bases, n, plants, np, plants_err,
-- fingerprint }; fingerprint is nil when the plant walk failed, since
-- the records are then not this load's whole state.
--
-- check_only, for remap's check: the records are not kept, only their
-- lines and counts, and the walk also writes down the layout, the lines
-- layout() writes, so the check walks the arrays once (layout in the
-- result; nil on a full collect). MEASURED 2026-10-01 (the load clock,
-- region4): the check took 250 ms, a separate layout walk about 40 of it.
local function collect(check_only)
    local prefixes = owned_prefixes()
    local site = df.global.plotinfo.site_id
    local lines = { LEDGER_FORMAT, 'S:' .. tostring(site) }
    local lparts = check_only and { tostring(site) } or nil

    -- Stores one record in tbl, a single value or a pair, and writes it
    -- as the next line of the fingerprint's text. A check writes only
    -- the line.
    local function record(tbl, tag, key, a, b)
        if b == nil then
            if not check_only then tbl[key] = a end
            lines[#lines + 1] = tag .. ':' .. key .. ':' .. tostring(a)
        else
            if not check_only then tbl[key] = { a, b } end
            lines[#lines + 1] = tag .. ':' .. key .. ':' .. tostring(a)
                .. ':' .. tostring(b)
        end
    end

    local mats, n = {}, 0

    -- bases: finish id -> the base metal it is made from, for every
    -- finish injected now. The remap sends an object whose finish is no
    -- longer generated to that base metal, and only a session that had
    -- the finish knows it. The id cannot be parsed back: a colour id
    -- reads the same for colour BLACK on BRONZE as for the alloy
    -- BLACK_BRONZE. Only finishes are in the blueprint, so only finishes
    -- get an entry.
    local bases = {}
    local bp = _G.refinish_blueprint and _G.refinish_blueprint.materials

    -- Each id is read once: a read through DFHack makes a new string.
    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        local id = mat.id
        if lparts then lparts[#lparts + 1] = id end
        if is_owned(id, prefixes) then
            record(mats, 'M', id, i)
            n = n + 1
            local entry = bp and bp[id]
            if entry and entry.base_metal_id then
                record(bases, 'B', id, entry.base_metal_id)
            end
        end
    end

    local plants, np = {}, 0
    local ok_p, err_p = pcall(function()
        plants, np = owned_plant_materials(prefixes, record, lparts)
    end)
    if not ok_p then plants, np = {}, 0 end

    -- tools: tool id -> its subtype number now, for every owned tool
    -- (TOOLS IN SAVED JOBS AND WORK ORDERS). Through record(), so a tool
    -- moved is a fingerprint changed and the full remap runs.
    local tools = {}
    if lparts then lparts[#lparts + 1] = '|TOOLS' end
    pcall(function()
        for i, def in ipairs(df.global.world.raws.itemdefs.tools) do
            local id = def.id
            if lparts then lparts[#lparts + 1] = id end
            if is_owned(id, prefixes) then record(tools, 'T', id, i) end
        end
    end)

    local fingerprint = nil
    if ok_p then
        local ok_h, h = pcall(dfhack.internal.md5, table.concat(lines, '\n'))
        if ok_h and type(h) == 'string' then fingerprint = h end
    end
    return {
        site_id = site, mats = mats, bases = bases, n = n,
        plants = plants, np = np, plants_err = (not ok_p) and err_p or nil,
        tools = tools,
        fingerprint = fingerprint,
        layout = (lparts and ok_p) and table.concat(lparts, string.char(10)) or nil,
    }
end


-- ==========================================
-- WRITE
-- ==========================================
-- Snapshots id -> current index for every injected inorganic, and
-- name -> current pair for every owned plant material.
--
-- Safe any time after Step 4, since nothing later in the pipeline
-- moves a material.
--
-- opts.if_changed: keep the stored ledger when nothing has moved since
-- the last write (UNCHANGED SINCE THE LAST WRITE). The save hook's
-- refresh, the shutdown's snapshot and the hotsave pass it. Startup
-- calls no write when remap() found THE FINGERPRINT unchanged, and a
-- full one otherwise.
--
-- Returns the number of materials recorded.
-- ==========================================
function write(opts)
    local t0 = dfhack.getTickCount()
    -- THE ARRAYS' SIZES, ASKED FIRST (above): no read of every id when
    -- they stand as they were at the last layout read.
    local sig = nil
    pcall(function() sig = sizes_sig() end)
    if opts and opts.if_changed and sig and last_layout and sig == last_sig then
        -- DETAIL: runs at every menu opening and every save.
        log('DETAIL', string.format('Nothing has moved since the last write'
            .. ' (the arrays are the sizes they were); its %d records stand'
            .. ' (checked in %d ms).', last_count, dfhack.getTickCount() - t0), 'WRITE')
        return last_count
    end
    local lay = nil
    pcall(function() lay = layout() end)
    if opts and opts.if_changed and lay and lay == last_layout then
        last_sig = sig
        -- DETAIL: runs at every menu opening and every save.
        log('DETAIL', string.format('Nothing has moved since the last write;'
            .. ' its %d records stand (checked in %d ms).', last_count,
            dfhack.getTickCount() - t0), 'WRITE')
        return last_count
    end

    -- The records, made in one place with their fingerprint (WHAT A
    -- WRITE RECORDS, AND ITS FINGERPRINT).
    local rec = collect()
    local mats, bases, n = rec.mats, rec.bases, rec.n
    local plants, np = rec.plants, rec.np
    local fingerprint = rec.fingerprint
    if rec.plants_err then
        log('ERROR', 'Plant materials could not be read, so none were'
            .. ' recorded: ' .. tostring(rec.plants_err), 'WRITE')
    end

    -- Refuse to overwrite a good ledger with an empty one. If
    -- injection failed this session, last session's record is the
    -- only thing that can still recover these objects. The same goes
    -- for each half on its own: whichever came back empty keeps last
    -- session's record instead of being wiped.
    if n == 0 and np == 0 then
        log('DETAIL', 'No injected materials found. Existing ledger left'
            .. ' intact.', 'WRITE')
        return 0
    end
    if n == 0 or np == 0 then
        local prev = read_ledger()
        if prev then
            -- Last session's half standing in for an empty one makes the
            -- stored records something other than this walk's, so they
            -- get no fingerprint and the next load takes the full path.
            if n == 0 then
                mats = prev.mats
                bases = type(prev.bases) == 'table' and prev.bases or {}
                if next(mats) ~= nil or next(bases) ~= nil then fingerprint = nil end
            end
            if np == 0 and type(prev.plants) == 'table' then
                plants = prev.plants
                if next(plants) ~= nil then fingerprint = nil end
            end
        end
    end

    local form, escaped, first = store_ledger({
        site_id = df.global.plotinfo.site_id,
        mats    = mats,
        bases   = bases,
        plants  = plants,
        tools   = rec.tools,
    }, fingerprint)
    -- What the stored ledger now describes, for the next if_changed call.
    last_layout, last_count = lay, n + np
    last_sig = sig

    log('DETAIL', string.format('Recorded %d material indices and %d plant'
        .. ' materials (%s, in %d ms).', n, np, form,
        dfhack.getTickCount() - t0), 'WRITE')
    -- DETAIL, once a session: ids with spaces are ordinary in raws, so
    -- this only confirms the escaping ran, with one example.
    if escaped > 0 and not escape_reported then
        escape_reported = true
        log('DETAIL', string.format('%d id(s) with whitespace or %% were'
            .. ' escaped in the ledger, e.g. "%s".', escaped, first), 'WRITE')
    end
    return n + np
end


-- ==========================================
-- SMELTERS' PART BARS (move_store, fit_stores)
-- ==========================================
-- A furnace keeps what a melt returns under a whole bar in melt_remainder,
-- one entry per metal, indexed by inorganic position (building_furnacest,
-- df-structures; tenths of a bar, measured 2026-10-04 by refinish-melt.lua,
-- which checks DF's credit against them on every melt). DF saves it as it
-- is, so an entry stays at its position, and an RM metal whose position
-- changed would leave its part bar on whatever took its place: one metal's
-- part bar becoming another's.
--
-- move_store moves one furnace's entries by name, as remap() moves objects
-- (SMELTERS' PART BARS, inside it). Unlike a pile's flags a part bar is
-- metal, so every move is read before any is written, and every source is
-- cleared before any destination is added to: none is counted twice, even
-- where one material's new position is another's old one.
--
-- fit_stores makes every furnace's store exactly as long as the array.
-- Past the end an entry can only be left over from an older, longer
-- layout, and a finish minted later in play would land on it and take a
-- part bar no one melted, so those go. A store shorter than the array is
-- grown: DF writes a melted metal's entry by its index, and sizes a
-- furnace's store to the array when the furnace is built (DFHack's own the
-- same, library/modules/Buildings.cpp). A finish minted later in play lies
-- past the end of every store sized before it; refinish-melt.lua grows a
-- smelter's store before any melt there.

-- One furnace's store, moved by name. resolver(old_index) returns the new
-- index, or nil to leave the entry where it is, and a second value naming
-- the finish when the entry goes to that finish's base metal. Returns the
-- moves made, each { from, to, v, finish }.
local function move_store(r, resolver)
    local moves = {}
    for oi = 0, #r - 1 do
        local v = r[oi]
        if v ~= 0 then
            local ni, finish = resolver(oi)
            if ni and ni ~= oi then
                moves[#moves + 1] = { from = oi, to = ni, v = v, finish = finish }
            end
        end
    end
    if #moves == 0 then return moves end
    for _, mv in ipairs(moves) do r[mv.from] = 0 end
    local need = 0
    for _, mv in ipairs(moves) do
        if mv.to + 1 > need then need = mv.to + 1 end
    end
    if need > #r then r:resize(need) end
    for _, mv in ipairs(moves) do r[mv.to] = r[mv.to] + mv.v end
    return moves
end

-- Every furnace's store made as long as the array (above). Logs what it
-- did, when it did anything.
local function fit_stores()
    local n = #df.global.world.raws.inorganics.all
    local cut, grown, dropped, tenths, faults = 0, 0, 0, 0, 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        local ok = pcall(function()
            if bld:getType() ~= df.building_type.Furnace then return end
            local r = bld.melt_remainder
            local len = #r
            if len > n then
                for i = n, len - 1 do
                    local v = r[i]
                    if v ~= 0 then
                        dropped = dropped + 1
                        tenths = tenths + v
                    end
                end
                r:resize(n)
                cut = cut + 1
            elseif len < n then
                r:resize(n)
                grown = grown + 1
            end
        end)
        if not ok then faults = faults + 1 end
    end
    if dropped > 0 then
        -- INFO: part bars that belonged to no material in this layout.
        log('INFO', string.format('Furnace stores: %d cut to the array and %d grown to it;'
            .. ' %d part bar(s) past the end, %d tenths in all, belonged to no material'
            .. ' and went with the cut.', cut, grown, dropped, tenths), 'STORES')
    elseif cut > 0 or grown > 0 then
        log('DETAIL', string.format('Furnace stores: %d cut to the array and %d grown'
            .. ' to it, %d entries long.', cut, grown, n), 'STORES')
    end
    if faults > 0 then
        -- WARNING: those stores keep the length the save gave them.
        log('WARNING', string.format('%d furnace store(s) could not be fitted.', faults),
            'STORES')
    end
end

-- ==========================================
-- MADE THIS LOAD (next_ids)
-- ==========================================
-- remap() takes every object it reads as saved: the index it finds is
-- read through the previous session's ledger. An object made during
-- the run that calls it is not saved. It already carries this load's
-- indices, and read through the old ledger it moves to whatever
-- material held that index last session, or is left on it when that
-- material is gone. Modules start at the end of startup's Step 2, and
-- their services make things as they start, well before the remap at
-- Step 6.5. SEEN 2026-10-12: Making Fuel's pooper drops dung as it
-- starts, and on a load whose layout had changed the remap read that
-- dung's index through the save's layout, where it belonged to a
-- material that was gone: one object left untouched for each pile it
-- dropped, on every such load.
--
-- DF numbers every new item, building, job, work order and history
-- event from a counter upward, so the counters, read before a run
-- starts any module, draw the line: an object numbered at or past them
-- was made by the run. next_ids() reads them for the caller to hand to
-- remap() (opts.since): refinish-startup.lua before its Step 2, the
-- hotsave (refinish-autosave.lua) before its rebuild. A counter that
-- cannot be read is left out, and that kind is remapped whole, as
-- before.
function next_ids()
    local ids = {}
    pcall(function() ids.item = df.global.item_next_id end)
    pcall(function() ids.building = df.global.building_next_id end)
    pcall(function() ids.job = df.global.job_next_id end)
    pcall(function() ids.order = df.global.world.manager_orders.manager_order_next_id end)
    pcall(function() ids.event = df.global.hist_event_next_id end)
    return ids
end

-- ==========================================
-- REMAP
-- ==========================================
-- Rewrites every object whose stored index belonged to an injected
-- material last session.
--
-- opts.since, optional: next_ids() as the caller read it before its
-- run started any module (MADE THIS LOAD, above). An object numbered at
-- or past it was made by the run and is left as it is. Without it every
-- object is read as saved, as before 2026-10-12.
--
-- Returns moved, skipped, and true as a third value when THE
-- FINGERPRINT showed there was nothing to do.
-- ==========================================
function remap(opts)
    pending_piles = nil
    local since = type(opts) == 'table' and type(opts.since) == 'table'
        and opts.since or nil
    -- ---- THE FINGERPRINT, FIRST ----
    -- When the stored ledger carries a fingerprint and no parked finish
    -- waits, collect what this load would record and compare (WHAT A
    -- WRITE RECORDS, AND ITS FINGERPRINT). Equal: nothing to move and
    -- nothing new to store, so the read and the passes below are skipped,
    -- and the last layout is seeded for startup's write to keep.
    local t_fp = dfhack.getTickCount()
    local raw = dfhack.persistent.getSiteDataString(LEDGER_KEY)
    local stored = raw and raw:sub(1, 64):match('^' .. LEDGER_FORMAT .. '\nF (%x+)')
    if stored then
        local parked = dfhack.persistent.getSiteDataString(PARKED_KEY)
        if not parked or parked == '' then
            local ok_c, rec = pcall(collect, true)
            if ok_c and rec.fingerprint == stored then
                -- The layout from the check's own walk (collect, check_only).
                last_layout = rec.layout
                last_count = rec.n + rec.np
                -- THE ARRAYS' SIZES, ASKED FIRST: seeded with the layout.
                last_sig = nil
                pcall(function() last_sig = sizes_sig() end)
                -- DETAIL: on every load where nothing has moved.
                log('DETAIL', string.format('Fingerprint matches: this load'
                    .. ' records exactly what the stored ledger holds, so no'
                    .. ' object needs remapping (checked in %d ms).',
                    dfhack.getTickCount() - t_fp), 'REMAP')
                -- Nothing moved, but a store can still be the wrong length
                -- (SMELTERS' PART BARS, above remap).
                fit_stores()
                return 0, 0, true
            end
        end
    end

    -- ---- READ THE PREVIOUS SESSION'S LEDGER ----
    -- read_ledger() (STORAGE, above) reads any stored form and applies
    -- the site id gate: a ledger from a different fortress describes a
    -- different array, the same anti-ghosting rule the payload kept.
    local old, what, info, bytes = read_ledger(raw)
    if not old then
        if what == 'none' then
            -- A save that has never had a ledger. Guessing at what the
            -- stored indices used to mean would corrupt objects that are
            -- currently fine, so do nothing. write() runs later this
            -- session and the save is protected from here on.
            log('DETAIL', 'No previous ledger on this save. Remap skipped.',
                'REMAP')
        elseif what == 'other site' then
            log('INFO', string.format('Discarded a ledger from another world'
                .. ' (site %s). Remap skipped.', tostring(info)), 'REMAP')
        else
            log('ERROR', 'Ledger could not be decoded. Remap skipped.', 'REMAP')
        end
        return 0, 0
    end
    -- DETAIL: the read's cost, which is what hung loads while the
    -- ledger was stored the double way (STORAGE, at the top).
    log('DETAIL', string.format('Ledger read: %d bytes, %s, in %d ms.',
        bytes, what, info), 'REMAP')
    -- The previous layout, for the piles (remap_piles, at the end).
    pending_piles = old.mats

    -- ---- BUILD BOTH DIRECTIONS ----
    -- by_old_idx answers "what material was this index last time".
    -- by_id answers "where does that material live now".
    --
    -- Two lookups rather than a precomputed old->new pair map,
    -- because a pair map breaks as soon as two materials swap
    -- places. The name is the only stable identity.
    local inorganics = df.global.world.raws.inorganics.all

    local by_old_idx = {}
    for id, idx in pairs(old.mats) do
        by_old_idx[idx] = id
    end

    local by_id = {}
    for i, mat in ipairs(inorganics) do
        by_id[mat.id] = i
    end

    -- ---- TOOLS, BOTH DIRECTIONS ----
    -- tool_by_old answers "what tool was this subtype number last time",
    -- tool_now "where does that tool sit now" (TOOLS IN SAVED JOBS AND
    -- WORK ORDERS). Empty for a ledger written before tools were recorded
    -- (2026-10-04): nothing moves then, and the write that ends startup
    -- records them from here on.
    local tool_by_old, tool_now = {}, {}
    for id, idx in pairs(type(old.tools) == 'table' and old.tools or {}) do
        tool_by_old[idx] = id
    end
    pcall(function()
        for i, def in ipairs(df.global.world.raws.itemdefs.tools) do tool_now[def.id] = i end
    end)

    -- old_bases answers "what base metal was this finish made from".
    -- Empty for a ledger written before bases were recorded; steel is
    -- then the fallback, the retired wash's own.
    local old_bases = type(old.bases) == 'table' and old.bases or {}
    local steel_idx = by_id["STEEL"]

    -- ---- PLANT PAIRS, BOTH DIRECTIONS ----
    -- by_old_pair answers "which plant material was this pair last
    -- time", by_name "which pair is it now". Same two-lookup shape as
    -- the inorganics, for the same reason.
    local by_old_pair = {}
    local has_plants = type(old.plants) == 'table'
    if has_plants then
        for name, pair in pairs(old.plants) do
            if type(pair) == 'table' and type(pair[1]) == 'number'
               and type(pair[2]) == 'number' then
                by_old_pair[pair[1] .. ':' .. pair[2]] = name
            end
        end
    else
        log('INFO', 'Previous ledger records no plant materials; plant'
            .. ' pairs left alone this once.', 'REMAP')
    end
    local by_name = {}
    local ok_np, err_np = pcall(function()
        by_name = owned_plant_materials(owned_prefixes())
    end)
    if not ok_np then
        log('ERROR', 'Plant materials could not be read, so plant pairs'
            .. ' were not remapped: ' .. tostring(err_np), 'REMAP')
        by_name = {}
    end

    local moved, skipped, plant_moved = 0, 0, 0
    -- gone: material id, or plant material name, -> objects left on it
    -- because it is not loaded now, so the WARNING at the end names what
    -- is missing instead of only counting it (added 2026-10-12).
    local gone = {}
    -- made_now: objects the run made, left as they are (MADE THIS LOAD).
    -- fresh(kind, id): true when the object was made by the run.
    local made_now = 0
    local function fresh(kind, id)
        local mark = since and since[kind]
        return type(mark) == 'number' and type(id) == 'number' and id >= mark
    end
    -- minted: finishes minted on demand for the objects that wear them
    -- (MINTED ON DEMAND, in resolve below).
    local minted = 0
    -- to_base: finishes no longer generated, sent to their base metal.
    -- to_steel: the same, with no recorded base.
    local to_base, to_steel = 0, 0

    -- ---- PARKING ----
    -- Every object this run sends to a base metal, with the finish it
    -- had (pf) and the base (pb). Kept in PARKED_KEY at the end, beside
    -- the records still waiting from earlier runs. One record per
    -- object: a tile can be reached twice, by its own item and as the
    -- floor above a wall.
    local newly_parked, parked_seen = {}, {}
    local function park(rec, pf, pb)
        if not pf then return end
        local key = rec.k .. ':' .. tostring(rec.id or (rec.x .. ',' .. rec.y .. ',' .. rec.z))
            .. ':' .. tostring(rec.tf) .. ':' .. table.concat(rec.p or {}, '.')
        if parked_seen[key] then return end
        parked_seen[key] = true
        rec.f, rec.b = pf, pb
        newly_parked[#newly_parked + 1] = rec
    end

    -- ---- THE DECISION, MADE ONCE PER OBJECT ----
    -- Returns nil to mean "write nothing". That covers two cases:
    --
    --   not in the ledger    vanilla stone, and, on a save the
    --                        retired save wash wrote, core RM
    --                        objects washed to a vanilla index.
    --                        Those sit below the injected band and
    --                        are restored by name in Step 7, the
    --                        one-time legacy migration.
    --
    --   material is gone     not injected at this point. For a module
    --                        material that means the module was
    --                        removed, or the material is one a watcher
    --                        injects on demand AFTER this (the drain
    --                        keys' per-retort materials, measured
    --                        2026-09-29 coming back where they were).
    --                        RM never writes a sentinel here, since a
    --                        sentinel would destroy the on-demand ones;
    --                        the object keeps its old index.
    --
    -- A FINISH is the exception, and never returns nil for being gone.
    -- Finishes are minted only once the fort can make them
    -- (refinish-mint-finish.lua), so a finish missing here may just not
    -- be minted yet: then it is minted now and the object moves onto it
    -- (MINTED ON DEMAND, in resolve). One the blueprint cannot make this
    -- session (its base metal not selected, Material Finishes off) is
    -- not generated at all. Its object
    -- goes to the base metal the old ledger recorded, or to steel when
    -- none was recorded, and is parked: resolve() also returns the
    -- finish and the base, and the pass that owns the object records
    -- them (PARKED FINISHES, at the end). Left on its old index, it
    -- would take whatever slid into that slot, the rest of the band or
    -- a material injected on demand, and the next ledger write would
    -- file it under that name for good.
    local function resolve(old_idx)
        local id = by_old_idx[old_idx]
        if not id then return nil end

        local new_idx = by_id[id]
        if not new_idx then
            if has_prefix(id, CORE_PREFIX) then
                -- ---- MINTED ON DEMAND ----
                -- A finish the blueprint can make is minted here, with its
                -- base's forge folder, and kept in the finish roster
                -- (refinish-mint-finish.lua, ON DEMAND). by_id learns its
                -- index, so the next object wearing it finds it at once.
                local mint = _G.refinish_mint_finish_on_demand
                if mint then
                    local ok_m, m_idx = pcall(mint, id)
                    if ok_m and m_idx then
                        by_id[id] = m_idx
                        minted = minted + 1
                        if m_idx ~= old_idx then moved = moved + 1 end
                        return m_idx
                    end
                end
                local b_idx = old_bases[id] and by_id[old_bases[id]]
                if b_idx then
                    to_base = to_base + 1
                    return b_idx, id, old_bases[id]
                end
                if steel_idx then
                    to_steel = to_steel + 1
                    return steel_idx, id, "STEEL"
                end
            end
            skipped = skipped + 1
            gone[id] = (gone[id] or 0) + 1
            return nil
        end

        if new_idx ~= old_idx then moved = moved + 1 end
        return new_idx
    end

    -- ---- THE SAME DECISION, FOR A PAIR ----
    -- Every stored reference is a (mat_type, mat_index) pair. Returns
    -- the pair to write, or nil to write nothing. An inorganic (type 0)
    -- goes through resolve() above; a plant pair through the plant maps,
    -- by name, with the same two nil cases (not ours, or gone). Any
    -- other type, creature or builtin, is never RM's.
    local function resolve_pair(t, i)
        if t == 0 then
            -- ---- PAST THE CURRENT END ----
            -- An index past the end is resolved by name like any other
            -- (2026-10-12). The band is complete at this point (see THE
            -- DECISION), so a material stored past the end moved down
            -- because the band shrank, or is not loaded now, and resolve()
            -- answers both: its new place, a finish's base metal, or left
            -- where it is and named in the WARNING as gone. resolve()
            -- never touches the array: it looks names up in two Lua
            -- tables, so an index past the end is safe to hand it. Only an
            -- index that is no index at all is refused here.
            --
            -- Until 2026-10-12 only a FINISH was resolved past the end, and
            -- any other material there was taken for an on-demand one its
            -- watcher had not injected yet: left alone, and not counted.
            -- Finishes had been let through for the reason that now covers
            -- every material: refusing them left the tail of a shrunken
            -- band as rock, with the material still loaded a few slots
            -- lower. SEEN 2026-10-12: four injected ports did not register
            -- on a load, 162 materials ahead of crust, heap, Making
            -- Concrete and Making Fuel, so all 83 of those moved down 162
            -- places and the array ended at 1029, below every index they
            -- were saved at. Every heap and dung pile in the fort stayed
            -- past the end, which DF shows as builtin rock, and the log
            -- said nothing. An on-demand material not injected yet (THE
            -- DECISION) is now named in the WARNING while it waits, and is
            -- still left where it is.
            if type(i) ~= 'number' or i < 0 then return nil end
            local ni, pf, pb = resolve(i)
            if ni then return 0, ni, pf, pb end
            return nil
        end
        if not is_plant_type(t) or type(i) ~= 'number' then return nil end
        local name = by_old_pair[t .. ':' .. i]
        if not name then return nil end
        local now = by_name[name]
        if not now then
            skipped = skipped + 1
            gone[name] = (gone[name] or 0) + 1
            return nil
        end
        if now[1] ~= t or now[2] ~= i then
            moved = moved + 1
            plant_moved = plant_moved + 1
        end
        return now[1], now[2]
    end

    -- ---- CONSTRUCTIONS ----
    -- Constructions have no id and no array. They are addressed
    -- only by tile, through dfhack.constructions.findAtTile, and
    -- they are reached through the item that built them, exactly as
    -- the retired save wash did it.
    --
    -- A wall occupies its own tile and the floor above, so z+1 is
    -- checked too, and only when it carries the same old pair as the
    -- tile below, the wash's own rule.
    --
    -- mat_type is written alongside mat_index because every
    -- construction write in RM does that, the legacy migration in
    -- refinish-load.lua included.
    --
    -- Wrapped so a construction fault cannot abort the item and
    -- building passes, as the legacy migration wraps its own.
    local function remap_construction_at(item)
        pcall(function()
            local pos = item.pos
            local cons = dfhack.constructions.findAtTile(pos)
            if not cons then return end

            local ot, oi = cons.mat_type, cons.mat_index
            local nt, ni, pf, pb = resolve_pair(ot, oi)
            if not nt then return end

            cons.mat_type = nt
            cons.mat_index = ni
            park({ k = 'con', x = pos.x, y = pos.y, z = pos.z }, pf, pb)

            local above = dfhack.constructions.findAtTile(
                { x = pos.x, y = pos.y, z = pos.z + 1 })
            if above and above.mat_type == ot and above.mat_index == oi then
                above.mat_type = nt
                above.mat_index = ni
                park({ k = 'con', x = pos.x, y = pos.y, z = pos.z + 1 }, pf, pb)
            end
        end)
    end

    -- ---- DYE REFERENCES ----
    -- Each reference below is a (type, index) pair and is moved exactly
    -- as an item's own is: through resolve_pair(), by name, inorganic or
    -- plant, and left untouched when its material is gone. Module dyes
    -- are plant materials now (DYE_HOST, TREE_DYE_HOST), so the plant
    -- half is the one that matters for them.
    --
    -- Where they live (df-structures; not yet measured in play, since
    -- no module dye has dyed anything yet):
    --   THREAD         dye_mat_type / dye_mat_index, and dye_profile
    --   SKIN_TANNED    dye_material / dye_matgloss, and dye_profile
    --   POWDER_MISC    dye_profile (a mixed dye lists its sources)
    --   built items    every thread improvement (the dye on cloth) and
    --                  sewn image improvement: a dye pair and a
    --                  dye_profile each
    --   history        see HISTORY EVENTS, after the building pass
    --
    -- dye_profile keeps its sources in parallel vectors. dye_material[k]
    -- is read as the source's material TYPE and dye_matg[k] as its
    -- INDEX, the naming DF uses for every other dye pair. That reading
    -- is unmeasured, so an entry changes only when the pair resolves
    -- through the old ledger. Were the reading backwards, the pair would
    -- not be one the ledger recorded, and it would be left alone rather
    -- than corrupted.
    local dye_moved, dye_faults = 0, 0

    -- One material pair: obj[type_f] is the material type, obj[index_f]
    -- the index. Both are written when the pair moves, since a plant
    -- material can change plant as well as position. Returns true when
    -- it changed, so each caller keeps its own count, and the finish and
    -- base when the pair was parked.
    local function move_pair(obj, type_f, index_f)
        local t, i = obj[type_f], obj[index_f]
        local nt, ni, pf, pb = resolve_pair(t, i)
        if nt and (nt ~= t or ni ~= i) then
            if nt ~= t then obj[type_f] = nt end
            obj[index_f] = ni
            return true, pf, pb
        end
        return false
    end

    local function dye_pair(obj, type_f, index_f)
        if move_pair(obj, type_f, index_f) then dye_moved = dye_moved + 1 end
    end

    local function dye_profile(p)
        local n = math.min(#p.dye_material, #p.dye_matg)
        for k = 0, n - 1 do
            local t, i = p.dye_material[k], p.dye_matg[k]
            local nt, ni = resolve_pair(t, i)
            if nt and (nt ~= t or ni ~= i) then
                if nt ~= t then p.dye_material[k] = nt end
                p.dye_matg[k] = ni
                dye_moved = dye_moved + 1
            end
        end
    end

    local THREAD      = df.item_type.THREAD
    local SKIN_TANNED = df.item_type.SKIN_TANNED
    local POWDER_MISC = df.item_type.POWDER_MISC

    -- Every dye reference one item carries. The item type is checked
    -- before any type-specific field is read: those fields exist only
    -- on their own item classes, and reading one elsewhere throws.
    local function remap_item_dyes(item)
        local t = item:getType()
        if t == THREAD then
            dye_pair(item, 'dye_mat_type', 'dye_mat_index')
            dye_profile(item.dye_profile)
        elseif t == SKIN_TANNED then
            dye_pair(item, 'dye_material', 'dye_matgloss')
            dye_profile(item.dye_profile)
        elseif t == POWDER_MISC then
            dye_profile(item.dye_profile)
        end
        if df.item_constructed:is_instance(item) then
            for _, imp in ipairs(item.improvements) do
                if df.itemimprovement_threadst:is_instance(imp)
                   or df.itemimprovement_sewn_imagest:is_instance(imp) then
                    dye_pair(imp.dye, 'mat_type', 'mat_index')
                    dye_profile(imp.dye_profile)
                end
            end
        end
    end

    -- ---- ITEMS ----
    -- getActualMaterial() is the item's own mat_type. Type 0 is the
    -- inorganic test used throughout RM; a type in the plant range may
    -- be one of our plant materials. Anything else (creature, builtin)
    -- is never RM's and is never touched here.
    --
    -- The construction pass rides this loop because the item is the
    -- only handle a construction has. flags.construction marks an
    -- item that is part of one (refinish-load.lua:124).
    for _, item in ipairs(df.global.world.items.all) do
        -- Made by this run (MADE THIS LOAD): already on this load's
        -- indices, so neither its own material nor its dyes move.
        local made = fresh('item', item.id)
        if made then made_now = made_now + 1 end
        local mt = item:getActualMaterial()
        if not made and (mt == 0 or is_plant_type(mt)) then
            if item.flags.construction then
                remap_construction_at(item)
            end

            local ok_i, mi = pcall(function() return item.mat_index end)
            if ok_i then
                local nt, ni, pf, pb = resolve_pair(mt, mi)
                if nt then
                    if nt ~= mt then item.mat_type = nt end
                    item.mat_index = ni
                    park({ k = 'item', id = item.id }, pf, pb)
                end
            end
        end

        -- Dye references, on every item whatever its own material: a
        -- plant or creature item can carry an inorganic dye. One item's
        -- fault is counted and reported, and the pass carries on.
        if not made and not pcall(remap_item_dyes, item) then
            dye_faults = dye_faults + 1
        end
    end

    -- ---- BUILDINGS ----
    for _, bld in ipairs(df.global.world.buildings.all) do
        local ok_b, bt, bi = pcall(function() return bld.mat_type, bld.mat_index end)
        if ok_b and fresh('building', bld.id) then
            -- Built by this run (MADE THIS LOAD): left as it is.
            made_now = made_now + 1
        elseif ok_b then
            local nt, ni, pf, pb = resolve_pair(bt, bi)
            if nt then
                if nt ~= bt then bld.mat_type = nt end
                bld.mat_index = ni
                park({ k = 'bld', id = bld.id }, pf, pb)
            end
        end
    end

    -- ---- SMELTERS' PART BARS ----
    -- Each furnace's store moved by name, through the same decision as every
    -- object here (resolve): to its metal's new position, onto a finish
    -- minted for it now, or, for a finish no longer generated, into its
    -- base metal's entry, added to what the base holds. A part bar is not
    -- parked: once it has joined the base's it cannot be told apart, so it
    -- does not go back when the finish returns. Then every store is fitted
    -- to the array (SMELTERS' PART BARS, above remap).
    local store_moved, store_based, store_faults = 0, 0, 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        local ok_s = pcall(function()
            if bld:getType() ~= df.building_type.Furnace then return end
            -- A furnace built by this run keeps a store of this load's
            -- layout (MADE THIS LOAD); counted with the buildings above.
            if fresh('building', bld.id) then return end
            local moves = move_store(bld.melt_remainder, function(oi)
                local nt, ni, pf = resolve_pair(0, oi)
                if nt ~= 0 then return nil end
                return ni, pf
            end)
            for _, mv in ipairs(moves) do
                if mv.finish then
                    store_based = store_based + 1
                    -- resolve() counted it among objects sent to a base, to be
                    -- parked and given their finish back. A part bar is not
                    -- parked, so it comes off that count (REPORT).
                    if old_bases[mv.finish] and by_id[old_bases[mv.finish]] then
                        to_base = to_base - 1
                    else
                        to_steel = to_steel - 1
                    end
                else
                    store_moved = store_moved + 1
                end
            end
        end)
        if not ok_s then store_faults = store_faults + 1 end
    end
    fit_stores()

    -- ---- JOBS AND WORK ORDERS ----
    -- Each job carries material pairs of its own: the job's (the material
    -- a forge job makes its item of) and, for each item it asks for
    -- (job_items.elements), the material the item must be and the one
    -- picked behind the magnifying glass (job_details_mat_type and
    -- job_details_mat_index). Field names read off a live job dump
    -- (df_data_reference, make_gadan_instrument_job_inspect_85.txt).
    --
    -- MEASURED 2026-10-02: the first load that minted finishes just in
    -- time moved every finish, and a forge job saved on amber steel came
    -- back as a rock breastplate in progress, while the amber steel
    -- breastplates it had already made (items) were moved and kept their
    -- finish. Nothing showed it before, because the finishes kept their
    -- indices from load to load.
    --
    -- A job is never parked. One whose finish is not generated goes to
    -- the base metal resolve() gives it, so it makes that instead of an
    -- item of no material; its finish does not come back to it.
    --
    -- A standing work order is moved the same way: its own pair, the
    -- items it asks for and the item conditions it checks. No order has
    -- been read in play yet (refinish-orders-probe counted none on its
    -- world), so a pair is moved only where the struct has one: a field a
    -- struct lacks throws on read, which is nothing to move, not a fault.
    local job_moved, job_faults, n_jobs, n_orders = 0, 0, 0, 0
    local function has_pair(obj, type_f, index_f)
        return (pcall(function() return obj[type_f], obj[index_f] end))
    end
    -- A tool's number, moved by name (TOOLS IN SAVED JOBS AND WORK
    -- ORDERS): an item slot or a condition asking for a TOOL, and a job or
    -- order that makes one. Only a number an owned tool held last session
    -- is touched; a vanilla tool's never moves.
    local tool_moved, tool_gone = 0, 0
    local TOOL, MAKE_TOOL = df.item_type.TOOL, df.job_type.MakeTool
    local function move_tool(obj)
        local s = obj.item_subtype
        if type(s) ~= 'number' or s < 0 then return end
        local id = tool_by_old[s]
        if not id then return end
        local ni = tool_now[id]
        if ni == nil then
            tool_gone = tool_gone + 1
            return
        end
        if ni ~= s then
            obj.item_subtype = ni
            tool_moved = tool_moved + 1
        end
    end
    local function tool_slot(obj)
        pcall(function()
            if obj.item_type == TOOL then move_tool(obj) end
        end)
    end
    local function tool_made(obj)
        pcall(function()
            if obj.job_type == MAKE_TOOL or obj.item_type == TOOL then move_tool(obj) end
        end)
    end
    local function job_pair(obj, type_f, index_f)
        if has_pair(obj, type_f, index_f) and move_pair(obj, type_f, index_f) then
            job_moved = job_moved + 1
        end
    end
    local function remap_job_items(reqst)
        local ok_e, els = pcall(function() return reqst.elements end)
        if not (ok_e and els) then return end
        for _, e in ipairs(els) do
            job_pair(e, 'mat_type', 'mat_index')
            job_pair(e, 'job_details_mat_type', 'job_details_mat_index')
            tool_slot(e)
        end
    end
    local function remap_job(j)
        job_pair(j, 'mat_type', 'mat_index')
        tool_made(j)
        remap_job_items(j.job_items)
    end
    local function remap_order(o)
        job_pair(o, 'mat_type', 'mat_index')
        tool_made(o)
        local ok_it, items = pcall(function() return o.items end)
        if ok_it and items then remap_job_items(items) end
        local ok_c, conds = pcall(function() return o.item_conditions end)
        if ok_c and conds then
            for _, c in ipairs(conds) do
                job_pair(c, 'mat_type', 'mat_index')
                tool_slot(c)
            end
        end
    end
    local link = df.global.world.jobs.list.next
    while link do
        local j = link.item
        -- A job made by this run (MADE THIS LOAD) already names this
        -- load's materials and tools, and is left as it is.
        if j and fresh('job', j.id) then
            made_now = made_now + 1
        elseif j then
            n_jobs = n_jobs + 1
            if not pcall(remap_job, j) then job_faults = job_faults + 1 end
        end
        link = link.next
    end
    local ok_o, orders = pcall(function() return df.global.world.manager_orders.all end)
    if ok_o and orders then
        for _, o in ipairs(orders) do
            -- Made by this run (MADE THIS LOAD): left as it is.
            if fresh('order', o.id) then
                made_now = made_now + 1
            else
                n_orders = n_orders + 1
                if not pcall(remap_order, o) then job_faults = job_faults + 1 end
            end
        end
    end

    -- ---- HISTORY EVENTS ----
    -- World history stores the material of what an event was about, and
    -- legends read it back by index. Every history event class in
    -- df-structures that carries a material (unmeasured in play):
    --
    --   masterpiece_created_item              mat_type / mat_index
    --   masterpiece_created_dye_item          mat_type / mat_index and
    --                                         dye_mat_type / dye_mat_index
    --   masterpiece_created_item_improvement  mat_type / mat_index and
    --                                         imp_mat_type / imp_mat_index
    --   item_stolen                           mattype / matindex
    --   hist_figure_died                      weapon.mattype / matindex and
    --                                         weapon.shooter_mattype /
    --                                         shooter_matindex
    --   body_abused                           the spike (Impaled) or the
    --                                         rope (Hung), mat_type /
    --                                         mat_index. abuse_data is a
    --                                         union, so only the member
    --                                         abuse_type names is read.
    --
    -- COST. RM injects only into this fort, so only this fort's era can
    -- hold one of our indices, and that era is a short tail on a vector
    -- worldgen fills with hundreds of thousands of events. Events are
    -- appended as they happen, so the walk starts at the newest and
    -- stops at the event that founded this site; everything before it
    -- is older than the fort. If that event is not found, the whole
    -- vector is walked. A class lookup keeps each event to one table
    -- read. The count, where it stopped and the time are logged.
    local hist_moved, n_events, found_start = 0, 0, false
    local t0 = dfhack.getTickCount()

    -- The event being walked, set by the walk before each handler runs,
    -- so a parked pair records which event it belongs to. path is the
    -- keys from the event to obj, given only where obj is not the event.
    local cur_ev = nil
    local function hist_pair(obj, type_f, index_f, path)
        local changed, pf, pb = move_pair(obj, type_f, index_f)
        if changed then hist_moved = hist_moved + 1 end
        if pf and cur_ev then
            park({ k = 'hist', id = cur_ev.id, p = path, tf = type_f,
                   xf = index_f }, pf, pb)
        end
    end

    -- A class missing from this DFHack build drops that class only.
    local function df_type(name)
        local ok_t, t = pcall(function() return df[name] end)
        if ok_t then return t end
        return nil
    end

    local ok_h, err_h = pcall(function()
        local IMPALED = df.body_abuse_method_type.Impaled
        local HUNG    = df.body_abuse_method_type.Hung

        -- Keyed by class type. An event's _type is its exact class,
        -- since DFHack exposes vtable classes in their exact type.
        local handlers = {}
        local function on(name, fn)
            local t = df_type(name)
            if t then handlers[t] = fn end
        end
        on('history_event_masterpiece_created_itemst', function(ev)
            hist_pair(ev, 'mat_type', 'mat_index')
        end)
        on('history_event_masterpiece_created_dye_itemst', function(ev)
            hist_pair(ev, 'mat_type', 'mat_index')
            hist_pair(ev, 'dye_mat_type', 'dye_mat_index')
        end)
        on('history_event_masterpiece_created_item_improvementst', function(ev)
            hist_pair(ev, 'mat_type', 'mat_index')
            hist_pair(ev, 'imp_mat_type', 'imp_mat_index')
        end)
        on('history_event_item_stolenst', function(ev)
            hist_pair(ev, 'mattype', 'matindex')
        end)
        on('history_event_hist_figure_diedst', function(ev)
            hist_pair(ev.weapon, 'mattype', 'matindex', { 'weapon' })
            hist_pair(ev.weapon, 'shooter_mattype', 'shooter_matindex', { 'weapon' })
        end)
        on('history_event_body_abusedst', function(ev)
            if ev.abuse_type == IMPALED then
                hist_pair(ev.abuse_data.Impaled, 'mat_type', 'mat_index',
                    { 'abuse_data', 'Impaled' })
            elseif ev.abuse_type == HUNG then
                hist_pair(ev.abuse_data.Hung, 'mat_type', 'mat_index',
                    { 'abuse_data', 'Hung' })
            end
        end)

        local FOUNDED = df_type('history_event_created_sitest')
        local site    = df.global.plotinfo.site_id
        local events  = df.global.world.history.events

        for i = #events - 1, 0, -1 do
            local ev  = events[i]
            local cls = ev._type
            if cls == FOUNDED and ev.site == site then
                found_start = true
                break
            end
            n_events = n_events + 1
            local fn = handlers[cls]
            -- One odd event is skipped, never allowed to end the walk. An
            -- event recorded by this run (MADE THIS LOAD) already names
            -- this load's materials, and is left as it is.
            if fn and fresh('event', ev.id) then
                made_now = made_now + 1
            elseif fn then
                cur_ev = ev
                pcall(fn, ev)
            end
        end
    end)
    if not ok_h then
        -- WARNING, not ERROR: a stale history reference reads oddly in
        -- a legend, but nothing in the fort points at a wrong material.
        log('WARNING', 'History events not remapped: ' .. tostring(err_h),
            'REMAP')
    end
    log('DETAIL', string.format('History pass read %d events %s in %d ms.',
        n_events,
        found_start and "back to this site's founding"
                     or "(founding not found, whole list)",
        dfhack.getTickCount() - t0), 'REMAP')

    -- ==========================================
    -- PARKED FINISHES: BACK WHEN GENERATED AGAIN
    -- ==========================================
    -- Objects an earlier run sent to their base metal get their finish
    -- back once it is generated again (the metal reselected, Material
    -- Finishes back ON). Only an object still on the base metal it was
    -- parked on is put back; one destroyed or changed since is dropped.
    --
    -- AFTER every pass above, never before: an object put back earlier
    -- would carry its finish's CURRENT index into passes that read
    -- indices through the OLD ledger, and they would move it again.
    -- Records whose finish is still missing keep waiting, and this
    -- run's newly parked objects join them.
    local restored, dropped = 0, 0
    local waiting = {}
    local prev_parked = read_parked()
    for _, r in ipairs(prev_parked) do
        local f_idx = by_id[r.f]
        -- A parked finish the blueprint can make again is minted for its
        -- object, as resolve does (MINTED ON DEMAND).
        if not f_idx and _G.refinish_mint_finish_on_demand then
            local ok_m, m_idx = pcall(_G.refinish_mint_finish_on_demand, r.f)
            if ok_m and m_idx then
                by_id[r.f] = m_idx
                f_idx = m_idx
                minted = minted + 1
            end
        end
        if not f_idx then
            waiting[#waiting + 1] = r
        else
            local ok_r, back = pcall(restore_parked, r, by_id[r.b], f_idx)
            if ok_r and back then restored = restored + 1
            else dropped = dropped + 1 end
        end
    end
    for _, r in ipairs(newly_parked) do waiting[#waiting + 1] = r end
    if #prev_parked > 0 or #newly_parked > 0 then
        local ok_w, err_w = pcall(write_parked, waiting)
        -- ERROR: the records not kept are finishes that cannot come back.
        if not ok_w then
            log('ERROR', 'Parked finishes could not be saved: '
                .. tostring(err_w), 'PARKED')
        end
    end

    -- ---- REPORT ----
    if moved > 0 then
        -- INFO: this only happens when a module was added, removed or
        -- changed, which a player may well want to confirm.
        log('INFO', string.format('Remapped %d objects to new material'
            .. ' indices.', moved), 'REMAP')
    end

    if plant_moved > 0 then
        log('DETAIL', string.format('%d of those were plant materials (host'
            .. ' plants and appended twins).', plant_moved), 'REMAP')
    end

    if dye_moved > 0 then
        log('DETAIL', string.format('%d of those were dye references on dyed'
            .. ' goods and dye profiles.', dye_moved), 'REMAP')
    end

    if hist_moved > 0 then
        log('DETAIL', string.format('%d of those were material references in'
            .. ' world history.', hist_moved), 'REMAP')
    end

    if job_moved > 0 then
        -- INFO: a job or work order a player may be waiting on.
        log('INFO', string.format('%d of those were materials on jobs and work'
            .. ' orders (%d job(s) and %d order(s) read).', job_moved, n_jobs,
            n_orders), 'REMAP')
    end

    if job_faults > 0 then
        -- WARNING: those jobs or orders may still name the wrong material.
        log('WARNING', string.format('%d job(s) or work order(s) faulted; their'
            .. ' materials were not remapped.', job_faults), 'REMAP')
    end

    if tool_moved > 0 then
        log('DETAIL', string.format('%d tool slot(s) in saved jobs and work orders moved to'
            .. ' their tool.', tool_moved), 'REMAP')
    end

    if tool_gone > 0 then
        -- WARNING: those slots still ask for whatever tool holds the old
        -- number; the jobs are worth cancelling.
        log('WARNING', string.format('%d tool slot(s) in saved jobs and work orders ask for a'
            .. ' tool no longer injected and were left as they were.', tool_gone), 'REMAP')
    end

    if store_moved > 0 then
        log('DETAIL', string.format('%d of those were part bars in furnace stores,'
            .. ' moved to their metal.', store_moved), 'REMAP')
    end

    if store_based > 0 then
        -- INFO: the consequence of a setting the player changed.
        log('INFO', string.format('%d part bar(s) in furnace stores, of finishes no longer'
            .. " generated, went into their base metal's; they do not go back.",
            store_based), 'REMAP')
    end

    if store_faults > 0 then
        -- WARNING: those furnaces keep their part bars where the save left them.
        log('WARNING', string.format('%d furnace store(s) could not be read or written.',
            store_faults), 'REMAP')
    end

    if dye_faults > 0 then
        log('WARNING', string.format('The dye pass faulted on %d items; their'
            .. ' dye references were not remapped.', dye_faults), 'REMAP')
    end

    if to_base > 0 then
        -- INFO: the consequence of a setting the player changed.
        log('INFO', string.format('%d objects in finishes no longer generated'
            .. ' went to their base metal; each gets its finish back when'
            .. ' the finish is generated again.', #newly_parked), 'REMAP')
    end

    if minted > 0 then
        -- INFO: what a save from before the finish roster shows once, on
        -- its first load; after that, only a roster lost or unreadable.
        log('INFO', string.format('%d finishes worn by objects were minted for'
            .. ' them.', minted), 'REMAP')
    end

    if restored > 0 then
        -- INFO: the other half of the line above.
        log('INFO', string.format('%d parked objects got their finish back.',
            restored), 'REMAP')
    end

    if dropped > 0 then
        log('DETAIL', string.format('%d parked records dropped: the object'
            .. ' is gone, or no longer on the base metal it was parked on.',
            dropped), 'REMAP')
    end

    if #waiting > 0 then
        log('DETAIL', string.format('%d objects parked, waiting for their'
            .. ' finish to be generated again.', #waiting), 'REMAP')
    end

    if to_steel > 0 then
        -- WARNING: correct metal unknown, so steel stood in for it.
        log('WARNING', string.format('%d objects in finishes no longer'
            .. ' generated had no recorded base metal and went to steel.',
            to_steel), 'REMAP')
    end

    if skipped > 0 then
        -- WARNING: the expected result of removing a mod, or of a module
        -- that did not register this load, not a fault in the remap
        -- itself. Since 2026-10-12 it names the materials, most objects
        -- first, so the missing mod reads off the line.
        local names = {}
        for name, n in pairs(gone) do names[#names + 1] = { name = name, n = n } end
        table.sort(names, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.name < b.name
        end)
        local shown = {}
        for k = 1, math.min(6, #names) do
            shown[k] = string.format('%s x%d', names[k].name, names[k].n)
        end
        if #names > 6 then
            shown[#shown + 1] = string.format('and %d more', #names - 6)
        end
        log('WARNING', string.format('%d objects left untouched; their'
            .. ' materials are not loaded now: %s.', skipped,
            table.concat(shown, ', ')), 'REMAP')
    end

    if made_now > 0 then
        -- DETAIL: an ordinary load makes a few (MADE THIS LOAD).
        log('DETAIL', string.format('%d object(s) made during this run were'
            .. " left as they are: they carry this load's indices already.",
            made_now), 'REMAP')
    end

    if moved == 0 and skipped == 0 and to_base == 0 and to_steel == 0
       and restored == 0 and dropped == 0 and minted == 0 and store_based == 0
       and tool_moved == 0 and tool_gone == 0 then
        log('DETAIL', 'No objects needed remapping.', 'REMAP')
    end

    return moved, skipped
end


-- ==========================================
-- PILE SETTINGS FOLLOW THEIR MATERIALS (remap_piles)
-- ==========================================
-- A stockpile keeps its choices in lists indexed by inorganic position:
-- the eleven lists refinish-stockpile-windows.lua names as indexed by
-- inorganic material (INORG_LISTS). MEASURED 2026-10-02 (the minter's
-- PILES line, the first finish minted in play): on a save written before
-- the finish roster, the piles' bars lists came back 62,606 long, the old
-- layout's length, not the array's. DF restores the lists as saved, so
-- an entry stays at its position, and a material whose position changed
-- leaves its pile choices behind on whatever takes its place. Nothing
-- moved them until 2026-10-03.
--
-- remap() moves objects by name; this moves the piles' entries the same
-- way. For every material RM owns that was in the previous layout and is
-- in the array now at another position, its entry is read from the old
-- position and written at the new one, in every list of every pile.
-- Then a list longer than the array is cut to the array's length: past
-- the end it holds only the previous layout's entries, and a finish
-- minted later in play would land on one of them and take a choice no
-- one made for it. MEASURED 2026-10-03 (region4, this pass's first
-- version, which moved entries but cut nothing): piles 29 and 30 kept
-- bars lists 62,606 long with no finish in today's array switched on,
-- and piles 27, 28 and 32 had empty bars lists. An empty list stays
-- empty.
--
-- A LIST SHORTER THAN THE ARRAY is grown to it before any entry moves,
-- every load (PILE LISTS FITTED TO THE ARRAY, below). Until 2026-10-16
-- nothing grew one, and a move to a position past a list's end was
-- dropped: a load that shrank the band cut every list to it, and when
-- the band came back every material past the cut lost its choices.
--
-- Run by refinish-startup.lua after Steps 6.7 and 7, so the finishes the
-- fort's bars and dusts mint keep their choices too. A finish first
-- minted later in play lies past the end of an old pile's lists, as it
-- does for a pile made in the same session, until the next load grows
-- them (PILE LISTS FITTED TO THE ARRAY).
-- All of a list's entries are read before any is written, because one
-- material's new position can be another's old one. Each entry is
-- written back as the type it was read as.
-- ==========================================
local PILE_LISTS = {
    { 'stone', 'mats' }, { 'ammo', 'mats' }, { 'coins', 'mats' },
    { 'bars_blocks', 'bars_mats' }, { 'bars_blocks', 'blocks_mats' },
    { 'gems', 'rough_mats' }, { 'gems', 'cut_mats' }, { 'finished_goods', 'mats' },
    { 'weapons', 'mats' }, { 'armor', 'mats' }, { 'furniture', 'mats' },
}

-- One list of one pile: every move read, then written. Returns how many
-- entries changed. Under pcall in the caller, so a list that cannot be
-- read or written is counted as a fault and the rest go on.
local function move_list(v, from, to, vals)
    local n = #v
    for k = 1, #from do
        local oi = from[k]
        if oi < n then vals[k] = v[oi] else vals[k] = nil end
    end
    local changed = 0
    for k = 1, #from do
        local val, ni = vals[k], to[k]
        if val ~= nil and ni < n and v[ni] ~= val then
            v[ni] = val
            changed = changed + 1
        end
    end
    return changed
end

-- ==========================================
-- PILE LISTS FITTED TO THE ARRAY (fit_piles)
-- ==========================================
-- A pile has an entry for a material only while its list reaches that
-- material's position. DF shows a row in the pile's settings only for an
-- entry the list holds, and a pile files an item only where its entry is
-- on (refinish-stockpile-windows.lua, THE PILES' TWIN SLOTS). The cut in
-- remap_piles shortens every list whenever a load's array is shorter, and
-- until 2026-10-16 nothing grew one back.
--
-- MEASURED 2026-10-16 (session log, the 16:10 load, and refinish-slag-probe
-- after it): that load moved 114 materials, exactly the ones injected after
-- the four ArgMOD ports (EML, ArgMOD, Glass & Ceramics and Mythical, 162
-- materials): crust, heap, Making Concrete's 4, Making Fuel's 78 and all
-- 30 finishes. So the session before it had no port material ahead of
-- them. The piles' lists were 1039 long and every new position was 1108 or
-- past it, so move_list wrote none of the moves ("none needed moving or
-- cutting, for 114 moved material(s) in 28 pile(s)"). Heap slag, made and
-- stockpiled in the fort until then, moved past the lists' end to #1109
-- and was gone from every pile's settings: the probe found pile 32's
-- finished goods, bars and blocks lists 1039 long against 1240
-- inorganics, and Goods/Stone built 299 rows, none for an injected
-- material.
--
-- THE FIT. Every list that is not empty and is shorter than the array is
-- grown to the array's length, every load, from remap_piles before any
-- entry moves, so a move can land anywhere in the array. The holders are
-- every pile, every stop of every hauling route and the template DF copies
-- into a new custom pile: every stockpile_settings in df-structures but
-- the settings screen's pointer to the one it edits. Only piles have their
-- entries moved (remap_piles). An empty list is a category its holder does
-- not take, and stays empty; a list longer than the array is the cut's.
--
-- THE FILL. A new entry no move writes takes the holder's intent for that
-- kind of material, read where the player's choices sit still: the raws
-- band, the inorganics below everything RM and its modules inject, whose
-- positions never move (RM's boot count, base_inorganics). A material DF
-- lists in that list starts on only when every listed raws entry of its
-- kind (metal, gem, stone, soil, other) is on: a pile taking every stone
-- takes slag too. A pile taking some stones and not others made a choice
-- this cannot read, so a new stone starts off there, to be switched on by
-- name. A kind the band does not hold follows the band's whole list. Who
-- each list lists is DFHack's test for it (plugins/stockpiles,
-- StockpileSerializer.cpp, the *_is_allowed functions); a material DF does
-- not list there starts off, as a pile made by a preset leaves it (THE
-- PILES' TWIN SLOTS, pile 2's 93 twin entries). A material whose old
-- position was itself past its old list's end had no entry to keep, and
-- its move carries the fill found at that position instead.
--
-- NOT UNDER AN OPEN SETTINGS SCREEN. Each of its rows keeps the address of
-- the one entry it toggles (custom_stockpile.spec_item[i].set_pointer), and
-- growing a list can move it to new memory. If the screen is open, nothing
-- is grown, the moves stop at each list's end as before, and the lists
-- wait for the next load.
-- ==========================================

-- ---- WHO EACH LIST LISTS ----
-- Keyed 'group.list', as PILE_LISTS names them. f is a row of list_facts().
local LISTED = {
    ['stone.mats'] = function(f) return f.soil or (f.stone and not f.nostock) end,
    ['ammo.mats'] = function(f) return f.metal end,
    ['coins.mats'] = function() return true end,
    ['bars_blocks.bars_mats'] = function(f) return f.metal end,
    ['bars_blocks.blocks_mats'] = function(f) return f.metal or f.stone end,
    ['gems.rough_mats'] = function(f) return f.gem end,
    ['gems.cut_mats'] = function(f) return f.gem or f.stone end,
    ['finished_goods.mats'] = function(f) return f.gem or f.metal or f.stone end,
    ['weapons.mats'] = function(f) return f.metal or f.stone end,
    ['armor.mats'] = function(f) return f.metal end,
    ['furniture.mats'] = function(f) return f.metal or f.stone end,
}

-- ---- WHAT THE LISTS GO BY, PER MATERIAL ----
-- One row per inorganic: IS_METAL, IS_GEM, IS_STONE, NO_STONE_STOCKPILE,
-- soil (SOIL or SOIL_ANY, and not AQUIFER: DFHack's stone test), and the
-- kind THE FILL counts it as, the first that fits. A material whose flags
-- cannot be read is kind 'other', listed by coins alone.
local function list_facts(all, n)
    local facts = {}
    for i = 0, n - 1 do
        local f = {}
        pcall(function()
            local inorg = all[i]
            local mf = inorg.material.flags
            f.metal, f.gem, f.stone = mf.IS_METAL, mf.IS_GEM, mf.IS_STONE
            f.nostock = mf.NO_STONE_STOCKPILE
            local fl = inorg.flags
            f.soil = (fl.SOIL or fl.SOIL_ANY) and not fl.AQUIFER
        end)
        f.kind = (f.metal and 'metal') or (f.gem and 'gem') or (f.stone and 'stone')
            or (f.soil and 'soil') or 'other'
        facts[i] = f
    end
    return facts
end

-- An entry as on or off. They read as 0 and 1 in play, and 0 is true in
-- Lua (refinish-stockpile-windows.lua, THE READ THAT HID IT).
local function entry_on(v)
    return v == true or (type(v) == 'number' and v ~= 0)
end

-- ---- ONE HOLDER'S INTENT, ONE LIST ----
-- Per kind: true when every listed raws entry of that kind is on. Also the
-- band's answer as a whole, for a kind it does not hold (false when the
-- band lists nothing at all).
local function list_intent(v, len, band, facts, listed)
    local by_kind, whole, any = {}, true, false
    for k = 0, math.min(len, band) - 1 do
        local f = facts[k]
        if listed(f) then
            local on = entry_on(v[k])
            any = true
            if not on then whole = false end
            if by_kind[f.kind] == nil then
                by_kind[f.kind] = on
            elseif not on then
                by_kind[f.kind] = false
            end
        end
    end
    return by_kind, any and whole
end

-- ---- ONE LIST GROWN ----
-- From len to target, each new entry set by THE FILL and written in the
-- form the list already holds (numbers, 0 and 1, on this build: a boolean
-- is refused, refinish-stockpile-organic.lua, GROWING A SETTINGS VECTOR).
-- Read back: the length and every new entry. Returns whether it held, and
-- how many new entries are on.
local function grow_list(v, len, target, band, facts, listed)
    local by_kind, whole = list_intent(v, len, band, facts, listed)
    local as_bool = type(v[0]) == 'boolean'
    local want, n_on = {}, 0
    for k = len, target - 1 do
        local f, on = facts[k], false
        if listed(f) then
            on = by_kind[f.kind]
            if on == nil then on = whole end
        end
        want[k] = on
        if on then n_on = n_on + 1 end
        if as_bool then v:insert('#', on) else v:insert('#', on and 1 or 0) end
    end
    if #v ~= target then return false, n_on end
    for k = len, target - 1 do
        if entry_on(v[k]) ~= want[k] then return false, n_on end
    end
    return true, n_on
end

-- ---- EVERY HOLDER OF THESE LISTS ----
-- { what, settings }: the piles, the stops of every hauling route, and the
-- custom pile template. A path this build cannot read leaves its holders
-- out.
local function list_holders()
    local out = {}
    pcall(function()
        for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
            out[#out + 1] = { what = 'pile', settings = b.settings }
        end
    end)
    pcall(function()
        for _, r in ipairs(df.global.plotinfo.hauling.routes) do
            for _, s in ipairs(r.stops) do
                out[#out + 1] = { what = 'stop', settings = s.settings }
            end
        end
    end)
    pcall(function()
        out[#out + 1] = { what = 'template',
                          settings = df.global.plotinfo.stockpile.custom_settings }
    end)
    return out
end

-- ---- THE FIT ----
-- Returns how many lists grew.
local function fit_piles()
    local all = df.global.world.raws.inorganics.all
    local n_arr = #all
    local open = false
    pcall(function() open = df.global.game.main_interface.custom_stockpile.open end)
    if open == true then
        -- WARNING: this load's moves stop at each list's end, as before
        -- 2026-10-16, and the lists wait for the next load.
        log('WARNING', 'Pile lists not grown: the stockpile settings screen is'
            .. ' open.', 'PILES')
        return 0
    end
    -- Every list's length: the whole cost of a load with nothing short.
    local short = {}
    for _, h in ipairs(list_holders()) do
        for _, pair in ipairs(PILE_LISTS) do
            local ok, v = pcall(function() return h.settings[pair[1]][pair[2]] end)
            local len = 0
            if ok and v then pcall(function() len = #v end) end
            if len > 0 and len < n_arr then
                short[#short + 1] = { what = h.what, v = v, len = len,
                    listed = LISTED[pair[1] .. '.' .. pair[2]] or function() return false end }
            end
        end
    end
    if #short == 0 then return 0 end
    local t0 = dfhack.getTickCount()
    local facts = list_facts(all, n_arr)
    -- THE FILL's band: RM's boot count, or the whole array without it.
    local band = n_arr
    pcall(function()
        local base = _G.refinish_telemetry.counts.base_inorganics
        if type(base) == 'number' and base > 0 and base <= n_arr then band = base end
    end)
    local grown, lists_on, faults, lo, hi = 0, 0, 0, nil, nil
    local in_what = { pile = 0, stop = 0, template = 0 }
    for _, s in ipairs(short) do
        local ok, held, n_on = pcall(grow_list, s.v, s.len, n_arr, band, facts, s.listed)
        if ok and held then
            grown = grown + 1
            in_what[s.what] = in_what[s.what] + 1
            if n_on > 0 then lists_on = lists_on + 1 end
            lo = math.min(lo or s.len, s.len)
            hi = math.max(hi or s.len, s.len)
        else
            faults = faults + 1
        end
    end
    if grown > 0 then
        -- INFO: what a player sees come back in the settings menus.
        log('INFO', string.format("Pile lists: %d grown to the array's %d entries (they"
            .. ' were %d to %d long): %d in piles, %d in route stops, %d in the'
            .. ' template; new entries on in %d of them, by the first %d entries;'
            .. ' in %d ms.', grown, n_arr, lo, hi, in_what.pile, in_what.stop,
            in_what.template, lists_on, band, dfhack.getTickCount() - t0), 'PILES')
    end
    if faults > 0 then
        -- WARNING: those lists keep their length, so the materials past their
        -- end stay out of them until a later load.
        log('WARNING', string.format('%d pile list(s) could not be grown.', faults),
            'PILES')
    end
    return grown
end

-- Returns how many entries were moved and in how many piles.
function remap_piles()
    local old_mats = pending_piles
    pending_piles = nil
    -- Short lists first, every load, so the moves below can land past where
    -- a list used to end (PILE LISTS FITTED TO THE ARRAY, above).
    pcall(fit_piles)
    if not old_mats then return 0, 0 end
    local t0 = dfhack.getTickCount()
    local inorganics = df.global.world.raws.inorganics.all
    local n_arr = #inorganics

    -- Each material in both layouts whose position changed: old -> new.
    local from, to = {}, {}
    for i, mat in ipairs(inorganics) do
        local oi = old_mats[mat.id]
        if oi and oi ~= i then
            from[#from + 1] = oi
            to[#to + 1] = i
        end
    end
    -- No return when nothing moved: a list can still need cutting.

    local moved, piles, faults, n_piles = 0, 0, 0, 0
    local cut, longest = 0, 0     -- lists cut to the array's length, the longest before
    local vals = {}
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
        n_piles = n_piles + 1
        local here = 0
        for _, pair in ipairs(PILE_LISTS) do
            -- Moves first, then the cut, so an entry read from past the
            -- array's end is read before the cut drops it.
            local ok, c, was = pcall(function()
                local v = b.settings[pair[1]][pair[2]]
                local changed = move_list(v, from, to, vals)
                local len = #v
                if len > n_arr then
                    v:resize(n_arr)
                    return changed, len
                end
                return changed, nil
            end)
            if ok then
                here = here + c
                if was then
                    cut = cut + 1
                    if was > longest then longest = was end
                end
            else
                faults = faults + 1
            end
        end
        if here > 0 then
            moved = moved + here
            piles = piles + 1
        end
    end

    -- INFO: a migration a player may want to see confirmed. Both numbers
    -- are always given, so a pass that moved nothing still shows it ran.
    if moved > 0 or cut > 0 then
        log('INFO', string.format("Stockpile settings: %d moved to their materials'"
            .. ' new places in %d of %d pile(s), for %d moved material(s); %d list(s)'
            .. " cut to the array's %d entries, the longest from %d; in %d ms.",
            moved, piles, n_piles, #from, cut, n_arr, longest,
            dfhack.getTickCount() - t0), 'PILES')
    else
        log('DETAIL', string.format('Stockpile settings: none needed moving or cutting,'
            .. ' for %d moved material(s) in %d pile(s).', #from, n_piles), 'PILES')
    end
    if faults > 0 then
        -- WARNING: those lists keep their entries where the save left them.
        log('WARNING', string.format('%d pile list(s) could not be read or written.',
            faults), 'PILES')
    end
    return moved, piles
end


return _ENV