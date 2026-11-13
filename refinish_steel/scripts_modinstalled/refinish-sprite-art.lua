-- refinish-sprite-art.lua
-- =====================================================================
-- MANUFACTURED TINTING
-- =====================================================================
-- A material slot does not adapt. Confirmed in play: green coke and
-- coke breeze were set to RED and their sprites did not move. DF applies
-- no colour to a texpos we hand it, and there is no flag reachable from
-- Lua that asks it to.
--
-- A TOOL is different. Its texpos lives on the itemdef, shared by every
-- material the tool can be made of, so DF has to tint it and does.
-- Nothing here is needed for tools; they stay on the PNG sheet.
--
-- So for material slots we do the tint ourselves: read the material's
-- own colour, multiply the grey art in Lua, and hand DF a texture that
-- is ALREADY the right colour. One grey source, every material, no hand
-- mixing.
--
-- WHY THE ART IS DATA AND NOT A PNG. loadTileset returns TexposHandles,
-- not pixels, and there is no way to read a PNG's pixels back out of DF.
-- Anything we intend to tint has to exist as a char map here. That
-- splits the module's sprites permanently:
--
--   tool sprites      making_fuel_byproducts.png, DF tints them
--   material sprites  char maps registered here, we tint them
--
-- Modules register their own art. This file owns the mechanism only.
--
--   local art = reqscript('refinish-sprite-art')
--   art.register('coal', { '   0123   ', ... })
--   local texpos, err = art.texpos_for(material, 'coal')
--   art.release_all()                     -- on shutdown, keeps them
-- =====================================================================

--@ module = true

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Info and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: TINT for a knob change, RELEASE for
-- the shutdown count.
--
-- This replaces a log() that PRINTED to the console and never reached
-- the log, under the system name 'REFINISH', which the log panel does
-- not recognise as RM. Both of its lines are run by other scripts, not
-- typed, so neither is a print.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SPRITE_ART'
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
-- THE RAMP
-- ==========================================
-- The vanilla neutral ramp, measured off ITEM_CONSTRUCTION 2:3 and 1:1.
-- '.' is '0' at half alpha, which is the vanilla soft edge convention.
-- Art for tinting belongs on THIS ramp, 56 to 199, never on the dark
-- charcoal ramp: multiplying already dark art by an already dark
-- descriptor leaves a flat blob with no readable form. The darkness is
-- the descriptor's job.
-- ==========================================
local RAMP = {
    ['.'] = { 0x2F, 0x30, 0x38, 128 },
    ['0'] = { 0x2F, 0x30, 0x38, 255 },
    ['1'] = { 0x3C, 0x3E, 0x46, 255 },
    ['2'] = { 0x49, 0x4C, 0x54, 255 },
    ['3'] = { 0x5A, 0x5E, 0x65, 255 },
    ['4'] = { 0x6B, 0x70, 0x76, 255 },
    ['5'] = { 0x8A, 0x90, 0x91, 255 },
    ['6'] = { 0xA5, 0xA6, 0xA5, 255 },
    ['7'] = { 0xC7, 0xC4, 0xB4, 255 },
    ['8'] = { 0xFF, 0xFF, 0xFF, 255 },
}

local CELL_PX = 32

-- ==========================================
-- PIXEL PACKING
-- ==========================================
-- ABGR. Confirmed by test card on a live peat boulder: a flat
-- 200,100,50 at full alpha rendered RED-PINK and semi transparent,
-- which is alpha taking the red byte and red taking the alpha byte.
--
-- The Lua_API doc says "packed RBGA format (for example, #0022FF11)"
-- and that is its only mention anywhere. It describes the BYTE layout,
-- not the integer, so the obvious 0xRRGGBBAA is wrong.
--
-- Signature of getting this wrong, so it is recognised rather than
-- rediscovered: sprites render as ghostly semi transparent negatives,
-- because alpha ends up tracking the red channel. Dark dominant art
-- goes INVISIBLE on the map while pale art survives looking washed out.
-- ==========================================
local function pack(r, g, b, a)
    return (a << 24) | (b << 16) | (g << 8) | r
end

-- ==========================================
-- THE BLEND
-- ==========================================
-- Tuned in play against vanilla boulders.
--
-- DESAT pulls the DESCRIPTOR toward its own luminance before
-- multiplying. It exists because a descriptor with a zeroed channel,
-- and MAROON at 128:0:0 is exactly that, leaves nothing for the shading
-- to carry and collapses the sprite onto one channel. At 0 it is off,
-- which is where it settled: the lift below turned out to do the work
-- on its own.
--
-- STRENGTH lerps from the untinted art toward the fully multiplied
-- result. 1.0 is a pure multiply and goes very dark under a dark
-- descriptor. 0.75 matches vanilla closely.
-- ==========================================
--
-- VALUE is the third knob, and it exists because the other two cannot
-- do what it does. A multiply can only DARKEN: out = p * c / 255, and c
-- is at most 255, so every tint costs brightness before STRENGTH is
-- even consulted. MEASURED on the ramp: art 138 under DARK_BROWN keeps
-- 46 per cent of its luminance at STRENGTH 0.75 and 28 per cent at 1.0,
-- and even a plain GRAY descriptor halves it. That is why fading with
-- STRENGTH feels like the only brightness control there is, and why it
-- costs colour to use: the two were welded together.
--
-- VALUE unwelds them by restoring the pixel's own luminance after the
-- blend. 1.00 means the tinted pixel is exactly as light as the art
-- pixel was, so STRENGTH sets how much hue, DESAT sets how pure it is,
-- and this sets how light it lands. Below 1 darkens, above 1 lightens
-- and starts clipping, which desaturates highlights. 0 turns the
-- restore off and gives the old darkening behaviour exactly.
-- ==========================================
-- Parked on _G so a script reload keeps whatever was tuned, and so the
-- values can be changed while the game runs. blend() reads them on
-- every pixel, so a change takes effect on the next manufacture; what
-- is already cached is not repainted, which is what tint() below deals
-- with.
_G.refinish_sprite_art_tint = _G.refinish_sprite_art_tint or {
    desat = 0.7, strength = 0.95, value = 0.65,
}
local KNOBS = _G.refinish_sprite_art_tint

-- ---- THE MODE: ONE SWITCH FOR EVERY ART ----
-- How every art colours, parked on _G with the knobs above:
--   palette  DF's own way (DF'S OWN COLOURS, below): each symbol becomes
--            the material's palette colour for its column, on ramp B, or
--            ramp A, DF's muted one, with ramp = 'A'. The default since
--            2026-09-25, so our sprites sit beside DF's in one colour
--            language. A colour with no palette row falls back to blend.
--   blend    the multiply below, on the knobs, or on an art's profile:
--            the material's true colour
-- For one delivery each profile carried its own mode. One switch is what
-- keeps every sprite consistent, and it is what refinish-tint palette and
-- refinish-tint blend flip. A session that parked the knobs before the
-- mode existed reads nil here, which becomes palette.
KNOBS.mode = KNOBS.mode or 'palette'
KNOBS.ramp = KNOBS.ramp or 'B'

-- ---- THE GENERATION ----
-- Moves on every cache wipe (a knob, the mode, a profile, or a palette
-- row rewritten in place, through forget()), so a consumer can tell its
-- textures are stale without knowing why: the tool tint compares it
-- every poll.
_G.refinish_sprite_art_generation = _G.refinish_sprite_art_generation or 0
local function bump()
    _G.refinish_sprite_art_generation = _G.refinish_sprite_art_generation + 1
end

-- ==========================================
-- A PROFILE PER ART
-- ==========================================
-- The knobs above were tuned in play against boulders, and VALUE puts
-- back the ART pixel's luminance, scaled by VALUE, whatever the
-- descriptor. For a material sprite that is the point: the art carries
-- the form, the descriptor the hue. It also throws the material's own
-- lightness away, so every neutral descriptor lands on one grey.
-- MEASURED 2026-09-25 on the tool forms: limestone (SILVER), granite,
-- clinker (GRAY) and every other grey stone wore one identical dark
-- grey, and only saturated colours kept reading (cinnabar's RED,
-- sawdust's wood browns). Worked through on the gravel map, every
-- neutral descriptor comes out at mean 51:53:57, luminance 52.
--
-- So an art may register a profile of its own (register's third
-- argument). It blends on its own desat and strength, then scales the
-- art's own luminance map so its MEAN lands where the material's
-- lightness says, between two absolute luminances:
--   dark    where a black descriptor's sprite lands
--   light   where a white one's lands
-- The shading between grains survives, because every pixel is scaled
-- from its own luminance; a very light material clips the brightest
-- pixels. On the gravel map at 50 and 200: obsidian 50, clinker 125,
-- limestone 159, cinnabar red at 192:45:49. mean is the art's own mean
-- luminance, measured once by register(). An art with no profile blends
-- exactly as before.
--
-- A profile's numbers are blend numbers: palette mode (THE MODE, above)
-- does not read them, except as the fallback for a colour with no
-- palette row. For one delivery a profile also carried its own mode;
-- the mode is one switch for every art now, so a profile never
-- overrides it.
-- ==========================================
_G.refinish_sprite_art_profiles = _G.refinish_sprite_art_profiles or {}
local PROFILES = _G.refinish_sprite_art_profiles

local function blend(p, rgb, prof)
    local DESAT, STRENGTH, VALUE = KNOBS.desat, KNOBS.strength, KNOBS.value
    if prof then DESAT, STRENGTH = prof.desat, prof.strength end
    local L = (30 * rgb[1] + 59 * rgb[2] + 11 * rgb[3]) // 100
    local c = {
        math.floor(rgb[1] * (1 - DESAT) + L * DESAT),
        math.floor(rgb[2] * (1 - DESAT) + L * DESAT),
        math.floor(rgb[3] * (1 - DESAT) + L * DESAT),
    }
    local out = {}
    for i = 1, 3 do
        local m = (p[i] * c[i]) // 255
        out[i] = math.floor(p[i] + (m - p[i]) * STRENGTH)
    end

    -- ---- BRIGHTNESS, PUT BACK ----
    -- Scaling all three channels by the same factor moves the value
    -- and leaves the ratios between them alone, so the hue and the
    -- saturation the knobs above decided are untouched.
    if prof then
        -- The material's lightness, not the art's: see A PROFILE PER ART.
        local lp = (30 * p[1] + 59 * p[2] + 11 * p[3]) // 100
        local lo = (30 * out[1] + 59 * out[2] + 11 * out[3]) // 100
        if lo > 0 then
            local k = lp * (prof.dark + (prof.light - prof.dark) * L / 255)
                      / (prof.mean * lo)
            for i = 1, 3 do
                out[i] = math.min(255, math.floor(out[i] * k))
            end
        end
    elseif VALUE > 0 then
        local lp = (30 * p[1] + 59 * p[2] + 11 * p[3]) // 100
        local lo = (30 * out[1] + 59 * out[2] + 11 * out[3]) // 100
        if lo > 0 then
            local k = (lp / lo) * VALUE
            for i = 1, 3 do
                out[i] = math.min(255, math.floor(out[i] * k))
            end
        end
    end

    return out[1], out[2], out[3]
end

-- ==========================================
-- REGISTRY
-- ==========================================
-- Modules put their char maps here. Parked on _G so a module reload
-- does not lose art the engine is already pointing at.
-- ==========================================
_G.refinish_sprite_art_registry = _G.refinish_sprite_art_registry or {}
local ART = _G.refinish_sprite_art_registry

-- A profile as stored: register()'s defaults for any number not given,
-- dark and light rounded to whole luminances within 0 to 255 (the
-- texture cache key writes them as integers), and the art's own mean
-- luminance over every pixel it draws, which dark and light are
-- measured against.
local function make_profile(charmap, profile)
    local sum, n = 0, 0
    for y = 1, CELL_PX do
        local line = charmap[y] or ''
        for x = 1, CELL_PX do
            local p = RAMP[line:sub(x, x)]
            if p then
                sum = sum + (30 * p[1] + 59 * p[2] + 11 * p[3]) // 100
                n = n + 1
            end
        end
    end
    local function lum(x, default)
        return math.max(0, math.min(255, math.floor((x or default) + 0.5)))
    end
    return {
        desat    = profile.desat    or 0.3,
        strength = profile.strength or 0.9,
        dark     = lum(profile.dark, 50),
        light    = lum(profile.light, 200),
        mean     = n > 0 and math.max(1, sum / n) or 128,
    }
end

-- profile is optional: { desat, strength, dark, light } (A PROFILE PER
-- ART, above). Registering without one clears any the name had.
function register(name, charmap, profile)
    if type(name) ~= 'string' or type(charmap) ~= 'table' then
        return false, 'register(name, charmap) wants a string and a table'
    end
    ART[name] = charmap
    if type(profile) == 'table' then
        PROFILES[name] = make_profile(charmap, profile)
    else
        PROFILES[name] = nil
    end
    return true
end

function registered()
    local out = {}
    for k in pairs(ART) do table.insert(out, k) end
    table.sort(out)
    return out
end

-- ==========================================
-- COLOUR
-- ==========================================
-- A material's state_color is DF's color_pattern: an index into
-- descriptors.patterns, not the colour list. The colour to draw with
-- is the pattern's first colour (as refinish-boot.lua names it). Read
-- as a colour index it matched only vanilla's first 136 colours; a
-- mod's colours have their patterns at the end of the list.
local function state_colour(idx)
    local c = nil
    pcall(function()
        local d = df.global.world.raws.descriptors
        local p = d.patterns[idx]
        if p and #p.colors > 0 then c = d.colors[p.colors[0]] end
    end)
    return c
end

local function material_rgb(m)
    local idx = nil
    pcall(function() idx = m.state_color.Solid end)
    if not idx or idx < 0 then return nil, 'no solid state colour' end
    local c = state_colour(idx)
    if not c then return nil, 'state colour ' .. tostring(idx) .. ' does not resolve' end
    return { c.orig_rgb[0], c.orig_rgb[1], c.orig_rgb[2] }, c.id
end

-- ---- DF'S OWN COLOURS: THE PALETTE ----
-- DF does not tint its item art by multiplying. Its art is drawn in the
-- key colours of palette row 0 (palettes.png in vanilla_descriptors_
-- graphics, [PALETTE_DEFAULT:0], "the one used in the images
-- themselves"), and DF swaps each key for the same column of the
-- material colour's own row: 18 curated colours, ramp A (columns 0 to
-- 8, muted) then ramp B (9 to 17, richer). Every descriptor carries its
-- row live, as palette.color, 54 bytes. MEASURED 2026-09-25: all 261
-- opaque pixels of the stock powder pile are row 0 keys (258 ramp B,
-- 3 ramp A), and PURPLE's row predicts DF's alunite dust at 175:126:154
-- for its brightest quarter against 171:124:152 on screen: a mauve with
-- more red than blue, where the PURPLE descriptor itself is 102:0:153.
-- That is why no multiply of the descriptor, at any knob setting, ever
-- looked like DF: the hue itself differs.
--
-- The rows are read live. refinish-palette-probe rewrote them in play
-- (2026-09-25) and many of DF's own sprites followed, though boulders
-- and blocks did not. A global vanilla or custom colour switch is
-- therefore possible. It is shelved for now: RM's art matches DF by
-- reading the rows as DF loaded them.
--
-- RAMP above is exactly ramp B's keys, so a char map's symbols are
-- palette columns: '0' to '8' are ramp B's nine, '.' is '0' at half
-- alpha.
local LEVEL = {
    ['.'] = 0, ['0'] = 0, ['1'] = 1, ['2'] = 2, ['3'] = 3,
    ['4'] = 4, ['5'] = 5, ['6'] = 6, ['7'] = 7, ['8'] = 8,
}

-- ---- LIGHTER OR DARKER ALONG THE PALETTE ----
-- An art drawn darker than DF draws lands darker in palette mode, since
-- each symbol takes its own column. MEASURED 2026-09-25: the 469 vanilla
-- item cells drawn wholly in palette keys sit at a median mean level of
-- 3.12 on the nine step ramp (quartiles 2.71 to 3.66; the powder pile
-- 2.73), and RM's gravel at 2.10, which read a step darker than alunite
-- dust beside it on screen. A shift moves every symbol of one art that
-- many steps along the material's own palette: every pixel stays a real
-- palette colour, so the colour family holds, and the ends clamp, so a
-- large shift flattens contrast. Palette mode only; blend has its own
-- lightness numbers. Per art, on _G, set by shift() below.
_G.refinish_sprite_art_shifts = _G.refinish_sprite_art_shifts or {}
local SHIFTS = _G.refinish_sprite_art_shifts
local DF_LEVEL = 3.12

-- The material's palette row as { [0] = { r, g, b }, ... [17] }, or nil
-- when its descriptor has none (every byte zero), so the caller blends.
local function material_palette(m)
    local idx = nil
    pcall(function() idx = m.state_color.Solid end)
    if not idx or idx < 0 then return nil end
    local c = state_colour(idx)
    if not c then return nil end
    local pal, any = {}, false
    local ok = pcall(function()
        for i = 0, 17 do
            local e = { c.palette.color[i * 3], c.palette.color[i * 3 + 1],
                        c.palette.color[i * 3 + 2] }
            if e[1] + e[2] + e[3] > 0 then any = true end
            pal[i] = e
        end
    end)
    if not ok or not any then return nil end
    return pal
end

-- ==========================================
-- BUILD
-- ==========================================
-- RESERVED, not dynamic. The dynamic range is periodically wiped and
-- the handle exists so you can re-resolve afterwards. We cannot: a
-- material slot holds a RAW INTEGER, not a handle, so once the vector is
-- wiped that integer points at whatever now occupies the index and the
-- material silently wears somebody else's sprite.
--
-- The reserved range is never wiped. The catch is that it is a fixed
-- size buffer and DFHack falls back to dynamic SILENTLY when full, with
-- no way to ask which you got. Right for a handful of material sprites,
-- wrong as a habit. If sprites start swapping themselves after a long
-- session, a full reserved buffer is the first suspect.
-- ==========================================
_G.refinish_sprite_art_handles = _G.refinish_sprite_art_handles or {}
_G.refinish_sprite_art_cache   = _G.refinish_sprite_art_cache   or {}
local HANDLES = _G.refinish_sprite_art_handles
local CACHE   = _G.refinish_sprite_art_cache

-- pal, when given, is the material's palette row (material_palette):
-- each symbol takes its column's colour, on the ramp THE MODE names,
-- moved shift steps along it (LIGHTER OR DARKER ALONG THE PALETTE),
-- instead of a blend.
local function build(charmap, rgb, prof, pal, shift)
    local pixels = {}
    local base = (KNOBS.ramp == 'A') and 0 or 9
    shift = shift or 0
    for y = 1, CELL_PX do
        local line = charmap[y] or ''
        for x = 1, CELL_PX do
            local ch = line:sub(x, x)
            local p = RAMP[ch]
            if p then
                local r, g, b
                if pal then
                    local lv = math.max(0, math.min(8, LEVEL[ch] + shift))
                    local e = pal[base + lv]
                    r, g, b = e[1], e[2], e[3]
                else
                    r, g, b = blend(p, rgb, prof)
                end
                pixels[#pixels + 1] = pack(r, g, b, p[4])
            else
                pixels[#pixels + 1] = 0
            end
        end
    end
    return dfhack.textures.createTileset(pixels, CELL_PX, CELL_PX,
                                         CELL_PX, CELL_PX, true)
end

-- ==========================================
-- THE ONE CALL THE ENGINE MAKES
-- ==========================================
-- Cached per material colour and art name, because the same pairing
-- resolves once per slot and a material with two boulder slots would
-- otherwise burn two reserved textures on one picture.
-- ==========================================
function texpos_for(m, art_name)
    local charmap = ART[art_name]
    if not charmap then
        return nil, 'no art registered as "' .. tostring(art_name) .. '"'
    end
    local rgb, cname = material_rgb(m)
    if not rgb then return nil, cname end

    local prof = PROFILES[art_name]
    -- THE MODE decides the colour: palette colours from the material's
    -- palette row, and a colour with none falls back to blend.
    local pal = (KNOBS.mode or 'palette') == 'palette' and material_palette(m) or nil
    local key
    if pal then
        -- A palette belongs to a descriptor, not an RGB (two can share
        -- one), and no blend number plays a part in it.
        key = string.format('%s:pal:%s:%s:s%d', art_name, tostring(cname),
            KNOBS.ramp or 'B', SHIFTS[art_name] or 0)
    else
        key = string.format('%s:%d:%d:%d', art_name, rgb[1], rgb[2], rgb[3])
        if prof then
            -- A profile changes the picture, so it is part of the pairing.
            key = key .. string.format(':p%.2f:%.2f:%d:%d', prof.desat,
                prof.strength, prof.dark, prof.light)
        end
    end
    if CACHE[key] then return CACHE[key], nil end

    local handles = build(charmap, rgb, prof, pal, SHIFTS[art_name])
    if not handles or not handles[1] then
        return nil, 'createTileset returned nothing'
    end
    local texpos = dfhack.textures.getTexposByHandle(handles[1])
    if not texpos or texpos <= 0 then
        -- Not deleted either. This is the same call that took the
        -- process down at shutdown, and a handle that just failed to
        -- resolve is the least trustworthy one to hand back to it. The
        -- cost is one unused texture per failed manufacture, which is a
        -- fault that should be read in the log and fixed, not swept up.
        return nil, 'handle did not resolve to a texpos'
    end
    table.insert(HANDLES, handles)
    CACHE[key] = texpos
    return texpos, nil
end

-- ==========================================
-- TEARDOWN: KEPT, NOT FREED
-- ==========================================
-- MEASURED, twice, 2026-09-22 at 16:55:52 and 17:10:18: deleting these
-- on the way out of a world took DF down with it. The stack is
-- Core::onStateChange, into Lua, into DFHack::Textures::deleteHandle,
-- into SDL. Both sessions stop at the same point of the teardown, the
-- line before this call, and neither ever printed the count below.
--
-- pcall is no guard here. A crash inside DFHack's own texture code is
-- native, and Lua never gets the chance to catch it. The old body had
-- every delete in a pcall and still took the process down.
--
-- It began crashing when the count grew. One pairing (peat) survived
-- this for months; anthracite, oil shale, bitumen, pitch, char,
-- naphthalene and anthracene took it to eight.
--
-- So nothing is deleted. These are RESERVED range textures, which are
-- never wiped, so the texpos a handle resolved to stays good for the
-- life of the process. The CACHE is kept for the same reason: the next
-- start asks for the same art and colour pairings and gets the same
-- textures back instead of manufacturing a second set, so keeping them
-- costs nothing that freeing them saved.
--
-- One cost, and it is a development one: editing an art entry needs a
-- full DF restart to see the change, because the pairing is cached.
--
-- The symptom to watch, from RM_Adaptive_Sprites: the reserved buffer
-- is a fixed size and DFHack falls back to the dynamic range silently
-- when it is full. If a sprite ever comes back wearing another
-- material's picture after many reloads, that is the buffer filling,
-- not this.
-- ==========================================
-- ---- FORGET ----
-- Wipes every cached pairing and moves the generation on, so every
-- consumer asks again and gets textures made from what is true now. For
-- changes the cache key cannot see, a palette row rewritten in place
-- (refinish-palette-probe) above all, and under every knob, mode and
-- profile change below. Returns how many pairings were dropped. The
-- textures themselves are kept (TEARDOWN, above).
function forget()
    local n = 0
    for k in pairs(CACHE) do CACHE[k] = nil; n = n + 1 end
    bump()
    return n
end

function generation()
    return _G.refinish_sprite_art_generation
end

-- ==========================================
-- LIVE TUNING
-- ==========================================
-- Set any of the three knobs while the game runs. The cache is keyed by
-- art name and colour, not by the knobs, so a stale entry would hand
-- back the OLD texture for ever: wiping it is the whole trick. The
-- textures themselves are left alone, because deleting a handle takes
-- the process down (see the note above), so a tuning session leaks one
-- texture per art and colour pairing per change. That is fine for
-- tuning and is why this is not something to call on a cadence.
--
-- Nothing is repainted by this call. A consumer has to ASK for its
-- texpos again: the tool tint watcher does that every poll, ash sprite
-- has refresh(), and slots written from module JSON are resolved at
-- injection, so those need the module stopped and started. None of it
-- needs DF restarted, which is what the cache used to force.
--
--   tint{ value = 0.9 }               one knob
--   tint{ strength = 1.0, desat = 0.2 }
--   tint{ mode = 'blend' }            THE MODE, for every art
--   tint{ ramp = 'A' }                palette ramp A, DF's muted one
--   tint()                            report only, nothing wiped
-- Returns desat, strength, value, mode, ramp.
function tint(opts)
    if type(opts) == 'table' then
        local touched = false
        for _, k in ipairs({ 'desat', 'strength', 'value' }) do
            local v = opts[k]
            if type(v) == 'number' then KNOBS[k] = v; touched = true end
        end
        if opts.mode == 'palette' or opts.mode == 'blend' then
            KNOBS.mode = opts.mode
            touched = true
        end
        if opts.ramp == 'A' or opts.ramp == 'B' then
            KNOBS.ramp = opts.ramp
            touched = true
        end
        if touched then
            local n = forget()
            -- DETAIL: refinish-tint reports the change itself. This is
            -- the cache beneath it.
            log('DETAIL', ('tint set to %s (ramp %s), desat %.2f strength %.2f '
                 .. 'value %.2f, %d cached pairing(s) dropped')
                :format(KNOBS.mode, KNOBS.ramp, KNOBS.desat, KNOBS.strength,
                        KNOBS.value, n), 'TINT')
        end
    end
    return KNOBS.desat, KNOBS.strength, KNOBS.value, KNOBS.mode, KNOBS.ramp
end

-- ==========================================
-- A PROFILE, LIVE
-- ==========================================
-- What tint() is to the shared knobs, for one art's profile, so
-- refinish-tint can tune it on screen.
--   profile(name)          that art's profile, or nil when it blends on
--                          the shared knobs
--   profile(name, opts)    change it: desat, strength, dark and light set
--                          those numbers, and an art with no profile gets
--                          one (register()'s defaults for the rest);
--                          shared = true drops the profile
-- A change drops that art's cached pairings, and only those, so the next
-- request manufactures with the new numbers. Returns a copy, or nil and
-- an error for a name nothing registered.
-- ==========================================
function profile(name, opts)
    local charmap = ART[name]
    if not charmap then
        return nil, 'no art registered as "' .. tostring(name) .. '"'
    end
    if type(opts) == 'table' and next(opts) then
        if opts.shared then
            PROFILES[name] = nil
        else
            local cur = PROFILES[name] or {}
            PROFILES[name] = make_profile(charmap, {
                desat    = opts.desat    or cur.desat,
                strength = opts.strength or cur.strength,
                dark     = opts.dark     or cur.dark,
                light    = opts.light    or cur.light,
            })
        end
        local n, prefix = 0, name .. ':'
        for k in pairs(CACHE) do
            if k:sub(1, #prefix) == prefix then CACHE[k] = nil; n = n + 1 end
        end
        bump()
        -- DETAIL: refinish-tint reports the change itself. This is the
        -- cache beneath it.
        log('DETAIL', ('%s profile %s, %d cached pairing(s) dropped')
            :format(name, PROFILES[name] and 'set' or 'dropped', n), 'PROFILE')
    end
    local p = PROFILES[name]
    if not p then return nil end
    return { desat = p.desat, strength = p.strength, dark = p.dark, light = p.light }
end

-- ==========================================
-- A SHIFT, LIVE
-- ==========================================
--   shift(name)       that art's palette shift, 0 when none is set
--   shift(name, n)    set it, in whole steps (clamped to -8 to 8); 0
--                     clears it. Drops that art's cached pairings and
--                     moves the generation on, so it repaints.
--   level(name)       the mean level the art is drawn at, then DF's own
--                     (LIGHTER OR DARKER ALONG THE PALETTE), as the guide
--                     for choosing a shift
-- Each returns nil and an error for a name nothing registered.
-- ==========================================
function shift(name, n)
    if not ART[name] then
        return nil, 'no art registered as "' .. tostring(name) .. '"'
    end
    if type(n) == 'number' then
        n = math.max(-8, math.min(8, math.floor(n + 0.5)))
        SHIFTS[name] = (n ~= 0) and n or nil
        local dropped, prefix = 0, name .. ':'
        for k in pairs(CACHE) do
            if k:sub(1, #prefix) == prefix then CACHE[k] = nil; dropped = dropped + 1 end
        end
        bump()
        -- DETAIL: refinish-tint reports the change itself. This is the
        -- cache beneath it.
        log('DETAIL', ('%s palette shift %+d, %d cached pairing(s) dropped')
            :format(name, n, dropped), 'SHIFT')
    end
    return SHIFTS[name] or 0
end

function level(name)
    local charmap = ART[name]
    if not charmap then
        return nil, 'no art registered as "' .. tostring(name) .. '"'
    end
    local sum, n = 0, 0
    for y = 1, CELL_PX do
        local line = charmap[y] or ''
        for x = 1, CELL_PX do
            local lv = LEVEL[line:sub(x, x)]
            if lv then
                sum = sum + lv
                n = n + 1
            end
        end
    end
    return n > 0 and sum / n or 0, DF_LEVEL
end

function release_all()
    local n = #HANDLES
    if n > 0 then
        -- DETAIL: runs at every shutdown and data cycle.
        log('DETAIL', 'kept ' .. n .. ' manufactured texture(s) for reuse.',
            'RELEASE')
    end
    return n
end