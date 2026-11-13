--@ module = true
-- refinish-bank-readout.lua
-- ==========================================
-- RM BANK READOUT: THE SHOULDER TAP
-- ==========================================
-- A small always-on panel beside the building sheet, whenever the open
-- building holds something back, showing what it holds.
--
-- WHY THIS EXISTS. A bank holds what a job earned under a whole item. On
-- small inputs a job can complete and drop NOTHING, correctly, several
-- runs in a row, and a log line explains that to nobody, because nobody
-- reads the log while wondering if the mod is broken. This panel sits in
-- their eyeline instead: the job finishes empty, these numbers tick up,
-- and the mechanism explains itself.
--
-- RM'S, NOT A MODULE'S (2026-10-04). It began as Making Fuel's fuel bank
-- readout, but banking is not only fuel's: DF's own melt keeps part bars
-- in every smelter, per metal, and shows them nowhere. So the panel is
-- RM's machinery, and what it shows comes from PROVIDERS.
--
-- ---- PROVIDERS ----
-- Anything that banks registers a function under a name of its own:
--     _G.refinish_bank_providers = _G.refinish_bank_providers or {}
--     _G.refinish_bank_providers.<name> = { order = <number>, fn = <function> }
-- fn(bld) is handed the open building and returns nil when it shows
-- nothing there, or a SECTION:
--     title    optional; the first section's title heads the panel, and a
--              later section's heads its own rows, as a line of its own
--     rows     in display order, each either
--                { key = <k>, label = <text>, value = <number>, full = <bool> }
--              a bar row: the label (18 columns), a ten-cell bar and the
--              value, in the row's own unit, where 1.00 is one whole
--              payout; full turns the row green (earned and waiting), or
--                { key = <k>, text = <text>, pen = <pen> }
--              a line drawn as given. key names the row for the flash and
--              must be unique across every provider.
--     footers  dim lines under the section's rows, 42 columns at most
--              (LENGTH IS LOAD BEARING, in making-fuel-bank-readout.lua)
-- Sections draw in order, lowest first. Each fn runs under pcall, on every
-- frame the panel is up, so it must be cheap.
-- A provider registers at its own load. The overlay plugin loads every
-- script that can load as a module when a world loads (script-manager's
-- foreach_module_script, the same scan that finds this file's widget), so
-- a provider file needs no other caller.
-- Today: Making Fuel's fuel banks (making-fuel-bank-readout.lua, order 10)
-- and the smelters' part bars (refinish-melt.lua, order 20).
--
-- PATTERN PARENT: refinish-warning.lua. Same overlay plugin, same
-- discovery path, same visible() shape gated on _G.refinish_active.
-- Registered by the OVERLAY_WIDGETS export at the bottom, so nothing
-- needs to start or stop it. Dormant saves hide it the same way the
-- warning hides.
-- ==========================================

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui     = require('gui')

_G.refinish_bank_providers = _G.refinish_bank_providers or {}

-- ==========================================
-- THE ROW CEILING
-- ==========================================
-- The Label's line count is fixed when its token list is PARSED, not
-- when the text callbacks run. `token.line` is documented as reserved
-- for internal use, and it is assigned once, at construction. So the
-- widget always renders exactly as many rows as it was last built with,
-- and the frame must be tall enough for ALL of them or the Label
-- scrolls. Undersizing it put a scrollbar on the fuel panel three times.
-- The rows are rebuilt (set_rows) when the count changes, off the render
-- path, in overlay_onupdate.
-- MAX_LINES is the most rows the panel will build: rows and footers
-- together, past which the last row says how many more there are.
-- START_LINES is what it is built with before the first update sizes it.
local MAX_LINES   = 40
local START_LINES = 8
local LABEL_W     = 18
local FLASH_MS    = 900

-- ==========================================
-- GATHERING THE SECTIONS
-- ==========================================
-- The building on the open sheet, or nil. Everything is pcall wrapped: a
-- nil anywhere means hide, never an error painted over the screen.
local function open_building()
    local b = nil
    pcall(function() b = dfhack.gui.getSelectedBuilding(true) end)
    return b
end

-- Every provider's section for one building, in order. A provider that
-- errors, returns nothing, or returns a section with neither rows nor
-- footers adds nothing.
local function sections_for(bld)
    local list = {}
    for name, p in pairs(_G.refinish_bank_providers or {}) do
        if type(p) == 'table' and type(p.fn) == 'function' then
            list[#list + 1] = { name = tostring(name), order = tonumber(p.order) or 100, fn = p.fn }
        end
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    local out = {}
    for _, p in ipairs(list) do
        local ok, s = pcall(p.fn, bld)
        if ok and type(s) == 'table'
           and ((type(s.rows) == 'table' and #s.rows > 0)
                or (type(s.footers) == 'table' and #s.footers > 0)) then
            out[#out + 1] = s
        end
    end
    return out
end

-- ONE GATHERING A FRAME. visible(), overlay_onupdate and the render pass
-- all ask on the same frame; the providers run once for them all. Keyed on
-- the wall clock's tick and the building, so a different sheet, or the
-- next frame, gathers afresh.
local memo_at, memo_bid, memo_secs = nil, nil, nil
local function sections_now()
    local bld = open_building()
    if not bld then return nil, nil end
    local now = dfhack.getTickCount()
    if memo_at == now and memo_bid == bld.id and memo_secs then return memo_secs, bld end
    local secs = sections_for(bld)
    memo_at, memo_bid, memo_secs = now, bld.id, secs
    return secs, bld
end

-- ==========================================
-- LINES FROM SECTIONS
-- ==========================================
-- One bar row as a line. The number is the bank in the row's own unit,
-- so 1.00 means one of whatever the row pays, on every row. Under one the
-- bar fills toward it; at one or more it sits FULL, because there is
-- nothing left to fill toward, and a full bar beside a number above one
-- reads as overfilled at a glance. The bar and the number are FIXED
-- width, 12 and 6, so a row is the label plus 20 against 43 usable
-- columns inside the 45 wide frame.
local function bar_text(label, value)
    local v = tonumber(value) or 0
    local fill = (v >= 1) and 10 or math.floor((v % 1) * 10 + 0.0001)
    if fill < 0 then fill = 0 end
    return string.format('%-' .. LABEL_W .. 's [%s%s]  %6.2f',
        tostring(label or '?'):sub(1, LABEL_W),
        string.rep(string.char(219), fill),
        string.rep(string.char(250), 10 - fill),
        v)
end

-- ---- THE FLASH ----
-- A row whose value just moved turns light green for FLASH_MS, then falls
-- back on its own: growth and payout alike, since a bank that just paid
-- drops by a whole coin and that is the moment worth catching the eye
-- with. The clock is wall time from getTickCount, so pausing right after
-- a run cannot freeze a green row. The first sight of a row records
-- silently; a change that happened while the sheet was closed flashes
-- once on the next open, which is the feature working: what moved since
-- you last looked. Kept per BUILDING: keyed by currency alone, as the
-- fuel panel was, opening one furnace after another flashed every row
-- whose bank differed between the two (seen in the mock, 2026-10-04).
local last_val, flash_until = {}, {}

local function observe(key, value, now)
    if key == nil or value == nil then return false end
    local seen = last_val[key]
    if seen ~= nil and math.abs(value - seen) > 1e-9 then
        flash_until[key] = now + FLASH_MS
    end
    last_val[key] = value
    local u = flash_until[key]
    return u ~= nil and now < u
end

-- The panel's lines for these sections: { t = text, p = pen } each, rows
-- then footers, section by section, at most MAX_LINES (THE ROW CEILING),
-- the last of them then saying how many more. observe_now is true on the
-- render pass only, so the flash clock moves once a pass; bid is the open
-- building's id, which scopes the flash (THE FLASH).
local function lines_of(secs, observe_now, bid)
    local now = dfhack.getTickCount()
    local all = {}
    for si, s in ipairs(secs or {}) do
        -- A section after the first heads its rows with its own title, the
        -- first one's being the panel's (title, in init): a smelter reads
        -- 'furnace bank' over the fuel rows and 'melt bank' over its part
        -- bars. Counted like any row, so the resize sees it.
        if si > 1 and s.title and s.title ~= '' then
            all[#all + 1] = { t = tostring(s.title), p = COLOR_YELLOW }
        end
        for _, r in ipairs(s.rows or {}) do
            if type(r) == 'table' then
                if r.text ~= nil then
                    all[#all + 1] = { t = tostring(r.text), p = r.pen or COLOR_WHITE }
                else
                    local v = tonumber(r.value) or 0
                    local lit = observe_now and r.key ~= nil
                        and observe(tostring(bid) .. '|' .. tostring(r.key), v, now)
                    -- An overfilled bank holds output that is earned and
                    -- waiting, so its row stays green while that is true,
                    -- rather than for FLASH_MS. Bars carry COLOR_WHITE
                    -- explicitly because what a pen callback returning nil
                    -- does is unspecified.
                    all[#all + 1] = { t = bar_text(r.label, v),
                                      p = (r.full or lit) and COLOR_LIGHTGREEN or COLOR_WHITE }
                end
            end
        end
        for _, f in ipairs(s.footers or {}) do
            all[#all + 1] = { t = tostring(f), p = COLOR_DARKGREY }
        end
    end
    if #all > MAX_LINES then
        local more = #all - (MAX_LINES - 1)
        local cut = {}
        for i = 1, MAX_LINES - 1 do cut[i] = all[i] end
        cut[MAX_LINES] = { t = ('... and %d more line(s)'):format(more), p = COLOR_DARKGREY }
        all = cut
    end
    return all
end

-- ==========================================
-- THE WIDGET
-- ==========================================
RefinishBankReadout = defclass(RefinishBankReadout, overlay.OverlayWidget)
RefinishBankReadout.ATTRS = {
    desc = 'RM bank readout: what the open building holds back',
    -- POSITIONING RULE: never over gameplay. Negative x anchors from the
    -- RIGHT edge, the same edge the sheet anchors to, so this holds its
    -- distance from the sheet on any monitor; y clears the top bar. The
    -- number is sheet width plus this panel plus a gap; players drag it in
    -- gui/overlay and the drag persists per player, so this is a starting
    -- point, not law. The fuel panel's own place, kept.
    default_pos = { x = -132, y = 5 },
    default_enabled = true,
    -- The BUILDING prefix, which the furnace work OBSERVED working:
    -- matching is by prefix, and it reaches workshops (the still, the
    -- kitchen, the metalsmith's forge) as well as furnaces. On a sheet no
    -- provider has anything for, visible() hides the panel.
    viewscreens = 'dwarfmode/ViewSheets/BUILDING',
    version = '1.0',

    -- The default throttle is FIVE SECONDS. The panel has to resize the
    -- moment the player opens a different building, so it asks to be
    -- called at the maximum rate. The widget only runs at all while a
    -- building sheet is open.
    overlay_onupdate_max_freq_seconds = 0,

    -- OUTER size: the header line, the rows, and the 2 the border takes.
    -- Resized by set_rows to what the open building draws.
    frame = { w = 45, h = 1 + START_LINES + 2 },
    frame_style = gui.FRAME_BOLD,
    frame_background = gui.CLEAR_PEN,

    visible = function()
        if not _G.refinish_active then return false end
        -- Interference guard. Negative x is a right-edge offset and the
        -- framework does not clamp, so on an interface grid narrower than
        -- the offset this panel would walk into the map. An overlay that
        -- cannot fit HIDES; it never overlaps gameplay.
        local sw = dfhack.screen.getWindowSize()
        if sw and sw < 104 then return false end
        -- Stand down under a modal child. The magnifying glass pushes
        -- JobDetails ON TOP of the sheet without replacing it, so the
        -- viewscreens prefix still matches and this panel would keep its
        -- z-order over the popup. THE LAST ENTRY IS THE TOP OF THE STACK:
        -- getCurFocus(true) returns parents too. Measured with the job
        -- list open:
        --   dwarfmode/ViewSheets/BUILDING/Furnace/Custom/Tasks
        --   dwarfmode/ViewSheets/BUILDING/Furnace/Custom/Items
        --   dwarfmode/JobDetails/BUILDING_TASK_LIST
        -- Inline, NOT a local function: this block is inside a TABLE
        -- CONSTRUCTOR, where `local` is a parse error and the whole script
        -- fails to load.
        local ok, covered = pcall(function()
            local st = dfhack.gui.getCurFocus(true) or {}
            local top = st[#st]
            if not top then return false end
            return not top:find('ViewSheets/BUILDING', 1, true)
        end)
        if ok and covered then return false end
        -- Stand down for DF's stockpile link window as well. The sheet's
        -- "Add stockpile links for this workshop" button opens it on the
        -- same screen, not as a child, so the top of the focus stack stays
        -- on the sheet and the check above never sees it. DFHack names it
        -- only while a new link is being picked, and that name still sits
        -- under the sheet (dwarfmode/ViewSheets/BUILDING/LinkingStockpile);
        -- the rest of the time it reads the sheet's own string (Gui.cpp,
        -- getFocusStrings). DF's own flag says the window is up:
        -- main_interface.stockpile_link.open, the field DFHack reads for it
        -- (df-structures, stockpile_link_interfacest). Read under pcall, so
        -- a DF without the field shows the panel as before.
        -- SEEN 2026-10-17: at a quern, this panel drew over that window and
        -- hid the links.
        local ok_l, linking = pcall(function()
            return df.global.game.main_interface.stockpile_link.open
        end)
        if ok_l and linking then return false end
        local secs = sections_now()
        return secs ~= nil and #secs > 0
    end,
}

function RefinishBankReadout:init()
    -- ---- LINES, BUILT ONCE PER RENDER PASS ----
    -- Label tokens whose text is a FUNCTION re-evaluate every render, so a
    -- job completing while the sheet is open moves the numbers in front of
    -- the player with no refresh machinery at all. The first slot's text
    -- callback rebuilds this cache; every other callback only reads it, so
    -- one render pass sees one consistent picture.
    local cache = nil
    local function lines_now(rebuild)
        if cache and not rebuild then return cache end
        local ok, built = pcall(function()
            local secs, bld = sections_now()
            return lines_of(secs, true, bld and bld.id)
        end)
        cache = ok and built or { { t = 'bank rows: ?', p = COLOR_WHITE } }
        return cache
    end

    local function text_at(i)
        return function()
            local e = lines_now(i == 1)[i]
            return e and e.t or ''
        end
    end
    local function pen_at(i)
        return function()
            local e = lines_now(false)[i]
            return e and e.p or COLOR_WHITE
        end
    end

    -- The title is the first section's, the building's kind of bank: the
    -- fuel panel's 'furnace bank', 'still bank' or 'kitchen bank', or the
    -- smelter's own when only its part bars show. A function, because the
    -- widget is built once and the open building changes underneath it.
    local function title()
        local t = 'bank'
        pcall(function()
            local secs = sections_now()
            for _, s in ipairs(secs or {}) do
                if s.title and s.title ~= '' then
                    t = tostring(s.title)
                    return
                end
            end
        end)
        return t
    end

    -- Names the building this panel is reading. getName gives the custom
    -- def's name for a retort and the vanilla name for the rest. The id is
    -- what separates two of the same kind, and it is the same id the bank
    -- keys use, so a player reading 'BANK_OIL_BONE@5' in the log can find
    -- building 5 on screen.
    local function subtitle()
        local s = nil
        pcall(function()
            local bld = open_building()
            if not bld then return end
            local name = dfhack.buildings.getName(bld)
            if name and name ~= '' then
                s = string.format('  %s [ID:%d]', tostring(name), bld.id)
            else
                s = string.format('  building [ID:%d]', bld.id)
            end
        end)
        return s or '  this building'
    end

    local function build_tokens(n)
        local t = {
            { text = title, pen = COLOR_YELLOW },
            { text = subtitle, pen = COLOR_DARKGREY },
        }
        for i = 1, n do
            t[#t + 1] = NEWLINE
            t[#t + 1] = { text = text_at(i), pen = pen_at(i) }
        end
        return t
    end

    -- ---- REBUILT ON SHAPE CHANGE, NOT ON RENDER ----
    -- setText on the render path, with a nil upvalue underneath it, once
    -- shipped the fuel panel blank. This runs from overlay_onupdate, off
    -- the render path, and only when the ROW COUNT changes, which is when
    -- the player opens a different kind of building or a new metal joins
    -- a smelter's part bars. A steady panel never calls it. Guarded so a
    -- failure is a stale size rather than a blank panel.
    self.rows_built = START_LINES
    self.set_rows = function(n)
        if type(n) ~= 'number' or n < 1 or n > MAX_LINES then return end
        if n == self.rows_built then return end
        local ok = pcall(function()
            self.subviews.bank_body:setText(build_tokens(n))
            self.frame.h = 1 + n + 2
        end)
        if ok then self.rows_built = n end
    end

    self:addviews{
        widgets.Label{
            view_id = 'bank_body',
            frame = { t = 0, l = 1 },
            text = build_tokens(START_LINES),
        },
    }
end

-- ---- THE RESIZE ----
-- Off the render path, throttle 0 so it lands the frame the sheet opens
-- on. The count is lines_of's, the same lines the render draws, so the
-- height and the content are never computed two different ways. Does
-- nothing when nothing shows: visible() already hides the panel there.
function RefinishBankReadout:overlay_onupdate()
    local secs = sections_now()
    if not secs or #secs == 0 then return end
    local n = #lines_of(secs, false)
    if n > 0 and self.set_rows then self.set_rows(n) end
end

-- For the mock tests: the line builder, without the widget.
_G.refinish_bank_lines = lines_of

OVERLAY_WIDGETS = { banks = RefinishBankReadout }
