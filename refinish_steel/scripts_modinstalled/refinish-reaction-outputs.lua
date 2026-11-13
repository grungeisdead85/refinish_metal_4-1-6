--@ module = true
-- refinish-reaction-outputs.lua
-- ==========================================
-- RM REACTION OUTPUTS: MADE OF WHAT WENT IN, AND STACKED
-- ==========================================
-- WHY
-- A product that takes its material from a reagent (GET_MATERIAL_SAME,
-- or that material's own product, GET_MATERIAL_PRODUCT) gets the
-- material of the FIRST item DF collected for that reagent. A slot that
-- holds several items can hold several materials, so the rest of the
-- input disappears into the first one's name: two branches of different
-- trees split into kindling all of the first tree (seen in play, Making
-- Fuel), three rough gems of two kinds grind into dust of one. Stacks
-- make it common: one slot fills from any number of stacks
-- (RM_Stacked_Tools.md), and nothing makes those stacks one material.
-- A product of a fixed material (concrete, a finish, a coal) is not
-- affected: what it is made of was never read off an input.
--
-- WHAT THIS DOES, for every custom reaction, RM's, a module's or the
-- raws':
--   1. OUTPUTS FOLLOW INPUTS. While a job runs, the items held for each
--      reagent a product takes its material from are measured, by volume
--      and by material. When the job completes, if that reagent held
--      more than one material, the job's new items of that product are
--      shared out across the materials by those volumes: largest
--      remainder, so every item lands on one, and a lone item goes to the
--      largest share (ties to the first collected). Each takes the
--      material the product would have given an input of that material:
--      the input's own, or its material product.
--   2. STACKS. The job's new items of a tool that declares stack = true
--      in its definition (read off every registered module's tools, the
--      way refinish-sprite-tool-tint.lua reads tint) are merged per
--      material, one stack each.
--   3. MEASURED STACKS. A measured product is sized from what its source
--      measured, in its tool's own unit, instead of DF's count, and DF's
--      count becomes how many stacks it comes in (its section, below).
--      Measured: RM's grinders, by code, and any product a registered
--      reaction declares measure = true on (the crushers' dust).
-- Otherwise nothing about a job changes: what DF consumed, and what kind
-- of items it made.
--
-- WHEN, READ FROM DFHACK'S SOURCE (EventManager.cpp, 2026-10-03): every
-- JOB_COMPLETED handler runs before any ITEM_CREATED handler of the same
-- tick, because the event types are walked in enum order (JOB_COMPLETED
-- is 3, ITEM_CREATED 6). So the sharing out and the merging are done
-- before anything that acts on a new item sees it (Making Fuel's fuel
-- wood hop, the gravel hop, the finish minter), and those see the final
-- items. An output whose material is not the one DF gave the first input
-- was changed by something else first: it is left alone, and the log
-- says so once per reaction.
--
-- HOW IT SEES A JOB (the binder watcher's way, making-fuel-binder-
-- watcher.lua): RM's dispatcher hands this file the custom reaction jobs
-- every 10 frames. A memo keeps, per job, its workshop, DF's next item
-- number at the last poll (the line between what the workshop already
-- held and what the job makes), and the measured inputs, read until the
-- job is being worked, when all its items are attached. JOB_COMPLETED,
-- which fires for a completion and never for a cancel, acts on the memo
-- and drops it; a memo not seen for GRACE_POLLS polls belonged to a
-- cancelled job.
--
-- An RM service: loaded at refinish_steel's load, started and stopped
-- with the others (RM'S SERVICES FOLLOW THE DATA there).
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local utils      = require('utils')

local KEY         = 'refinish-reaction-outputs'
local EVERY       = 10   -- frames between polls
local GRACE_POLLS = 20   -- polls a vanished job's memo is kept (200 frames)

-- RM's grinders, by code; their JIT clones begin the same way
-- (refinish_steel.lua, build_ghost_grinder_jit). Every tool they make is
-- a measured product (3). RM core names its own reactions here; a
-- module's are declared with measure = true on the product instead.
local MEASURE_PREFIX = 'REFINISH_STEEL_RXN_LUA_GRIND_'

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. DETAIL is debugging material (each share-out and merge),
-- faults are WARNING and ERROR. No console prints: nothing here answers
-- a typed command.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'OUTPUTS'
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

local said = {}
local function log_once(key, typ, msg, subject)
    if said[key] then return end
    said[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- SMALL READS
-- ==========================================
local function stack_of(it)
    local n = nil
    pcall(function() n = it.stack_size end)
    return n or 1
end

local function mat_name(mt, mi)
    local s = nil
    pcall(function() s = dfhack.matinfo.decode(mt, mi):toString() end)
    return s or ('%s:%s'):format(tostring(mt), tostring(mi))
end

-- RM's reaction index answers by code and checks itself on every use
-- (refinish-resolve.lua). No walk of the array as a fallback: at 100,000
-- reactions a walk costs about 38 ms (walk probe, 2026-09-30).
local function find_rx(code)
    local f = _G.refinish_find_reaction
    if not f then return nil end
    local ok, r = pcall(f, code)
    if ok then return r end
    return nil
end

-- A job's filter list: job_items.elements on current DF, job_items on
-- older builds (making-fuel-binder-watcher.lua, filters).
local function filters(job)
    local list = job.job_items
    local ok, el = pcall(function() return list.elements end)
    if ok and el then return el end
    return list
end

-- ==========================================
-- THE STACKED TOOLS
-- ==========================================
-- [subtype] = tool id, for every tool that declares stack = true. The
-- registry is replaced every data cycle and injection can move a
-- subtype, so the set is rebuilt whenever the registry table or the tool
-- list's length has changed since it was built.
local stacked, stacked_for, stacked_len = {}, nil, -1

local function stacked_set()
    local reg = _G.refinish_module_registry
    local defs = df.global.world.raws.itemdefs.tools
    if reg == stacked_for and #defs == stacked_len then return stacked end
    local want = {}
    for prefix, entry in pairs(reg or {}) do
        for _, t in ipairs(entry.tools or {}) do
            if t.stack == true and t.key then want[prefix .. tostring(t.key)] = true end
        end
    end
    local set = {}
    for i, d in ipairs(defs) do
        local id = tostring(d.id)
        if want[id] then set[i] = id end
    end
    stacked, stacked_for, stacked_len = set, reg, #defs
    return stacked
end

-- [reaction code] = { { tool = tool id, from = reagent code }... }: the
-- products a registered reaction declares measure = true on, read off
-- the registry's reactions (the code is prefix .. 'RXN_' .. key, as the
-- engine builds it). Matched on the live reaction by tool and reagent,
-- not by position, so a product the builder skipped cannot shift it.
local declared, declared_for = {}, nil

local function declared_set()
    local reg = _G.refinish_module_registry
    if reg == declared_for then return declared end
    local out = {}
    for prefix, entry in pairs(reg or {}) do
        for _, r in ipairs(entry.reactions or {}) do
            for _, p in ipairs(r.products or {}) do
                if p.measure == true and r.key and p.subtype then
                    local code = prefix .. 'RXN_' .. tostring(r.key)
                    local list = out[code] or {}
                    list[#list + 1] = { tool = tostring(p.subtype),
                                        from = tostring(p.get_material_same or ''),
                                        whole = (p.whole == true) }
                    out[code] = list
                end
            end
        end
    end
    declared, declared_for = out, reg
    return declared
end

-- ==========================================
-- WHICH REACTIONS
-- ==========================================
-- [code] = false, or { inherits = { { itype, isub, ri, pcode, tool,
-- measured }... }, tools = whether any product is a tool, measured_subs
-- = the subtypes of its measured products }. An inheriting product
-- names a reagent by code (get_material.reagent_code); ri is that
-- reagent's position, pcode the material product it asks for ('' for
-- the reagent's own material), tool its tool id when it is a tool. A
-- code not found yet is not cached, so it is looked up again. Only data
-- is kept, never the reaction: a data cycle rebuilds every reaction, and
-- start() empties this anyway.
local classes = {}

local function classify(code)
    local c = classes[code]
    if c ~= nil then return c end
    local rx = find_rx(code)
    if not rx then return nil end
    c = { inherits = {}, tools = false, measured_subs = {} }
    local wanted = declared_set()[code]
    local grinder = code:find(MEASURE_PREFIX, 1, true) == 1
    local defs = df.global.world.raws.itemdefs.tools
    local at = {}
    pcall(function()
        for i, r in ipairs(rx.reagents) do at[tostring(r.code)] = i end
    end)
    pcall(function()
        for _, p in ipairs(rx.products) do
            if df.reaction_product_itemst:is_instance(p) then
                if p.item_type == df.item_type.TOOL then c.tools = true end
                local rc, pc = '', ''
                pcall(function() rc = tostring(p.get_material.reagent_code) end)
                pcall(function() pc = tostring(p.get_material.product_code) end)
                local ri = (rc ~= '') and at[rc] or nil
                if ri then
                    local h = { itype = p.item_type, isub = p.item_subtype,
                                ri = ri, pcode = pc }
                    if p.item_type == df.item_type.TOOL then
                        pcall(function() h.tool = tostring(defs[p.item_subtype].id) end)
                    end
                    -- Measured (3): a grinder's tool, or a declared one.
                    if h.tool and grinder then h.measured = true end
                    for _, w in ipairs(wanted or {}) do
                        if h.tool == w.tool and rc == w.from then h.measured = true end
                    end
                    if h.measured then c.measured_subs[h.isub] = true end
                    c.inherits[#c.inherits + 1] = h
                end
            end
        end
    end)
    if #c.inherits == 0 and not c.tools then c = false end
    classes[code] = c
    return c
end

-- ==========================================
-- THE MEMO
-- ==========================================
-- [job id] = { code, last (poll last seen), bld (workshop id), mark
--              (item_next_id at the last poll that found the workshop),
--              src = { [ri] = { { mt, mi, vol }... } }, frozen }
-- src lists each material once, in the order the job collected it,
-- with the volume held of it. getVolume scales with stack size
-- (refinish-reaction-adaptive.lua, ITEMS THAT LIE ABOUT VOLUME) and
-- with a bar's dimension, so one measure serves stacks, bars and
-- boulders alike.
local memo, polls = {}, 0

local function read_sources(job, c)
    local want = {}
    for _, h in ipairs(c.inherits) do want[h.ri] = true end
    local fl = filters(job)
    local src, any = {}, false
    for _, ref in ipairs(job.items) do
        pcall(function()
            local f = fl[ref.job_item_idx]
            local ri = f and f.reagent_index
            if ri and want[ri] then
                local it = ref.item
                local info = dfhack.matinfo.decode(it)
                local v = it:getVolume()
                if info and v and v > 0 then
                    local list = src[ri]
                    if not list then
                        list = {}
                        src[ri] = list
                    end
                    local hit = nil
                    for _, e in ipairs(list) do
                        if e.mt == info.type and e.mi == info.index then hit = e break end
                    end
                    if hit then
                        hit.vol = hit.vol + v
                    else
                        list[#list + 1] = { mt = info.type, mi = info.index, vol = v }
                    end
                    any = true
                end
            end
        end)
    end
    return any and src or nil
end

local function memo_job(job, c)
    local m = memo[job.id]
    if not m then
        m = { code = tostring(job.reaction_name) }
        memo[job.id] = m
    end
    m.last = polls
    -- A workshop runs one job at a time, so DF's next item number, read
    -- here, is the line between what it holds now and what this job will
    -- make (making-fuel-binder-watcher.lua, WHERE THIS JOB'S OUTPUT
    -- STARTS: one global read, where a walk of the workshop cost 0.82 ms).
    local bld = nil
    pcall(function() bld = dfhack.job.getHolder(job) end)
    if bld then
        m.bld = bld.id
        m.mark = df.global.item_next_id
    end
    -- The inputs, until the job is being worked: by then every item is
    -- attached, and nothing more needs reading.
    if #c.inherits > 0 and not m.frozen then
        local src = read_sources(job, c)
        if src then m.src = src end
        local working = false
        pcall(function() working = job.flags.working end)
        if working and m.src then m.frozen = true end
    end
end

-- ==========================================
-- 1. OUTPUTS FOLLOW INPUTS
-- ==========================================
-- The material an input of material (mt, mi) gives a product: its own,
-- or its material product by pcode. nil when it has no such product.
local function target_of(mt, mi, pcode)
    if not pcode or pcode == '' then return mt, mi end
    local tt, ti = nil, nil
    pcall(function()
        local rp = dfhack.matinfo.decode(mt, mi).material.reaction_product
        for i = 0, #rp.id - 1 do
            if rp.id[i].value == pcode then
                tt, ti = rp.material.mat_type[i], rp.material.mat_index[i]
                break
            end
        end
    end)
    return tt, ti
end

-- U units shared by weight, largest remainder: every unit is placed,
-- and a tie goes to the earlier entry. shares = { { w }... }, returns
-- the units each gets, by position.
local function apportion(shares, U)
    local W = 0
    for _, s in ipairs(shares) do W = W + s.w end
    local out, rem, given = {}, {}, 0
    for i, s in ipairs(shares) do
        local exact = (W > 0) and (U * s.w / W) or 0
        local n = math.floor(exact)
        out[i] = n
        given = given + n
        rem[#rem + 1] = { i = i, frac = exact - n }
    end
    table.sort(rem, function(a, b)
        if a.frac ~= b.frac then return a.frac > b.frac end
        return a.i < b.i
    end)
    local k = 1
    while given < U and #rem > 0 do
        out[rem[k].i] = out[rem[k].i] + 1
        given = given + 1
        k = k % #rem + 1
    end
    return out
end

-- Which input each output goes to: the input still owed the most units
-- takes the next item, whole (ties to the earlier input). Items are
-- { n = units }, inputs { vol }. Returns the plan, by item position,
-- and the units each input was owed.
local function plan_share(items, inputs)
    local U = 0
    for _, it in ipairs(items) do U = U + it.n end
    local shares = {}
    for i, inp in ipairs(inputs) do shares[i] = { w = inp.vol } end
    local owed = apportion(shares, U)
    local given = {}
    for i = 1, #inputs do given[i] = 0 end
    local plan = {}
    for k, it in ipairs(items) do
        local best, need = 1, -math.huge
        for i = 1, #inputs do
            local left = owed[i] - given[i]
            if left > need then best, need = i, left end
        end
        plan[k] = best
        given[best] = given[best] + it.n
    end
    return plan, owed
end

local function share_out(m, c, items)
    for _, h in ipairs(c.inherits) do
        -- A measured product is sized per material in 3 instead.
        local src = (not h.measured) and m.src and m.src[h.ri]
        if src and #src > 1 then
            -- The inputs as the product's materials, in collection order.
            -- Two inputs whose products coincide count as one.
            local inputs = {}
            for _, e in ipairs(src) do
                local tt, ti = target_of(e.mt, e.mi, h.pcode)
                if tt then
                    local hit = nil
                    for _, x in ipairs(inputs) do
                        if x.mt == tt and x.mi == ti then hit = x break end
                    end
                    if hit then
                        hit.vol = hit.vol + e.vol
                    else
                        inputs[#inputs + 1] = { mt = tt, mi = ti, vol = e.vol }
                    end
                end
            end
            if #inputs > 1 then
                -- DF gave every output the first input's material. Only
                -- outputs still wearing it are shared out (WHEN, header).
                local first = inputs[1]
                local outs, units, off = {}, {}, 0
                for _, it in ipairs(items) do
                    local mine = false
                    pcall(function()
                        mine = it:getType() == h.itype
                            and (h.isub < 0 or it:getSubtype() == h.isub)
                    end)
                    if mine then
                        local same = false
                        pcall(function()
                            same = it.mat_type == first.mt and it.mat_index == first.mi
                        end)
                        if same then
                            outs[#outs + 1] = it
                            units[#units + 1] = { n = stack_of(it) }
                        else
                            off = off + 1
                        end
                    end
                end
                if off > 0 then
                    log_once('off:' .. m.code, 'DETAIL', ('%s: %d output(s) no longer wore'
                        .. ' the first input\'s material when the job completed, so'
                        .. ' something changed them first; they are left as they'
                        .. ' are.'):format(m.code, off), 'SHARE')
                end
                if #outs > 0 then
                    local plan, owed = plan_share(units, inputs)
                    local total = 0
                    for _, x in ipairs(units) do total = total + x.n end
                    for k, it in ipairs(outs) do
                        local to = inputs[plan[k]]
                        pcall(function()
                            if it.mat_type ~= to.mt or it.mat_index ~= to.mi then
                                it.mat_type, it.mat_index = to.mt, to.mi
                            end
                        end)
                    end
                    -- What each material was owed, in collection order.
                    local parts = {}
                    for i, inp in ipairs(inputs) do
                        parts[#parts + 1] = ('%s %d'):format(mat_name(inp.mt, inp.mi), owed[i])
                    end
                    log('DETAIL', ('%s: %d output unit(s) shared by what went in: %s.')
                        :format(m.code, total, table.concat(parts, ', ')), 'SHARE')
                end
            end
        end
    end
end

-- ==========================================
-- 3. MEASURED STACKS
-- ==========================================
-- A measured product's units are what its source measured, in the
-- product tool's own unit (the volume of one item DF made, before any
-- stack is set): the source's volume of each material, less what the
-- job's other products from the same source took (a crusher's gravel),
-- plus what this building banked of that material last time. What is
-- left below one unit banks again, per building, tool and material, in
-- refinish-persist-banks (REFINISH_OUTPUTS), so nothing is lost and no
-- material pays for another.
-- DF's count is how many stacks: a boulder's dust from the grinder comes
-- in four, so four jobs can draw from it at once, since a job holds a
-- whole stack (RM_Stacked_Tools.md). Several materials in the source get
-- stacks of their own, in proportion, at least one each. DF's items are
-- reused as the stacks; more are made in the workshop when the materials
-- need them, and any left over go.
-- Binder's way of stacking (making-fuel-binder-watcher.lua, MAKING: SET
-- THE STACKS), with the source split by material and the remainder kept.
local bank = {}

local function bank_key(tool, mt, mi, bld)
    return ('BV:%s:%s:%s@%s'):format(tostring(tool), tostring(mt), tostring(mi), tostring(bld))
end

-- A tool item of sub in (mt, mi), placed in bld as the byproduct service
-- places its payouts (refinish-job-byproducts.lua, make). nil on failure.
local function make_stack(sub, mt, mi, bld)
    local it = nil
    pcall(function()
        local list = dfhack.items.createItem(df.global.world.units.active[0],
            df.item_type.TOOL, sub, mt, mi)
        it = type(list) == 'table' and list[1] or nil
    end)
    if not it then return nil end
    local placed = false
    pcall(function()
        placed = dfhack.items.moveToBuilding(it, bld, df.building_item_role_type.TEMP, false)
    end)
    if not placed then
        pcall(function()
            dfhack.items.moveToGround(it, { x = bld.centerx, y = bld.centery, z = bld.z })
        end)
    end
    return it
end

local function size_measured(m, c, items, bld)
    for _, h in ipairs(c.inherits) do
        local src = h.measured and m.src and m.src[h.ri]
        if src then
            -- DF's items of this product: the stacks it asked for.
            local mine = {}
            for _, it in ipairs(items) do
                local yes = false
                pcall(function() yes = it:getType() == h.itype and it:getSubtype() == h.isub end)
                if yes then mine[#mine + 1] = it end
            end
            local unit = nil
            if #mine > 0 then
                pcall(function() unit = mine[1]:getVolume() / stack_of(mine[1]) end)
            end
            if unit and unit > 0 then
                -- The source, by the product's material, in collection order.
                local avail, order = {}, {}
                for _, e in ipairs(src) do
                    local tt, ti = target_of(e.mt, e.mi, h.pcode)
                    if tt then
                        local k = tt .. ':' .. ti
                        if not avail[k] then
                            avail[k] = { mt = tt, mi = ti, vol = 0 }
                            order[#order + 1] = k
                        end
                        avail[k].vol = avail[k].vol + e.vol
                    end
                end
                -- Less what the job's other products took from it.
                for _, o in ipairs(c.inherits) do
                    if o ~= h and o.ri == h.ri then
                        for _, it in ipairs(items) do
                            pcall(function()
                                if it:getType() == o.itype
                                        and (o.isub < 0 or it:getSubtype() == o.isub) then
                                    local k = it.mat_type .. ':' .. it.mat_index
                                    if avail[k] then avail[k].vol = avail[k].vol - it:getVolume() end
                                end
                            end)
                        end
                    end
                end
                -- Units per material, the remainder banked.
                local per, total = {}, 0
                for _, k in ipairs(order) do
                    local a = avail[k]
                    local key = bank_key(h.tool, a.mt, a.mi, m.bld)
                    local have = math.max(0, a.vol) + (tonumber(bank[key]) or 0)
                    local n = math.floor(have / unit)
                    bank[key] = have - n * unit
                    if n > 0 then
                        per[#per + 1] = { mt = a.mt, mi = a.mi, n = n }
                        total = total + n
                    end
                end
                -- Stacks: DF's count, shared by units, at least one per
                -- material and never more than its units.
                local S = #mine
                local stacks = {}
                for _, p in ipairs(per) do
                    local s = (#per == 1) and S or math.floor(S * p.n / total + 0.5)
                    s = math.max(1, math.min(s, p.n))
                    local each, extra = math.floor(p.n / s), p.n % s
                    for i = 1, s do
                        stacks[#stacks + 1] = { mt = p.mt, mi = p.mi, n = each + (i <= extra and 1 or 0) }
                    end
                end
                -- DF's items carry the stacks; more are made, the rest go.
                local made, parts = 0, {}
                for i, st in ipairs(stacks) do
                    local it = mine[i] or make_stack(h.isub, st.mt, st.mi, bld)
                    if it then
                        pcall(function()
                            it.mat_type, it.mat_index = st.mt, st.mi
                            it.stack_size = st.n
                        end)
                        made = made + st.n
                    end
                end
                for i = #stacks + 1, #mine do
                    pcall(function() dfhack.items.remove(mine[i]) end)
                end
                for _, p in ipairs(per) do
                    parts[#parts + 1] = ('%s %d'):format(mat_name(p.mt, p.mi), p.n)
                end
                log('DETAIL', ('%s: %s measured at %s a unit: %s, in %d stack(s).'):format(
                    m.code, tostring(h.tool), ('%g'):format(unit),
                    #parts > 0 and table.concat(parts, ', ') or 'nothing yet, all banked',
                    #stacks), 'MEASURE')
            elseif #mine == 0 then
                log_once('nostack:' .. m.code, 'DETAIL', ('%s: DF made none of %s, so there'
                    .. ' was nothing to size.'):format(m.code, tostring(h.tool)), 'MEASURE')
            end
        end
    end
end

-- ==========================================
-- 2. STACKS
-- ==========================================
-- The job's new items of a stacked tool, merged per material: the first
-- keeps the total, the rest go. One item is a stack of one already.
-- Runs after 1 and 3, so it merges the materials as they ended up.
local function merge(m, c, items)
    local set = stacked_set()
    if not next(set) then return end
    local groups, order = {}, {}
    for _, it in ipairs(items) do
        pcall(function()
            -- A measured product's stacks were set in 3; never merged.
            if it:getType() == df.item_type.TOOL and set[it:getSubtype()]
                    and not c.measured_subs[it:getSubtype()] then
                local key = it:getSubtype() .. ':' .. it.mat_type .. ':' .. it.mat_index
                if not groups[key] then
                    groups[key] = {}
                    order[#order + 1] = key
                end
                table.insert(groups[key], it)
            end
        end)
    end
    for _, key in ipairs(order) do
        local g = groups[key]
        if #g > 1 then
            local total = 0
            for _, it in ipairs(g) do total = total + stack_of(it) end
            if pcall(function() g[1].stack_size = total end) then
                for i = 2, #g do pcall(function() dfhack.items.remove(g[i]) end) end
                local name = '?'
                pcall(function() name = dfhack.items.getDescription(g[1], 0) end)
                log('DETAIL', ('%s: %d item(s) merged into %s.'):format(m.code, #g,
                    tostring(name)), 'STACK')
            end
        end
    end
end

-- ==========================================
-- COMPLETION
-- ==========================================
-- The job's new items: in its workshop, numbered at or above the mark,
-- oldest first.
local function new_items(m)
    local out = {}
    local bld = m.bld and df.building.find(m.bld) or nil
    if not bld then return out end
    for _, ci in ipairs(bld.contained_items) do
        local it = ci.item
        if it and (not m.mark or it.id >= m.mark) then out[#out + 1] = it end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function on_completed(job)
    local m = nil
    pcall(function() m = memo[job.id] end)
    if not m then return end
    memo[job.id] = nil
    local ok, err = pcall(function()
        local c = classes[m.code]
        if not c then return end
        local items = new_items(m)
        if #items == 0 then return end
        share_out(m, c, items)
        if next(c.measured_subs) then
            local bld = m.bld and df.building.find(m.bld) or nil
            if bld then size_measured(m, c, items, bld) end
            items = new_items(m)   -- 3 may have made or removed some
        end
        if c.tools then merge(m, c, items) end
    end)
    if not ok then log('ERROR', 'completion failed: ' .. tostring(err), 'COMPLETE') end
end

-- ==========================================
-- WHO WALKS THE LIST
-- ==========================================
-- RM's dispatcher walks the job list for every subscriber and hands this
-- file only custom reaction jobs. serve() is the work either way; poll()
-- is this file's own walk, for an RM without a dispatcher.
local CUSTOM = df.job_type.CustomReaction
local function is_custom(_, job_type) return job_type == CUSTOM end

local function serve(jobs)
    polls = polls + 1
    for _, job in ipairs(jobs) do
        local code = nil
        pcall(function() code = tostring(job.reaction_name) end)
        local c = code and classify(code)
        if c then memo_job(job, c) end
    end
    for id, m in pairs(memo) do
        if polls - (m.last or polls) > GRACE_POLLS then memo[id] = nil end
    end
end

local function ready()
    return dfhack.isMapLoaded() and _G.refinish_active
end

local function on_dispatch(jobs)
    if not ready() then return end
    local ok, err = pcall(serve, jobs)
    if not ok then log_once('poll', 'ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

local function poll()
    if not ready() then return end
    local ok, err = pcall(function()
        local jobs = {}
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == CUSTOM then jobs[#jobs + 1] = job end
        end
        serve(jobs)
    end)
    if not ok then log_once('poll', 'ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

-- ==========================================
-- START AND STOP
-- ==========================================
function start()
    memo, classes, polls, said = {}, {}, 0, {}
    stacked, stacked_for, stacked_len = {}, nil, -1
    declared, declared_for = {}, nil
    -- The remainders below one unit (3), saved with the fort. reqscript
    -- here only, never on a poll (about 2 ms a call, engine notes).
    local ok_b, banks = pcall(reqscript, 'refinish-persist-banks')
    if ok_b and banks and banks.open then
        bank = banks.open('REFINISH_OUTPUTS')
    else
        bank = {}
        log('WARNING', 'refinish-persist-banks did not load; measured remainders are'
            .. ' kept for this session only.', 'BANK')
    end
    eventful.onJobCompleted[KEY] = on_completed
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    -- ---- AND EVERY UNIT OF A WORK ORDER ----
    -- DFHack reports a work order's job once, at the order's last unit;
    -- RM's job units service reports every unit on the tick it finishes,
    -- to this same handler (refinish-job-units.lua). Without the service,
    -- DFHack's report is the only one, as before.
    local units = _G.refinish_job_units_api
    if units and units.subscribe then units.subscribe(KEY, on_completed) end
    -- The dispatcher when RM has one; this file's own loop otherwise.
    -- Whichever runs, the other is cleared.
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(KEY,
            { every = EVERY, jobs = is_custom, fn = on_dispatch, paused = true }) then
        repeatUtil.cancel(KEY)
    else
        repeatUtil.scheduleEvery(KEY, EVERY, 'frames', poll)
    end
    log('DETAIL', 'started: outputs follow what went in, and stacked tools merge'
        .. ' per material.', 'START')
end

function stop()
    repeatUtil.cancel(KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(KEY) end
    eventful.onJobCompleted[KEY] = nil
    local units = _G.refinish_job_units_api
    if units and units.unsubscribe then units.unsubscribe(KEY) end
    memo = {}
    log('DETAIL', 'stopped.', 'STOP')
end

-- ==========================================
-- THE READOUT (2026-10-05)
-- ==========================================
-- The remainders below one unit (3), as rows for RM's bank readout
-- (refinish-bank-readout.lua, PROVIDERS): one row per product and
-- material this building holds a remainder of, and each measured
-- product made here that holds none as one row at zero (ALWAYS VISIBLE,
-- below). Keys are BV:<tool id>:<mat type>:<mat index>@<building>
-- (bank_key), in volume; one unit is the tool's size, the volume of one
-- of its items, so a row reads as a share of the next item: "willow
-- kindling".
local readout_tools = {}   -- tool id -> { name, size }, once found
local function readout_tool(id)
    local d = readout_tools[id]
    if d then return d end
    pcall(function()
        for _, t in ipairs(df.global.world.raws.itemdefs.tools) do
            if t.id == id then d = { name = t.name, size = t.size }; break end
        end
    end)
    readout_tools[id] = d
    return d
end

-- ---- ALWAYS VISIBLE (2026-10-05) ----
-- A building that banks shows its bank always (THE DISPLAY LAW,
-- making-fuel-bank-readout.lua). This bank is kept per material, and no
-- list can hold every material a building might ever grind, so the law is
-- kept per PRODUCT: every measured product a building's reactions make is
-- a row, one per material once a material holds a remainder, and one
-- under the product's own name at zero while none does. Measured is what
-- the MEASURED STACKS section says: a grinder's tool (MEASURE_PREFIX) or
-- a product declared measure = true (declared_set). A product declared
-- whole = true as well gets no zero row: its measure always comes out
-- whole (the crushers' dust, 25 from every boulder), so it never banks,
-- and a row that is always empty is not a bank (2026-10-06). Were it ever
-- to leave a remainder, that shows like any other. Found once per kind
-- of building, [<type>:<subtype>:<custom>] = tool ids, and kept until the
-- reactions change: a data cycle or a JIT grinder minted in play changes
-- the count, and the list is found again.
local measured_at = { n = -1, by = {} }

local function measured_tools(bld)
    local t, s, c = -1, -1, -1
    pcall(function() t = bld:getType() end)
    pcall(function() s = bld:getSubtype() end)
    pcall(function() c = bld:getCustomType() end)
    local rxs = df.global.world.raws.reactions.reactions
    if measured_at.n ~= #rxs or measured_at.reg ~= _G.refinish_module_registry then
        measured_at = { n = #rxs, reg = _G.refinish_module_registry, by = {} }
    end
    local kind = ('%d:%d:%d'):format(t, s, c)
    local list = measured_at.by[kind]
    if list then return list end
    list = {}
    local seen = {}
    local wanted = declared_set()
    local defs = df.global.world.raws.itemdefs.tools
    pcall(function()
        for _, rx in ipairs(rxs) do
            local code = tostring(rx.code)
            local mine = wanted[code]
            local grinder = code:find(MEASURE_PREFIX, 1, true) == 1
            -- Only a measuring reaction is asked where it runs, so the
            -- walk costs a string test for every other reaction.
            if mine or grinder then
                local here = false
                local b = rx.building
                for i = 0, #b.type - 1 do
                    if b.type[i] == t and b.subtype[i] == s
                       and (c < 0 or b.custom[i] == c) then
                        here = true
                        break
                    end
                end
                if here then
                    for _, p in ipairs(rx.products) do
                        pcall(function()
                            if p.item_type == df.item_type.TOOL then
                                local id = tostring(defs[p.item_subtype].id)
                                local ok = grinder
                                for _, w in ipairs(mine or {}) do
                                    -- Declared whole: it never banks, so no row.
                                    if w.tool == id and not w.whole then ok = true end
                                end
                                if ok and not seen[id] then
                                    seen[id] = true
                                    list[#list + 1] = id
                                end
                            end
                        end)
                    end
                end
            end
        end
    end)
    measured_at.by[kind] = list
    return list
end

-- A material's short name: the tree, the creature, the stone.
local function readout_mat(mt, mi)
    local name = nil
    pcall(function()
        local m = dfhack.matinfo.decode(mt, mi)
        if m.plant then name = m.plant.name
        elseif m.creature then name = m.creature.name[0]
        else name = m.material.state_name.Solid end
    end)
    return name
end

local function readout(bld)
    if not (bld and bank) then return nil end
    local suffix = '@' .. tostring(bld.id)
    local rows, held = {}, {}
    pcall(function()
        for k, v in pairs(bank) do
            if type(k) == 'string' and k:sub(-#suffix) == suffix then
                local tool, mt, mi = k:match('^BV:([^:]+):(%-?%d+):(%-?%d+)@%d+$')
                local def = tool and readout_tool(tool)
                if def and (def.size or 0) > 0 then
                    held[tool] = true
                    local mat = readout_mat(tonumber(mt), tonumber(mi)) or '?'
                    local bal = tonumber(v) or 0
                    rows[#rows + 1] = { key = 'RM_OUTPUTS:' .. k,
                                        label = mat .. ' ' .. def.name,
                                        value = bal / def.size, full = bal >= def.size }
                end
            end
        end
    end)
    -- Every measured product made here that holds nothing: one row under
    -- its own name, at zero (ALWAYS VISIBLE).
    for _, tool in ipairs(measured_tools(bld)) do
        if not held[tool] then
            local def = readout_tool(tool)
            if def and (def.size or 0) > 0 then
                rows[#rows + 1] = { key = 'RM_OUTPUTS:' .. tool .. suffix,
                                    label = def.name, value = 0, full = false }
            end
        end
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(a, b) return a.label < b.label end)
    return { title = 'output bank', rows = rows }
end
_G.refinish_bank_providers = _G.refinish_bank_providers or {}
_G.refinish_bank_providers.rm_outputs = { order = 40, fn = readout }

-- For the mock tests and anything that wants the arithmetic.
_G.refinish_outputs_math = { apportion = apportion, plan_share = plan_share }