--@ module = true
-- refinish-job-surgery.lua
-- ==========================================
-- RM JOB SURGERY
-- ==========================================
-- The rules for adding and removing item filters on a live job, in one
-- place. The ghost, fuel access and the tank each carried their own
-- copy of these loops; the rules below are what those copies learned,
-- most of them by crashing.
--
-- THE RULES
--   APPEND AT THE END, ONLY. Every attached item holds a job_item_idx
--   into the filter vector, and every filter a reagent_index into the
--   reaction. Nothing before the last entry may shift, so a new filter
--   goes on the end and nowhere else.
--
--   REMOVE ONLY WHAT YOU OWN, BY WHAT IT IS. A caller says which
--   filters are its own with a test (a fuel slot, a vessel slot whose
--   reagent it added), never by position or by counting from the end.
--   Two writers on one job then never take each other's filters: the
--   fuel copies carry reagent_index -1, the ghost's vessel slots name
--   the reagents it added, and neither test can match the other.
--
--   NEVER UNDER AN ATTACHED ITEM. A job that holds anything has items
--   pointing into its filters, so erase refuses and returns 0 unless
--   the caller passes force. The safe moments are before the first
--   haul and between cycles, when the job holds nothing.
--
--   WALK DOWNWARD. Erasing moves everything after it, so the walk runs
--   from the end, where an erase never moves a filter still to visit.
--
-- THE CALLS
--   surgery.holds_nothing(job)       true when no item is attached;
--                                    false if it cannot tell, the safe
--                                    answer for a caller about to erase
--   surgery.count(job, owns)         how many filters owns() claims
--   surgery.append(job, proto)       a copy of proto on the end; returns
--                                    its index, or nil if it failed
--   surgery.erase(job, owns, opts)   removes owned filters, downward.
--       opts.limit       stop after this many
--       opts.keep_first  leave the first owned filter where it is
--       opts.force       erase even under an attached item
--     returns how many it removed, even if it failed part way
--
-- owns(e) is called with each filter and must not throw on a normal
-- one. Everything here runs under pcall, and a filter that makes owns()
-- throw ends that call with what it had done so far.
-- ==========================================

local function items_n(job) return #job.items end

function holds_nothing(job)
    local ok, n = pcall(items_n, job)
    return ok and n == 0
end

local function do_count(job, owns)
    local n = 0
    for _, e in ipairs(job.job_items.elements) do
        if owns(e) then n = n + 1 end
    end
    return n
end

function count(job, owns)
    local ok, n = pcall(do_count, job, owns)
    return ok and n or 0
end

local function do_append(job, proto)
    local ne = proto._type:new()
    ne:assign(proto)
    local els = job.job_items.elements
    els:insert('#', ne)
    return #els - 1
end

function append(job, proto)
    local ok, at = pcall(do_append, job, proto)
    return ok and at or nil
end

-- st.n counts as it goes, so a failure part way still reports what was
-- actually removed and the caller's bookkeeping stays true.
local function do_erase(job, owns, limit, keep_first, st)
    local els = job.job_items.elements
    local stop = -1
    if keep_first then
        for i = 0, #els - 1 do
            if owns(els[i]) then stop = i break end
        end
        if stop < 0 then return end
    end
    for i = #els - 1, stop + 1, -1 do
        if limit and st.n >= limit then break end
        if owns(els[i]) then
            els[i]:delete()
            els:erase(i)
            st.n = st.n + 1
        end
    end
end

function erase(job, owns, opts)
    opts = opts or {}
    if not opts.force and not holds_nothing(job) then return 0 end
    local st = { n = 0 }
    pcall(do_erase, job, owns, opts.limit, opts.keep_first, st)
    return st.n
end
