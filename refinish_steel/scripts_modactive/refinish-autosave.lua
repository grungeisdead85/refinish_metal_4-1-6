-- refinish-autosave.lua
-- ==========================================
-- REFINISH METAL: AUTOSAVE CYCLE
-- ==========================================
-- One cycle, the hotsave: ledger snapshot -> clear RAM -> quicksave ->
-- re-index RAM -> ledger remap. Items are never touched; they keep
-- their materials and the remap moves any that shifted, by name.
--
-- The second protocol, AUTOSAVE (wash items to a JSON payload, clear,
-- quicksave, full rebuild), was retired 2026-09-29 with the wash.
--
-- Timing data is written to _G.refinish_telemetry.last_save
-- (the persistent telemetry sub-table). This is NOT nil'd at
-- the end; it persists for the status panel and debug dump.
-- ==========================================

local utils = require('utils')

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
-- SUBJECT is the correlation slot, here HOTSAVE for the cycle's own
-- lines or the gate that ended the run early. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'AUTOSAVE'
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

-- ---- WHICH LINES POP ----
-- The cycle summary is COMPLETE: a finished save is one of the few
-- confirmations worth a line in Quiet. The cycle's start line is
-- INFO, so Info brackets the cycle. Each phase's own line is DETAIL
-- beneath the summary, which carries every phase's timing. A crash is
-- FATAL: the cycle cannot finish and RAM is left cleared.

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- OWNERSHIP TEST
-- ==========================================
-- Every id prefix RM or one of its modules owns. Core RM is always
-- included; module prefixes come from the live registry, which
-- clear_module_assets does not nil, so they remain readable after a
-- clear. A nil registry means the token call has not run yet, so
-- nothing of ours is in the arrays to find.
--
-- Declared here rather than beside the clear gate because the
-- baseline check below needs it too.
-- ==========================================
local function rm_owned(str)
    if string.sub(str, 1, 15) == "REFINISH_STEEL_" then return true end
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        if string.sub(str, 1, #prefix) == prefix then return true end
    end
    return false
end

-- ==========================================
-- BASELINE CHECK
-- If RAM isn't loaded there's nothing for us to do.
-- Just fire a vanilla quicksave and exit.
-- ==========================================
-- _G.refinish_ram_loaded alone is not sufficient. It describes core
-- RM only, and module materials are injected by a separate pipeline
-- with its own flag. Any state where one is live and the other is
-- not would pass this check and write injected data to disk.
--
-- The array is the ground truth, so it is asked directly. This runs
-- once per save trigger, not per frame, so a walk of the inorganics
-- and reactions arrays is affordable.
local function ram_is_at_baseline()
    if _G.refinish_ram_loaded then return false end
    if _G.refinish_modules_injected then return false end
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if rm_owned(mat.id) then return false end
    end
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if rm_owned(rxn.code) then return false end
    end
    return true
end

if ram_is_at_baseline() then
    log('INFO', 'Memory at baseline. Standard quicksave.', 'BASELINE')
    dfhack.run_command('quicksave')
    return
end

-- ==========================================
-- TELEMETRY HELPER
-- ==========================================
-- Writes to _G.refinish_telemetry.last_save if the table exists.
-- ==========================================
local function lset(key, value)
    if _G.refinish_telemetry and _G.refinish_telemetry.last_save then
        _G.refinish_telemetry.last_save[key] = value
    end
end

-- Reset the last_save sub-table for this cycle
if _G.refinish_telemetry and _G.refinish_telemetry.last_save then
    local ls = _G.refinish_telemetry.last_save
    ls.timestamp = os.date("%H:%M:%S")
    ls.t_clr_ent = 0; ls.t_clr_rxn = 0; ls.t_clr_mat = 0
    ls.t_engine = 0; ls.t_restore = 0; ls.t_active = 0
end

_G.refinish_autosave_in_progress = true

-- ---- PAUSED FOR THE WHOLE CYCLE ----
-- No game tick may run while RM's data is out of RAM: a LIQUID_MISC
-- item of a module material resolves to magma past the end of the
-- array (measured at load 2026-08-26; liquids misted in play
-- 2026-09-29). So the cycle pauses whatever Pause on Save says, and
-- the save watcher below holds the pause until RAM is back. Pause on
-- Save decides only what happens after: No resumes a game that was
-- running when the cycle began (resume_after_cycle, from the restore).
local pause_setting = dfhack.persistent.getSiteData('refinish_config_pause')
local was_running = not df.global.pause_state
if was_running then
    df.global.pause_state = true
    log('DETAIL', 'Paused for the save routine.', 'PAUSE')
end

-- Hands the pause back once RAM is restored, or once the tick fallback
-- takes over. Runs once however it is reached.
local resumed = false
local function resume_after_cycle()
    if resumed then return end
    resumed = true
    if pause_setting == 'NO' and was_running then
        df.global.pause_state = false
        log('DETAIL', 'Resumed after the save routine (Pause on Save: No).',
            'PAUSE')
    end
end

-- ==========================================
-- SHARED: PHYSICAL RAM CLEAR CHECK
-- ==========================================
-- Used by the cycle below to confirm RAM is fully evacuated
-- before handing off to the engine save.
-- ==========================================
local function is_memory_physically_clear()
    -- Every id prefix that must be gone before the engine save.
    -- Core RM plus every module prefix from the live registry.
    -- Testing only REFINISH_STEEL_ meant this returned true with
    -- module materials still in the array, so a failed module clear
    -- was invisible and the quicksave went ahead regardless.
    -- clear_module_assets does not nil the registry, so the prefixes
    -- are still readable here after it runs.

    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if rm_owned(mat.id) then return false end
    end
    local reactions = df.global.world.raws.reactions.reactions
    for _, rxn in ipairs(reactions) do
        if rm_owned(rxn.code) then return false end
    end
    for _, cat in ipairs(df.global.world.raws.reactions.reaction_categories) do
        if rm_owned(cat.id) then return false end
    end

    -- Injected tools. Omitting these meant this returned true with
    -- containers still in world.raws.itemdefs.tools, so a failed tool
    -- clear was invisible and the save went ahead regardless. The save
    -- then records the itemdef ids, and the next load fails outright
    -- with "Missing Item Definition". Same class of hole as testing
    -- only REFINISH_STEEL_ above, and the same fix.
    for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
        local ok, id = pcall(function() return td.id end)
        if ok and type(id) == 'string' and rm_owned(id) then return false end
    end
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if player_civ and player_civ.entity_raw then
        local permitted = player_civ.entity_raw.workshops.permitted_reaction_id
        for _, pid in ipairs(permitted) do
            if pid >= #reactions then return false end
        end
    end
    return true
end


-- ==============================================================
-- ==============================================================
-- THE HOTSAVE CYCLE
-- Clear RAM -> Quicksave -> Re-index RAM.
-- Items on the map are never touched. No JSON payload written.
--
-- A do-block so it keeps its indentation: until 2026-09-29 this was
-- the HOTSAVE branch of a protocol choice, with AUTOSAVE after it.
-- ==============================================================
-- ==============================================================
do
    log('INFO', 'Cycle initiated. Clearing RAM.', 'HOTSAVE')

    -- ==========================================
    -- LEDGER SNAPSHOT, BEFORE ANY CLEARING
    -- ==========================================
    -- Objects on the map carry the indices the array holds RIGHT NOW.
    -- This records that layout so the remap after the rebuild can put
    -- them back by name.
    --
    -- FIRST LINE OF THE PROTOCOL, and the position is the whole point.
    -- The clear is strict LIFO, core RM before modules, so ANY later
    -- placement snapshots a half demolished array. Measured: written
    -- between the two clears it recorded 63 materials instead of 441,
    -- having lost the 378 core RM entries AND slid every module index
    -- down by that amount, then saved that over a correct ledger.
    -- ==========================================
    -- if_changed, as in refinish-shutdown's snapshot: kept only when the
    -- arrays stand exactly as the last write found them.
    pcall(function()
        dfhack.script_environment('refinish-ledger').write({ if_changed = true })
    end)

    local cycle_clock = os.clock()

    -- ==========================================
    -- HOTSAVE STEP 1: CLEAR RAM
    -- ==========================================
    -- We call the three clear scripts directly rather than going
    -- through refinish-shutdown, which used to wash items first
    -- (the AUTOSAVE protocol, retired 2026-09-29). Shutdown no
    -- longer washes, so the two paths now run the same clears.
    -- ==========================================

    -- RM's services stop first, as in refinish-shutdown (refinish_steel
    -- .lua, RM'S SERVICES FOLLOW THE DATA): nothing of theirs polls
    -- through the save, and the stockpile windows hand their twins'
    -- flags back while the twins still exist. The modules stop in
    -- clear_module_assets, below.
    pcall(function()
        local svc = _G.refinish_services
        if svc and svc.stop then svc.stop() end
    end)

    local t = os.clock()
    dfhack.run_script('refinish-clear-entity')
    local t_clr_ent = os.clock() - t; lset('t_clr_ent', t_clr_ent); t = os.clock()

    dfhack.run_script('refinish-clear-reaction')
    local t_clr_rxn = os.clock() - t; lset('t_clr_rxn', t_clr_rxn); t = os.clock()

    dfhack.run_script('refinish-clear')

    -- The three clear scripts above filter on the literal
    -- REFINISH_STEEL_ prefix, so they remove core RM and nothing
    -- else. Module assets are swept only by clear_module_assets,
    -- which HOTSAVE never reached because it bypasses
    -- refinish-shutdown. Module materials stayed live in the
    -- inorganics array across the quicksave.
    --
    -- Runs last, matching refinish-shutdown.lua:56-82. Core RM
    -- injects after modules, so removing core RM first and modules
    -- second is strict LIFO across the whole injected region.
    -- clear_module_assets sweeps entity permissions before deleting
    -- reactions (engine:819), so no permitted_reaction_id is left
    -- dangling for is_memory_physically_clear to trip on.
    pcall(function()
        local mod_engine = dfhack.script_environment('refinish-module-engine')
        if mod_engine and mod_engine.clear_module_assets then
            mod_engine.clear_module_assets()
        end
    end)

    local t_clr_mat = os.clock() - t; lset('t_clr_mat', t_clr_mat)

    log('DETAIL', string.format('RAM cleared (Ent:%.3f | Rxn:%.3f | Mat:%.3f).',
        t_clr_ent, t_clr_rxn, t_clr_mat), 'HOTSAVE')

    -- ==========================================
    -- HOTSAVE STEP 2: WAIT FOR PHYSICAL CONFIRMATION
    -- Then fire the engine save and re-index the moment it is written.
    -- ==========================================
    local function hotsave_trigger()
        local ok, err = pcall(function()
            log('DETAIL', 'RAM confirmed clear. Initiating quicksave.', 'HOTSAVE')

            local function do_save_and_restore()
                local engine_start = os.clock()
                dfhack.run_command('quicksave')

                -- ==========================================
                -- WHEN THE SAVE IS WRITTEN: THE REQUEST CLEARS
                -- ==========================================
                -- Restoring while the save is still being written collides
                -- with it and corrupts the save: an early version restored
                -- straight after the quicksave call and did exactly that.
                -- For years no hook was known, so the first game tick after
                -- the request stood in for one, and that tick simulated with
                -- every module material out of the array (magma liquids).
                --
                -- MEASURED 2026-09-29/30 with refinish-save-probe.lua, four
                -- runs, game paused: quicksave raises
                -- plotinfo.main.autosave_request, its timer counts down one
                -- per frame, the saver works through its stages one per
                -- frame (DF's main loop blocking seconds inside some), and
                -- the request clears as the saver ends, with no tick run.
                -- The last run watched the save folders on disk (1,824
                -- files): world.sav and DFHack's .dat files were all written
                -- before the request cleared, and nothing changed in the
                -- 1,500 frames after. The request clearing is the hook.
                --
                -- restore() runs on that frame, before any tick. If the
                -- request is never seen rising (the quicksave failed) or
                -- never clears, the tick rule takes over for that cycle,
                -- with a warning: the old behaviour, window and all.
                local function restore()
                    local ok2, err2 = pcall(function()
                        local t_engine = os.clock() - engine_start
                        lset('t_engine', t_engine)

                        log('DETAIL', string.format(
                            'Quicksave complete (%.3fs). Restoring RAM.',
                            t_engine), 'HOTSAVE')

                        -- ==========================================
                        -- HOTSAVE STEP 3: RESTORE RAM
                        -- ==========================================
                        -- Run the full index chain. No payload restore:
                        -- items carry their own mat_index, and
                        -- refinish-load is now only startup's one-time
                        -- migration of a save the retired wash wrote.
                        -- ==========================================
                        local restore_start = os.clock()
                        local t2 = restore_start

                        -- ---- WHAT THE REBUILD MAKES, MARKED ----
                        -- Read before the module pipeline below starts any
                        -- module: anything numbered from here on is made
                        -- by the rebuild, on the rebuilt indices, and the
                        -- remap leaves it as it is (refinish-ledger.lua,
                        -- MADE THIS LOAD). Added 2026-10-12, as startup's.
                        local made_from = nil
                        pcall(function()
                            made_from = dfhack.script_environment('refinish-ledger').next_ids()
                        end)

                        -- Ghost job sweep
                        local orphaned_jobs_fixed = 0
                        pcall(function()
                            for _, job in utils.listpairs(df.global.world.jobs.list) do
                                if job.job_type == df.job_type.CustomReaction then
                                    local r_name = tostring(job.reaction_name)
                                    if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                                        -- A finished-metal grinder's ghost is cut at
                                        -- the finish's id, keeping the base's grinder
                                        -- (refinish-startup.lua, STEP 1, says why).
                                        local base_name = string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_FIN_")
                                            and (string.match(r_name, "^(.-)_REFINISH_STEEL_MAT_") or r_name)
                                            or string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                                        if base_name and r_name ~= base_name then
                                            job.reaction_name = base_name
                                            orphaned_jobs_fixed = orphaned_jobs_fixed + 1
                                        end
                                    end
                                end
                            end
                        end)
                        if orphaned_jobs_fixed > 0 then
                            log('DETAIL', string.format(
                                'Rescued %d orphaned reactions.',
                                orphaned_jobs_fixed), 'HOTSAVE')
                        end
                        local r_sweep = os.clock() - t2; t2 = os.clock()

                        -- Modules are cleared before the quicksave now, so
                        -- they have to be rebuilt here. Order mirrors
                        -- refinish-startup exactly: modules inject first and
                        -- occupy the lower band, core RM appends after them.
                        -- Re-injecting in any other order would swap the bands
                        -- and move every index in the save.
                        --
                        -- refinish-scan depends on this having run: the
                        -- blueprint is built from the live inorganics array,
                        -- so module materials must be present before it scans.
                        --
                        -- run_module_pipeline returns immediately unless
                        -- _G.refinish_modules_injected is false, which
                        -- clear_module_assets set on the way out (engine:877
                        -- and engine:623).
                        pcall(function()
                            dfhack.script_environment('refinish-module-engine').run_module_pipeline()
                        end)
                        local r_mod = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-scan')
                        local r_scan = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-index')
                        local r_mat = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-index-reaction')
                        local r_rxn = os.clock() - t2; t2 = os.clock()

                        -- Module permissions were erased with the module
                        -- reactions, so they are re-evaluated here. Sits
                        -- between index-reaction and index-entity because that
                        -- is where refinish-startup:141-147 puts it: the
                        -- evaluator registers module metals as known, and
                        -- index-entity gates core RM permissions on that.
                        pcall(function()
                            if _G.refinish_module_registry and next(_G.refinish_module_registry) then
                                dfhack.script_environment('refinish-module-evaluate-permissions').evaluate_and_inject()
                            end
                        end)
                        local r_modperm = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-index-entity')
                        local r_ent = os.clock() - t2

                        -- ---- LEDGER REMAP ----
                        -- Same position refinish-startup uses, after
                        -- material indices are final. Moves every
                        -- object from the index its material held
                        -- before the clear to the index it holds now,
                        -- matched by name.
                        --
                        -- Without this the restore is only correct
                        -- when the rebuilt array is identical to the
                        -- one that was cleared, which stops being true
                        -- the moment anything injects outside startup.
                        pcall(function()
                            dfhack.script_environment('refinish-ledger').remap({ since = made_from })
                        end)

                        -- ---- RM'S SERVICES START ----
                        -- Last, as at the end of refinish-startup: every
                        -- asset in RAM, the modules started and the
                        -- ledger remapped (refinish_steel.lua, RM'S
                        -- SERVICES FOLLOW THE DATA).
                        pcall(function()
                            local svc = _G.refinish_services
                            if svc and svc.start then svc.start() end
                        end)

                        local t_restore = os.clock() - restore_start
                        lset('t_restore', t_restore)

                        _G.refinish_autosave_in_progress = false

                        -- ==========================================
                        -- HOTSAVE TELEMETRY REPORT
                        -- ==========================================
                        local clear_total = t_clr_ent + t_clr_rxn + t_clr_mat
                        local active_time = clear_total + t_engine + t_restore
                        lset('t_active', active_time)

                        -- Log the full cycle as a single structured entry
                        log('COMPLETE', string.format(
                            'Cycle complete (%.3fs); Clear:%.3f | Engine:%.3f | Restore:%.3f',
                            active_time, clear_total, t_engine, t_restore),
                            'HOTSAVE')

                        -- ---- NO COMPLETION PROMPT (removed 2026-09-30) ----
                        -- A prompt is a modal screen (gui.ZScreenModal), which
                        -- holds the game paused while it is up: shown just
                        -- before resume_after_cycle(), it overrode the resume
                        -- that Pause on Save: No asks for. The status panel's
                        -- LAST SAVE CYCLE already carries these figures, so
                        -- the report became a DETAIL line, logged in every
                        -- mode, and the only thing left on screen is the
                        -- announcement, which does not pause. Silent shows
                        -- nothing.
                        log('DETAIL', string.format('Restore breakdown: sweep'
                            .. ' %.3f | modules %.3f | scan %.3f | materials'
                            .. ' %.3f | reactions %.3f | module perms %.3f |'
                            .. ' entities %.3f | orphans fixed %d', r_sweep,
                            r_mod, r_scan, r_mat, r_rxn, r_modperm, r_ent,
                            orphaned_jobs_fixed), 'HOTSAVE')
                        if msg_setting ~= 'SILENT' then
                            local THEME = reqscript('refinish-theme').get_current_theme()
                            dfhack.gui.showAnnouncement(string.format(
                                'Refinish Metal: Hotsave complete (%.2fs).',
                                active_time), THEME.PRI, true)
                        end
                    end)

                    if not ok2 then
                        log('FATAL', 'Restore crashed: ' .. tostring(err2),
                            'HOTSAVE')
                    end
                    -- Whatever happened above, the pause is the player's again.
                    resume_after_cycle()
                end

                -- ---- THE SAVE WATCHER ----
                -- Every frame: note the request rising, restore on the frame
                -- it clears, and hold the pause meanwhile, so a player's
                -- unpause mid-save cannot run a tick. The limits are frames:
                -- the request rose within a frame of the quicksave in every
                -- run, and the saver took about 56.
                local SEEN_LIMIT, UP_LIMIT = 600, 36000
                local frames, seen_up = 0, false
                local function wait_for_save()
                    frames = frames + 1
                    local up = false
                    pcall(function() up = df.global.plotinfo.main.autosave_request end)
                    if up then seen_up = true end
                    if seen_up and not up then
                        restore()
                        return
                    end
                    if (not seen_up and frames >= SEEN_LIMIT) or frames >= UP_LIMIT then
                        -- WARNING: the tick rule, and its window, are back for
                        -- this one cycle.
                        log('WARNING', string.format('The save request %s after'
                            .. ' %d frames; restoring on the next game tick'
                            .. ' instead.', seen_up and 'never cleared'
                            or 'was never seen', frames), 'HOTSAVE')
                        resume_after_cycle()
                        dfhack.timeout(1, 'ticks', restore)
                        return
                    end
                    if not df.global.pause_state then df.global.pause_state = true end
                    dfhack.timeout(1, 'frames', wait_for_save)
                end
                dfhack.timeout(1, 'frames', wait_for_save)
            end

            -- Pre-save prompt for DEBUG only. Guided just proceeds.
            if msg_setting == 'DEBUG' then
                local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                local THEME = reqscript('refinish-theme').get_current_theme()
                RefinishPrompt{
                    text = "RAM cleared. Press ENTER to quicksave. RAM comes back the moment the save is written.",
                    text_pen = THEME.PRI,
                    on_ok = function() do_save_and_restore() end
                }:show()
            else
                do_save_and_restore()
            end
        end)

        if not ok then
            log('FATAL', 'Hotsave crashed: ' .. tostring(err), 'HOTSAVE')
            resume_after_cycle()
        end
    end

    -- Poll until RAM is physically confirmed clear, then fire
    local function wait_for_clear()
        if not is_memory_physically_clear() then
            dfhack.timeout(10, 'frames', wait_for_clear)
        else
            hotsave_trigger()
        end
    end

    wait_for_clear()
end