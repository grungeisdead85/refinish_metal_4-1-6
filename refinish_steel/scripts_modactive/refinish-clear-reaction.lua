-- refinish-clear-reaction.lua
-- Removes dynamically generated reactions from global memory. Every
-- line is DETAIL: the shutdown or save cycle that calls this reports
-- the outcome.

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CLEAR_REACTIONS'
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
-- THE METAL GRINDER'S CLASS, TAKEN BACK
-- ==========================================
-- refinish-index-reaction grants the metal grinder's class, the words
-- 'unfinished metal' (GRIND_METAL_CLASS below), to the metals
-- the metal grinder may take (THE METAL GRINDER'S CLASS, there). It
-- comes off here at every shutdown, before the next cycle copies base
-- metals into finishes again, and ahead of the early return below, so
-- it comes off even when the reactions are already gone.
-- From EVERY inorganic, not only the ones given it: anything copied from
-- a metal while it carried the class holds the same string, and freeing
-- a string something still points at is a crash. Erased everywhere
-- first, then each string freed once. One walk of the inorganics a
-- shutdown.
-- The finished-metal grinders' classes, "finished <base name>" words
-- (refinish-mint-finish.lua, fin_words_of), matched by the exact words
-- that file publishes on _G.refinish_grind_fin_words as it makes them,
-- come off in the same walk: one string per base, shared by all of that
-- base's finishes, freed once. This runs before refinish-clear.lua
-- deletes the finishes, so they are still in the array to be read.
-- ==========================================
local GRIND_METAL_CLASS = 'unfinished metal'   -- the words refinish-index-reaction.lua grants
-- The finished-metal grinders' words this cycle: exact text, never a
-- prefix, so no other material's class is ever taken for one.
local fin_words = _G.refinish_grind_fin_words or {}
do
    local doomed, erased, freed = {}, 0, 0
    local find = string.find
    pcall(function()
        for _, r in ipairs(df.global.world.raws.inorganics.all) do
            local v = r.material.reaction_class
            for i = #v - 1, 0, -1 do
                local rc = v[i]
                local s = rc and rc.value
                if s and (s == GRIND_METAL_CLASS or fin_words[s]) then
                    doomed[tostring(rc)] = rc   -- tostring is the address: one key per string
                    v:erase(i)
                    erased = erased + 1
                end
            end
        end
    end)
    for _, p in pairs(doomed) do
        if pcall(df.delete, p) then freed = freed + 1 end
    end
    if erased > 0 then
        log('DETAIL', ('grinder classes taken off %d material(s), %d string(s) freed.')
            :format(erased, freed))
    end
    -- The next cycle's finishes publish theirs afresh.
    _G.refinish_grind_fin_words = {}
end

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_reactions_loaded == nil or _G.refinish_reactions_loaded == true then
    local actually_loaded = false
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
            actually_loaded = true
            break
        end
    end
    if not actually_loaded then _G.refinish_reactions_loaded = false end
end

if not _G.refinish_reactions_loaded then
    log('DETAIL', 'Reactions already cleared. Skipping.')
    return
end

local reactions_array = df.global.world.raws.reactions.reactions
local scrubbed_rxns = 0

-- LIFO loop prevents array index shifting
for i = #reactions_array - 1, 0, -1 do
    local rxn = reactions_array[i]
    if string.find(rxn.code, "REFINISH_STEEL_") then
        rxn:delete() -- Free the C++ memory allocation
        reactions_array:erase(i) -- Remove the pointer from the global vector
        scrubbed_rxns = scrubbed_rxns + 1
    end
end

if scrubbed_rxns > 0 then
    log('DETAIL', 'Excised ' .. scrubbed_rxns .. ' injected reactions from RAM.')
else
    log('DETAIL', 'No injected reactions found in RAM.')
end

-- Add this to the bottom of refinish-clear-reaction.lua
local cat_array = df.global.world.raws.reactions.reaction_categories
local scrubbed_cats = 0

for i = #cat_array - 1, 0, -1 do
    local cat = cat_array[i]
    if string.find(cat.id, "REFINISH_STEEL_CAT_") then
        cat:delete()
        cat_array:erase(i)
        scrubbed_cats = scrubbed_cats + 1
    end
end

if scrubbed_cats > 0 then
    log('DETAIL', 'Excised ' .. scrubbed_cats .. ' UI categories.')
end

_G.refinish_reactions_loaded = false