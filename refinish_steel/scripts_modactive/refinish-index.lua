-- refinish-index.lua
-- Mints core RM's finish materials at Step 4: the finishes in the fort's
-- finish roster, in roster order (refinish-mint-finish.lua, THE ROSTER).
-- Until 2026-10-02 this built every finish in the blueprint, 61,392 with
-- every base metal selected; a finish is now minted only once the fort
-- can make it. The material builder, with the measurements that shaped
-- it, moved to refinish-mint-finish.lua, which mints in play as well.

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
-- SUBJECT is the correlation slot: the step or thing a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INDEX_MATERIALS'
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

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_ram_loaded == nil or _G.refinish_ram_loaded == false then
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if string.find(mat.id, "REFINISH_STEEL_MAT_") then
            _G.refinish_ram_loaded = true
            break
        end
    end
end

if _G.refinish_ram_loaded then
    log('DETAIL', 'Materials already indexed. Skipping.')
    return
end

-- ==========================================
-- SCRIPT LOGIC: THE ROSTER'S FINISHES
-- ==========================================
if not _G.refinish_blueprint or not _G.refinish_blueprint.materials then
    log('ERROR', 'Blueprint not found in memory, so no finish materials'
        .. ' were built. refinish-scan has to run first.')
    return
end

-- A failure returns before the flag at the end is set, so the next data
-- cycle tries again, and refinish-load (Step 7) leaves a legacy payload
-- for a load that has the finishes.
local ok_m, mint = pcall(reqscript, 'refinish-mint-finish')
if not ok_m then
    log('ERROR', 'refinish-mint-finish could not be loaded, so no finish'
        .. ' materials were built: ' .. tostring(mint))
    return
end
local ok_l, built, skipped = pcall(mint.load_materials)
if not ok_l then
    log('ERROR', 'Finish materials not built: ' .. tostring(built))
    return
end
log('DETAIL', string.format('Built and injected %d custom materials into RAM from'
    .. ' the finish roster (%d roster finishes not in this blueprint).',
    built, skipped))

-- Toggle state manager at the absolute end of the file
_G.refinish_ram_loaded = true