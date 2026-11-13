--@ module = true
-- refinish-panel-config.lua

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')
local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt

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
-- SUBJECT is the correlation slot: the setting a line is about. Nil
-- renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CONFIG'
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

RefinishPanelConfig = defclass(RefinishPanelConfig, widgets.Panel)
RefinishPanelConfig.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelConfig:init()
    local function get_pref(id, default)
        local state = dfhack.persistent.getSiteData(id)
        return (state and state ~= "") and state or default
    end

    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    local C_LBL = self.theme.SEC
    local C_VAL = self.theme.PRI
    local C_KEY = self.theme.PRI
    local C_NEG = self.theme.SEC

    local current_perf = get_pref('refinish_config_perf', 'ON')
    -- Protect Bases also decides which metals carry the metal grinder's
    -- class, which is granted only at startup (refinish-index-reaction,
    -- THE METAL GRINDER'S CLASS), so a change takes a data cycle, prompted
    -- as Material Finishes is below. The grind watcher reads the setting
    -- live and needs none.
    -- Off by default (refinish-index-reaction.lua, protected_bases).
    local current_protect = get_pref('refinish_config_protect', 'NO')
    
    local hk_config   = get_pref('refinish_hk_config',   'Ctrl-Shift-C')
    local hk_metals   = get_pref('refinish_hk_metals',   'Ctrl-Shift-M')
    local hk_civs     = get_pref('refinish_hk_civs',     'Ctrl-Shift-V')
    local hk_status   = get_pref('refinish_hk_status',   'Ctrl-Shift-I')
    local hk_log      = get_pref('refinish_hk_log',      'Ctrl-Shift-L')
    local hk_inspect  = get_pref('refinish_hk_inspect',  'Ctrl-Shift-E')
    local hk_help     = get_pref('refinish_hk_help',     'Ctrl-Shift-H')
    local hk_autosave = get_pref('refinish_hk_autosave', 'Ctrl-Shift-S')
    local hk_wipe     = get_pref('refinish_hk_wipe',     'Ctrl-Shift-X')
    local hk_startup  = get_pref('refinish_hk_startup',  'Ctrl-Alt-X')
    local hk_hardwipe = get_pref('refinish_hk_hardwipe', 'Ctrl-Shift-Q')

    local function safe_rebind(old_k, new_k, cmd)
        if old_k and old_k ~= "" then pcall(function() dfhack.run_command('keybinding', 'clear', old_k) end) end
        pcall(function() dfhack.run_command('keybinding', 'add', new_k, cmd) end)
    end

    local function make_hk_changer(pref_id, script_cmd, old_key)
        local choices = {}
        for _, mod in ipairs({'Ctrl-', 'Ctrl-Shift-', 'Ctrl-Alt-'}) do
            for char = 65, 90 do table.insert(choices, {text = mod .. string.char(char), value = mod .. string.char(char)}) end
        end
        dialogs.showListPrompt("Rebind Hotkey", "Select new hotkey for: " .. script_cmd .. "\n(Current: " .. old_key .. ")", self.theme.PRI, choices,
            function(idx, choice)
                dfhack.persistent.saveSiteData(pref_id, choice.value)
                safe_rebind(old_key, choice.value, script_cmd)
                -- INFO: a setting the player changed. script_cmd names
                -- which hotkey it was.
                log('INFO', 'Hotkey for ' .. tostring(script_cmd) .. ' bound to '
                    .. tostring(choice.value) .. '.', 'HOTKEY')
                if _G.refinish_hud_view then _G.refinish_hud_view:dismiss() end
                dfhack.run_script('refinish-hud', 'show', 'config')
            end)
    end

    -- ==========================================
    -- THEMED CYCLE WIDGET FACTORY
    -- ==========================================
    self.cycles = {}
    self.actions = {}

    local function make_themed_cycle(t_pos, key_token, label_text, options, pref_id, default_val, on_change_extra)
        local current_val = get_pref(pref_id, default_val)
        local current_idx = 1
        for i, opt in ipairs(options) do if opt.value == current_val then current_idx = i; break end end
        local state = { idx = current_idx, options = options }

        local function get_display_text()
            local opt = state.options[state.idx]
            return {
                {text = dfhack.screen.getKeyDisplay(df.interface_key[key_token]), pen = C_KEY},
                {text = ": " .. label_text .. " ", pen = C_LBL},
                {text = opt.label, pen = opt.pen or C_VAL}
            }
        end

        local function do_cycle()
            state.idx = (state.idx % #state.options) + 1
            local opt = state.options[state.idx]
            dfhack.persistent.saveSiteData(pref_id, opt.value)
            if on_change_extra then on_change_extra(opt.value, state) end
        end

        -- 1. Create the widget without the on_click handler
        local w = widgets.Label{ frame = {t = t_pos, l = 0, w = 32}, text = get_display_text() }
        
        -- 2. Assign the click handler AFTER instantiation so 'w' is correctly in scope
        w.on_click = function() 
            do_cycle()
            w:setText(get_display_text()) 
        end

        table.insert(self.cycles, { key = key_token, widget = w, state = state,
            cycle = function() do_cycle(); w:setText(get_display_text()) end, get_display_text = get_display_text })
        return w
    end

    local function make_key_label(key_token, label_text, pen_label)
        return {
            {text = dfhack.screen.getKeyDisplay(df.interface_key[key_token]), pen = C_KEY},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    -- ==========================================
    -- SYSTEM SETTINGS
    -- ==========================================
    self.w_autosave = make_themed_cycle(4, 'CUSTOM_SHIFT_Q', 'Autosave:', {
        {label = 'Seasonal', value = 'SEASONAL', pen = C_VAL}, {label = 'Semi-Annual', value = 'SEMIANNUAL', pen = C_VAL},
        {label = 'Yearly', value = 'YEARLY', pen = C_VAL}, {label = '15 Min', value = 'REAL_15', pen = C_VAL},
        {label = '30 Min', value = 'REAL_30', pen = C_VAL}, {label = '1 Hour', value = 'REAL_60', pen = C_VAL},
        {label = 'Off', value = 'NONE', pen = C_NEG},
    }, 'refinish_config_interval', 'SEASONAL')

    self.w_pause = make_themed_cycle(6, 'CUSTOM_SHIFT_W', 'Pause on Save:', {
        {label = 'Yes', value = 'YES', pen = C_VAL}, {label = 'No', value = 'NO', pen = C_NEG},
    }, 'refinish_config_pause', 'YES')

    -- SAVE PROTOCOL OPTION (removed 2026-09-29)
    -- It chose between Hotsave (items keep their materials through a
    -- save) and Autosave (the legacy wash: finished items rewritten to
    -- their base metals, their finishes kept in a JSON payload). Measured
    -- the same day: both game saves bring every finish back under Hotsave
    -- with no payload either way, so the wash was retired and every save
    -- is a hotsave. A stored refinish_config_save_protocol is no longer
    -- read.

    -- MENU DATA CYCLE OPTION (removed 2026-09-29)
    -- It chose whether opening the ESC options screen unloaded RM's data
    -- (Auto) or left it loaded for a manual shutdown before saving
    -- (Manual). refinish-save-hook.lua now unloads for the game's own
    -- saves, from the moment one is asked for, so there is nothing left
    -- to choose. A stored refinish_config_esc is no longer read.

    -- Load Delay. Instant is the only safe setting; the risk pens used
    -- to say the opposite. Any delay leaves a window in which a save's
    -- module material items point past the end of the inorganics
    -- array, where LIQUID_MISC resolves to magma. Longer delay, wider
    -- window, hotter pen. Kept selectable for diagnosis only.
    -- LOAD DELAY OPTION (removed)
    -- Startup always runs Instant now, hardcoded in refinish_steel.lua.
    -- Any delay leaves a window in which a save's module material items
    -- point past the end of the inorganics array, where LIQUID_MISC
    -- resolves to magma. There is no setting here worth offering.
    -- self.w_delay = make_themed_cycle(12, 'CUSTOM_SHIFT_T', 'Load Delay:', {
    --     {label = 'Instant', value = 'NONE', pen = C_VAL}, {label = '1 Tick', value = 'TICK', pen = self.theme.RISK_L},
    --     {label = '20 Frames', value = 'FRAMES_20', pen = self.theme.RISK_M}, {label = '100 Frames', value = 'FRAMES_100', pen = self.theme.RISK_H},
    -- }, 'refinish_config_delay', 'NONE')

    -- ROW ORDER, 2026-09-29: the rows from here down moved up into the
    -- slots the three removed options left, and the hotkeys run
    -- QWERTYUIOP from the top of the column down, so a row's key follows
    -- its place. The rows are defined out of order; frame t places them.
    self.w_perf = make_themed_cycle(10, 'CUSTOM_SHIFT_R', 'Material Finishes:', {
        {label = 'ON', value = 'ON', pen = C_VAL}, {label = 'OFF', value = 'OFF', pen = C_NEG},
    }, 'refinish_config_perf', current_perf, function(val, state)
        RefinishPrompt{
            text = "Changing this configuration will cancel all active jobs involving Refinish Metal materials and trigger data cycling.\n\nAre you sure you want to proceed?",
            text_pen = self.theme.PRI,
            on_yes = function()
                current_perf = val
                -- INFO: a setting the player changed, and why the data
                -- cycle that follows ran.
                log('INFO', 'Material finishes set to ' .. tostring(val)
                    .. '. Triggering a data cycle.', 'FINISHES')
                dfhack.run_script('refinish-hard-shutdown', 'SILENT')
                dfhack.run_script('refinish-startup', 'SILENT')
                local jobs_killed = _G.refinish_last_jobs_canceled or 0; _G.refinish_last_jobs_canceled = nil
                local msg_setting = get_pref('refinish_config_msg', 'GUIDED')
                if msg_setting == 'GUIDED' or msg_setting == 'DEBUG' then
                    -- No "saved" or "restored": since the payload's retirement
                    -- nothing records an item's Material Finish while OFF.
                    local action_txt = (val == 'OFF') and "purged from active RAM." or "injected into active RAM."
                    local debug_txt = (msg_setting == 'DEBUG') and ("\n\n[DEBUG: Material Finishes flag toggled to " .. val .. ". " .. jobs_killed .. " jobs canceled.]") or ""
                    RefinishPrompt{ frame_h = (msg_setting == 'DEBUG') and 18 or 12, text = "Material finish data has been successfully " .. action_txt .. debug_txt, text_pen = self.theme.PRI, on_ok = function() end }:show()
                elseif msg_setting == 'PASSIVE' then
                    dfhack.gui.showAnnouncement('Refinish Metal: RAM cycled successfully.', self.theme.PRI, true)
                end
            end,
            on_no = function()
                dfhack.persistent.saveSiteData('refinish_config_perf', current_perf)
                for _, c in ipairs(self.cycles) do
                    if c.key == 'CUSTOM_SHIFT_R' then
                        for i, opt in ipairs(c.state.options) do
                            if opt.value == current_perf then c.state.idx = i; c.widget:setText(c.get_display_text()); break end
                        end; break
                    end
                end
            end
        }:show()
    end)

    -- ---- TURNED DOWN, NOT AT RISK ----
    -- Passive and Silent turn the mod's notices down, as Relaxed turns the
    -- grind watcher down and NO DUST and the lower Byproduct Rates turn
    -- byproducts down, so all of them wear Tertiary. Passive and Relaxed
    -- wore Caution, and Silent Warning, until 2026-10-14, as settings
    -- thought to carry risk; the hot colours are for faults alone
    -- (refinish-panel-log.lua, EVERY VERDICT HAS ITS OWN COLOUR).
    self.w_msg = make_themed_cycle(12, 'CUSTOM_SHIFT_T', 'Invasiveness:', {
        {label = 'Guided', value = 'GUIDED', pen = C_VAL}, {label = 'Passive', value = 'PASSIVE', pen = self.theme.TER},
        {label = 'Silent', value = 'SILENT', pen = self.theme.TER}, {label = 'Debug', value = 'DEBUG', pen = C_NEG},
    }, 'refinish_config_msg', 'GUIDED')

    self.w_protect = make_themed_cycle(14, 'CUSTOM_SHIFT_Y', 'Protect Bases:', {
        {label = 'Yes', value = 'YES', pen = C_VAL}, {label = 'No', value = 'NO', pen = C_NEG},
    }, 'refinish_config_protect', current_protect, function(val, state)
        RefinishPrompt{
            text = "Changing this configuration will cancel all active jobs involving Refinish Metal materials and trigger data cycling.\n\nAre you sure you want to proceed?",
            text_pen = self.theme.PRI,
            on_yes = function()
                current_protect = val
                -- INFO: a setting the player changed, and why the data
                -- cycle that follows ran.
                log('INFO', 'Base protection set to ' .. tostring(val)
                    .. '. Triggering a data cycle.', 'PROTECT')
                dfhack.run_script('refinish-hard-shutdown', 'SILENT')
                dfhack.run_script('refinish-startup', 'SILENT')
                local jobs_killed = _G.refinish_last_jobs_canceled or 0; _G.refinish_last_jobs_canceled = nil
                local msg_setting = get_pref('refinish_config_msg', 'GUIDED')
                if msg_setting == 'GUIDED' or msg_setting == 'DEBUG' then
                    local action_txt = (val == 'YES')
                        and "on: the metal grinder leaves your selected base metals alone."
                        or "off: the metal grinder takes your selected base metals too."
                    local debug_txt = (msg_setting == 'DEBUG') and ("\n\n[DEBUG: Protect Bases toggled to " .. val .. ". " .. jobs_killed .. " jobs canceled.]") or ""
                    RefinishPrompt{ frame_h = (msg_setting == 'DEBUG') and 18 or 12, text = "Base protection is now " .. action_txt .. debug_txt, text_pen = self.theme.PRI, on_ok = function() end }:show()
                elseif msg_setting == 'PASSIVE' then
                    dfhack.gui.showAnnouncement('Refinish Metal: RAM cycled successfully.', self.theme.PRI, true)
                end
            end,
            on_no = function()
                dfhack.persistent.saveSiteData('refinish_config_protect', current_protect)
                for _, c in ipairs(self.cycles) do
                    if c.key == 'CUSTOM_SHIFT_Y' then
                        for i, opt in ipairs(c.state.options) do
                            if opt.value == current_protect then c.state.idx = i; c.widget:setText(c.get_display_text()); break end
                        end; break
                    end
                end
            end
        }:show()
    end)

    -- ---- UI LOG VERBOSITY ----
    -- Display only. The session file on disk is always debug-verbose,
    -- because a setting that reduces what gets RECORDED is a setting
    -- that loses the one line you needed.
    --
    -- Filters on the TYPE tag, which the emitter already declares and
    -- which already drives the colour, so one classification serves
    -- both and no module has to supply anything new.
    -- LEVELS (2026-10-07): Quiet, Info and Debug, Quiet the default and
    -- so in the ordinary value colour, no longer the caution colour.
    -- Info was Normal: a world still holding 'NORMAL' shows the first
    -- row, Quiet, and refinish-panel-log.lua reads it as Quiet too.
    self.w_loglevel = make_themed_cycle(16, 'CUSTOM_SHIFT_U', 'Log Detail:', {
        {label = 'Quiet',  value = 'QUIET',  pen = C_VAL},
        {label = 'Info',   value = 'INFO',   pen = C_VAL},
        {label = 'Debug',  value = 'DEBUG',  pen = C_NEG},
    }, 'refinish_config_log', 'QUIET', function()
        -- Bumped so the log panel notices without polling the
        -- persistent store every frame. make_themed_cycle already
        -- saves the value before calling this.
        _G.refinish_log_filter_gen = (_G.refinish_log_filter_gen or 0) + 1
    end)

    -- ---- POLLING RATE ----
    -- How often the JIT grind watcher in refinish_steel.lua runs
    -- (get_poll_frames there: Fast 10 frames, Normal 25, Relaxed 50). It
    -- names each grind job for what is being ground and, with Protect
    -- Bases on, cancels a grind that took a protected base metal. Read at
    -- every pass, so a change needs no data cycle. A slower rate costs
    -- less CPU, which a large fort may want, and does both a little later.
    -- Nothing else reads it: the save hook's monitor runs every frame and
    -- the calendar every 1000 frames. Until 2026-10-13 the comment here
    -- said it paced the UI monitor loops too.
    self.w_poll = make_themed_cycle(8, 'CUSTOM_SHIFT_E', 'Polling Rate:', {
        {label = 'Fast',    value = 'FAST',    pen = C_VAL},
        {label = 'Normal',  value = 'NORMAL',  pen = C_VAL},
        -- Tertiary, as Passive and Silent are (TURNED DOWN, NOT AT RISK).
        {label = 'Relaxed', value = 'RELAXED', pen = self.theme.TER},
    }, 'refinish_config_poll_rate', 'FAST')

    -- ---- BYPRODUCTS ----
    -- refinish-job-byproducts.lua reads this at every job it pays (THE
    -- SWITCH there), so a change applies to the next job with no data
    -- cycle, and it needs none of the prompts the rows above use.
    --   ON       every byproduct, RM's dust and every module's.
    --   NO DUST  every byproduct but dust. Dust's share of a loss is not
    --            handed to anything else.
    --   OFF      no byproducts at all.
    -- RM core pays one byproduct of its own, dust, so one row covers it
    -- (two rows, Byproducts and Byproduct Dust, until 2026-10-03).
    -- Grinders and crushers are orders, not byproducts, and make dust
    -- whatever this says.
    self.w_byproducts = make_themed_cycle(18, 'CUSTOM_SHIFT_I', 'Byproducts:', {
        {label = 'ON', value = 'ON', pen = C_VAL},
        {label = 'NO DUST', value = 'NO_DUST', pen = self.theme.TER},
        {label = 'OFF', value = 'OFF', pen = C_NEG},
    }, 'refinish_config_byproducts', 'ON', function(val)
        -- INFO: a setting the player changed.
        local paid = { ON = 'every byproduct is paid', NO_DUST = 'every byproduct but dust is paid',
                       OFF = 'no byproduct is paid' }
        log('INFO', ('Byproducts set to %s: %s from the next job.'):format(tostring(val),
            paid[val] or 'an unknown setting, read as ON'), 'BYPRODUCTS')
    end)

    -- ---- BYPRODUCT RATE ----
    -- One multiplier on every byproduct paid, RM's dust and every module's
    -- streams alike, added 2026-10-07 so players can turn the output down
    -- while the recovery rates are still being tuned. Read by
    -- refinish-job-byproducts.lua at every job it pays (THE RATE there),
    -- so a change applies to the next job with no data cycle. It scales
    -- what each stream is paid, never the split between streams. Grinders
    -- and crushers are orders, not byproducts, and are not scaled. Stored
    -- as the percentage, a string; no value, or one the service does not
    -- know, reads as 100. On O, the next key in the QWERTYUIOP run, so the
    -- keys still read in order down the column and Restore moves to P.
    self.w_byproduct_rate = make_themed_cycle(20, 'CUSTOM_SHIFT_O', 'Byproduct Rate:', {
        {label = '100%', value = '100', pen = C_VAL},
        {label = '75%',  value = '75',  pen = self.theme.TER},
        {label = '50%',  value = '50',  pen = self.theme.TER},
        {label = '25%',  value = '25',  pen = self.theme.TER},
        {label = '10%',  value = '10',  pen = self.theme.TER},
    }, 'refinish_config_byproduct_rate', '100', function(val)
        -- INFO: a setting the player changed.
        log('INFO', ('Byproduct rate set to %s%%: every byproduct pays that share of'
            .. ' its measured amount from the next job.'):format(tostring(val)), 'BYPRODUCTS')
    end)

    -- ==========================================
    -- RESTORE DEFAULTS
    -- ==========================================
    -- The last row of the column, so it takes the next key in the
    -- QWERTYUIOP run (it sat on the plus sign, STRING_A043, until the
    -- rows were compacted, then on I until Byproducts took I, then on O
    -- until Byproduct Rate took O).
    self.actions.CUSTOM_SHIFT_P = function()
        -- ---- THE DATA CYCLE TWO DEFAULTS NEED ----
        -- Material Finishes and Protect Bases take effect through a data
        -- cycle (their rows above), so a restore that moves either one runs
        -- the same hard shutdown and startup once it has written the
        -- defaults, and its prompt says so first. Until 2026-10-14 it only
        -- wrote them: the panel showed the defaults while the loaded game
        -- kept the old state until the next load or data cycle. Asked at
        -- the key press for the prompt, and again on Yes, before the
        -- defaults are written over the values it reads.
        local function moves_cycled()
            return get_pref('refinish_config_perf', 'ON') ~= 'ON'
                or get_pref('refinish_config_protect', 'NO') ~= 'NO'
        end
        local cycle_note = moves_cycled() and "\n\nMaterial Finishes or Protect Bases changes with them, so this will also cancel all active jobs involving Refinish Metal materials and trigger data cycling." or ""
        -- 14 rows, not the default 12, to fit the note.
        RefinishPrompt{ frame_h = (cycle_note ~= "") and 14 or nil, text = "Are you sure you want to revert all configurations to their original defaults?" .. cycle_note, text_pen = self.theme.PRI,
            on_yes = function()
                local cycle = moves_cycled()
                for _, kv in ipairs({
                    {'refinish_config_interval','SEASONAL'}, {'refinish_config_pause','YES'},
                    -- SAVE PROTOCOL OPTION (removed): {'refinish_config_save_protocol','AUTOSAVE'},
                    -- LOAD DELAY OPTION (removed): {'refinish_config_delay','NONE'},
                    -- MENU DATA CYCLE OPTION (removed): {'refinish_config_esc','AUTO'},
                    {'refinish_config_msg','GUIDED'},
                    {'refinish_config_protect','NO'}, {'refinish_config_perf','ON'},
                    {'refinish_config_poll_rate','FAST'},
                    {'refinish_config_log','QUIET'},
                    {'refinish_config_byproducts','ON'}, {'refinish_config_byproduct_rate','100'},
                    {'refinish_theme_pri','LIGHTGREEN'}, {'refinish_theme_sec','LIGHTBLUE'}, {'refinish_theme_ter','CYAN'},
                    {'refinish_theme_neutral_b','WHITE'}, {'refinish_theme_neutral_s','DARKGREY'},
                    {'refinish_theme_risk_l','YELLOW'}, {'refinish_theme_risk_m','LIGHTRED'}, {'refinish_theme_risk_h','RED'},
                    {'refinish_hk_config','Ctrl-Shift-C'}, {'refinish_hk_metals','Ctrl-Shift-M'}, {'refinish_hk_civs','Ctrl-Shift-V'},
                    {'refinish_hk_status','Ctrl-Shift-I'}, {'refinish_hk_log','Ctrl-Shift-L'}, {'refinish_hk_inspect','Ctrl-Shift-E'},
                    {'refinish_hk_help','Ctrl-Shift-H'}, {'refinish_hk_autosave','Ctrl-Shift-S'}, {'refinish_hk_wipe','Ctrl-Shift-X'},
                    {'refinish_hk_startup','Ctrl-Alt-X'}, {'refinish_hk_hardwipe','Ctrl-Shift-Q'},
                }) do dfhack.persistent.saveSiteData(kv[1], kv[2]) end
                safe_rebind(hk_config,'Ctrl-Shift-C','refinish-hud show config'); safe_rebind(hk_metals,'Ctrl-Shift-M','refinish-hud show metals')
                safe_rebind(hk_civs,'Ctrl-Shift-V','refinish-hud show civs'); safe_rebind(hk_status,'Ctrl-Shift-I','refinish-hud show status')
                safe_rebind(hk_log,'Ctrl-Shift-L','refinish-hud show log'); safe_rebind(hk_inspect,'Ctrl-Shift-E','refinish-hud show inspect')
                safe_rebind(hk_help,'Ctrl-Shift-H','refinish-hud show help'); safe_rebind(hk_autosave,'Ctrl-Shift-S','refinish-autosave')
                safe_rebind(hk_wipe,'Ctrl-Shift-X','refinish-shutdown'); safe_rebind(hk_startup,'Ctrl-Alt-X','refinish-startup')
                safe_rebind(hk_hardwipe,'Ctrl-Shift-Q','refinish-hard-shutdown')
                -- ---- THE CYCLE, AS THE ROWS RUN IT ----
                -- INFO: a change the player made, and why a data cycle
                -- followed it.
                log('INFO', 'Default settings restored.' .. (cycle and ' Material Finishes or'
                    .. ' Protect Bases changed with them. Triggering a data cycle.' or ''), 'RESTORE')
                local jobs_killed = 0
                if cycle then
                    dfhack.run_script('refinish-hard-shutdown', 'SILENT')
                    dfhack.run_script('refinish-startup', 'SILENT')
                    jobs_killed = _G.refinish_last_jobs_canceled or 0; _G.refinish_last_jobs_canceled = nil
                end
                if _G.refinish_hud_view then _G.refinish_hud_view:dismiss() end
                dfhack.run_script('refinish-hud', 'show', 'config')
                -- The report goes on top of the rebuilt panel, in the
                -- restored theme (the prompt reads it as it is drawn) and by
                -- the restored Invasiveness, as each row reports its cycle.
                if cycle then
                    local msg_setting = get_pref('refinish_config_msg', 'GUIDED')
                    if msg_setting == 'GUIDED' or msg_setting == 'DEBUG' then
                        local debug_txt = (msg_setting == 'DEBUG') and ("\n\n[DEBUG: Material Finishes ON, Protect Bases NO. " .. jobs_killed .. " jobs canceled.]") or ""
                        RefinishPrompt{ frame_h = (msg_setting == 'DEBUG') and 16 or 12, text = "Defaults restored, and the data cycled: material finishes are in active RAM, and the metal grinder takes your selected base metals too." .. debug_txt, on_ok = function() end }:show()
                    elseif msg_setting == 'PASSIVE' then
                        dfhack.gui.showAnnouncement('Refinish Metal: RAM cycled successfully.',
                            reqscript('refinish-theme').get_current_theme().PRI, true)
                    end
                end
            end }:show()
    end

    self.btn_restore = widgets.Label{ frame = {t = 22, l = 0, w = 32},
        text = make_key_label('CUSTOM_SHIFT_P', 'Restore Default Settings', self.theme.PRI),
        on_click = self.actions.CUSTOM_SHIFT_P }

    -- ==========================================
    -- HOTKEY REBINDERS
    -- ==========================================
    local hk_defs = {
        {t=25, key='STRING_A049', lbl="Config:",    pref='refinish_hk_config',   cmd='refinish-hud show config',  cur=hk_config},
        {t=26, key='STRING_A050', lbl="Metals:",    pref='refinish_hk_metals',   cmd='refinish-hud show metals',  cur=hk_metals},
        {t=27, key='STRING_A051', lbl="Civs:",      pref='refinish_hk_civs',     cmd='refinish-hud show civs',    cur=hk_civs},
        {t=28, key='STRING_A052', lbl="Status:",    pref='refinish_hk_status',   cmd='refinish-hud show status',  cur=hk_status},
        {t=29, key='STRING_A053', lbl="Log:",       pref='refinish_hk_log',      cmd='refinish-hud show log',     cur=hk_log},
        {t=30, key='STRING_A054', lbl="Inspect:",   pref='refinish_hk_inspect',  cmd='refinish-hud show inspect', cur=hk_inspect},
        {t=31, key='STRING_A055', lbl="Help:",      pref='refinish_hk_help',     cmd='refinish-hud show help',    cur=hk_help},
        {t=34, key='STRING_A056', lbl="Startup:",   pref='refinish_hk_startup',  cmd='refinish-startup',          cur=hk_startup},
        {t=35, key='STRING_A057', lbl="Mem Wipe:",  pref='refinish_hk_wipe',     cmd='refinish-shutdown',         cur=hk_wipe},
        {t=36, key='STRING_A048', lbl="Hard Wipe:", pref='refinish_hk_hardwipe', cmd='refinish-hard-shutdown',    cur=hk_hardwipe},
        {t=37, key='STRING_A045', lbl="Autosave:",  pref='refinish_hk_autosave', cmd='refinish-autosave',         cur=hk_autosave},
    }

    local hk_widgets = {}
    for _, hk in ipairs(hk_defs) do
        local action = function() make_hk_changer(hk.pref, hk.cmd, hk.cur) end
        self.actions[hk.key] = action
        table.insert(hk_widgets, widgets.Label{ frame = {t = hk.t, l = 0, w = 32},
            text = { {text = dfhack.screen.getKeyDisplay(df.interface_key[hk.key]), pen = C_KEY},
                     {text = ": " .. string.format("%-10s [%s]", hk.lbl, hk.cur), pen = self.theme.SEC} },
            on_click = action })
    end

    -- ==========================================
    -- THEME COLOUR PICKERS
    -- ==========================================
    local COLOR_OPTIONS = {
        {label='Black',    value='BLACK',       pen=COLOR_BLACK},
        {label='Blue',     value='BLUE',        pen=COLOR_BLUE},
        {label='Green',    value='GREEN',       pen=COLOR_GREEN},
        {label='Cyan',     value='CYAN',        pen=COLOR_CYAN},
        {label='Red',      value='RED',         pen=COLOR_RED},
        {label='Magenta',  value='MAGENTA',     pen=COLOR_MAGENTA},
        {label='Brown',    value='BROWN',       pen=COLOR_BROWN},
        {label='Grey',     value='GREY',        pen=COLOR_GREY},
        {label='Dgrey',    value='DARKGREY',    pen=COLOR_DARKGREY},
        {label='Lblue',    value='LIGHTBLUE',   pen=COLOR_LIGHTBLUE},
        {label='Lgreen',   value='LIGHTGREEN',  pen=COLOR_LIGHTGREEN},
        {label='Lcyan',    value='LIGHTCYAN',   pen=COLOR_LIGHTCYAN},
        {label='Lred',     value='LIGHTRED',    pen=COLOR_LIGHTRED},
        {label='Lmagenta', value='LIGHTMAGENTA',pen=COLOR_LIGHTMAGENTA},
        {label='Yellow',   value='YELLOW',      pen=COLOR_YELLOW},
        {label='White',    value='WHITE',        pen=COLOR_WHITE},
    }

    local function make_color_opts()
        local opts = {}; for _, o in ipairs(COLOR_OPTIONS) do table.insert(opts, {label=o.label, value=o.value, pen=o.pen}) end; return opts
    end

    local function make_theme_picker(t_pos, key_token, label_text, pref_id, default_color)
        return make_themed_cycle(t_pos, key_token, label_text, make_color_opts(), pref_id, default_color, function(val)
            -- Deferred to next frame: dismissing the HUD from inside a click
            -- handler destroys the widget tree mid-event, which crashes the UI.
            dfhack.timeout(1, 'frames', function()
                if _G.refinish_hud_view then
                    _G.refinish_hud_restore_left = _G.refinish_hud_view.router_left:getSelected()
                    _G.refinish_hud_restore_right = _G.refinish_hud_view.router_center:getSelected()
                    _G.refinish_hud_view:dismiss()
                end
                dfhack.run_script('refinish-hud', 'show', 'config')
            end)
        end)
    end

    self.w_theme_pri = make_theme_picker(40, 'STRING_A033', 'Primary:',     'refinish_theme_pri',       'LIGHTGREEN')
    self.w_theme_sec = make_theme_picker(41, 'STRING_A064', 'Secondary:',   'refinish_theme_sec',       'LIGHTBLUE')
    self.w_theme_ter = make_theme_picker(42, 'STRING_A035', 'Tertiary:',    'refinish_theme_ter',       'CYAN')
    self.w_theme_nb  = make_theme_picker(43, 'STRING_A036', 'Neutral Bold:','refinish_theme_neutral_b', 'WHITE')
    self.w_theme_ns  = make_theme_picker(44, 'STRING_A037', 'Neutral Soft:','refinish_theme_neutral_s', 'DARKGREY')
    self.w_theme_rl  = make_theme_picker(45, 'STRING_A094', 'Caution:',     'refinish_theme_risk_l',    'YELLOW')
    self.w_theme_rm  = make_theme_picker(46, 'STRING_A038', 'Warning:',     'refinish_theme_risk_m',    'LIGHTRED')
    self.w_theme_rh  = make_theme_picker(47, 'STRING_A042', 'Danger:',      'refinish_theme_risk_h',    'RED')

    -- ==========================================
    -- TOOLTIP HELPER
    -- ==========================================
    local function bind_tooltip(target_widget, title, body)
        return widgets.TooltipLabel{ frame = {t = 2, l = 0, r = 0}, text_to_wrap = title .. "\n\n" .. body,
            text_pen = self.theme.SEC, show_tooltip = function() return target_widget:getMousePos() ~= nil end }
    end

    -- ==========================================
    -- VIEW ASSEMBLY
    -- ==========================================
    local views = {
        widgets.Label{ frame = {t = 0, l = 0}, text = "CONFIGURATION", text_pen = self.theme.PRI },
        widgets.Label{ frame = {t = 2, l = 0}, text = "SYSTEM SETTINGS", text_pen = self.theme.NEUTRAL_B },
        -- LOAD DELAY OPTION (removed): self.w_delay
        -- MENU DATA CYCLE OPTION (removed): self.w_menu
        -- SAVE PROTOCOL OPTION (removed): self.w_save_protocol
        self.w_autosave, self.w_pause,
        self.w_perf, self.w_msg, self.w_protect, self.w_poll,
        self.w_loglevel, self.w_byproducts, self.w_byproduct_rate, self.btn_restore,
        widgets.Label{ frame = {t = 24, l = 0}, text = "UI NAVIGATION HOTKEYS", text_pen = self.theme.NEUTRAL_B },
    }
    for _, hw in ipairs(hk_widgets) do table.insert(views, hw) end
    table.insert(views, widgets.Label{ frame = {t = 33, l = 0}, text = "SYSTEM COMMAND HOTKEYS", text_pen = self.theme.NEUTRAL_B })
    table.insert(views, widgets.Label{ frame = {t = 39, l = 0}, text = "THEME COLOURS", text_pen = self.theme.NEUTRAL_B })
     for _, tw in ipairs({self.w_theme_pri, self.w_theme_sec, self.w_theme_ter, self.w_theme_nb, self.w_theme_ns, self.w_theme_rl, self.w_theme_rm, self.w_theme_rh}) do
        table.insert(views, tw)
    end
    table.insert(views, widgets.Panel{ frame = {t = 0, l = 34, r = 0, b = 0}, subviews = {
        widgets.Label{ frame = {t = 0, l = 0}, text = "INFORMATION", text_pen = self.theme.PRI },
        bind_tooltip(self.w_autosave, "Autosave Interval",
            "How often the mod runs its full save cycle. Seasonal saves at every season change, Semi-Annual at the start of spring and autumn, and Yearly at each new year. The real-time options count wall-clock minutes, whatever the game speed. Off means no autosaves at all, because the mod switches vanilla's autosave off while it is loaded; save with the quicksave hotkey or the game's own save, both of which are safe."),
        bind_tooltip(self.w_pause, "Pause on Save",
            "The simulation is always paused while an autosave cycle runs, because no game tick may pass while Refinish Metal's data is out of RAM. This setting decides what happens after: Yes leaves the game paused when the cycle ends; No resumes it by itself if it was running."),
        -- SAVE PROTOCOL OPTION (removed): its tooltip went with it.
        -- MENU DATA CYCLE OPTION (removed): its tooltip went with it.
        -- LOAD DELAY OPTION (removed). Tooltip text kept for reference;
        -- note that its advice was backwards, which is how the window
        -- stayed open as long as it did.
        -- bind_tooltip(self.w_delay, "Startup Load Delay",
        --     "Controls when mod data is injected into RAM after a map loads. '1 Tick' waits for the player to unpause the game, giving the engine time to fully settle after a heavy load. Faster options inject while the game is still paused. Non-Tick options may cause instability on large saves or heavily modded worlds and are not recommended."),
        bind_tooltip(self.w_perf, "Material Finishes",
            "When ON, a finish is also made for each material a dust is ground from, named for it (e.g. 'obsidian steel'); materials whose names give the same finish share one. When OFF, only Colour Finishes and the named Special Finishes are made. Either way, a finish is made only once your fort has had both its base metal's bars and the dust. Changing this mid-game cancels active Refinish Metal jobs and runs a full data cycle. While it is OFF, items in a material finish wait on their base metal and get the finish back when it is ON again."),
        bind_tooltip(self.w_msg, "System Invasiveness",
            "How the mod tells you about its work.\n\nGuided, the default: a prompt says Refinish Metal is online at each load; the startup, shutdown and hard shutdown hotkeys ask before they run; and a prompt reports what they did, and what a data cycle run by a setting did.\n\nPassive: results go to the announcements instead of prompts, and the shutdown and hard shutdown hotkeys run without asking.\n\nSilent: nothing about the mod's own work, the autosave's completion notice included, and the shutdown and hard shutdown hotkeys run without asking.\n\nDebug: Guided, with timings and counts in its prompts, and a prompt before each autosave's quicksave.\n\nAt every level the startup hotkey and any setting that runs a data cycle ask first, every level but Silent announces each autosave, and alerts and warnings always show. What the event log shows is set by Log Detail, not here."),
        bind_tooltip(self.w_protect, "Protect Base Metals",
            "Set to Yes, the metal grinder also leaves your active base metals alone, and a dwarf about to grind one cancels the job with an announcement. It never takes finished metals either way: finished bars are ground in the Grind finished metals folder, one grinder per base metal. This is No by default, because with every base metal active it would stop all metal grinding. Changing it runs a full data cycle."),
        bind_tooltip(self.w_loglevel, "Log Detail",
            "What the event log panel shows. The session log file on disk keeps every line whatever this is set to, so turning it down never loses anything.\n\nQuiet, the default: faults, from fatal errors to warnings and suspect results, plus completions and session milestones, so every fault is easy to find.\n\nInfo: everything but per-item debugging detail, so ordinary activity and yields as well.\n\nDebug: everything.\n\nA line that never said what kind it is shows as UNTYPED at every level: that is a fault in the code that wrote it."),

        bind_tooltip(self.w_poll, "Polling Rate",
            "How often the grind job watcher looks for new grind jobs to name for what is being ground. Fast (every 10 frames, the default) answers soonest and costs the most CPU; Normal (25 frames) is a balance; Relaxed (50 frames) costs the least, and a job may show its generic name a little longer. With Protect Bases on, the same watcher cancels a grind that took a protected base metal, so a slower rate cancels it a little later too. The mod's other monitors keep their own pace."),
        bind_tooltip(self.w_byproducts, "Byproducts",
            "A job that destroys material pays part of it back where it was worked, measured from what the job actually used: Refinish Metal's dust, its gravel and slag when a module asks for them, and the byproducts installed modules declare. ON pays them all. NO DUST pays everything but dust, Refinish Metal's or a module's; dust's share of each loss is simply not recovered. OFF pays nothing and measures nothing, and that material is lost, as in vanilla. Grinding and crushing still make dust, since those are orders rather than byproducts. Applies from the next job, with no data cycle; amounts already counted toward an item are kept."),
        bind_tooltip(self.w_byproduct_rate, "Byproduct Rate",
            "Scales every byproduct a job pays, Refinish Metal's own and every module's alike: 100% pays the full measured share, 10% a tenth of it. It is there to turn the output down while the recovery rates are still being tuned. What is too small for a whole item still banks toward the next one, so a low rate slows output rather than stopping it. Grinding and crushing are orders, not byproducts, and keep their full yield. Applies from the next job, with no data cycle."),
        bind_tooltip(self.btn_restore, "Restore Default Settings",
            "Resets every configuration value and all hotkey bindings to their original defaults: autosave interval, pause on save, material finishes, invasiveness, base metal protection, polling rate, log detail, byproducts, byproduct rate, all theme colours, and all eleven global hotkeys. A confirmation prompt appears before anything changes. If material finishes or base metal protection changes with the restore, it also cancels active Refinish Metal jobs and runs a full data cycle, as those settings do."),
        bind_tooltip(self.w_theme_pri, "Primary Colour",
            "The dominant foreground colour. Used for panel headers, active/selected values in cycle widgets, hotkey key labels, and confirmation prompt text."),
        bind_tooltip(self.w_theme_sec, "Secondary Colour",
            "The standard body text colour. Used for list entries, cycle widget labels, button text, and most informational labels throughout the UI."),
        bind_tooltip(self.w_theme_ter, "Tertiary Colour",
            "A general-purpose accent colour. Used for DETAIL lines in the event log, the debug output shown at the Debug log level; for the Origin line the Inspect panel gives Refinish Metal's own materials and reactions; and on this page for the settings that turn output down without turning it off: NO DUST and Byproduct Rates under 100%."),
        bind_tooltip(self.w_theme_nb, "Neutral Bold",
            "Used for section headers such as 'SYSTEM SETTINGS', 'UI NAVIGATION HOTKEYS' and 'THEME COLOURS', for the event log's cursor, and in the Base Metals list for a selected metal your civilization does not know."),
        bind_tooltip(self.w_theme_ns, "Neutral Soft",
            "Used in the Base Metals list for a metal your civilization does not know, while it is not selected, and for a metal no civilization can make, marked with an asterisk."),
        bind_tooltip(self.w_theme_rl, "Caution",
            "Used for low-severity notices, such as a dwarf cancelling a grind of a protected base metal, the notice that the mod's script files can be found again, the hard shutdown's warning before it cancels jobs, and a loop costing 2 percent of the machine's time or more in the status panel."),
        bind_tooltip(self.w_theme_rm, "Warning",
            "Used for mid-severity notices, such as the one after a map unload that had to use the mod's kept copies of its scripts, a module whose settings were refused, a failed diagnostic dump, and a loop costing a tenth of the machine's time or more in the status panel."),
        bind_tooltip(self.w_theme_rh, "Danger",
            "Used for high-severity states: critical failures, the alarm when the mod's script files go missing while the game runs, and the notice when the mod could not take its data out of memory as a map unloaded."),
    }})
    self:addviews(views)
end

-- ==========================================
-- KEY INPUT HANDLER
-- ==========================================
function RefinishPanelConfig:onInput(keys)
    for _, c in ipairs(self.cycles) do if keys[c.key] then c.cycle(); return true end end
    for key_name, action in pairs(self.actions) do if keys[key_name] then action(); return true end end
    return RefinishPanelConfig.super.onInput(self, keys)
end

return _ENV