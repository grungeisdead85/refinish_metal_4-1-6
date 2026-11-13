-- refinish-tint.lua
-- =====================================================================
-- LIVE TINT TUNER
-- =====================================================================
-- Changes the three tint knobs while the game runs and pushes the
-- change out as far as it can reach, so a colour can be judged on
-- screen instead of across a recycle.
--
--   refinish-tint                      report the current values: the
--                                      mode, the shared knobs and every
--                                      profile
--   refinish-tint palette              every art in DF's own colours,
--                                      from each material's palette row
--                                      (the default since 2026-09-25)
--   refinish-tint blend                every art on our blend: the
--                                      material's true colour
--   refinish-tint ramp=a               palette ramp A, DF's muted one;
--                                      ramp=b is back to B
--   refinish-tint value=0.9            set one blend knob
--   refinish-tint strength=1 desat=0.2 value=0.85
--   refinish-tint off                  value=0, the old darkening blend
--
-- An art with a profile of its own (gravel and sawdust; A PROFILE PER
-- ART in refinish-sprite-art.lua) blends on its own numbers instead of
-- the shared ones, so in blend mode it is tuned by name:
--   refinish-tint gravel               report that art's profile
--   refinish-tint gravel dark=60 light=210
--   refinish-tint sawdust dark=50      give an art a profile of its own
--   refinish-tint sawdust shared       back to the shared knobs
--   refinish-tint gravel shift=1       palette mode: that art a step
--                                      lighter along each material's
--                                      own palette (negative is darker,
--                                      0 clears it); the report gives the
--                                      level it is drawn at, beside DF's
-- The mode is one switch for every art (THE MODE in refinish-sprite-
-- art.lua). For one delivery it was set per art (refinish-tint gravel
-- palette); one switch is what keeps every sprite consistent.
-- A profile change lasts until DF closes (the forms file sets its own at
-- the next launch), so the report is a line ready to copy back into
-- refinish-sprite-art-forms.lua.
--
-- WHAT EACH KNOB DOES, since they are easy to confuse:
--   strength  how much hue the multiply contributes, 0 none, 1 full
--   desat     how pure that hue is, pulling the descriptor toward its
--             own grey before it is applied
--   value     how light the result lands, 1.00 meaning as light as the
--             untinted art was. 0 turns the restore off entirely
-- and a profile's own:
--   desat, strength   as above, for that art alone
--   dark, light       the mean luminance, out of 255, its sprite lands at
--                     under a black and under a white descriptor; every
--                     colour lands between, by its own lightness
--
-- WHAT GETS REPAINTED, and what does not. The art module's cache is
-- keyed by art and colour, not by the knobs, so this wipes it: the next
-- request manufactures with the new numbers. Nothing already written
-- into a texpos field changes by itself, so this then asks the
-- consumers to fetch again:
--   tools        refinish-sprite-tool-tint re-reads the tint knobs on its own
--                poll; its pass() is called below so a change lands in
--                the same frame
--   ash sprite   has refresh(), called below
--   material art TINT: slots from module JSON (Making Fuel's peat and
--                cokes wear the coal and coke art this way) are kept by
--                the sprite engine, and its retint(), called below,
--                repaints them. Until 2026-09-25 they were resolved only
--                at injection and wanted the module stopped and started.
--                No DF restart either way: the cache was the only thing
--                that ever forced one.
-- A profile change drops only that art's pairings, then asks the same
-- consumers.
--
-- COST. Textures are never deleted, because deleting a handle takes the
-- process down (see refinish-sprite-art.lua). So every change leaks one
-- texture per art and colour pairing in use. Fine for a tuning session,
-- not something to put on a timer.
-- =====================================================================

--@ module = true

local art = reqscript('refinish-sprite-art')

-- RM core's own system name. This file said 'REFINISH', which the log
-- panel does not recognise as RM, so its lines rendered as a module's.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TINT'
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
-- SUBJECT is the correlation slot: ARGS for a refused argument, VALUES
-- for the knobs, REFRESH for what was pushed out.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise.
--
-- No console prints. The print this replaces only ran when RM's log
-- was not loaded.
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
-- ARGUMENTS
-- ==========================================
-- key=value pairs in any order, plus the bare word 'off'. Anything
-- unrecognised is reported rather than ignored, because a typo that
-- silently does nothing is worse than a refusal when the whole point
-- is watching a number change.
local ALIAS = {
    desat = 'desat', d = 'desat',
    strength = 'strength', s = 'strength',
    value = 'value', v = 'value', brightness = 'value', b = 'value',
}

local function parse(args)
    local opts, bad = {}, {}
    for _, a in ipairs(args or {}) do
        local word = tostring(a):lower()
        if word == 'off' then
            opts.value = 0
        elseif word == 'palette' or word == 'blend' then
            opts.mode = word
        elseif word == 'ramp=a' or word == 'ramp=b' then
            opts.ramp = word:sub(-1):upper()
        else
            local k, v = word:match('^([%a_]+)=([%-%d%.]+)$')
            local key = k and ALIAS[k]
            if key and tonumber(v) then
                opts[key] = tonumber(v)
            else
                table.insert(bad, tostring(a))
            end
        end
    end
    return opts, bad
end

-- ==========================================
-- PUSH THE CHANGE OUT
-- ==========================================
-- Each consumer in its own pcall: one of them missing is a cosmetic
-- failure and must not stop the others.
local function refresh_consumers()
    local done = {}

    local ok_ash, ash = pcall(reqscript, 'making-fuel-ash-sprite')
    if ok_ash and ash and ash.refresh then
        if pcall(ash.refresh) then table.insert(done, 'ash sprite') end
    end

    -- The tool watcher would pick this up on its own poll; calling its
    -- pass here just makes the change land in the same frame.
    local ok_tt, tt = pcall(reqscript, 'refinish-sprite-tool-tint')
    if ok_tt and tt and tt.pass then
        local ok_n, n = pcall(tt.pass)
        if ok_n then
            table.insert(done, ('tool tint (%s field(s))'):format(tostring(n)))
        end
    end

    -- Material art: the sprite engine keeps every TINT: slot it wrote
    -- and repaints them all here.
    local ok_se, se = pcall(reqscript, 'refinish-sprite-engine')
    if ok_se and se and se.retint then
        local ok_n, n = pcall(se.retint)
        if ok_n then
            table.insert(done, ('material art (%s field(s))'):format(tostring(n)))
        end
    end

    return done
end

-- ==========================================
-- ONE ART'S PROFILE
-- ==========================================
-- A first word naming a registered art tunes that art's profile rather
-- than the shared knobs. Its own keys: desat and strength (d and s, as
-- above), dark and light, and the word shared to drop the profile. They
-- are blend numbers: palette mode does not read them. The mode is one
-- switch for every art, so palette, blend and ramp= belong to the plain
-- command, not to an art.
-- ==========================================
local PROFILE_ALIAS = {
    desat = 'desat', d = 'desat',
    strength = 'strength', s = 'strength',
    dark = 'dark', light = 'light',
}

local function art_named(word)
    for _, name in ipairs(art.registered()) do
        if name == word or name == word:lower() then return name end
    end
    return nil
end

local function parse_profile(args)
    local opts, bad = {}, {}
    for i = 2, #args do
        local word = tostring(args[i]):lower()
        if word == 'shared' then
            opts.shared = true
        elseif word:match('^shift=[%-%+]?%d+$') then
            -- A palette number, not a blend one: it goes to art.shift and
            -- never creates or changes a profile.
            opts.shift = tonumber((word:gsub('^shift=%+?', '')))
        else
            local k, v = word:match('^([%a_]+)=([%-%d%.]+)$')
            local key = k and PROFILE_ALIAS[k]
            if key and tonumber(v) then
                opts[key] = tonumber(v)
            else
                table.insert(bad, tostring(args[i]))
            end
        end
    end
    return opts, bad
end

-- One art's profile as a line ready to paste into
-- refinish-sprite-art-forms.lua.
local function profile_line(name, p)
    return ('%s = { desat = %g, strength = %g, dark = %d, light = %d }')
        :format(name, p.desat, p.strength, p.dark, p.light)
end

-- One art's palette shift, with the level the art is drawn at beside
-- DF's own, as the guide for choosing one.
local function log_shift(name)
    if not (art.shift and art.level) then return end
    local s = art.shift(name) or 0
    local lv, df_lv = art.level(name)
    if not lv then return end
    log('INFO', ('%s palette shift %+d: drawn at level %.2f, lands near %.2f;'
        .. ' DF\'s item art sits at %.2f'):format(name, s, lv, lv + s, df_lv), 'SHIFT')
end

local function report_profiles()
    if not art.profile then return end
    for _, name in ipairs(art.registered()) do
        local p = art.profile(name)
        if p then log('INFO', profile_line(name, p), 'PROFILE') end
        if art.shift and (art.shift(name) or 0) ~= 0 then log_shift(name) end
    end
end

local function main_profile(name, args)
    local opts, bad = parse_profile(args)
    for _, b in ipairs(bad) do
        log('WARNING', 'ignored "' .. b .. '": expected desat=, strength=, dark=,'
            .. ' light= or shared. The mode is one switch for every art:'
            .. ' refinish-tint palette, blend or ramp=a', 'ARGS')
    end
    if not art.profile then
        -- WARNING: an older refinish-sprite-art, from before profiles, is
        -- loaded, and nothing else would say why nothing changed.
        log('WARNING', 'refinish-sprite-art has no profiles to tune; is it the'
            .. ' current file?', 'PROFILE')
        return
    end
    -- INFO throughout, as below: each line answers a command a player
    -- typed.
    -- A shift comes out first: it is a palette number and goes to
    -- art.shift, so it never creates or changes a profile.
    local want_shift = opts.shift
    opts.shift = nil
    if not next(opts) and want_shift == nil then
        local p = art.profile(name)
        log('INFO', p and profile_line(name, p)
            or (name .. ' blends on the shared knobs (no profile).'), 'PROFILE')
        log_shift(name)
        return
    end
    if want_shift ~= nil and art.shift then art.shift(name, want_shift) end
    local p = art.profile(name)
    if next(opts) then
        local err
        p, err = art.profile(name, opts)
        if err then
            log('WARNING', err, 'PROFILE')
            return
        end
    end
    local done = refresh_consumers()
    log('INFO', p and profile_line(name, p)
        or (name .. ' blends on the shared knobs (no profile).'), 'PROFILE')
    log_shift(name)
    log('INFO', ('refreshed: %s'):format(#done > 0 and table.concat(done, ', ')
                                         or 'nothing live to refresh'), 'REFRESH')
    log('INFO', 'this lasts until DF closes; to keep it, put it in the file'
        .. ' that registers the art (refinish-sprite-art-forms.lua for RM\'s'
        .. ' forms, making-fuel-sprite-art.lua for Making Fuel\'s)', 'PROFILE')
end

function main(args)
    args = args or {}
    local target = args[1] and art_named(tostring(args[1]))
    if target then
        main_profile(target, args)
        return
    end
    local opts, bad = parse(args)
    for _, b in ipairs(bad) do
        log('WARNING', 'ignored "' .. b .. '": expected desat=, strength=,'
            .. ' value=, off, palette, blend, ramp=a, ramp=b, or an art\'s name'
            .. ' first', 'ARGS')
    end

    local before = { art.tint() }
    local d, s, v, mode, ramp = art.tint(opts)
    mode, ramp = mode or 'palette', ramp or 'B'

    if not next(opts) then
        -- INFO throughout: every line here answers a command a player
        -- typed, so each is worth seeing at Normal.
        log('INFO', ('mode %s (ramp %s); blend knobs desat %.2f, strength %.2f,'
            .. ' value %.2f'):format(mode, ramp, d, s, v), 'VALUES')
        -- The shared knobs do not reach an art with a profile, so its
        -- numbers are part of the answer.
        report_profiles()
        return
    end

    local done = refresh_consumers()
    log('INFO', ('mode %s -> %s, ramp %s -> %s, desat %.2f -> %.2f, strength %.2f'
        .. ' -> %.2f, value %.2f -> %.2f'):format(before[4] or 'palette', mode,
        before[5] or 'B', ramp, before[1], d, before[2], s, before[3], v), 'VALUES')
    log('INFO', ('refreshed: %s'):format(#done > 0 and table.concat(done, ', ')
                                         or 'nothing live to refresh'), 'REFRESH')
end

if not dfhack_flags.module then
    main({ ... })
end