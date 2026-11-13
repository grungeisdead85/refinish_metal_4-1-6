--@ module = true
-- refinish-stockhook-install.lua
-- ==========================================
-- STOCKHOOK INSTALLER: puts the DLL where DF loads it
-- ==========================================
-- WHAT: copies the Stockhook DLL from RM's folder into DF's install folder
-- as dfhooks_stockhook.dll, the first time a fort with RM in its load
-- order is loaded, and again whenever RM's copy changes (a Workshop
-- update). A copy made this session takes effect at the next launch, and
-- RM's prompt says so once. The player's whole install: load an RM fort,
-- restart DF once.
--
-- ACTIVE WORLDS ONLY: the scripts live in RM's scripts_modactive/, so
-- nothing of Stockhook runs in a world without RM (refinish-stockhook.lua,
-- ONE WORLD ONLY).
--
-- WHY A COPY, NOT AN .INI (dfhooks, ChainLoader.cpp and LibWrapper.cpp,
-- the build DFHack 53.16-r3 ships: depends/dfhooks at 5a904e3):
--   * DF's chain-loader loads every dfhooks_*.dll in the install folder,
--     and an .ini there may instead name a DLL anywhere by its path.
--   * An .ini naming a missing file is fatal to EVERY hook library: the
--     loader calls std::filesystem::canonical on the path, which throws
--     for a missing file; the throw leaves the loader's constructor, and
--     dfhooks_init catches it with no loader at all. DFHack itself would
--     not load. Unsubscribing Stockhook would leave such an .ini pointing
--     at nothing.
--   * A copied DLL left behind after the mod is removed is harmless: with
--     no Lua side, its block stays disabled and it passes every call to
--     DF unchanged (stockhook_dll.cpp). After a DF update it hooks only a
--     build it can verify (stockhook_dll.cpp, THE AUTOMATIC TARGET).
--
-- REPLACING A LOADED DLL: Windows will not overwrite or delete a DLL that
-- is loaded, but will rename it (test 14, in play). The old copy is renamed
-- to dfhooks_stockhook.dll.old, or .old1 to .old9 when an earlier one is
-- still held (SET-ASIDE NAMES; the loader takes only .dll and .ini, so all
-- are ignored), and the new one written in its place; set-aside copies are
-- deleted at a later run, once nothing holds them.
--
-- THE TARGETS FILE: stockhook_targets.txt, the DF builds the DLL may hook
-- (stockhook_dll.cpp, THE TARGETS). The DLL reads it from DF's folder at
-- launch. A build not listed is hooked only if the DLL verifies it (THE
-- AUTOMATIC TARGET there), so after a DF update a new line in the mod's
-- copy, shipped as a Workshop update, is needed only when the checks refuse
-- the build: this file copies it beside the DLL like the DLL itself. Plain text,
-- never held open, so it is simply overwritten.
--
-- WHERE THE MOD'S COPY IS: next to this mod's info.txt, found from this
-- script's own path (dfhack.findScript): <mod>/scripts_modactive/this
-- file.
-- That works wherever DF keeps the mod (the Workshop folder, mods/,
-- data/installed_mods/).
--
-- COMMANDS (through refinish-stockhook.lua): refinish-stockhook install,
-- refinish-stockhook uninstall.
--
-- THE FALLBACK PROMPT (2026-11-09): at the fort load, when Stockhook's
-- hook is not live and no restart is pending, RM's prompt tells the player
-- that the older stockpile system is running. See the section of that name.
--
-- API: check(popup), uninstall()

local DLL_NAME = 'dfhooks_stockhook.dll'
local TARGETS_NAME = 'stockhook_targets.txt'

-- ---- RM'S LOG ----
-- Through refinish-stockhook.lua's log (RM'S LOG there): RM's session
-- log, no console prints. Looked up per call: this file loads beside it.
local function log_line(msg, typ)
    local ok, sh = pcall(reqscript, 'refinish-stockhook')
    if ok and sh and sh.log then sh.log(typ or 'INFO', msg, 'INSTALL') end
end

-- ==========================================
-- PATHS
-- ==========================================
local function as_dir(p)
    p = tostring(p or ''):gsub('\\', '/')
    if p ~= '' and p:sub(-1) ~= '/' then p = p .. '/' end
    return p
end

-- The mod's own copy: <mod>/dfhooks_stockhook.dll, two folders up from
-- this script. nil when this script is not on the script path (the mod is
-- not active in this world).
-- name: the file in the mod's root, DLL_NAME unless another is asked for.
local function source_path(name)
    local me = dfhack.findScript('refinish-stockhook-install')
    if not me then return nil end
    me = me:gsub('\\', '/')
    local mod_root = me:match('^(.*)/scripts_modactive/[^/]+$')
    if not mod_root then return nil end
    return mod_root .. '/' .. (name or DLL_NAME)
end

local function target_path(name)
    return as_dir(dfhack.filesystem.getInstallDir()) .. (name or DLL_NAME)
end

-- ==========================================
-- FILES
-- ==========================================
local function read_all(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function write_all(path, data)
    local f, err = io.open(path, 'wb')
    if not f then return false, err end
    local ok, werr = f:write(data)
    f:close()
    if not ok then return false, werr end
    return true
end

-- ==========================================
-- SET-ASIDE NAMES
-- ==========================================
-- A DLL moved aside goes to the first free name of .old, .old1 ... .old9.
-- Several may be needed in one session: a copy renamed earlier in the
-- session is still loaded, cannot be deleted, and blocks its name (test 14:
-- the update at map load took .old, then uninstall's rename onto .old failed
-- with "File exists"). The loader takes only .dll and .ini, so every one of
-- these is ignored, and each is deleted once nothing holds it.
local ASIDE = { '.old' }
for i = 1, 9 do ASIDE[#ASIDE + 1] = '.old' .. i end

-- Deletes every set-aside copy nothing holds any more. One still loaded
-- this session fails quietly and is tried again at a later run.
local function clear_aside()
    local dst = target_path()
    for _, ext in ipairs(ASIDE) do os.remove(dst .. ext) end
end

-- Renames the installed DLL to the first free set-aside name. Returns that
-- path, or nil and why.
local function move_aside()
    local dst = target_path()
    clear_aside()
    for _, ext in ipairs(ASIDE) do
        if not dfhack.filesystem.exists(dst .. ext) then
            local ok, err = os.rename(dst, dst .. ext)
            if ok then return dst .. ext end
            return nil, tostring(err)
        end
    end
    return nil, 'every set-aside name is taken; restart DF and try again'
end

-- ==========================================
-- THE RESTART PROMPT
-- ==========================================
-- RM's own prompt (refinish-prompt.lua), as every RM message to the
-- player. "Restart" alone read as "back to the title screen" (test 14):
-- DF loads hook DLLs only when the program starts, so the text says to
-- close DF completely. what: 'installed' or 'updated'.
local function restart_prompt(what)
    local ok, err = pcall(function()
        local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
        RefinishPrompt{
            frame_h = 12,
            text = ('Stockhook was %s. Close Dwarf Fortress completely and start it again to finish.'
                .. ' Until the restart, piles use the old stockpiling system.')
                :format(what),
            on_ok = function() end,
        }:show()
    end)
    if not ok then log_line('install: the restart prompt failed: ' .. tostring(err), 'ERROR') end
end

-- ==========================================
-- THE TARGETS FILE: copied when the copies differ
-- ==========================================
-- Returns true when it was written this run. A mod without the file
-- writes nothing: the DLL's built-in build stays the only one.
local function check_targets()
    local src = source_path(TARGETS_NAME)
    local new = src and read_all(src)
    if not new or #new == 0 then return false end
    local dst = target_path(TARGETS_NAME)
    if read_all(dst) == new then return false end
    local ok, err = write_all(dst, new)
    if not ok then
        log_line('install: could not write ' .. dst .. ': ' .. tostring(err))
        return false
    end
    log_line('install: ' .. TARGETS_NAME .. ' written at ' .. dst .. '; read at the next launch')
    return true
end

-- ==========================================
-- CHECK: install or update when the copies differ
-- ==========================================
-- Returns 'current', 'installed', 'updated', or nil and why. popup: show
-- RM's restart prompt when the DLL changed this session.
function check(popup)
    -- Copies set aside earlier are free to go once nothing holds them.
    clear_aside()

    local src = source_path()
    if not src then return nil, 'Stockhook not active in this world' end
    local new = read_all(src)
    if not new or #new == 0 then
        log_line('install: no ' .. DLL_NAME .. ' in the mod folder (' .. src .. ')')
        return nil, 'no DLL in the mod folder'
    end

    -- The targets file first: a new DF build listed needs the same restart
    -- as a new DLL.
    local targets_new = check_targets()

    local dst = target_path()
    local old = read_all(dst)
    if old == new then
        if targets_new and popup then restart_prompt('updated') end
        return targets_new and 'updated' or 'current'
    end

    -- ---- MOVE THE OLD COPY ASIDE ----
    -- A loaded DLL can be renamed but not overwritten (test 14: renamed
    -- while loaded, in play).
    local aside = nil
    if old then
        local err
        aside, err = move_aside()
        if not aside then
            log_line('install: could not move the old DLL aside: ' .. tostring(err))
            return nil, 'old DLL not renamable: ' .. tostring(err)
        end
    end

    -- ---- WRITE THE NEW ONE ----
    -- Written under a temporary name first, so a failed write never leaves
    -- a truncated dfhooks_stockhook.dll for the loader to find.
    local tmp = dst .. '.new'
    local ok, err = write_all(tmp, new)
    if ok then ok, err = os.rename(tmp, dst) end
    if not ok then
        os.remove(tmp)
        if aside then os.rename(aside, dst) end   -- put the old one back
        log_line('install: could not write ' .. dst .. ': ' .. tostring(err))
        return nil, 'install folder not writable'
    end

    local what = old and 'updated' or 'installed'
    log_line(('install: DLL %s at %s; takes effect at the next launch'):format(what, dst))
    if popup then restart_prompt(what) end
    return what
end

-- ==========================================
-- UNINSTALL
-- ==========================================
-- The DLL is moved to a set-aside name (deleted at a later run of check,
-- or by the player once DF is closed). From the next launch DF no longer
-- loads it.
function uninstall()
    local dst = target_path()
    if not dfhack.filesystem.isfile(dst) then return false, 'not installed' end
    local aside, err = move_aside()
    if not aside then return false, err end
    log_line('uninstall: DLL moved to ' .. aside .. '; not loaded from the next launch')
    return true
end

-- ==========================================
-- THE FALLBACK PROMPT (2026-11-09)
-- ==========================================
-- When Stockhook's hook is not live at a fort load, RM's own stockpile
-- system runs instead, and the player is told so then, at the load, not
-- left to find out in play that Stockhook's rows sort nothing. Before
-- this the only sign was a WARNING in RM's log, written once the game was
-- unpaused (refinish-stockpile-windows.lua asks from its loop, which does
-- not run paused).
-- Once a session. Not shown:
--   * when this load already asks for a restart (installed or updated):
--     the hook comes up at the next launch;
--   * for stockhook.disable: the player switched it off.
-- A hook live on a DF build nobody listed (stockhook_dll.cpp, THE
-- AUTOMATIC TARGET) is said in RM's log at INFO: nothing for the player
-- to do, but it tells a maintainer the build can be listed.
-- RISK_M (light red) is the theme's colour for something broken that the
-- player will notice and can carry on past.
local function fallback_check()
    if _G.stockhook_fallback_said then return end
    local ok_sh, sh = pcall(reqscript, 'refinish-stockhook')
    if not ok_sh or type(sh) ~= 'table' or not sh.available then return end
    _G.stockhook_fallback_said = true
    local live, why = sh.available()
    if live then
        local st = sh.stats and sh.stats()
        if st and st.automatic == 1 then
            log_line('live on a DF build not listed in ' .. TARGETS_NAME .. ": the DLL verified it"
                .. " and hooked it. stockhook.log, in DF's folder, holds the line that lists it.")
        end
        return
    end
    why = tostring(why)
    if why:find('stockhook.disable', 1, true) then
        log_line('not live: stockhook.disable is present, so no prompt.')
        return
    end
    log_line('not live at the fort load: ' .. why, 'WARNING')
    local okp, err = pcall(function()
        local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
        local THEME = reqscript('refinish-theme').get_current_theme()
        RefinishPrompt{
            frame_h = 14,
            text_pen = THEME.RISK_M,
            text = "Stockhook is not working with this version of Dwarf Fortress, so Refinish"
                .. " Metal's older stockpile system is running instead. Stockpiles still work, but"
                .. " the extra stockpile rows Stockhook adds sort nothing until Refinish Metal is"
                .. " updated. The reason is in refinish_session.log, in DF's folder.",
            on_ok = function() end,
        }:show()
    end)
    if not okp then log_line('the fallback prompt failed: ' .. tostring(err), 'ERROR') end
end

-- ==========================================
-- MAP LOAD: check once a map is up
-- ==========================================
-- Map load rather than script load, so RM's prompt has a screen to show on.
-- Once a session: a copy made earlier this session is already in place.
-- Only in a world with RM in its load order: the handler stays for
-- the session once registered (refinish-stockhook.lua, ONE WORLD ONLY).
local function world_active()
    local ok, active = pcall(function() return reqscript('refinish-stockhook').world_active() end)
    return ok and active
end

if dfhack_flags and dfhack_flags.module then
    dfhack.onStateChange.stockhook_install = function(code)
        if code == SC_MAP_LOADED and not _G.stockhook_install_checked and world_active() then
            dfhack.timeout(1, 'frames', function()
                if _G.stockhook_install_checked then return end
                local ok, what, why = pcall(check, true)
                if not ok then
                    log_line('install: ' .. tostring(what))
                elseif what then
                    _G.stockhook_install_checked = true
                else
                    log_line('install: not done: ' .. tostring(why))
                end
                -- THE FALLBACK PROMPT, unless this load asks for a restart.
                if not (ok and (what == 'installed' or what == 'updated')) then
                    local okf, err = pcall(fallback_check)
                    if not okf then log_line('fallback check failed: ' .. tostring(err), 'ERROR') end
                end
            end)
        end
    end
end
