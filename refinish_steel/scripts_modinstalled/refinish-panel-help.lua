--@ module = true
-- refinish-panel-help.lua

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')

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
-- SUBJECT is the correlation slot: the panel action a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'HELP'
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
-- TEXT WRAPPING HELPER (With Paragraph Support)
-- Splits text into display lines that fit within max_width.
-- Blank lines in the source text produce blank separator lines.
-- ==========================================
local function wrap_help_text(text, max_width)
    local lines = {}
    if not text or text == "" then return lines end
    
    for paragraph in string.gmatch(text .. "\n", "(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "") 
        else
            local current_line = ""
            for word in paragraph:gmatch("%S+") do
                if current_line == "" then
                    current_line = word
                elseif #current_line + 1 + #word <= max_width then
                    current_line = current_line .. " " .. word
                else
                    table.insert(lines, current_line)
                    current_line = word
                end
            end
            if current_line ~= "" then
                table.insert(lines, current_line)
            end
        end
    end
    return lines
end

-- ==========================================
-- HELP SYSTEM DATA DICTIONARY
-- Each topic has: id, title, keywords[], text
-- Keywords drive search; include synonyms and alternate phrasings.
-- Text uses \n for line breaks and \n\n for paragraph spacing.
--
-- Every statement here is checked against the code it describes
-- (2026-10-07). This is where players look first, so when the code
-- changes, the topic changes with it.
-- ==========================================
local HELP_TOPICS = {

    -- ----------------------------------------
    -- OVERVIEW
    -- ----------------------------------------
    {
        id       = "overview",
        title    = "Overview",
        keywords = {"overview", "about", "what", "features", "summary", "introduction", "rawless"},
        text     =
            "Refinish Metal is a rawless DFHack mod that adds a material finishing " ..
            "system to Dwarf Fortress. Dust ground from stone, gems or metal is " ..
            "combined with bars of a base metal at a Smelter. The result is a " ..
            "finished bar: a new material with the base metal's physical properties " ..
            "and the dust's colour and name.\n\n" ..
            "Every sufficiently craftable metal in your world is a base by default, " ..
            "and the Base Metals panel can narrow the selection. Finishes are made as " ..
            "your fort needs them: a base metal's finishes for a dust appear once the " ..
            "fort has had that metal's bars and that dust.\n\n" ..
            "All custom data is loaded into RAM after map load and taken out before " ..
            "any save. Finished items keep their materials in the save, and a ledger " ..
            "in site data moves them back into place by name on every reload. Loaded " ..
            "without Refinish Metal, they show as plain rock.\n\n" ..
            "KEY FEATURES\n" ..
            "- Configurable base metals: finish any qualifying metal, not just steel.\n" ..
            "- Grind stone, gems and metal bars into dust at a Quern or Millstone.\n" ..
            "- Combine dust and base metal bars at a Smelter to make finished bars.\n" ..
            "- Three kinds of finish: colour, special and material.\n" ..
            "- Byproducts: jobs that destroy material pay part of it back as dust.\n" ..
            "- Dust also makes grog bricks and mineral dyes, and metal dust melts " ..
            "back into bars.\n" ..
            "- Reads live world data and economy on every load; modpack-compatible.\n" ..
            "- Every way of saving takes the mod's data out first, and the mod's own " ..
            "autosave replaces vanilla's.\n" ..
            "- Status dashboard, live event log and object inspector for diagnostics."
    },

    -- ----------------------------------------
    -- GETTING STARTED
    -- ----------------------------------------
    {
        id       = "getting_started",
        title    = "Getting Started",
        keywords = {"start", "begin", "new", "first time", "install", "welcome", "setup", "how to"},
        text     =
            "FIRST LOAD\n" ..
            "On first install, a prompt says Refinish Metal is online; press OK to " ..
            "open System Settings. At minimum, check your autosave interval before " ..
            "playing.\n\n" ..
            "DATA LOADS AT ONCE\n" ..
            "Mod data is loaded the moment a save finishes loading, before the first " ..
            "game tick.\n\n" ..
            "BASIC WORKFLOW\n" ..
            "1. Check your base metals in the Base Metals panel (see 'Base Metals'). " ..
            "Every valid base metal is active by default.\n" ..
            "2. At a Quern or Millstone, order a grind job: 'grind common stone into " ..
            "dust', 'grind any stone into dust', 'grind rough gems into dust' or " ..
            "'grind metal bars into dust'.\n" ..
            "3. The dwarf grinds the material into dust, in stacks. No bag is needed.\n" ..
            "4. At a Smelter, order a finishing reaction: 6 dust of one material and " ..
            "3 bars of a base metal make 3 finished bars. A finish's reaction appears " ..
            "once your fort has had that dust and those bars.\n\n" ..
            "SAVING\n" ..
            "Save any way you like; see 'Saving Safely'. The mod's autosave and " ..
            "quicksave (Ctrl-Shift-S) replace vanilla's autosave."
    },

    -- ----------------------------------------
    -- BASE METALS
    -- ----------------------------------------
    {
        id       = "base_metals",
        title    = "Base Metals",
        keywords = {"base", "bases", "metal", "steel", "iron", "configure", "select", "activate", "valid", "crafting path", "smelting", "ctrl shift m"},
        text     =
            "The base metal is what gets finished. Dust is applied to bars of the " ..
            "base metal at a Smelter, making finished bars that keep the base metal's " ..
            "physical and combat properties, with a new colour, name and value.\n\n" ..
            "Every metal in your world that passes the checks below is active by " ..
            "default; the Base Metals panel can narrow the selection.\n\n" ..
            "WHICH METALS QUALIFY\n" ..
            "- Carries the IS_METAL flag.\n" ..
            "- Has a crafting or smelting path. Metals nothing can make are left out.\n" ..
            "- Has a melting point of 0 or above 10015, so it stays solid in play.\n" ..
            "- Has a material value of 0 or more.\n" ..
            "- Carries at least one item flag, such as ITEMS_METAL, ITEMS_WEAPON, " ..
            "ITEMS_ARMOR or ITEMS_HARD.\n" ..
            "- Is not DIVINE or MYTHICAL.\n\n" ..
            "THE BASE METALS PANEL\n" ..
            "Open it from the main nav or with Ctrl-Shift-M. Selected metals are " ..
            "listed first, then those your civilization knows, then the rest. Hover " ..
            "any entry to see its raw data. Shift-A selects all, Shift-C clears all, " ..
            "Shift-S saves and Shift-D discards your changes. Saving asks first, then " ..
            "cancels jobs on Refinish Metal materials and runs a full data cycle.\n\n" ..
            "Each active base gets its own finishes and reactions as your fort makes " ..
            "them, so more active bases means more of both over time."
    },

    -- ----------------------------------------
    -- GRINDING DUST
    -- ----------------------------------------
    {
        id       = "grinding",
        title    = "Grinding Dust",
        keywords = {"grind", "grinding", "dust", "quern", "millstone", "stone", "gem", "metal", "yield", "reagent", "protect"},
        text     =
            "Grinding turns stone, gems and metal bars into dust, which gives a " ..
            "finished bar its colour and name. It happens at a Quern or Millstone, " ..
            "needs no bag, and makes dust in stacks. The skill depends on what is " ..
            "ground.\n\n" ..
            "STONE | Masonry\n" ..
            "- 'grind common stone into dust' takes non-economic boulders.\n" ..
            "- 'grind any stone into dust' takes economic stone as well, without " ..
            "changing your economic stone settings.\n" ..
            "- 1 boulder makes 50 dust, in 4 stacks.\n\n" ..
            "GEMS | Gem Cutting\n" ..
            "- 'grind rough gems into dust' takes 3 rough gems and makes 3 dust. The " ..
            "three quarters left over is kept at that workshop for its next grind.\n\n" ..
            "METALS | Metalcraft\n" ..
            "- 'grind metal bars into dust' takes 1 bar and makes 3 dust.\n" ..
            "- It takes unfinished metals only. With Protect Bases on, it also leaves " ..
            "your active base metals alone.\n" ..
            "- Finished bars are ground in the 'Grind finished metals' folder, one " ..
            "grinder per base metal, there once the fort has that base's finishes. " ..
            "That dust melts back into bars of the same finish and never finishes a " ..
            "bar.\n\n" ..
            "Once a dwarf picks the item up, the job is named for it, as in 'grind " ..
            "cinnabar into dust'.\n\n" ..
            "WHICH MATERIALS QUALIFY\n" ..
            "The scanner checks every inorganic in the world at startup. A material " ..
            "qualifies when it:\n" ..
            "- Is stone, metal, gem, soil or sand (IS_STONE, IS_METAL, IS_GEM, " ..
            "SOIL_ANY or SOIL_SAND).\n" ..
            "- Has a crafting or smelting path, if it is a metal.\n" ..
            "- Has a melting point of 0 or above 10015.\n" ..
            "- Has a material value of 0 or more."
    },

    -- ----------------------------------------
    -- BRICKS, DYES & MELTING
    -- ----------------------------------------
    {
        id       = "using_dust",
        title    = "Bricks, Dyes & Melting",
        keywords = {"dust", "grog", "brick", "bricks", "kiln", "clay", "dye", "dyes", "dyer", "mineral dye", "melt", "melting", "smelter", "part bar", "scrap"},
        text     =
            "Dust has uses beyond finishing.\n\n" ..
            "GROG BRICKS\n" ..
            "- At a Kiln, 'make clay bricks with stone dust' fires a clay boulder and 13 " ..
            "stone dust into 8 clay bricks. Clay alone makes 6.\n\n" ..
            "MINERAL DYES\n" ..
            "- At a Dyer's Shop, 2 dust of a stone, gem or metal and an empty bag " ..
            "make a dye of that material's colour. Each material has its own row " ..
            "under Make dye > Make mineral dye.\n\n" ..
            "MELTING\n" ..
            "- Metal dust melts like any metal item: mark it for melting and queue " ..
            "'melt a metal object' at a Smelter.\n" ..
            "- Every melt returns nine tenths of what is in what it melted. A dust " ..
            "holds a third of a bar; anything else holds what it cost to make, or its " ..
            "own volume if that is less. Melting always loses metal; it never makes " ..
            "it.\n" ..
            "- A smelter keeps part bars, per metal, until they make a whole one. Its " ..
            "sheet shows its melt bank."
    },

    -- ----------------------------------------
    -- FINISHING BARS
    -- ----------------------------------------
    {
        id       = "finishing",
        title    = "Finishing Bars",
        keywords = {"finish", "finishing", "smelter", "combine", "bar", "reaction", "colour", "color", "special", "material finish", "output", "fuel"},
        text     =
            "Finishing reactions take place at a Smelter or Magma Smelter. Each takes " ..
            "6 dust of one material and 3 bars of a base metal, and makes 3 finished " ..
            "bars: the base metal with a new colour, name and value. At an ordinary " ..
            "Smelter it burns fuel.\n\n" ..
            "A finish's reaction appears once your fort has had that base metal's " ..
            "bars and that dust. Nothing is made for a pair the fort has never had.\n\n" ..
            "KINDS OF FINISH\n" ..
            "1. Colour finish: made whatever the Material Finishes setting. One per " ..
            "colour per base metal, named for the colour (for example 'red steel'). " ..
            "Every dust of that colour makes it.\n\n" ..
            "2. Special finish: made whatever the Material Finishes setting, for 43 " ..
            "materials with names of their own. Gold makes 'gilded' finishes, iron " ..
            "'ironclad', zinc 'galvanized', adamantine 'adamantinized'.\n\n" ..
            "3. Material finish: made only with Material Finishes ON. Named for the " ..
            "material the dust came from (for example 'obsidian steel'). Materials " ..
            "that give the same name share one finish.\n\n" ..
            "A finish whose name already belongs to another material in your world is " ..
            "not made, so it never hides that material.\n\n" ..
            "While Material Finishes is OFF, items in a material finish wait on their " ..
            "base metal and get the finish back when it is ON again. Finishes of a " ..
            "base metal you deselect wait the same way."
    },

    -- ----------------------------------------
    -- VALUE & ECONOMICS
    -- ----------------------------------------
    {
        id       = "economics",
        title    = "Value & Economics",
        keywords = {"value", "worth", "economics", "wealth", "math", "price", "material value", "mv"},
        text     =
            "A finished bar's value starts from its base metal's material value, " ..
            "which is the floor. Every value is read from your world's live data on " ..
            "every load, so mods that change values are reflected.\n\n" ..
            "COLOUR AND SHARED FINISHES\n" ..
            "A colour finish, and any finish several materials make, is worth exactly " ..
            "its base metal: one material stands for many reagents, so it carries " ..
            "none of their worth.\n\n" ..
            "FINISHES ONE MATERIAL MAKES\n" ..
            "A special or material finish that only one material makes adds a share " ..
            "of that material's value (v): the share one bar's 2 dust carries.\n" ..
            "- Stone: + floor(v / 25). A boulder makes 50 dust.\n" ..
            "- Metal: + floor(v x 2 / 3). A bar makes 3 dust.\n" ..
            "- Gem: + floor(v x 8 / 5). A rough gem makes 1.25 dust.\n\n" ..
            "Because the base metal's value is the floor, finishes of a higher-value " ..
            "base (platinum, adamantine) are worth more than the same finish on a " ..
            "cheaper one."
    },

    -- ----------------------------------------
    -- BYPRODUCTS & BANKS
    -- ----------------------------------------
    {
        id       = "byproducts",
        title    = "Byproducts & Banks",
        keywords = {"byproduct", "byproducts", "waste", "offcut", "filings", "bank", "banked", "readout", "workshop", "dust"},
        text     =
            "Jobs that destroy material pay part of it back where the work was done, " ..
            "measured from what each job actually used up.\n\n" ..
            "WHAT COMES BACK\n" ..
            "- Stone work: 40% of the stone lost, as dust.\n" ..
            "- Gem cutting: all of the gem lost, as dust.\n" ..
            "- Metal work: 60% of the metal lost, as dust.\n" ..
            "- Installed modules can add byproducts of their own, such as gravel, slag or " ..
            "sawdust.\n\n" ..
            "Amounts too small for a whole item are banked at that workshop until " ..
            "they make one, and kept through saves. A small panel beside a building's " ..
            "sheet shows what it has banked, and a smelter's part bars.\n\n" ..
            "The Byproducts and Byproduct Rate settings turn this down or off (see 'System " ..
            "Configuration')."
    },

    -- ----------------------------------------
    -- FORGE MENUS
    -- ----------------------------------------
    {
        id       = "forge_menus",
        title    = "Forge Menus",
        keywords = {"forge", "menu", "task", "folder", "refinished metals", "back", "category", "list"},
        text     =
            "FORGE TASK MENU\n" ..
            "At a Metalsmith's Forge, each item category files its finished metals in " ..
            "a 'refinished metals' folder, then by base metal, then colour-based or " ..
            "material-based finishes. Vanilla metals stay in the list as usual.\n\n" ..
            "BACK\n" ..
            "Every reaction folder, at any workshop, has a Back entry that returns to " ..
            "the folder above."
    },

    -- ----------------------------------------
    -- SAVING SAFELY
    -- ----------------------------------------
    {
        id       = "saving",
        title    = "Saving Safely",
        keywords = {"save", "saving", "corrupt", "corruption", "manual", "esc", "options", "continue", "quit", "cauldron", "tools", "missing"},
        text     =
            "Refinish Metal's data has to be out of the game's arrays when the game " ..
            "writes a save, and the mod takes care of that on every save.\n\n" ..
            "HOW EACH SAVE IS HANDLED\n" ..
            "- Save & Continue: mod data is unloaded the moment you ask for the save, " ..
            "before the game writes, and reloaded when the options menu closes. The " ..
            "game stays paused in between.\n" ..
            "- Save & Quit: mod data is cleared as the map unloads, which the game " ..
            "does before it writes.\n" ..
            "- Autosave and quicksave (Ctrl-Shift-S): the mod's own cycle unloads, " ..
            "saves and reloads (see 'Autosave Routine').\n\n" ..
            "The short pause when you save is that unload and reload.\n\n" ..
            "IF THE MOD'S FILES GO MISSING\n" ..
            "If Refinish Metal's script files are moved or deleted while the game " ..
            "runs, the mod raises an alarm and refuses Save & Continue rather than " ..
            "write a save that would not load. Put the files back and restart " ..
            "Dwarf Fortress, or quit without saving.\n\n" ..
            "TOOLS\n" ..
            "Items made as tools (dust, and the tools modules add) are recorded " ..
            "before each save and put back after the next load. If one ever comes " ..
            "back as a cauldron, its record was lost."
    },

    -- ----------------------------------------
    -- AUTOSAVE ROUTINE
    -- ----------------------------------------
    {
        id       = "autosave",
        title    = "Autosave Routine",
        keywords = {"autosave", "quicksave", "routine", "cycle", "pause", "purge", "buffer", "telemetry", "interval", "ctrl shift s"},
        text     =
            "Refinish Metal replaces the vanilla autosave, which is switched off " ..
            "while the mod is loaded and restored when it unloads.\n\n" ..
            "AUTOSAVE SEQUENCE\n" ..
            "1. The interval is reached, or Ctrl-Shift-S is pressed.\n" ..
            "2. The game is paused for the whole cycle. Pause on Save decides only " ..
            "whether it stays paused afterwards.\n" ..
            "3. The material ledger records where every custom material sits.\n" ..
            "4. Custom materials, reactions, categories and permissions, and the " ..
            "modules' content, are removed from RAM. Items keep their materials.\n" ..
            "5. A scan confirms memory is clear, checking again every 10 frames until " ..
            "it is. The save is not issued before then.\n" ..
            "6. The game's quicksave is issued.\n" ..
            "7. The moment the save is written, the data is rebuilt and the ledger " ..
            "moves anything that shifted back into place by name, before any game " ..
            "tick runs.\n\n" ..
            "AUTOSAVE INTERVALS\n" ..
            "Seasonal, Semi-Annual, Yearly, 15 minutes, 30 minutes, 1 hour, or Off. " ..
            "Set it in System Settings.\n\n" ..
            "WHEN IT FINISHES\n" ..
            "An announcement gives the cycle's time, unless System Invasiveness is " ..
            "Silent. In Debug, a prompt also waits before the quicksave. The event " ..
            "log keeps the timing of each phase."
    },

    -- ----------------------------------------
    -- SYSTEM CONFIGURATION
    -- ----------------------------------------
    {
        id       = "configuration",
        title    = "System Configuration",
        keywords = {"config", "settings", "options", "hotkey", "rebind", "invasiveness", "polling", "material finishes", "protect", "defaults", "byproducts", "log detail", "colours", "colors", "theme"},
        text     =
            "Open System Settings with Ctrl-Shift-C, or from the shortcut on the " ..
            "options (Esc) screen.\n\n" ..
            "AUTOSAVE\n" ..
            "- Interval: Seasonal (default), Semi-Annual, Yearly, 15 Min, 30 Min, 1 " ..
            "Hour or Off.\n" ..
            "- Pause on Save: the game is paused for every cycle either way. Yes " ..
            "(default) leaves it paused afterwards; No resumes it if it was running.\n\n" ..
            "POLLING RATE\n" ..
            "- How often the grind job watcher checks for new grind jobs: Fast (every " ..
            "10 frames, default), Normal (25) or Relaxed (50). With Protect Bases " ..
            "on, the same watcher cancels a grind that took a protected base metal.\n\n" ..
            "MATERIAL FINISHES\n" ..
            "- ON (default): material finishes are made as well as colour and special " ..
            "ones.\n" ..
            "- OFF: colour and special finishes only; items in a material finish wait " ..
            "on their base metal until it is ON again.\n" ..
            "- Changing it cancels jobs on Refinish Metal materials and runs a full " ..
            "data cycle.\n\n" ..
            "SYSTEM INVASIVENESS\n" ..
            "- Guided (default): a prompt at each load says the mod is online; the " ..
            "startup, shutdown and hard shutdown hotkeys ask first; prompts report " ..
            "what they did, and what a data cycle run by a setting did.\n" ..
            "- Passive: announcements instead of prompts; the shutdown and hard " ..
            "shutdown hotkeys run without asking.\n" ..
            "- Silent: nothing about the mod's own work, the autosave's completion " ..
            "notice included; the shutdown and hard shutdown hotkeys run without " ..
            "asking.\n" ..
            "- Debug: Guided, with timings and counts in its prompts, and a prompt " ..
            "before each autosave's quicksave.\n" ..
            "- At every level the startup hotkey and any setting that runs a data " ..
            "cycle ask first, and alerts and warnings always show.\n\n" ..
            "PROTECT BASES\n" ..
            "- Yes: the metal grinder leaves your active base metals alone. No by " ..
            "default: with every base metal active, it would stop all metal grinding. " ..
            "Changing it runs a full data cycle.\n\n" ..
            "LOG DETAIL\n" ..
            "- What the event log panel shows: Quiet (default: faults and key confirmations), " ..
            "Info (all but debugging detail) or Debug (everything). The " ..
            "log file on disk always keeps everything.\n\n" ..
            "BYPRODUCTS\n" ..
            "- ON (default): jobs that destroy material pay part of it back (see " ..
            "'Byproducts & Banks').\n" ..
            "- NO DUST: every byproduct but dust.\n" ..
            "- OFF: none, and nothing is measured; the material is lost, as in " ..
            "vanilla.\n" ..
            "- Byproduct Rate scales everything the jobs pay, from 100% (the " ..
            "default) down to 10%, for turning the output down while it is " ..
            "still being tuned.\n" ..
            "- Grinding and crushing make dust either way. A change applies from the " ..
            "next job.\n\n" ..
            "COLOURS\n" ..
            "- Each of the panel's colours can be changed: Primary, Secondary, " ..
            "Tertiary, Neutral Bold, Neutral Soft, Caution, Warning and Danger.\n\n" ..
            "HOTKEYS\n" ..
            "- All 11 global hotkeys can be rebound here (see 'Default Hotkeys'). " ..
            "Restore Default Settings (Shift-P) puts every setting and binding back, " ..
            "with a data cycle when that changes Material Finishes or Protect Bases."
    },

    -- ----------------------------------------
    -- SHUTDOWN COMMANDS
    -- ----------------------------------------
    {
        id       = "shutdown",
        title    = "Shutdown Commands",
        keywords = {"shutdown", "wipe", "purge", "unload", "startup", "manual", "hard", "cancel jobs", "ctrl shift x", "ctrl shift q", "ctrl alt x"},
        text     =
            "MANUAL SHUTDOWN (Ctrl-Shift-X)\n" ..
            "Takes all mod data out of RAM: custom materials, reactions and " ..
            "civilization permissions, and the modules' content. Items keep their " ..
            "materials. Saving does not need it; see 'Saving Safely'.\n\n" ..
            "HARD SHUTDOWN (Ctrl-Shift-Q)\n" ..
            "The same, after first cancelling every active job on Refinish Metal " ..
            "materials or reactions.\n\n" ..
            "MANUAL STARTUP (Ctrl-Alt-X)\n" ..
            "Loads mod data back into RAM after a shutdown.\n\n" ..
            "WHY USE HARD SHUTDOWN?\n" ..
            "Removing reactions while a dwarf is mid-job on one can leave the engine " ..
            "in an inconsistent state. Cancelling those jobs first lets the dwarf " ..
            "reset cleanly. Use it when dwarves are working grinding or finishing " ..
            "jobs, or when you purge with the game unpaused.\n\n" ..
            "A hard shutdown and startup also run by themselves when you change " ..
            "Material Finishes, Protect Bases or the Base Metals selection, and when " ..
            "Restore Default Settings changes either of the first two."
    },

    -- ----------------------------------------
    -- COMPATIBILITY
    -- ----------------------------------------
    {
        id       = "compatibility",
        title    = "Compatibility",
        keywords = {"compatible", "compatibility", "modpack", "mods", "load order", "rawless", "argmod", "aaco", "metallic", "caldfir", "wall", "floor", "jit", "menu clutter"},
        text     =
            "Refinish Metal is rawless and loads after every raw mod has finished. " ..
            "Because it reads live world data, it works with mods that add materials, " ..
            "change values or change colours.\n\n" ..
            "KNOWN COMPATIBLE\n" ..
            "- ArgMOD (new materials, value and property changes)\n" ..
            "- AACO (economy changes)\n" ..
            "- Caldfir's Metallic (colour changes and additions)\n" ..
            "- Any mod that does not run its own save routines and does not reorder " ..
            "the inorganic array after the world has loaded.\n\n" ..
            "KNOWN INCOMPATIBLE\n" ..
            "- Mods that run their own autosave or save routines. They write to disk " ..
            "without taking Refinish Metal's data out first, which corrupts the save, " ..
            "unless they call the Refinish Metal shutdown first.\n\n" ..
            "BUILT WHILE DORMANT\n" ..
            "If a dwarf builds a wall from a finished bar while mod data is out of " ..
            "RAM (after a manual shutdown, say), the wall takes the bar's material as " ..
            "it stands. On the next load the ledger moves walls and floors along with " ..
            "the items, so they come back in the right finish.\n\n" ..
            "MENUS STAY SHORT\n" ..
            "Grind jobs are named on the fly: a watcher sees each dwarf start a " ..
            "generic grind, reads the item in hand and names the job for it. Finishes " ..
            "are made only for what your fort has had. Workshop menus stay short " ..
            "however many reagents or base metals are active."
    },

    -- ----------------------------------------
    -- MODULES
    -- ----------------------------------------
    {
        id       = "modules",
        title    = "Modules",
        keywords = {"module", "modules", "making fuel", "making concrete", "addon", "extension", "fertilizer", "settings"},
        text     =
            "Refinish Metal can load modules: separate mods that add their own " ..
            "materials, reactions, tools, plants and buildings through it, such as " ..
            "Making Fuel and Making Concrete.\n\n" ..
            "- A module's content loads and saves with Refinish Metal's own, the same " ..
            "safe way.\n" ..
            "- A module with settings gets its own page in the panel, after Civs.\n" ..
            "- Services that only a module switches on, such as the fertilizer " ..
            "service, stay off with Refinish Metal alone.\n\n" ..
            "If a module, or part of one, is left out or refused, the event log says " ..
            "why."
    },

    -- ----------------------------------------
    -- STATUS DASHBOARD
    -- ----------------------------------------
    {
        id       = "status",
        title    = "Status Dashboard",
        keywords = {"status", "dashboard", "monitor", "health", "memory", "ram", "blueprint", "background", "save hook", "watcher", "loop cost", "lag", "ctrl shift i"},
        text     =
            "Open the Status Dashboard with Ctrl-Shift-I.\n\n" ..
            "SYSTEM STATE\n" ..
            "Shows whether mod data is in RAM, and the last check-in of the three " ..
            "background monitors: Save Hook, Calendar Loop and JIT Watcher.\n\n" ..
            "LIVE MEMORY COUNTS\n" ..
            "Counts of injected materials, reactions, menu categories and " ..
            "civilization permissions in the game's arrays, and whether the blueprint " ..
            "cache is live or cleared.\n\n" ..
            "LOOP COST\n" ..
            "What every scheduled script loop in the session costs, in milliseconds " ..
            "per second, calls per second and milliseconds per call: Refinish " ..
            "Metal's, modules' and other mods' alike, so a slow game shows whose loop " ..
            "it is."
    },

    -- ----------------------------------------
    -- OBJECT INSPECTOR
    -- ----------------------------------------
    {
        id       = "inspector",
        title    = "Object Inspector",
        keywords = {"inspect", "inspector", "object", "search", "ram", "memory sheet", "gm-editor", "ctrl shift e"},
        text     =
            "Open the Object Inspector with Ctrl-Shift-E. It is experimental.\n\n" ..
            "- Ctrl-I searches by ID, name or map coordinates (for example 'STEEL', " ..
            "'SWORD', 'GRIND', '142,45,1') across inorganics, reactions, entities, " ..
            "items, buildings, constructions and active jobs.\n" ..
            "- Selecting a result builds a sheet from live memory: materials show " ..
            "their properties, temperatures, flags and combat physics; reactions show " ..
            "their permissions, reagents and products; map objects show their " ..
            "position and material.\n" ..
            "- Ctrl-B returns to the results. Ctrl-G opens the object in DFHack's " ..
            "gm-editor.\n\n" ..
            "Sheet reads are wrapped so a failed read leaves a blank rather than a " ..
            "crash."
    },

    -- ----------------------------------------
    -- CIVILIZATION DASHBOARD
    -- ----------------------------------------
    {
        id       = "civilizations",
        title    = "Civilization Dashboard",
        keywords = {"civ", "civilization", "tech", "roster", "forge", "mason", "gem", "smelting", "alloying", "known metals", "entity", "race", "ctrl shift v"},
        text     =
            "Open the Civilization Dashboard with Ctrl-Shift-V or from the main nav. " ..
            "It shows each civilization's tech and Refinish Metal access, from the " ..
            "blueprint's civ tech cache.\n\n" ..
            "CIV LIST\n" ..
            "- LOCAL: your fortress's civilization, shown first.\n" ..
            "- GLOBAL: a summary roster of all shown civs.\n" ..
            "- Individual civs, listed alphabetically. Civs of your civ's entity " ..
            "class are highlighted.\n\n" ..
            "DOSSIER\n" ..
            "Selecting a civ shows its tech (forging, stoneworking, gem cutting), the " ..
            "metals it may smelt and alloy, and how many Refinish Metal finishing " ..
            "reactions it can use so far. Finishes are made as your fort needs them, " ..
            "so the count grows as you play.\n\n" ..
            "FILTERS\n" ..
            "- Shift-P hides or shows civs with no forge, mason or gem tech.\n" ..
            "- Shift-U hides or shows civs whose name could not be resolved.\n" ..
            "- Shift-L searches by name, race adjective or entity class."
    },

    -- ----------------------------------------
    -- LOGGING & DIAGNOSTICS
    -- ----------------------------------------
    {
        id       = "logging",
        title    = "Logging & Diagnostics",
        keywords = {"log", "event", "debug", "dump", "export", "session", "troubleshoot", "telemetry", "diagnostic", "txt", "file", "search", "ctrl shift l"},
        text     =
            "LIVE EVENT LOG\n" ..
            "Open it with Ctrl-Shift-L or from the main nav. It shows the session's " ..
            "events, newest at the bottom, up to 15,000 lines, coloured by type.\n" ..
            "- Ctrl-F searches it: every word you type must appear in a line.\n" ..
            "- Repeats close together fold into one line with a count.\n" ..
            "- Log Detail, in System Settings, sets what it shows; the file on disk " ..
            "keeps everything.\n" ..
            "- Ctrl-C clears the live feed (RAM only; the file is untouched).\n" ..
            "- Ctrl-L exports the log to refinish_log_<date>_<time>.txt.\n" ..
            "- Ctrl-D exports the master diagnostic dump to " ..
            "refinish_dump_<date>_<time>.txt.\n\n" ..
            "SESSION LOG FILES\n" ..
            "Every event is written as it happens to refinish_session.log in the DF " ..
            "folder. On each new DF launch, the previous one is renamed " ..
            "refinish_last_session.log, so you always have this session and the one " ..
            "before.\n\n" ..
            "MASTER DIAGNOSTIC DUMP\n" ..
            "A snapshot of the mod's state at the moment of export:\n" ..
            "- System state and every configuration value.\n" ..
            "- The inorganic sweep: accepted reagents, and why the rest were " ..
            "rejected.\n" ..
            "- The blueprint: the full material and reaction cache.\n" ..
            "- Any legacy payload from an old save still waiting to be migrated.\n" ..
            "- The civ tech cache: each race's tech and metal access.\n\n" ..
            "Use the dump to check load order behaviour, look into value oddities, or " ..
            "report a problem."
    },

    -- ----------------------------------------
    -- DEFAULT HOTKEYS
    -- ----------------------------------------
    {
        id       = "hotkeys",
        title    = "Default Hotkeys",
        keywords = {"hotkey", "hotkeys", "keybind", "shortcut", "ctrl", "shift", "alt", "key", "binding", "rebind"},
        text     =
            "Every hotkey can be rebound in System Settings.\n\n" ..
            "Ctrl-Shift-C | System Settings\n" ..
            "Ctrl-Shift-M | Base Metals\n" ..
            "Ctrl-Shift-V | Civilizations\n" ..
            "Ctrl-Shift-I | Status Dashboard\n" ..
            "Ctrl-Shift-L | Event Log\n" ..
            "Ctrl-Shift-E | Object Inspector\n" ..
            "Ctrl-Shift-H | Help\n" ..
            "Ctrl-Shift-S | Quicksave (the full autosave cycle)\n" ..
            "Ctrl-Shift-X | Manual Shutdown\n" ..
            "Ctrl-Shift-Q | Hard Shutdown\n" ..
            "Ctrl-Alt-X | Manual Startup\n\n" ..
            "In this Help panel, Ctrl-I opens the search prompt. Enter a keyword or a " ..
            "topic name to filter the topics, or leave it blank and press Enter to " ..
            "show them all."
    }

}

-- ==========================================
-- UI: HELP PANEL (LEFT ROUTER MODULAR PAGE)
-- ==========================================
RefinishPanelHelp = defclass(RefinishPanelHelp, widgets.Panel)
RefinishPanelHelp.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelHelp:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()
    
    -- Panel init log removed: init() fires on every HUD construction,
    -- not just when the user navigates to this panel.

    local function make_key_label(key_token, label_text, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = self.theme.PRI},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    self.actions = {
        CUSTOM_CTRL_I = function() self:prompt_search() end
    }
    
    self.active_choices = self:build_list_choices("") 

    self.content_list = widgets.List{
        frame = {t = 0, l = 0, r = 0, b = 0},
        choices = {"Loading..."},
        text_pen = self.theme.PRI,
        cursor_pen = self.theme.PRI, 
    }

    self.topic_list = widgets.List{
        frame = {t = 0, l = 0, r = 0, b = 0},
        choices = self.active_choices,
        text_pen = self.theme.SEC,
        cursor_pen = self.theme.PRI,
        on_select = function(idx, choice)
            if choice and choice.data and self.content_list then
                -- Width set to 46 to prevent text from overlapping the scrollbar margin
                local wrapped_lines = wrap_help_text(choice.data.text, 46)
                self.content_list:setChoices(wrapped_lines)
            end
        end
    }

    self.btn_search = widgets.Label{
        frame = {b = 0, l = 0},
        text = make_key_label('CUSTOM_CTRL_I', 'Search Help', self.theme.SEC),
        on_click = self.actions.CUSTOM_CTRL_I
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "SYSTEM DOCUMENTATION", text_pen = self.theme.PRI },
        
        widgets.Panel{
            frame = {t = 2, l = 0, w = 22, b = 2},
            subviews = { self.topic_list }
        },

        widgets.Label{ 
            frame = {t = 2, l = 23, w = 1, b = 2},
            text = "", 
            frame_background = self.theme.PRI
        },
        
        widgets.Panel{
            frame = {t = 2, l = 25, r = 0, b = 2},
            subviews = { self.content_list }
        },
        
        widgets.Panel{
            frame = {b = 0, l = 0, r = 0, h = 1, w = 19},
            subviews = { self.btn_search }
        }
    }

    if #self.active_choices > 0 then
        self.topic_list:setSelected(1)
        local initial_wrapped = wrap_help_text(self.active_choices[1].data.text, 46)
        self.content_list:setChoices(initial_wrapped)
    end
end

function RefinishPanelHelp:onInput(keys)
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelHelp.super.onInput(self, keys)
end

-- ==========================================
-- SEARCH & FILTER LOGIC
-- Matches query against topic title and all keywords (case-insensitive).
-- Empty query returns all topics.
-- ==========================================
function RefinishPanelHelp:build_list_choices(query)
    local choices = {}
    local q_lower = query and string.lower(query) or ""

    for _, topic in ipairs(HELP_TOPICS) do
        local match = false
        if q_lower == "" then
            match = true
        else
            if string.find(string.lower(topic.title), q_lower, 1, true) then
                match = true
            else
                for _, kw in ipairs(topic.keywords) do
                    if string.find(string.lower(kw), q_lower, 1, true) then
                        match = true
                        break
                    end
                end
            end
        end

        if match then
            table.insert(choices, { text = topic.title, data = topic })
        end
    end

    if #choices == 0 then
        table.insert(choices, { text = "No results", data = { title = "No Results", text = "No help topics match your search query." } })
    end

    return choices
end

function RefinishPanelHelp:update_list(query)
    self.active_choices = self:build_list_choices(query)
    self.topic_list:setChoices(self.active_choices)
    
    if #self.active_choices > 0 then
        self.topic_list:setSelected(1)
        local updated_wrapped = wrap_help_text(self.active_choices[1].data.text, 46)
        self.content_list:setChoices(updated_wrapped)
    end
end

function RefinishPanelHelp:prompt_search()
    dialogs.showInputPrompt(
        "Search Documentation", 
        "Enter a keyword or topic. Leave blank and press Enter to clear:", 
        self.theme.SEC, 
        "", 
        function(query)
            if not query or query == "" then
                -- DETAIL: search tracking is only useful when debugging
                -- the panel itself.
                log('DETAIL', 'Search cleared.', 'SEARCH')
                self:update_list("")
            else
                log('DETAIL', "Searched for '" .. tostring(query) .. "'.",
                    'SEARCH')
                self:update_list(query)
            end
        end
    )
end

return _ENV