-- refinish-sprite-tool-tint.lua
-- =====================================================================
-- RM TOOL TINT
-- =====================================================================
-- Any module's tool can ask for this: add "tint": "<art name>" to the
-- tool in the module's tools JSON, and register that art with
-- refinish-sprite-art. This file then writes the art, tinted to each
-- material's own colour, into DF's per-material cache for that tool.
-- This was Making Fuel's making-fuel-tool-tint.lua, written for its
-- gravel, cinders and sawdust: RM core had to name that module to
-- refresh a tint, and no second module could have the same. Everything
-- it learned is kept below.
--
-- WHICH TOOLS. Read from the module registry at every data cycle: each
-- registered module's tools payload, any entry carrying tint. The tool
-- id is the module's prefix plus the entry's key, as the tool injector
-- builds it.
--
-- ONLY TOOLS DF'S TINT DEMONSTRABLY FAILS ON, and it stays that way. On
-- Making Fuel's sheet every other tool rendered correctly under DF's own
-- tint, and dressing them all cost nothing but damage: converted art
-- with shifted shapes, stray flecks, and blown out contrast that the
-- stronger tint here turned neon. A tool declares tint because DF's tint
-- demonstrably fails on it, not because its art happens to be
-- convertible.
--
-- WHEN. On RM's dispatcher every POLL_FRAMES, paused included, since a
-- player looks at items while paused. The registry is replaced at every
-- data cycle, so a new registry drops every cache here and the next
-- poll resolves the tools afresh.
-- =====================================================================
-- =====================================================================
-- TOOL TINT: OUR COLOUR IN DF'S CACHE
-- =====================================================================
-- MEASURED, the whole reason this file exists. A tool itemdef holds one
-- texpos per material CLASS, not per material, so DF does its own per
-- material tint and files the result in itemdef.graphics_info. Dumped
-- on MAKING_FUEL_GRAVEL:
--
--   flags: material 1, quality 0, variant 0, damage_level 0,
--          color_index 31, localdef_shape_index 0
--   texpos 167916
--
-- While an entry exists DF draws THAT texpos and never reads
-- texpos_item or texpos_stone. Proved twice in play: pointing every
-- texpos field at another tool's cell changed nothing on screen, and
-- writing this entry's texpos changed it instantly. DF also rebuilds
-- the entry when it is cleared, so the vector cannot be emptied to
-- force the flat fields back.
--
-- DF's tint is weaker than ours, which is the pale stippled gravel:
-- same descriptor colour reads strong on a boulder we tinted and washed
-- out on a tool DF tinted. So this file manufactures the texture in the
-- material's colour, the way the boulder art already is, and writes it
-- into DF's own cache entry.
--
-- ART LIVES IN LUA, NOT ON THE SHEET. Nothing can read a PNG's pixels
-- back out of DF, so only char map art can be tinted. The maps are in
-- refinish-sprite-art-forms.lua (making-fuel-sprite-art-tools.lua until
-- the forms moved to RM), converted from the sheet or drawn there.
--
-- THE COLOUR KEY, MEASURED. An entry's color_index is the material's
-- COLOUR index plus one. Oil shale read 30 against 31 first; the
-- evidence lines settled it on 2026-09-25 with clinker 49 against 50,
-- limestone 96 against 97 and cinnabar 87 against 88. Those were read
-- off state_color.Solid, which is a PATTERN index (DF's color_pattern);
-- for vanilla's first 136 colours the pattern and colour numbers match,
-- so it read as the colour. They part for a mod's colours: a cobaltous
-- clay binder's entry read 151, COBALTITE's colour 150 plus one, while
-- its pattern is 435 (2026-09-30, Argmod). So the key is the pattern's
-- first colour (read_tool). An entry that
-- matches nothing is a colour that came into play after the last walk:
-- it keeps DF's own tint until the walk it asks for. (It used to fall
-- back to dressing every entry when only one colour was in play, which
-- painted every gravel the first gravel's colour, 2026-09-25: see AN
-- UNMATCHED ENTRY IS LEFT TO DF.)
-- =====================================================================

--@ module = true

-- No eventful. The colours in play are learned from the tools made
-- since the last poll, read off the end of world.items.all (THE NEW
-- TOOLS), from DF's own signal (a cache entry for a colour nothing
-- explained) and from a slow backstop, so this file never needed the
-- created event it used to require.
local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'refinish-sprite-tool-tint'


-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core's own system and subsystem now. Guarded reqscript: a bare top
-- level one is a hard load time dependency.
--
-- Declared above the first function that logs: a log declared below
-- its first caller compiles to a global log, which is nil.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TOOL_TINT'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity is declared by the module, not
-- inferred anywhere: RM core does not know this module exists.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   YIELD    the module made something, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: the art a line is about (gravel,
-- cinders, sawdust), RELEASE for tools handed back to DF, START and
-- STOP.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise, and printed to
-- the console when RM was not loaded.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
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

-- ---- THE ART MODULE, RESOLVED ONCE ----
-- MEASURED COST, the reason this sits at file scope and not in the
-- pass: the pass used to call reqscript('refinish-sprite-art') on every
-- poll, and reqscript costs about 2 ms a call (engine notes, +2.24 ms a
-- call on a 1 frame poll). The profiler had this loop at 2.32 ms a
-- call, 10 calls a second, 2026-09-24, so that one line was very likely
-- nearly all of it. The next profiler run confirms it.
--
-- File scope and guarded, the same as the log above. The art module
-- keeps its caches on _G, so this handle and any reloaded one share
-- them. A failed load costs the tint, never the module, and start()
-- says so.
local art = nil
pcall(function() art = reqscript('refinish-sprite-art') end)


-- The offset between a material's colour index and the entry's
-- color_index, measured four times (THE COLOUR KEY, MEASURED, above).
-- Read from here so a correction is one number.
local COLOR_INDEX_OFFSET = 1

-- ==========================================
-- CADENCES
-- ==========================================
-- Dressing on one clock, and the colours in play learned on three.
--
--   DRESSING, every POLL_FRAMES, which is every frame since 2026-09-25.
--   Writes our texpos into DF's cache entries, or the flat fields when a
--   tool has none. It has to keep running because DF rebuilds an entry
--   whenever it needs one, and an entry appears when an item is first
--   DRAWN, not when it is made. A rebuilt entry wears DF's own art (the
--   stock powder pile, ITEM_CONSTRUCTION 2:3, which gravel, dust and
--   cement all register as their base) until the next dressing: at ten
--   frames that showed as a flicker whenever gravel or cement was made.
--   Every frame, the window is one frame. REDRESSED in the poll counts
--   how often DF does it. Cheap: a handful of entries on three tools,
--   compared and written.
--
--   THE WALK, rare. Reads the TOOL vector to learn which colours are in
--   play, so nothing is manufactured for a colour no item wears. It used
--   to run on every poll, and with its two closures and a decode per
--   matching tool it was the second half of the old cost. Now it runs
--   whole, in one poll:
--     * on the first poll that finds the tools injected;
--     * when DF starts drawing a colour index nothing explained, which
--       is DF itself saying a new colour is on screen, and no sooner
--       than WALK_GAP_POLLS after the last walk or backstop pass;
--     * whenever pass() is called: start(), and refinish-tint after a
--       tint change.
--
--   THE NEW TOOLS, every poll. The tools made since the last poll are
--   read off the end of world.items.all, so a new tool's colour is in
--   play the poll after it is made (THE NEW TOOLS). One read of the next
--   item number when nothing was made.
--
--   THE BACKSTOP, every WALK_POLLS, read WALK_SLICE tools a poll (THE
--   BACKSTOP, A SLICE A POLL). It catches what the other two cannot: a
--   tool a script moved onto another material, and a colour that left
--   play.
--
--   THE TINT KNOBS are read every poll through art.tint(), which only
--   reports when given nothing. If they moved since the textures were
--   resolved, the textures are resolved again from what is known to be
--   in play, no walk needed. That keeps the promise refinish-tint and
--   refinish-sprite-art make about this watcher: it re-asks on its own
--   poll.
-- ==========================================
local POLL_FRAMES    = 1
local WALK_POLLS     = 1000 // POLL_FRAMES  -- backstop, 1000 frames
local WALK_GAP_POLLS = 50 // POLL_FRAMES    -- a triggered walk waits at least 50 frames
local WALK_SLICE     = 500                  -- backstop tools read a poll (THE BACKSTOP, A SLICE A POLL)
-- REDRESSED: entries DF rebuilt since the last report, and the frames
-- that report covers. Said about once a minute, and only while it
-- happens.
local REPORT_FRAMES = 6000
local redressed, frames_since_report = 0, 0

-- One line per fault, not per poll. A tool that cannot be dressed says
-- so once and then stays quiet.
local said = {}
local function log_once(key, typ, msg, subject)
    if said[key] then return end
    said[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- SUBTYPE RESOLUTION
-- ==========================================
-- Rebuilt by start(), because injection moves subtypes between
-- sessions. subtype integer -> { art = name, def = itemdef }.
local by_subtype = nil

-- #itemdefs.tools at the last resolve that found nothing. start() runs
-- inside the token call, before the engine has injected any tool, so
-- the first resolve always finds nothing, and retrying walks every tool
-- def with a string made per def. A failed resolve is therefore retried
-- only once the tool list has changed size, which the inject does.
local failed_at = nil

-- tool id -> art name, from every module's tools payload. See WHICH
-- TOOLS in the header.
local function declared_tints()
    local want = {}
    for prefix, entry in pairs(_G.refinish_module_registry or {}) do
        for _, t in ipairs(entry.tools or {}) do
            if type(t.tint) == 'string' and t.key then
                want[prefix .. tostring(t.key)] = t.tint
            end
        end
    end
    return want
end

local function resolve_subtypes()
    if by_subtype then return by_subtype end
    local defs = df.global.world.raws.itemdefs.tools
    local n_defs = #defs
    if failed_at == n_defs then return nil end
    local want = declared_tints()
    local found, n = {}, 0
    pcall(function()
        for _, td in ipairs(defs) do
            local art_name = want[tostring(td.id)]
            if art_name then
                found[td.subtype] = { art = art_name, def = td }
                n = n + 1
            end
        end
    end)
    if n == 0 then
        failed_at = n_defs
        return nil
    end
    failed_at = nil
    by_subtype = found
    return by_subtype
end

-- ==========================================
-- WHICH COLOURS ARE IN PLAY
-- ==========================================
-- colour_of[mat_type][mat_index] = that material's solid colour (its
-- colour index, read through its pattern: THE COLOUR KEY, MEASURED),
-- or false when it has none. The colour sits on the
-- MATERIAL, and a fort holds thousands of tools in a few dozen
-- materials, so each pair is decoded once per session and every later
-- tool of it costs two reads and a lookup.
--
-- INTEGERS ONLY, no material reference is kept between frames. A data
-- cycle sweeps module materials, and a kept reference would outlive
-- what it points at. Cleared in start(), since injected indices can
-- move between cycles.
local colour_of = {}

-- in_play[subtype][colour] = { mat_type, mat_index }, the first material
-- the last walk saw wearing that colour. One is enough: the texture is
-- keyed on colour, not on material.
local in_play = {}

-- wanted[subtype] = { by_ci = { [color_index] = texpos },
--                     n = colours in play, last = the lowest colour's texpos }
local wanted = {}

-- unmatched[subtype][color_index] = true for an entry a walk could not
-- explain. DF keeps a cache entry after the last item of that colour is
-- gone, so without this a colour that has LEFT play would start a walk
-- every WALK_GAP_POLLS for ever. Only a NEW unexplained index triggers a
-- walk; a colour that comes back into play later is caught by the new
-- tool read or the backstop. Cleared in start().
local unmatched = {}

-- The tint knobs the current textures were resolved under.
local knobs = {}

local polls_since_walk = 0
local walk_wanted = false

-- The new tool read and the backstop pass (THE NEW TOOLS; THE BACKSTOP,
-- A SLICE A POLL). Cleared with the caches. The first walk sets
-- tail_next, and nothing is read as new before it.
local tail_next  = nil    -- the first item id the next poll reads as new
local bpass      = nil    -- the backstop pass under way, or nil
local order_said = false  -- the items.all order warning, once per cache

-- One tool item. Hoisted, so pcall(read_tool, it, ...) allocates
-- nothing per item, where the old walk built two closures for every
-- tool in the fort. TOOL items always carry mat_type and mat_index, so
-- the raw fields are safe here (a corpse would throw; none is a TOOL).
local function read_tool(it, subs, found)
    local st = it.subtype.subtype
    if not subs[st] then return end
    local mt, mi = it.mat_type, it.mat_index
    local row = colour_of[mt]
    if not row then
        row = {}
        colour_of[mt] = row
    end
    local colour = row[mi]
    if colour == nil then
        colour = false
        local info = dfhack.matinfo.decode(mt, mi)
        if info and info.material then
            -- state_color holds a PATTERN index; the entry follows the
            -- colour, the pattern's first (THE COLOUR KEY, MEASURED).
            pcall(function()
                local p = df.global.world.raws.descriptors.patterns[info.material.state_color.Solid]
                if p and #p.colors > 0 then colour = p.colors[0] end
            end)
        end
        row[mi] = colour
    end
    if colour then
        local per = found[st]
        if not per then
            per = {}
            found[st] = per
        end
        -- True for a colour this table did not hold yet, which the new
        -- tool read counts (THE NEW TOOLS). The walks ignore it.
        if not per[colour] then
            per[colour] = { mt, mi }
            return true
        end
    end
end

-- The texture for one colour, decoded fresh from the pair, because no
-- material is kept between frames (see INTEGERS ONLY above).
local function texpos_of(pair, art_name)
    local info = dfhack.matinfo.decode(pair[1], pair[2])
    if not (info and info.material) then
        return nil, ('material %d:%d no longer resolves'):format(pair[1], pair[2])
    end
    return art.texpos_for(info.material, art_name)
end

-- wanted, rebuilt from in_play. Cheap after the first time: the art
-- module caches every art and colour pairing, and it only drops that
-- cache when the tint knobs change, which is exactly when this runs
-- without a walk.
local function resolve_wanted(subs)
    local fresh = {}
    for st, entry in pairs(subs) do
        local w = { by_ci = {}, n = 0, last = nil }
        local last_colour = nil
        for colour, pair in pairs(in_play[st] or {}) do
            local texpos, err = texpos_of(pair, entry.art)
            if texpos then
                w.by_ci[colour + COLOR_INDEX_OFFSET] = texpos
                w.n = w.n + 1
                -- ---- THE FLAT FIELDS' ONE COLOUR, THE SAME EVERY TIME ----
                -- The lowest colour in play, not whichever one pairs()
                -- reached last. in_play is built by walks, passes and the
                -- new tool read, each in its own order, and a tool with no
                -- cache entries must not change colour because a table
                -- was built in another order (2026-10-02).
                if not last_colour or colour < last_colour then
                    w.last, last_colour = texpos, colour
                end
            else
                log_once('mk:' .. entry.art, 'WARNING', ('could not manufacture %s: %s')
                    :format(entry.art, tostring(err)), tostring(entry.art))
            end
        end
        fresh[st] = w
    end
    wanted = fresh
    knobs.d, knobs.s, knobs.v = art.tint()
end

-- ==========================================
-- THE WALK
-- ==========================================
-- ---- A COLOUR THAT LEFT PLAY ----
-- DF keeps a cache entry after the last item of its colour is gone, and
-- an entry no colour in play explains asks for a whole walk (unmatched,
-- above). That walk only learned what the walk or pass that found the
-- colour gone already knew, and stalled a poll to do it. So since
-- 2026-10-02 a colour a walk or a sure pass finds gone is marked
-- unmatched there and then: its leftover entry keeps the dressing it
-- has, as it did after that walk. A tool of that colour made later is
-- read as new and dressed as before (THE NEW TOOLS).
local function mark_gone(st, colour)
    local miss = unmatched[st]
    if not miss then
        miss = {}
        unmatched[st] = miss
    end
    miss[colour + COLOR_INDEX_OFFSET] = true
end

-- One pass of the TOOL vector: in_play rebuilt from it, then wanted.
-- One closure for the whole walk, none per item.
local function walk(subs)
    -- The new tool read starts after this walk: every tool there is now
    -- is read below, and each one made later is read as new.
    tail_next = df.global.item_next_id
    local found = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.other.TOOL) do
            pcall(read_tool, it, subs, found)
        end
    end)

    -- A line only when the colours in play actually changed. A walk
    -- that found what the last one found says nothing.
    local new_colours = 0
    for st, per in pairs(found) do
        local old = in_play[st] or {}
        for colour in pairs(per) do
            if not old[colour] then new_colours = new_colours + 1 end
        end
    end
    -- Colours that left play (A COLOUR THAT LEFT PLAY).
    for st, per in pairs(in_play) do
        for colour in pairs(per) do
            if not (found[st] and found[st][colour]) then mark_gone(st, colour) end
        end
    end

    in_play = found
    resolve_wanted(subs)
    -- A whole walk supersedes a backstop pass under way.
    polls_since_walk, walk_wanted, bpass = 0, false, nil
    if new_colours > 0 then
        log('DETAIL', ('%d new colour(s) in play; textures resolved.')
            :format(new_colours), 'WALK')
    end
end

-- ==========================================
-- THE NEW TOOLS
-- ==========================================
-- Every item made since the last poll, read off the end of
-- world.items.all, so a new tool's colour is in play the poll after the
-- tool is made. DF builds a cache entry, in its own art, the first time
-- it draws an item, and the next poll dresses it as it does any entry DF
-- rebuilds: one frame. Until 2026-10-02 a new colour was learned only
-- once DF drew it, by a walk at least WALK_GAP_POLLS after the last one,
-- so DF's paler tint could show for that long, or by the 1000 frame
-- backstop, the only thing that ever learned a new colour on a tool with
-- no cache entries (cinders).
--
-- items.all is kept in id order: DFHack finds an item by id with a
-- binary search over it (df.item.xml: the item instance vector, keyed by
-- id), as the coal and tinder watchers' reads of new items rely on. The
-- read checks the order as it goes and says so once if it ever finds it
-- broken; the backstop still finds any colour it misses.
--
-- A tool a script moves onto another material after it is made (a hop
-- onto a twin) is read here with the material it was made with. Its new
-- colour is learned by the backstop or, once DF draws it, by DF's
-- signal, as before.

-- The first position in items.all holding an item id of at least id.
local function first_at_or_after(all, id)
    local lo, hi = 0, #all
    while lo < hi do
        local mid = (lo + hi) // 2
        if all[mid].id < id then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- The tools made since the last poll, read into in_play, and into the
-- backstop pass under way, which may not reach them by position (BY
-- POSITION, KEPT IN STEP). Returns how many colours were new to play.
local function read_new(subs)
    local top = df.global.item_next_id
    local all = df.global.world.items.all
    local TOOL = df.item_type.TOOL
    local added = 0
    pcall(function()
        local prev = -1
        for i = first_at_or_after(all, tail_next), #all - 1 do
            local it = all[i]
            local id = it.id
            if id >= top then break end
            if id < prev and not order_said then
                -- WARNING: the read of new tools may miss one; the backstop
                -- still finds its colour.
                order_said = true
                log('WARNING', ('items.all is out of id order at item %d, so the'
                    .. ' read of new tools can miss one; the backstop still'
                    .. ' finds its colour.'):format(id), 'WALK')
            end
            prev = id
            if it:getType() == TOOL then
                local ok, new = pcall(read_tool, it, subs, in_play)
                if ok and new then added = added + 1 end
                if bpass then pcall(read_tool, it, subs, bpass.found) end
            end
        end
    end)
    tail_next = top
    if added > 0 then
        log('DETAIL', ('%d new colour(s) in play, from tools just made.')
            :format(added), 'WALK')
    end
    return added
end

-- ==========================================
-- THE BACKSTOP, A SLICE A POLL
-- ==========================================
-- MEASURED 2026-10-02 (section probe, tool tint: walk): 13.3 ms a call,
-- 30 ms at worst, every 1000 frames. The backstop read every tool in the
-- fort (about 10,000) in one poll, so that poll stalled for as long.
-- Now a pass reads WALK_SLICE tools a poll, about twenty polls under a
-- millisecond each, and its end does what the walk did: in_play rebuilt
-- from what it found, then wanted.
--
-- BY POSITION, KEPT IN STEP. A pass reads the TOOL vector by position
-- across polls, and a tool removed meanwhile below its place moves the
-- rest down one, which would pass one over. So each slice first checks
-- that the last tool it read is still where it left it, and if not
-- looks for it within SHIFT_LOOK places either way and goes on after it.
-- A pass that cannot find it (that tool was itself removed, say) may
-- have passed one over, so it is unsure: it adds what it found to play
-- but takes nothing out, and the next pass does that. A tool made during
-- the pass is read into it by the new tool read, wherever it sits.
local SHIFT_LOOK = 64

-- One poll of the pass, started if none is under way. Returns true when
-- the pass ended and the textures were resolved again.
local function slice(subs)
    local vec = df.global.world.items.other.TOOL
    local n = #vec
    if not bpass then
        bpass = { cursor = 0, last_id = nil, found = {}, unsure = false }
    end
    local from = bpass.cursor
    -- ---- KEPT IN STEP ----
    if from > 0 then
        local at = nil
        pcall(function()
            if from - 1 < n and vec[from - 1].id == bpass.last_id then
                at = from - 1
                return
            end
            for p = math.min(from - 1, n - 1), math.max(0, from - 1 - SHIFT_LOOK), -1 do
                if vec[p].id == bpass.last_id then at = p; return end
            end
            for p = from, math.min(n - 1, from - 1 + SHIFT_LOOK) do
                if vec[p].id == bpass.last_id then at = p; return end
            end
        end)
        if at then from = at + 1 else bpass.unsure = true end
    end
    local stop = math.min(from + WALK_SLICE, n)
    local found = bpass.found
    pcall(function()
        for i = from, stop - 1 do
            pcall(read_tool, vec[i], subs, found)
        end
        if stop > from then bpass.last_id = vec[stop - 1].id end
    end)
    bpass.cursor = stop
    if stop < n then return false end

    -- ---- THE PASS ENDS ----
    -- A sure pass rebuilds in_play from what it found, as the walk does.
    -- An unsure one keeps every colour already in play beside those.
    local new_colours, gone = 0, 0
    for st, per in pairs(found) do
        local old = in_play[st] or {}
        for colour in pairs(per) do
            if not old[colour] then new_colours = new_colours + 1 end
        end
    end
    for st, per in pairs(in_play) do
        for colour, pair in pairs(per) do
            if not (found[st] and found[st][colour]) then
                if bpass.unsure then
                    local row = found[st]
                    if not row then
                        row = {}
                        found[st] = row
                    end
                    row[colour] = pair
                else
                    gone = gone + 1
                    mark_gone(st, colour)
                end
            end
        end
    end
    in_play = found
    resolve_wanted(subs)
    polls_since_walk, bpass = 0, nil
    if new_colours > 0 or gone > 0 then
        log('DETAIL', ('backstop pass: %d new colour(s) in play, %d gone;'
            .. ' textures resolved.'):format(new_colours, gone), 'WALK')
    end
    return true
end

-- ==========================================
-- DRESSING, ONE TOOL
-- ==========================================
-- Hoisted, called as pcall(dress_one, st, entry): a tool that throws
-- costs that tool alone, and no closure is built per poll. Returns how
-- many fields it wrote.
local FLAT_FIELDS = { 'texpos_stone', 'texpos_metal', 'texpos_wood', 'texpos_glass' }

local function write_array(def, field, texpos)
    local arr = def[field]
    local wrote = 0
    for i = 0, #arr - 1 do
        if arr[i] ~= texpos then
            arr[i] = texpos
            wrote = wrote + 1
        end
    end
    return wrote
end

-- The materials in play for one tool, as "ID = colour" pairs, for the
-- colour key's evidence line. Called once per unexplained index.
local function in_play_list(st)
    local out = {}
    for colour, pair in pairs(in_play[st] or {}) do
        local id = tostring(pair[1]) .. ':' .. tostring(pair[2])
        pcall(function() id = dfhack.matinfo.decode(pair[1], pair[2]):getToken() end)
        out[#out + 1] = id .. ' = ' .. tostring(colour)
    end
    table.sort(out)
    return #out > 0 and table.concat(out, ', ') or 'none'
end

local function dress_one(st, entry)
    local w = wanted[st]
    local gi = entry.def.graphics_info
    local n_gi = #gi

    if not w or w.n == 0 then
        -- Nothing known in play for this tool. An entry means DF is
        -- drawing one of its items anyway, so the last walk is out of
        -- date and another is wanted.
        if n_gi > 0 then walk_wanted = true end
        return 0
    end

    -- ---- NO CACHE ENTRY: DRESS THE FLAT FIELDS ----
    -- MEASURED: gravel carries entries and took our texture at once,
    -- while cinders carry none and kept their boulder art, because a
    -- cache-only writer had nothing to write into. With the vector
    -- empty DF draws from texpos_item and the per class arrays, so
    -- those are what get written.
    --
    -- They are per material CLASS, not per material, so they hold ONE
    -- colour. With more than one material in play one of them wins,
    -- and it says so rather than looking right by accident.
    if n_gi == 0 then
        local texpos = w.last
        local wrote = 0
        -- DETAIL, not WARNING (2026-09-27). Gravel said this as a WARNING
        -- at every start: DF builds a tool's cache entries only once it
        -- draws one of its items, so at start gravel has none yet, and
        -- once DF draws it the entries arrive and take our art (MEASURED
        -- above: gravel carries entries). A tool DF never caches keeps
        -- the flat fields for good, and then all its colours are one.
        if w.n > 1 then
            log_once('flat:' .. entry.art, 'DETAIL', ('%s has no cache '
                .. 'entry yet and %d colour(s) in play, so the flat fields '
                .. 'hold one colour for all of them until DF draws one and '
                .. 'builds its entries.')
                :format(entry.art, w.n), tostring(entry.art))
        end
        if entry.def.texpos_item ~= texpos then
            entry.def.texpos_item = texpos
            wrote = wrote + 1
        end
        for _, field in ipairs(FLAT_FIELDS) do
            local ok, n = pcall(write_array, entry.def, field, texpos)
            if ok then wrote = wrote + n end
        end
        return wrote
    end

    local wrote = 0
    local miss = unmatched[st]
    for i = 0, n_gi - 1 do
        local g = gi[i]
        local ci = g.flags.color_index
        local texpos = w.by_ci[ci]
        if not texpos then
            -- ---- AN UNMATCHED ENTRY IS LEFT TO DF ----
            -- Until 2026-09-25 an unmatched entry was dressed with the
            -- only colour in play whenever just one was known: a fallback
            -- while the key was unproven ("one colour in play means every
            -- entry is that colour, whatever the number says"). It was
            -- wrong as soon as a second material turned up before the
            -- next walk: every new gravel took the first gravel's colour
            -- (limestone came out as dark as the first stone crushed),
            -- and because that branch returned before the walk request
            -- below, the walk never learned the new colour. An entry this
            -- file cannot place now keeps DF's own tint, weaker but the
            -- right colour, and asks for one walk.
            if not (miss and miss[ci]) then
                -- An index nothing in the last walk explains: DF is
                -- drawing a colour that walk never saw. Remembered, so
                -- it asks for one walk and not one per poll.
                if not miss then
                    miss = {}
                    unmatched[st] = miss
                end
                miss[ci] = true
                walk_wanted = true
                -- DETAIL: the colour key's evidence, once per index. The
                -- key assumes an entry's color_index is the material's
                -- colour index (through its pattern) plus
                -- COLOR_INDEX_OFFSET, so this names both for every
                -- material in play.
                log_once(('ci:%s:%d'):format(entry.art, ci), 'DETAIL',
                    ('%s entry color_index %d matches no material in play '
                    .. '(offset %d); in play, id = colour: %s. '
                    .. 'Left to DF\'s own tint.'):format(entry.art, ci,
                    COLOR_INDEX_OFFSET, in_play_list(st)), tostring(entry.art))
            end
        end
        if texpos and g.texpos ~= texpos then
            g.texpos = texpos
            wrote = wrote + 1
        end
    end
    return wrote
end

-- ==========================================
-- THE POLL
-- ==========================================
-- Everything above, in the order that matters: resolve, notice a tint
-- change, walk if one is due, then dress.
-- The registry the caches were built from. A new one means a data
-- cycle: tool subtypes may have moved, so everything is dropped.
local seen_registry = nil

local function reset_caches()
    by_subtype, failed_at = nil, nil
    colour_of, in_play, wanted, unmatched, knobs = {}, {}, {}, {}, {}
    polls_since_walk, walk_wanted = WALK_POLLS, false
    tail_next, bpass, order_said = nil, nil, false
end

local function poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end
    if not art then return end
    -- SECTION CLOCK (refinish-section-probe): where a frame's time goes.
    -- MEASURED 2026-10-02 (DFHack's own counters, print_timers, now that
    -- the dispatcher names its subscribers): 2,029 ms in one session of
    -- about five minutes. Off, each lap costs one global read.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    if _G.refinish_module_registry ~= seen_registry then
        seen_registry = _G.refinish_module_registry
        reset_caches()
    end
    local subs = resolve_subtypes()
    if not subs then return end

    local d, s, v = art.tint()
    -- A quiet poll is one that resolved no textures (no walk, no pass
    -- ending, no new colour, no knob change), so any write it makes is
    -- an entry DF built or rebuilt with its own art.
    local quiet = true
    if d ~= knobs.d or s ~= knobs.s or v ~= knobs.v then
        resolve_wanted(subs)
        quiet = false
    end
    if sc then t0 = sc.lap('tool tint: subtypes, knobs', t0) end
    -- ---- THE NEW TOOLS ----
    if tail_next and tail_next < df.global.item_next_id then
        if read_new(subs) > 0 then
            resolve_wanted(subs)
            quiet = false
        end
        if sc then t0 = sc.lap('tool tint: new tools read', t0) end
    end
    polls_since_walk = polls_since_walk + 1
    if not tail_next
       or (walk_wanted and polls_since_walk >= WALK_GAP_POLLS) then
        -- The first walk, or DF's signal: every tool, this poll.
        walk(subs)
        quiet = false
        if sc then t0 = sc.lap('tool tint: walk', t0) end
    elseif bpass or polls_since_walk >= WALK_POLLS then
        -- The backstop: WALK_SLICE tools a poll until its pass ends.
        if slice(subs) then quiet = false end
        if sc then t0 = sc.lap('tool tint: backstop slice', t0) end
    end
    local wrote = 0
    for st, entry in pairs(subs) do
        local ok, n = pcall(dress_one, st, entry)
        if ok and n then wrote = wrote + n end
    end
    if sc then sc.lap('tool tint: every tool dressed', t0) end
    -- ---- REDRESSED ----
    -- The flicker's measure: how many entries DF rebuilt with its own
    -- art, each put back within POLL_FRAMES. DETAIL, about once a minute,
    -- only while it happens.
    if quiet then redressed = redressed + wrote end
    frames_since_report = frames_since_report + POLL_FRAMES
    if frames_since_report >= REPORT_FRAMES then
        if redressed > 0 then
            log('DETAIL', ('DF rebuilt %d cache entr%s with its own art in the '
                .. 'last %d frames; each was redressed within %d frame(s).')
                :format(redressed, redressed == 1 and 'y' or 'ies',
                frames_since_report, POLL_FRAMES), 'REDRESS')
        end
        redressed, frames_since_report = 0, 0
    end
end

-- ==========================================
-- THE PASS, ON DEMAND
-- ==========================================
-- A full walk and a full dressing, now. start() calls it, and so does
-- refinish-tint after changing the tint, so a change lands in the same
-- frame instead of on the next poll. Returns how many fields it wrote,
-- which refinish-tint reports.
function pass()
    if not art then return 0 end
    local subs = resolve_subtypes()
    if not subs then return 0 end
    walk(subs)
    local dressed = 0
    for st, entry in pairs(subs) do
        local ok, n = pcall(dress_one, st, entry)
        if ok and n then dressed = dressed + n end
    end
    return dressed
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- DF rebuilds a cache entry whenever it needs one, so this has to keep
-- running rather than dressing once at start. The created event is not
-- enough on its own: an entry appears when an item is first DRAWN, not
-- when it is made.
--
-- start() runs at every token call, before the inject, so everything is
-- cleared here and nothing found yet: the first poll after the inject
-- resolves the tools and walks, because polls_since_walk starts due.
-- ==========================================
-- LIFECYCLE
-- ==========================================
-- Started by refinish_steel once the pipeline is up, beside the
-- dispatcher it rides, and stopped at map unload.
function start()
    reset_caches()
    redressed, frames_since_report = 0, 0
    seen_registry = _G.refinish_module_registry
    said = {}
    if not art then
        -- WARNING: tools keep DF's own paler tint, and nothing else
        -- would say why.
        log('WARNING', 'refinish-sprite-art did not load, so tools keep DF\'s'
            .. ' own tint this session.', 'START')
    end
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(REPEAT_KEY, {
            every = POLL_FRAMES, fn = function() pcall(poll) end, paused = true }) then
        repeatUtil.cancel(REPEAT_KEY)
    else
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', function()
            pcall(poll)
        end)
    end
    log('DETAIL', 'active.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(REPEAT_KEY) end
    reset_caches()
    -- The entries are DF's, not ours: left as they are. DF rewrites
    -- them itself the next time it needs one, and the textures they
    -- point at are kept for the life of the process anyway (see
    -- TEARDOWN: KEPT, NOT FREED in refinish-sprite-art.lua).
    log('DETAIL', 'stopped.', 'STOP')
end