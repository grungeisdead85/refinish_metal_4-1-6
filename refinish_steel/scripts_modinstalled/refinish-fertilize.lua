--@ module = true
-- refinish-fertilize.lua
-- ==========================================
-- RM SERVICE: DF'S FERTILIZE JOB TAKES ANY FERTILIZER
-- ==========================================
-- WHAT IT DOES
-- A farm plot set to fertilize gets FertilizeField jobs from DF, one per
-- unit the plot needs, each asking for a potash bar. This opens them to
-- every fertilizer: a TOOL whose material carries the FERTILIZER class.
-- RM's own are sylvite and saltpeter dust (THE CLASS, below) and gall,
-- whose material is RM's (refinish-core-payload.lua); a module adds its
-- own by giving its material the class, as Making Fuel does for dung,
-- bone meal and ammonium sulfate. Byproduct fertilizer goes first and potash only
-- covers what it cannot (THE GAP), since potash has other uses (pearlash
-- for clear and crystal glass) and the point is to spend the byproducts.
--
-- MEASURED (refinish-fertilize-probe, 2026-10-06, an 80 tile plot in a
-- fort with no potash at all; the log is the record):
--   * DF posts a plot's jobs with no potash anywhere in the fort: 21 of
--     them, floor(80/4)+1, the plot's max_fertilization, which DF sets
--     when the plot is built. It posts them again by itself at each season
--     change, when the plot's current_fertilization goes back to 0, and
--     not again within a season.
--   * Each job asks for BAR + builtin POTASH, quantity 1, vector BAR,
--     with nothing attached when it appears. Widened to TOOL and a class,
--     the farmers fetched TOOL stacks of that class and the jobs
--     completed.
--   * DF credits the plot with every unit in the stack it brings, and
--     eats the whole stack: a stack of five dust gave +5, a potash bar +1.
--     It does not stop at the plot's max: a plot needing 9 took 15
--     (2026-10-06, refinish-fertilize, plot 9).
--   * Cutting a stack a farmer has claimed makes DF fetch more for the
--     same job: job 824's sylvite was cut from 12 to 9 and the job then
--     took a stack of 6 gall crust as well (same run). A claim is never
--     cut since.
--   * A job that finds nothing cancels with an announcement: "Needs flux
--     tool" for a filter asking for a FLUX tool, "Needs potash" for DF's
--     own.
--
-- HOW
--   1. OPEN. Each new fertilize job, at posting (eventful's job event),
--      before any farmer can claim an item. Its potash filter asks for a
--      TOOL of the FERTILIZER class instead, vector IN_PLAY, field for
--      field as making-fuel-access.lua widens DF's fuel filter. TOOL,
--      because the class sits on a material and a sylvite boulder must
--      never be carried to a field. THE GAP: the fertilizer stacks lying
--      free in the fort are counted against the plot's need first, and
--      only what they cannot cover is left to potash, as many jobs left as
--      DF wrote them as the gap and the free bars allow. A fort with
--      enough byproduct fertilizer spends no potash at all.
--   2. SETTLE. DF eats the whole stack and credits all of it, past the
--      plot's max, and a claimed stack cannot be cut (MEASURED). So a
--      claim goes through whole, and when the job ends a plot credited
--      past its max is set back to it, and what it could not take is
--      handed back into the plot as its product, for a hauler to take
--      (THE HAND BACK).
--   3. CLEAR. A plot already covered, by its fertilization and the stacks
--      its farmers have claimed, has its remaining jobs removed, rather
--      than leaving them to fetch what it cannot take or to cancel with an
--      announcement each. A plot that fills is said once a season, checked
--      when its last job ends as well, since a full plot has no jobs left
--      to be seen with (missed until 2026-10-06).
--
-- THE CLASS. FERTILIZER is given at start, through RM's class grants
-- (refinish-material-classes.lua), to SYLVITE and SALTPETER: minerals the
-- vanilla raws themselves describe as fertilizer in their comments, and
-- which nothing in vanilla uses. Given classes are taken back before every
-- save with all the others. Being economic stones now is accepted for a
-- legitimate class (refinish-material-classes.lua, ECONOMIC).
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local utils      = require('utils')

local KEY      = 'refinish-fertilize'
-- ---- EVERY FIVE FRAMES, NOT EVERY FRAME (2026-10-31) ----
-- This was 1, the only subscriber asking the dispatcher for jobs on every
-- frame, so the whole job list was walked on every frame, paused or not,
-- to find fertilize jobs that are usually not there. MEASURED on a 161
-- dwarf fort: the dispatcher's own row, mostly that walk, at 57.8 ms/sec
-- paused and 32.6 to 39.6 unpaused, against 0.05 ms a call for this
-- file's own pass. Every other job subscriber is on 5 frames or slower,
-- so at 5 this shares the walk fuel access already pays for. Opening a
-- job still happens at posting (the job event), and a claim takes a
-- farmer's walk to the stack and back before DF eats it, far longer than
-- five frames, so the pass still sees every claim (THE HAND BACK).
local EVERY    = 5                     -- frames; only fertilize jobs are handed over
local CLASS    = 'FERTILIZER'
local OWNER    = 'REFINISH_FERTILIZE'  -- the grant's owner, in the log
local MINERALS = { 'SYLVITE', 'SALTPETER' }

local FERT   = df.job_type.FertilizeField
local POTASH = df.builtin_mats.POTASH

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- The house grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed by
-- refinish-log. SUBJECT is PLOT_<id> or JOB_<id>. INFO is a plot filled
-- for the season; DETAIL is every job opened, stack trimmed and job
-- cleared; WARNING is something that did not go as measured.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'FERTILIZE'
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
-- STATE
-- ==========================================
-- Ids and numbers only, never a job or an item object: a job is good only
-- for the tick it is handed out in (refinish-loop-dispatch).
--   decided[job id]  what OPEN did with it: 'open', 'potash', 'held'
--                    (something was already claimed) or 'left' (no
--                    potash filter: opened before, by this file or a
--                    save). Dropped once the job is gone.
--   waiting[job id]  the plot id of a job left for potash that has not
--                    claimed a bar yet: bars THE GAP has promised away.
--   held[job id]     { pid, pos, items }: its plot, where it stands, and
--                    what it last held (type, subtype, material, units),
--                    read every pass, so that what a finished job took is
--                    known after DF has eaten it (THE HAND BACK).
--   posted[plot id]  { open, potash, need, covered, how }, this tick's
--                    openings, said in one line per plot by the next pass.
--   full[key]        plot id and season already said to be full.
local decided, waiting, held, posted, full = {}, {}, {}, {}, {}

-- ==========================================
-- READERS
-- ==========================================
local function asks_potash(e)
    local hit = false
    pcall(function() hit = e.mat_type == POTASH end)
    return hit
end

-- A stack's units; anything without a stack is one.
local function units_of(it)
    local n = 1
    pcall(function() n = it:getStackSize() end)
    if type(n) ~= 'number' or n < 1 then n = 1 end
    return n
end

local function plot_of(job)
    local p = nil
    pcall(function()
        local b = dfhack.job.getHolder(job)
        if b and df.building_farmplotst:is_instance(b) then p = b end
    end)
    return p
end

local function claimed(job)
    local out = {}
    pcall(function()
        for _, ir in ipairs(job.items) do
            if ir.item then out[#out + 1] = ir.item end
        end
    end)
    return out
end

-- A potash bar a farmer could still take: not forbidden, not claimed by a
-- job, not a trader's, not built into anything, not marked to go.
local function free_potash()
    local n = 0
    pcall(function()
        for _, it in ipairs(df.global.world.items.other.BAR) do
            if it.mat_type == POTASH then
                local f = it.flags
                if not (f.forbid or f.in_job or f.garbage_collect or f.removed
                        or f.trader or f.construction or f.in_building
                        or f.hostile or f.dump or f.melt) then
                    n = n + 1
                end
            end
        end
    end)
    return n
end

local function item_words(it)
    local d = '?'
    pcall(function() d = dfhack.items.getReadableDescription(it) end)
    return d
end

-- ==========================================
-- 1. OPEN
-- ==========================================
-- Units of fertilizer a farmer could still take: TOOL stacks whose
-- material carries the class, free on the same terms as a potash bar.
-- Each material is asked about once per count.
local function free_fertilizer()
    local n, known = 0, {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.other.TOOL) do
            local f = it.flags
            if not (f.forbid or f.in_job or f.garbage_collect or f.removed
                    or f.trader or f.construction or f.in_building
                    or f.hostile or f.dump or f.melt) then
                local key = tostring(it.mat_type) .. ':' .. tostring(it.mat_index)
                local yes = known[key]
                if yes == nil then
                    yes = false
                    pcall(function()
                        local info = dfhack.matinfo.decode(it)
                        for _, rc in ipairs(info.material.reaction_class) do
                            if rc and rc.value == CLASS then yes = true break end
                        end
                    end)
                    known[key] = yes
                end
                if yes then n = n + units_of(it) end
            end
        end
    end)
    return n
end

-- THE GAP. Counted once per game tick, because DF posts a plot's jobs
-- together, and shared by every plot posting in that tick: the free
-- fertilizer units, and the free bars less the jobs already waiting on
-- one. Each plot's first job of the tick makes its plan: the fertilizer
-- covers as much of the plot's need as it can and is set aside for it,
-- the rest is the gap, and as many of the plot's jobs as the gap and the
-- bars allow are left for potash. A paused tick keeps its count, so plots
-- set to fertilize one after another while paused share the same stock.
local budget, plans = nil, {}   -- budget { at, fert, potash }; plans[at:pid]

local function tick_key()
    return tostring(df.global.cur_year) .. ':' .. tostring(df.global.cur_year_tick)
end

local function plan_for(p, pid)
    local key = tick_key()
    if not budget or budget.at ~= key then
        local promised = 0
        for _ in pairs(waiting) do promised = promised + 1 end
        budget = { at = key, fert = free_fertilizer(), potash = free_potash() - promised }
        plans = {}
    end
    local pk = key .. ':' .. tostring(pid)
    local plan = plans[pk]
    if plan then return plan end
    local need = 0
    pcall(function() need = p.max_fertilization - p.current_fertilization end)
    if type(need) ~= 'number' or need < 0 then need = 0 end
    local covered = math.min(budget.fert, need)
    budget.fert = budget.fert - covered
    local keep = math.max(0, math.min(budget.potash, need - covered))
    budget.potash = budget.potash - keep
    plan = { keep = keep, kept = 0, need = need, covered = covered }
    plans[pk] = plan
    return plan
end

-- The widened filter, in the order it is written.
local function wide_fields()
    return {
        { 'item_type',      df.item_type.TOOL },
        { 'item_subtype',   -1 },
        { 'mat_type',       -1 },
        { 'mat_index',      -1 },
        { 'reaction_class', CLASS },
        { 'vector_id',      df.job_item_vector_id.IN_PLAY },
    }
end

local function note_posted(pid, kind, plan, how)
    local p = posted[pid]
    if not p then
        p = { open = 0, potash = 0, need = plan.need, covered = plan.covered, how = how }
        posted[pid] = p
    end
    p[kind] = p[kind] + 1
end

-- how: 'posted' at the job event, 'found' when a pass meets a job this
-- file has not decided (a save, a data cycle).
local function open_job(job, how)
    if decided[job.id] then return end
    local p = plot_of(job)
    local pid = p and p.id or -1

    local has_potash = false
    pcall(function()
        for _, e in ipairs(job.job_items.elements) do
            if asks_potash(e) then has_potash = true end
        end
    end)
    if not has_potash then decided[job.id] = 'left' return end
    -- A claim made before this file saw the job stands: it can only be
    -- potash, which is a fertilizer.
    if #claimed(job) > 0 then decided[job.id] = 'held' return end

    local plan = plan_for(p, pid)
    if plan.kept < plan.keep then
        plan.kept = plan.kept + 1
        waiting[job.id] = pid
        decided[job.id] = 'potash'
        note_posted(pid, 'potash', plan, how)
        return
    end

    -- Every write its own pcall, and a failed one named, so a field that
    -- did not take cannot pass silently.
    local failed = {}
    pcall(function()
        for _, e in ipairs(job.job_items.elements) do
            if asks_potash(e) then
                for _, fv in ipairs(wide_fields()) do
                    if not pcall(function() e[fv[1]] = fv[2] end) then
                        failed[#failed + 1] = fv[1]
                    end
                end
            end
        end
    end)
    -- As the fuel widening did: ask DF to look at the job again.
    pcall(function() job.recheck_cntdn = 0 end)
    decided[job.id] = 'open'
    note_posted(pid, 'open', plan, how)
    if #failed > 0 then
        log('WARNING', ('opening the filter failed on %s; the job may still ask for'
            .. ' potash'):format(table.concat(failed, ', ')), 'JOB_' .. tostring(job.id))
    end
end

-- One line per plot for what the last tick posted.
local function say_posted()
    for pid, p in pairs(posted) do
        log('DETAIL', ('%d fertilize job(s) %s: %d take any fertilizer, %d kept for potash;'
            .. ' the plot needs %d, fertilizer on hand covers %d'):format(p.open + p.potash,
            p.how == 'found' and 'found open' or 'posted', p.open, p.potash, p.need,
            p.covered), 'PLOT_' .. tostring(pid))
    end
    posted = {}
end

-- ==========================================
-- 2. SETTLE: THE HAND BACK
-- ==========================================
-- What a finished job took past its plot's need, made again as one stack
-- of what it was, and put into the plot in the TEMP role, the one a
-- workshop holds its products in until a hauler takes them, as RM pays
-- every byproduct (refinish-job-byproducts.lua). Never loose on the
-- ground: a player reads that as the item having vanished. The ground
-- only if the plot will not take it, said once. Made the way the stacked
-- fuel slot hands back what a furnace did not owe (making-fuel-access.lua,
-- hand_back_stack): createItem by the recorded type, subtype and
-- material, then stack_size. true when made.
local function hand_back(r, n, pos, plot)
    local it = nil
    pcall(function()
        local list = dfhack.items.createItem(df.global.world.units.active[0],
            r.t, r.st, r.mt, r.mi)
        it = type(list) == 'table' and list[1] or nil
    end)
    if not it then return false end
    if n > 1 then pcall(function() it.stack_size = n end) end
    local placed = false
    if plot then
        pcall(function()
            placed = dfhack.items.moveToBuilding(it, plot,
                df.building_item_role_type.TEMP, false)
        end)
    end
    if not placed then
        log_once('ground', 'WARNING', 'a farm plot would not take a handed back stack,'
            .. ' so it went on the ground where the job was done', 'HANDBACK')
        if pos then pcall(function() dfhack.items.moveToGround(it, pos) end) end
    end
    return true
end

-- A job's plot, position and claim, read every pass while it is open.
local function remember(job, pid)
    local rec = held[job.id]
    if not rec then
        rec = { pid = pid }
        held[job.id] = rec
    end
    pcall(function() rec.pos = { x = job.pos.x, y = job.pos.y, z = job.pos.z } end)
    local items = {}
    for _, it in ipairs(claimed(job)) do
        pcall(function()
            items[#items + 1] = { t = it:getType(), st = it:getSubtype(),
                mt = it:getMaterial(), mi = it:getMaterialIndex(), n = units_of(it),
                words = item_words(it) }
        end)
    end
    -- An item DF has eaten is gone from the job, so the last claim seen
    -- is kept rather than an empty one.
    if #items > 0 then rec.items = items end
end

local function remove_job(job, why)
    local id = job.id
    local ok, err = pcall(function() dfhack.job.removeJob(job) end)
    if ok then
        log('DETAIL', 'cleared: ' .. why, 'JOB_' .. tostring(id))
    else
        log_once('remove:' .. tostring(err), 'WARNING', ('a fertilize job could not be'
            .. ' removed (%s): %s'):format(why, tostring(err)), 'JOB_' .. tostring(id))
    end
    return ok
end

-- ==========================================
-- 3. THE PLOT'S NEED, AND CLEAR
-- ==========================================
-- Filled for the season: said once per plot and season.
local function say_full(p)
    local maxf, cur = nil, nil
    pcall(function()
        maxf = p.max_fertilization
        cur  = p.current_fertilization
    end)
    if type(maxf) ~= 'number' or maxf <= 0 or type(cur) ~= 'number' or cur < maxf then return end
    local key = tostring(p.id) .. ':' .. tostring(df.global.cur_year) .. ':'
        .. tostring(df.global.cur_season)
    if full[key] then return end
    full[key] = true
    log('INFO', ('fully fertilized for the season (%d of %d)'):format(cur, maxf),
        'PLOT_' .. tostring(p.id))
end

-- need = max_fertilization - current_fertilization, less every unit the
-- plot's farmers have already claimed. Claims are counted in job id
-- order, so the earliest posted job keeps its units: the claim that
-- overshoots is trimmed to what is left, and a claim with nothing left
-- for it is cleared, which releases its stack where it lies. Once the
-- need is met, every job that has claimed nothing is cleared too.
-- Jobs are handed out good for this tick only, so this runs straight
-- through on this tick's list and keeps none of them.
local function fit_plot(p, jobs)
    local maxf, cur = nil, nil
    pcall(function()
        maxf = p.max_fertilization
        cur  = p.current_fertilization
    end)
    if type(maxf) ~= 'number' or maxf <= 0 or type(cur) ~= 'number' then return end
    local pid = p.id
    local need = maxf - cur
    table.sort(jobs, function(a, b) return a.id < b.id end)
    local idle = {}
    for _, job in ipairs(jobs) do
        local items = claimed(job)
        if #items == 0 then
            idle[#idle + 1] = job
        else
            local units = 0
            for _, it in ipairs(items) do units = units + units_of(it) end
            if need <= 0 then
                remove_job(job, ('plot %s is covered, so this claim of %d is released')
                    :format(tostring(pid), units))
            elseif units > need then
                -- Past the need: the claim goes through whole and the rest
                -- comes back when the job ends (SETTLE).
                log_once('over:' .. tostring(job.id), 'DETAIL', ('claims %d unit(s), plot %s'
                    .. ' needs %d: the other %d come back when the job ends'):format(units,
                    tostring(pid), need, units - need), 'JOB_' .. tostring(job.id))
                need = 0
            else
                need = need - units
            end
        end
    end
    if need <= 0 then
        for _, job in ipairs(idle) do
            remove_job(job, ('plot %s is covered'):format(tostring(pid)))
        end
    end
    say_full(p)
end

-- THE HAND BACK, for one plot whose jobs just ended. DF has credited
-- everything they took; past the max, the plot is set back to it and the
-- difference made again from what the jobs held, the last job's last item
-- first, since it is the one that overshot.
local function settle(pid, list)
    local p = nil
    pcall(function() p = df.building.find(pid) end)
    if not p then return end
    local maxf, cur = nil, nil
    pcall(function()
        maxf = p.max_fertilization
        cur  = p.current_fertilization
    end)
    if type(maxf) ~= 'number' or type(cur) ~= 'number' or maxf <= 0 then return end
    if cur > maxf then
        local over = cur - maxf
        if not pcall(function() p.current_fertilization = maxf end) then
            log_once('setback:' .. tostring(pid), 'WARNING', ('plot %s took %d of %d and could'
                .. ' not be set back'):format(tostring(pid), cur, maxf), 'PLOT_' .. tostring(pid))
            return
        end
        local back, given = over, {}
        for i = #list, 1, -1 do
            local rec = list[i].rec
            local items = rec.items or {}
            for k = #items, 1, -1 do
                if back <= 0 then break end
                local r = items[k]
                local n = math.min(back, r.n)
                if hand_back(r, n, rec.pos, p) then
                    back = back - n
                    given[#given + 1] = ('%d from %s'):format(n, tostring(r.words))
                end
            end
        end
        log('DETAIL', ('took %d of %d: set back to %d, %s handed back into the plot'):format(cur,
            maxf, maxf, #given > 0 and table.concat(given, ', ') or 'nothing'),
            'PLOT_' .. tostring(pid))
        if back > 0 then
            log('WARNING', ('%d unit(s) past what the plot needs could not be handed back'):format(back),
                'PLOT_' .. tostring(pid))
        end
    end
    say_full(p)
end

-- ==========================================
-- THE PASS
-- ==========================================
local function serve(jobs)
    say_posted()
    local seen, by_plot = {}, {}
    for _, job in ipairs(jobs) do
        seen[job.id] = true
        -- A job posted before this file started (a save, a data cycle)
        -- is opened here instead of at its event.
        if not decided[job.id] then open_job(job, 'found') end
        -- A bar claimed for a job left for potash is no longer promised.
        if waiting[job.id] and #claimed(job) > 0 then waiting[job.id] = nil end
        local p = plot_of(job)
        remember(job, p and p.id or -1)
        if p then
            local g = by_plot[p.id]
            if not g then
                g = { plot = p, jobs = {} }
                by_plot[p.id] = g
            end
            g.jobs[#g.jobs + 1] = job
        end
    end
    for id in pairs(waiting) do if not seen[id] then waiting[id] = nil end end
    for id in pairs(decided) do if not seen[id] then decided[id] = nil end end
    for _, g in pairs(by_plot) do fit_plot(g.plot, g.jobs) end
    -- Jobs gone since the last pass, by plot, in the order they were
    -- posted: a plot credited past its max is set back and the rest handed
    -- back (SETTLE), and a plot that filled is said, which a full plot
    -- with no jobs left would otherwise never be.
    local ended = {}
    for id, rec in pairs(held) do
        if not seen[id] then
            held[id] = nil
            if rec.pid >= 0 then
                local list = ended[rec.pid] or {}
                list[#list + 1] = { id = id, rec = rec }
                ended[rec.pid] = list
            end
        end
    end
    for pid, list in pairs(ended) do
        table.sort(list, function(a, b) return a.id < b.id end)
        settle(pid, list)
    end
end

-- ==========================================
-- WHO WALKS THE LIST
-- ==========================================
-- RM's dispatcher walks the job list for every subscriber and hands this
-- file only fertilize jobs. poll() is this file's own walk, for an RM
-- without a dispatcher. This file removes jobs (CLEAR), and its predicate
-- is FertilizeField alone, which no other subscriber shares
-- (refinish-loop-dispatch.lua, JOBS ARE ONLY GOOD FOR THE TICK).
local function is_fert(_, job_type) return job_type == FERT end

local function ready()
    return dfhack.isMapLoaded() and _G.refinish_active
end

local function on_dispatch(jobs)
    if not ready() then return end
    local ok, err = pcall(serve, jobs)
    if not ok then log_once('pass', 'ERROR', 'PASS ERROR: ' .. tostring(err), 'POLL') end
end

local function poll()
    if not ready() then return end
    local ok, err = pcall(function()
        local jobs = {}
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == FERT then jobs[#jobs + 1] = job end
        end
        serve(jobs)
    end)
    if not ok then log_once('pass', 'ERROR', 'PASS ERROR: ' .. tostring(err), 'POLL') end
end

-- At posting, before a farmer can claim anything.
local function on_initiated(job)
    if not ready() then return end
    local ok, err = pcall(function()
        if job.job_type == FERT then open_job(job, 'posted') end
    end)
    if not ok then log_once('event', 'ERROR', 'JOB EVENT ERROR: ' .. tostring(err), 'EVENT') end
end

-- ==========================================
-- START AND STOP
-- ==========================================
-- ==========================================
-- ONLY ON REQUEST
-- ==========================================
-- RM is not a fertilizer mod. None of this runs, no class is given and no
-- job is touched, unless a module asks for it: a module that brings
-- fertilizers asks by name at its start and withdraws at its stop
-- (making_fuel.lua does), and the service runs while anyone is asking.
-- RM still starts and stops this file with its other services
-- (refinish_steel.lua), but start only arms it; it engages on a request.
-- Requests live on _G so a reload of this file keeps them, and the API is
-- published at load, so a request made before RM's services start is
-- simply waiting when they do. The minerals' class is given on engaging
-- and taken back with every other grant at RM's stop.
_G.refinish_fertilize_requests = _G.refinish_fertilize_requests or {}
local armed, engaged = false, false

local function asked()
    return next(_G.refinish_fertilize_requests) ~= nil
end

local function engage()
    engaged = true
    decided, waiting, held, posted, full, budget, plans, said =
        {}, {}, {}, {}, {}, nil, {}, {}
    -- THE CLASS, on the minerals. RM's class grants take every given
    -- class back before a save (refinish-material-classes.lua stop, run
    -- first in RM's stop_services), so nothing here has to.
    local api = _G.refinish_class_api
    if api and api.grant then
        local ok, err = pcall(api.grant, OWNER, { class = CLASS, ids = MINERALS })
        if not ok then
            log('WARNING', 'the class could not be given to the minerals: '
                .. tostring(err), 'START')
        end
    else
        log('WARNING', 'RM class grants are not loaded: sylvite and saltpeter are not'
            .. ' fertilizer this session', 'START')
    end
    eventful.onJobInitiated[KEY] = on_initiated
    eventful.enableEvent(eventful.eventType.JOB_INITIATED, 0)
    -- The dispatcher when RM has one; this file's own loop otherwise.
    -- Paused included, so a plot set to fertilize while paused is
    -- opened before the game runs.
    local dapi = _G.refinish_dispatch_api
    if dapi and dapi.subscribe and dapi.subscribe(KEY,
            { every = EVERY, jobs = is_fert, fn = on_dispatch, paused = true }) then
        repeatUtil.cancel(KEY)
    else
        repeatUtil.scheduleEvery(KEY, EVERY, 'frames', poll)
    end
    log('DETAIL', 'started: fertilize jobs take any fertilizer; potash covers only the'
        .. ' gap.', 'START')
end

local function disengage()
    engaged = false
    repeatUtil.cancel(KEY)
    local dapi = _G.refinish_dispatch_api
    if dapi and dapi.unsubscribe then dapi.unsubscribe(KEY) end
    eventful.onJobInitiated[KEY] = nil
    decided, waiting, held, posted, budget, plans = {}, {}, {}, {}, nil, {}
    log('DETAIL', 'stopped.', 'STOP')
end

function start()
    armed = true
    if asked() and not engaged then engage() end
end

function stop()
    armed = false
    if engaged then disengage() end
end

_G.refinish_fertilize_api = {
    -- owner: the asking module's name, as it reads in the log.
    request = function(owner)
        _G.refinish_fertilize_requests[tostring(owner)] = true
        log('DETAIL', tostring(owner) .. ' asked for the fertilize service.', 'REQUEST')
        if armed and not engaged then engage() end
    end,
    withdraw = function(owner)
        _G.refinish_fertilize_requests[tostring(owner)] = nil
        if engaged and not asked() then disengage() end
    end,
}