--@ module = true
-- refinish-warning.lua
-- ==========================================
-- THE OPTIONS SCREEN SHORTCUT
-- ==========================================
-- This overlay was the save warning: red while RM's data was loaded,
-- telling the player not to save from the options screen, and in AUTO
-- saying the data was being unloaded, because opening the screen
-- unloaded it. refinish-save-hook.lua now unloads RM for the game's own
-- saves from the moment one is asked for, so every save from this
-- screen is safe, and the warning went with the ESC-menu data cycle
-- (2026-09-29). It had also been reading two core flags only, so it
-- could say nothing true about a module's data.
--
-- What stays is the shortcut to Refinish Metal's configuration. The
-- file, class and widget names are kept, so the widget keeps its
-- identity in DFHack's overlay settings and control panel; its stored
-- position is reset by its version (WHERE THE BOX SITS).
-- ==========================================

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

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
-- SUBJECT is the correlation slot: the overlay control a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'OVERLAY'
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
-- WHERE THE BOX SITS
-- ==========================================
-- Directly over the ESC menu. The 52x11 warning box sat there at
-- x = 70, y = 10 (positive values count from the left and top of the
-- interface area). The shortcut keeps that box's centre column and
-- bottom row: 46 wide puts its left edge 3 columns further right
-- (x = 73), 3 tall puts its top 8 rows lower (y = 18).
--
-- version went from "3.2" to "4.0.0": DFHack resets a widget's stored
-- position and enabled state when its version changes, so a position
-- saved for the 52x11 box cannot hold this one out of place.
--
-- WIDTH: 46 fits the longest binding the configuration panel offers,
-- "Ctrl-Shift-" and a letter (12 characters), then ": Refinish Metal
-- Configuration" (30), with a space either side, inside the border.
-- A shorter binding is centred (THE LINE, below).
-- ==========================================
local BOX_W, BOX_H = 46, 3
local INNER_W = BOX_W - 2   -- the border takes a column each side
local LABEL = 'Refinish Metal Configuration'

-- ==========================================
-- THE REAL HOTKEY
-- ==========================================
-- The configuration panel saves the player's binding in site data
-- (refinish_hk_config, refinish-panel-config.lua) and binds it to
-- 'refinish-hud show config'. refinish_steel.lua binds the same key at
-- map load with no focus context, so it opens the configuration from
-- this screen as well. This overlay therefore binds no key of its own
-- (it used to bind Alt+C, which nothing else knew about): it shows the
-- real binding, and a click on it opens the same screen.
--
-- Read on every frame the box is drawn, cheaply: the stored text is
-- fetched without decoding (getSiteDataString, one C++ read) and is
-- decoded only when it changes, which is when the panel saves a new
-- binding. The same pattern as PROTECTED BASES, CACHED in
-- refinish_steel.lua. false, not nil, marks "never read": nil is what a
-- fort with no saved binding returns, and it reads as the default.
-- ==========================================
local HK_PREF, HK_DEFAULT = 'refinish_hk_config', 'Ctrl-Shift-C'
local hk_raw_seen, hk_shown = false, HK_DEFAULT

local function config_hotkey()
    local raw = nil
    pcall(function() raw = dfhack.persistent.getSiteDataString(HK_PREF) end)
    if raw == hk_raw_seen then return hk_shown end
    hk_raw_seen = raw
    local v = nil
    pcall(function() v = dfhack.persistent.getSiteData(HK_PREF) end)
    hk_shown = (type(v) == 'string' and v ~= '') and v or HK_DEFAULT
    return hk_shown
end

-- ==========================================
-- THE LINE
-- ==========================================
-- "<binding>: Refinish Metal Configuration", centred in the inner
-- width. The key in light green and the label in light blue, the
-- colours this shortcut has always used (RM's PRI and SEC defaults).
-- ==========================================
local function pad_text()
    local len = #config_hotkey() + 2 + #LABEL
    return string.rep(' ', math.max(0, math.floor((INNER_W - len) / 2)))
end

-- A click opens what the hotkey opens. This used to run
-- 'refinish-config show', and RM has no script of that name, so the
-- shortcut could never open anything.
local function open_config()
    -- DETAIL: menu navigation is only useful when debugging.
    log('DETAIL', 'Configuration opened from the options screen shortcut.',
        'SHORTCUT')
    local ok, err = pcall(dfhack.run_script, 'refinish-hud', 'show', 'config')
    if not ok then
        -- ERROR: the click did nothing. The hotkey runs the same command,
        -- so the reason here is the reason it would fail too.
        log('ERROR', 'The configuration did not open: ' .. tostring(err),
            'SHORTCUT')
    end
end

RefinishWarningOverlay = defclass(RefinishWarningOverlay, overlay.OverlayWidget)
RefinishWarningOverlay.ATTRS = {
    desc = "Refinish Metal configuration shortcut on the options screen",
    -- WHERE THE BOX SITS, above: position, version and size together.
    default_pos = {x = 73, y = 18},
    default_enabled = true,
    viewscreens = 'dwarfmode/Options',
    version = "4.0.0",

    -- One line inside a bold border.
    frame = {w = BOX_W, h = BOX_H},
    frame_style = gui.FRAME_BOLD,
    frame_background = gui.CLEAR_PEN,

    visible = function() 
        -- Hide entirely if the master mod state is dormant (Vanilla saves)
        if not _G.refinish_active then return false end

        local focus = dfhack.gui.getCurFocus()
        
        if type(focus) == 'table' and #focus == 1 and focus[1] == 'dwarfmode/Options' then
            return true
        end
        
        return false
    end,
}

function RefinishWarningOverlay:init()
    self:addviews{
        -- THE LINE: the whole inner row, so a click anywhere on it counts.
        widgets.Label{
            frame = {l = 0, t = 0, r = 0},
            text = {
                {text = pad_text},
                {text = config_hotkey, pen = COLOR_LIGHTGREEN},
                {text = ': ' .. LABEL, pen = COLOR_LIGHTBLUE},
            },
            on_click = open_config,
        }
    }
end

OVERLAY_WIDGETS = { warning = RefinishWarningOverlay }