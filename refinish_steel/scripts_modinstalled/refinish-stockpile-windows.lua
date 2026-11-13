--@ module = true
-- refinish-stockpile-windows.lua
-- ==========================================
-- RM STOCKPILE WINDOWS
-- ==========================================
-- A TWIN is a copy of a material made at run time so an item can carry
-- classes its source must not (gravel carries AGGREGATE, kindling the fuel
-- classes). A twin must stay HIDDEN: with its source's flags it would show
-- as a second copy of every stone in half the game's menus, and RM's
-- refinish scan would take it as a second reagent for every stone. But
-- DF files an item in a stockpile only by its material's class flags, and
-- it re-decides every haul at pickup, so a flagless twin is never stored,
-- and nothing RM posts can make it be (RM_Stockpile_Mechanics.md, 6 to 9).
--
-- So twins borrow their flags only while there is something to haul. A
-- WINDOW opens when a twin item is loose: each twin gets its source's flags,
-- DF's own dwarves haul the items as if they were the source's, and when
-- nothing is loose or being hauled the flags go back exactly as they were.
--
-- MEASURED 2026-09-27 (refinish-twin-exposure, one window): DF filed all 25
-- loose twin items in about 70 seconds of play. With the flags back off,
-- Making Fuel's char kindling reaction took the kindling out of its pile,
-- nothing moved a stored twin out, and no job outside the modules took or
-- made a twin item. The fuel wood twin never appeared in the material
-- picker; the stone twins joined six stockpile settings lists while the
-- window was open (WHAT A WINDOW WAITS FOR).
--
-- ==========================================
-- CLAIMING
-- ==========================================
-- The same shape as refinish-stockpile-organic. An owner states which of
-- its materials are twins and what each copies; this file knows nothing
-- about gravel or kindling.
--
--   _G.refinish_window_api.claim(owner, select, opts)
--     select() returns a list of { twin = { mt, mi }, source = { mt, mi } }:
--       each twin's material address and its source's. Called at every
--       scan, so twins are never held between frames, and as the stockpile
--       settings open while no window is (THE MENUS, RESOLVED AS THEY OPEN).
--     opts.item_types: the item vectors an owner's twin items live in, as
--       names in world.items.other. Default { 'TOOL' }.
--     opts.menu_tag: a word appended to the twins' rows in the stockpile
--       settings screen, in brackets. See THE MENU LABEL. A work order
--       condition's Material list draws each row from the material's
--       name and lists a twin beside its source, so there the tag goes on
--       the twins' names while a work order's conditions are open
--       (tagged(), below).
--     opts.file_as: 'coal' files the claim's materials through the soap
--       switch (COAL: THE SOAP SWITCH); its entries need no source.
--   Claiming again under the same owner replaces the claim.
--   _G.refinish_window_api.unclaim(owner)
--
--   _G.refinish_window_api.hide(owner, select, opts)
--     For an owner's materials that are not windowed twins but must not be
--     listed. select() returns a list of { mt, mi }, called at every scan
--     like a claim's and as either menu opens (THE MENUS, RESOLVED AS THEY
--     OPEN). They are edited out of every menu (EDITING ROWS
--     OUT), never windowed and never mirrored.
--     opts.keep_in: stockpile settings lists, named as in INORG_LISTS
--       ('finished_goods.mats'), where their rows stay.
--     opts.menu_tag: the label their rows carry where they are edited out,
--       so a row that ever shows reads what it is. A row that stays listed
--       is never labelled (EDITING ROWS OUT). In a work order condition's
--       Material list the tag goes on their names while a work order's
--       conditions are open, as a claim's does (tagged(), below).
--   Hiding again under the same owner replaces it.
--   _G.refinish_window_api.unhide(owner)
--
--   _G.refinish_window_api.label(owner, select)
--     For an owner's materials whose names read only beside their form,
--     like Making Fuel's mash, named "fresh" and "dried" so the item reads
--     "fresh mash". select() returns a list of { mt, mi, text }, called at
--     every scan like a claim's and as either menu opens (THE MENUS,
--     RESOLVED AS THEY OPEN), and each stockpile settings row for one of
--     them reads text instead of the material's name (THE MENU LABEL). Only
--     the row strings are written: the material and its items keep their
--     names. Labelling again under the same owner replaces it.
--   _G.refinish_window_api.unlabel(owner)
--
--   _G.refinish_window_api.tagged()
--     Every material a claim or a hide gave a menu_tag, as a list of
--     { mt, mi, tag }, each select called afresh. For a screen outside
--     this service that labels the materials itself: a work order
--     condition's Material list (refinish-menu-orders.lua). A claim filed
--     as coal is left out: coal is a real material, never tagged.
--
-- Claimed today: REFINISH_CORE_AGGREGATE (the stone twins, from
-- refinish-material-aggregate.lua), MAKING_FUEL_FUELWOOD (the fuel wood
-- twins, from making-fuel-tinder-mat.lua), MAKING_FUEL_COAL (the coal host's
-- coals, filed as soap) and MAKING_FUEL_BINDER (the binder twins of stone
-- sources, from making-fuel-binder-watcher.lua). Hidden today:
-- MAKING_FUEL_STONE_CLAY (the listed binder twins, kept in finished goods)
-- and MAKING_FUEL_KEYS (Making Fuel's key materials, kept nowhere).
-- Labelled today: MAKING_FUEL_LABELS (Making Fuel's fresh and dried mash,
-- its dried peat, and bone meal's material, named bone).
--
-- ==========================================
-- LOOSE, AND NEVER STRANDED
-- ==========================================
-- A twin item is LOOSE when DF could haul it somewhere and nothing holds
-- it there already:
--   * on the ground and on no stockpile tile: anything a job dropped, a
--     cancelled load, whatever a removed pile or workshop left behind;
--   * a PRODUCT SITTING IN A WORKSHOP OR FURNACE: "building clutter" in
--     DFHack's words. It is not on the ground. It carries a BUILDING_HOLDER
--     reference and sits in the building's contained_items with the TEMP
--     role; the building's own materials carry PERM, and in_building, and
--     never count. Read from DFHack's detachItem and moveToBuilding
--     (library/modules/Items.cpp, reverse-engineered from DF): a TEMP item
--     gets NEITHER in_building nor in_inventory, so no flag marks it and
--     the holder itself has to be asked.
--     MEASURED 2026-09-27, twice: the first build read only items on the
--     ground; the second looked for in_inventory or in_building before
--     asking the holder, so products sitting in workshops were still never
--     seen. Both times they moved only once removed the workshop and
--     they fell to the floor.
--   * ON A PILE, BUT NOT BINNED, where the pile allows bins and a bin on
--     its tiles has room for it. DF bins what a pile holds when bins
--     arrive, but only what it can file, so a claimed item stored before
--     the bins came would lie unbinned forever (in play 2026-09-27:
--     real soap was binned the moment bins were added, coal only once new
--     coal opened a window). Room is the bin's capacity
--     (dfhack.items.getCapacity) less the volume of what it holds, against
--     the item's own volume; bins lying on the pile's tiles, not in a job
--     or forbidden, count for that pile.
-- Not loose: an item in a job, carried by a creature, in a container,
-- part of a building, forbidden, or marked for dumping, since the player
-- or another job has it; and an item on a pile with no bin room for it.
--
-- A window opens when a new twin item is made (the item created event,
-- checked on the next tick, after the aggregate and tinder hops have moved
-- it onto its twin) or when the backstop scan finds a loose one (every
-- SCAN_FRAMES; it catches drops, cancelled jobs and removed piles).
-- The scan and the open window's recount count the twin items already
-- known, renewed by a backstop pass at least every FULL_FRAMES (THE
-- KNOWN TWINS; THE RENEWAL, A SLICE A TICK).
--
-- A window NEVER closes while a hauling job holds a twin item: DF re-decides
-- at pickup, and with the flags back off it would set the item straight
-- down. It closes when nothing is loose and nothing is being hauled.
--
-- If loose items remain but nothing has been hauled for STALL_FRAMES, they
-- are STUCK. Time while DF's hauling queue is full does not count (A FULL
-- QUEUE HOLDS THE STALL CLOCK). The window closes and the log names the
-- stuck items and says, pile by pile, why: whether the pile takes finished
-- goods and tools, how many of the stuck twins' entries are on against
-- their stones', whether it takes from links only, its free tiles and bins,
-- and whether the items can walk to it, with the stuck items' own storage
-- timers. The next try waits BACKOFF_MIN frames, doubling to BACKOFF_MAX.
-- That is the one stranding a trigger cannot prevent, and it is the
-- player's to see: a pile's settings or its space.
--
-- ==========================================
-- DF'S STORAGE TIMER, AND WHY A WINDOW RESETS IT
-- ==========================================
-- DF does not look at an item for storage every frame. Each item carries
-- stockpile_countdown, which falls by 1 every 50 frames; at 0 DF looks
-- at the item, and if it does not store it, it resets the countdown to
-- stockpile_delay and RAISES stockpile_delay for next time.
-- MEASURED 2026-09-27 on 20 stuck gravel, read 500 frames apart:
-- countdowns fell 9 to 11; at each look that stored nothing the delay
-- grew by 1, 11 or 14; the delays went from 24-49 to 47-76 in one
-- minute. Every sampled item's countdown had been reset during a 3000
-- frame window (all delays were under the window's 60 countdown steps),
-- so DF looked at every one of them with the flags lent, and stored none.
--
-- So every look that finds no pile stretches the wait before the next,
-- and most of an old item's looks fall while the flags are back off: its
-- looks drift out of step with the windows, while a new item, on a short
-- timer, is looked at within the next window. That is the pattern
-- seen: new gravel and kindling hauled, gravel left from an earlier load
-- not, and neither every time.
--
-- WHEN A WINDOW OPENS, every loose twin item's timer is set short:
-- countdown 1 to TIMER_SPREAD (so the looks spread over a few hundred
-- frames, not one spike) and delay TIMER_DELAY, the value measured on a
-- fresh item (13, in the haul probe's capture). DF then looks at each of
-- them within TIMER_SPREAD * 50 frames while the flags are on, and again
-- about TIMER_DELAY * 50 frames later, well inside STALL_FRAMES.
--
-- Why DF left the gravel at a look with the flags on is not yet known.
-- DF keeps storage job and hauler counts per hauler type
-- (world.stockpile num_jobs and num_haulers); saw the gravel ignored
-- while haulers worked through other tools, and hauled on a load where he
-- had forbidden them. Every STUCK report and the check now record those
-- counts, so a failure shows whether DF was out of haulers at the time.
--
-- ==========================================
-- A FULL QUEUE HOLDS THE STALL CLOCK
-- ==========================================
-- DF creates no storage job while its hauling queue is full: storage jobs
-- at or above its haulers, on the Any row of world.stockpile num_jobs and
-- num_haulers. MEASURED 2026-09-27: stalls came with that row at 12 of 12
-- and 13 of 12, after windows that had been hauling steadily, while DF's
-- haulers worked through other items. Such a stall is DF being busy, not a
-- refusal, so while the queue is full the stall clock stands still: the
-- window stays open and the retry wait does not grow.
--
-- While the queue is full, every look DF takes at a twin stores nothing,
-- and each such look raises the item's delay (DF'S STORAGE TIMER). So when
-- the queue frees, the loose twins' timers are set short again, at most
-- once per RECOUNT frames, so DF looks at them promptly.
--
-- A fort with no haulers at all never counts as full: nothing will haul
-- there, and the stall rule's retry wait is the right answer.
--
-- ==========================================
-- THE RETRY WAIT GIVES WAY TO A CHANGE
-- ==========================================
-- A STUCK closes the window and waits BACKOFF frames before trying the
-- same items again, doubling to BACKOFF_MAX. But a wait is only right for
-- the SAME items in the SAME places. MEASURED 2026-09-27: the last window
-- of a load closed with a 32000 frame wait, and then removed the mason,
-- dropping its gravel to the floor, with no window to follow. Now the
-- census taken at a STUCK is kept, and while the wait runs the backstop
-- scan still counts; if the census no longer matches (items made, dropped,
-- moved), a window opens without waiting.
--
-- MEASURED 2026-10-01: in a busy fort that rule left no wait at all. A
-- STUCK at 08:32:15 listed 554 twins unhauled, 540 of them in workshops;
-- new twins of the same kinds changed the census at the next scan, and the
-- window reopened 14 seconds later, ran 15,750 frames, logged a STUCK for
-- 580, and reopened 10 seconds after that. So the wait now gives way only
-- to a change that could let stuck twins move:
--   - a loose twin of a material, in a place, that the STUCK did not have
--     loose there (the dropped gravel above: on the floor, not in a shop);
--   - the piles: one made or removed, or its categories, its bin, barrel
--     or wheelbarrow allowance, its links-only flag or its links changed;
--   - the mirror setting twin entries, which it does when a pile's stone
--     entries have changed.
-- More twins of the stuck kinds in the stuck places wait out the backoff
-- like the ones before them: they would meet whatever stopped those. The
-- backoff still ends every wait, and a window that closes with nothing
-- loose puts it back to BACKOFF_MIN.
--
-- ==========================================
-- THE TEST COMMAND
-- ==========================================
-- refinish-stockpile-windows test [frames]
-- MEASURED 2026-09-27, the seventh load: with DF's haulers free (storage
-- jobs 0 or 1 of 12) and every stuck gravel looked at several times per
-- window with the flags lent, DF stored none of the stone twins, while in
-- the same window it stored new kindling (a wood twin) and dust (not a
-- twin) from the same mason. So DF refuses stone twin gravel on some loads
-- and not others (all 23 went on the fifth load), and whether the refusal
-- belongs to the WORKSHOP, the PILE or the MATERIAL is not known. The test
-- splits them in one run, facts only:
--   1. A window opens at once (or the open one is kept) and is HELD for
--      the given unpaused frames (default TEST_FRAMES): no stall close,
--      no screen wait, every loose twin timer set short.
--   2. Up to TEST_DROP gravel twins are moved out of their workshop onto
--      a free floor tile beside it, in the same walkable group.
--   3. (Until 2026-09-27 each pile was also asked through DF's building
--      method canStoreItem. It answered no for a pile that was taking the
--      gravel, so it is not the pile's acceptance, and is no longer asked.)
--   4. The piles that exist at the start are noted; a pile made during
--      the test (with the flags lent) is named at the end.
--   5. At the end: where each tracked item is, DF's storage counts, and
--      the window closes.
-- The console copy only posts the request (S.test_request); the running
-- copy runs it, since only it holds the window.
--
-- ==========================================
-- THE PILES' TWIN SLOTS, AND THE MIRROR
-- ==========================================
-- MEASURED 2026-09-27, ninth load, by the piles command (below): a stone
-- twin is filed only where the pile's own finished goods entry for THAT
-- TWIN is on (settings.finished_goods.mats, indexed by inorganic).
--   pile 2 against pile 3: they differ at 93 entries of finished_goods.mats,
--   exactly the 93 stone twins (323-415): 0 in pile 2, 1 in pile 3. Piles 1
--   and 2 were made while paused, before any window; pile 3 was made during
--   the test's window, and took the gravel as soon as it was made.
-- DF's pile presets turn on only the materials DF lists at that moment,
-- and it lists a stone twin only while it has its stone's flags, so a pile
-- made while the flags are off leaves every twin's entry off, and one made
-- during a window turns them on. Wood twins file under the single Wood
-- entry of finished_goods.other_mats, not per material, which is why
-- kindling went to piles made either way. The route 2 exposure test that
-- did file gravel into an older pile ran after the slot probe had forced
-- the twin entries on in it.
--
-- THE READ THAT HID IT. These settings vectors read as 0 and 1 in play, not
-- false and true, and 0 is TRUE in Lua. The STUCK report tested the entries
-- by truth alone, so it counted 0 as on and printed "these materials 3/3"
-- for piles whose twin entries were all off. Every settings entry is now
-- read through truth() below. Any count of settings entries taken the old
-- way, in this file or in older probes, is suspect.
--
-- THE MIRROR. Both halves are needed: the entry on, and the flags lent
-- while DF looks (the slot probe forced entries on with no flags, and
-- nothing moved). The player never sees a twin in a pile's settings, so
-- RM keeps each twin's entry EQUAL TO ITS STONE'S, in every pile: the
-- player's choice for granite in a pile is the choice for granite gravel.
-- mirror_slots() does it at every backstop scan, when a window opens, and
-- at every recount while one is open, so a pile made or edited at any
-- time follows. Entries are addressed by inorganic index, which is stable
-- while the load order is; the twins are pushed at the same indices each
-- load.
--
-- canStoreItem is not the pile's acceptance: during the test it answered
-- no for pile 3 too, which was taking the gravel. It is no longer asked.
--
-- refinish-stockpile-windows piles
--   Facts only, run by the running copy on its next unpaused tick: every
--   pile's twin entries against its stones', and every pile's settings,
--   storage and flags compared field by field against the newest pile,
--   grouped by field with index ranges and how many are stone twins.
--
-- ==========================================
-- THE MENU LABEL
-- ==========================================
-- While a window is open, a stone twin carries its stone's flags, so DF
-- lists it in the stockpile settings as a second copy of its stone:
-- saw two granites (2026-09-27). Each row of that screen is DF's own UI
-- record, game.main_interface.custom_stockpile.spec_item[i]
-- (custom_stockpile_itemst): the label strings name and simple_name, and
-- set_pointer, the address of the one settings entry the row toggles. A
-- row whose set_pointer lands on a stone twin's entry, in any of the
-- pile's inorganic lists (INORG_LISTS), gets " (TAG)" appended to both
-- strings, TAG being its owner's claim option menu_tag (the aggregate
-- claims 'aggregate'): "granite (aggregate)". Only the screen's row
-- strings are written. DF rebuilds the rows from the materials whenever
-- the list is redrawn, so the material and every item keep their names,
-- and the label is written again on each rebuild.
--
-- WHEN IT RUNS. DF counts the game as paused while that screen is open
-- (DFHack World::ReadPauseState lists custom_stockpile.open), so the
-- window's own loop does not run there. The label runs from a second
-- dispatcher subscription that asks to run while paused, every
-- MENU_FRAMES frames, and does nothing unless the screen is open. See
-- HIDING THE TWINS IN THE MENUS for what that subscription also does.
--
-- WHAT IT READS. The labels come from resolve(), with the twins and the
-- hides, and until 2026-10-13 only the loop ran it, at its backstop scan
-- or as a window opened, neither of which happens while the game is
-- paused or a stockpile or work orders screen is up. SEEN in play
-- 2026-10-13: a pile's settings opened after a load showed Making Fuel's
-- dried peat and dried mash both as a bare "Dried", and in earlier
-- sessions the labels had appeared only later in play. A session log from
-- the same day had this service start at 16:32:52 and its first scan (its
-- first CENSUS line) at 16:37:38: nearly five minutes in which every
-- label and hide was missing from both menus. So each menu now resolves
-- as it opens (THE MENUS, RESOLVED AS THEY OPEN).
--
-- The mirror still governs: a labelled row follows its stone, and a
-- toggle on the labelled row alone is set back at the next recount.
--
-- ==========================================
-- COAL: THE SOAP SWITCH
-- ==========================================
-- Making Fuel's coals are BARs of plant materials on its coal host, so
-- their names read bare ("charcoal", not "charcoal bars"). A bars pile
-- takes a bar through its per-inorganic list or five named entries,
-- bars_other_mats: Coal, Potash, Ash, Pearlash, Soap. The first four are
-- DF's builtin materials. Soap is any material carrying the SOAP flag,
-- plant and creature soap alike, so it is the one door a plant-mode bar
-- can use. MEASURED 2026-09-27 (making-fuel-coal-probe): with SOAP set on
-- the coal host's materials, 138 storage jobs took coal, every one to the
-- pile whose only named entry was Soap, none to the pile with only Coal;
-- and one CleanPatient job took a coal ash bar to wash with (any bar
-- whose material carries SOAP, even a metal bar, is used up bit by bit).
--
-- So a claim with file_as = 'coal' is filed through that door, with every
-- seam closed, while a window has it ENGAGED:
--   * COAL IS SOAP. Its materials carry SOAP.
--   * SOAP IS NOT. Every real soap material present on a bar loses SOAP,
--     so real soap is neither filed nor used while coal is being hauled:
--     coal takes priority. Soap already stored stays where it is:
--     with no category, DF has nowhere to move it (as with the twins).
--   * THE COAL ENTRY RULES. Each pile's Soap entry is set to its own Coal
--     entry, the player's Soap entries kept, and put back whenever the
--     flags come off: at the window's close, and while a pile's settings
--     are open (HIDING THE TWINS IN THE MENUS), so the player always sees
--     and edits their own Soap entry, and the Coal entry governs coal.
--   * NOTHING WASHES WITH COAL. A job that takes coal as soap is cancelled
--     on sight: CleanPatient, CleanSelf, StoreItemInLocation (a hospital's
--     supplies), or any job whose item filter for the coal asks for SOAP
--     (job_item flags2 or flags3 .soap, "check for material flag SOAP").
--     Storage jobs and every other use (fuel) go through.
--   * SOAP IN HAND IS LEFT ALONE. Coal is engaged only when no job holds a
--     real soap bar, so no dwarf carrying or using soap has it turn into
--     something else mid-job. Until then the window runs without coal and
--     engages it at a later recount.
--   * SOAP KEEPS ITS LOOK. DF draws a soap bar with its own tile only
--     while the material carries SOAP (vanilla graphics_items.txt:
--     [TILE_GRAPHICS:ITEM_CONSTRUCTION:1:1:ITEM_BARS_SOAP], beside the
--     plain ITEM_BARS at 0:1), so set aside it drew as a plain bar (
--     in play). While a real soap material is set aside, its material
--     bar_texpos slot holds that soap tile, resolved through the live page
--     registry the way the sprite engine resolves PAGE:<token>:<x>:<y>; the
--     slot goes back when SOAP does. A material bar slot outranks the
--     SOAP choice: the coals carry art in theirs and kept it while they
--     carried SOAP. A soap material that already has art of its own in
--     that slot is left alone.
--     TINTED: DF tints a tile it chooses itself but never a texpos handed
--     to a material slot (refinish-sprite-art.lua, MANUFACTURED TINTING),
--     so the raw tile drew in its sheet's grey (in play). The slot
--     now takes RM's own tint of the same picture: vanilla_soap_bar, the
--     ITEM_BARS_SOAP cell retoned onto the neutral ramp
--     (refinish-sprite-art-vanilla.lua), made in each soap's own colour by
--     refinish-sprite-art's texpos_for. The raw tile is the fallback.
--   * SOAP GETS ITS TURN. While coal is engaged no soap can be used, and
--     a fort making coal constantly would keep it from soap for good.
--     MEASURED 2026-09-27: with a hospital in the fort, one window of
--     about two minutes stopped 5 jobs that took coal as soap. So when a
--     job is stopped for taking coal as soap, soap is wanted, and coal
--     hands soap back AT ONCE: soap has at least SOAP_TURN frames in which
--     coal is not engaged, and coal also waits while any job holds real
--     soap, so a soap job keeps its turn for as long as it takes. The
--     reposted job then finds real soap, or, with none in the fort, goes
--     ahead without it as vanilla would.
--     NO CANCELLATION LOOPS (2026-09-28: a loop of cancelled jobs
--     would be a big issue, and a few hundred frames is not long for a
--     job to finish). The first build gave coal a guaranteed turn in which
--     stops were only counted, and waited up to 500 frames for coal in
--     flight before releasing: in both, DF could repost a soap job, see
--     coal again, and have it cancelled again. Now one stop releases coal,
--     so at most one job is cancelled per coal turn, and a turn begins only
--     after soap's. The cost: coal being carried at that moment is set
--     down, lies loose, and goes on coal's next turn.
--     THE ONE SLOW REPEAT LEFT. A demand real soap cannot meet: a hospital
--     wanting soap in a fort with none, or a modded job that consumes soap
--     (no vanilla, RM or Making Fuel reaction does). Soap's turn cannot
--     serve it, so the next coal turn meets it again: one cancelled job per
--     coal turn, for as long as it lasts. Never a tight loop, since every
--     cancel releases coal. A cancelled REPEAT job is gone for good, so a
--     modded soap reaction set to repeat would need re-adding. When soap is
--     wanted UNMET_WARN times running with no real soap anywhere, a WARNING
--     says so, once per session.
--     A hospital's own "needs soap" flag (need_more.soap) was considered
--     and left out: while coal is engaged the hospital's stored soap is
--     set aside too, so DF could read the hospital as short BECAUSE of
--     the switch and cut every coal window short. A stopped job is an
--     actual attempt to use soap, which the switch cannot cause.
--     SOAP'S TURN HOLDS THE STALL CLOCK. Loose coal sitting out soap's
--     turn is waiting, not stuck. MEASURED 2026-09-28 with a hospital: a
--     CleanPatient took coal 14 seconds into a window, was stopped, and
--     coal was released in the same tick. Coal next engaged 88 seconds
--     later: soap's 2000 frames, then a job held real soap at every check
--     after them. With nothing else fileable, no haul came for STALL_FRAMES,
--     so the window closed as stuck, its STUCK report listed the 61
--     waiting coal items as "could not be stockpiled", and the retry wait
--     doubled. So while loose coal waits out soap's turn, the stall clock
--     stands still, as it does for a full hauling queue: the window stays
--     open, coal engages at the first recount after soap's turn, and a
--     STUCK report lists only items that had their chance. Coal already
--     waits for as long as a job holds real soap, so the hold adds no
--     wait of its own.
-- Coal is engaged only when coal is loose. It is released with the window.
--
-- THE OPTIONS SCREEN HOLDS COAL OFF (2026-10-27). The switch writes pile
-- settings, and saves carry them. RM's hotsave and the game's save &
-- continue stop every service before the game writes (refinish-autosave,
-- refinish-shutdown), and stop() closes the window, which puts the
-- player's Soap entries back. A save & quit stops nothing first: DF
-- unloads the map and then writes, the stop comes from refinish_steel.lua's
-- map unload handler, and this file's own unload handler drops soap_saved
-- unwritten. DFHack calls state change handlers in an arbitrary order (Lua
-- API, Event type: it loops through the table with next), so whenever this
-- file's ran first, stop() found no window and the save carried every
-- pile's Soap entry set to its Coal entry: on where Coal is on, off where
-- Coal is off. Whether a pile can still be written at the map unload was
-- never measured either.
-- SEEN in play 2026-10-27: soap turning up in coal piles, and every coal
-- pile's Soap entry on after a load, and on again after the next load once
-- switched off. The path above is the one found in the code by which a
-- save can carry the switch.
-- So while RM's save hook reports the options screen up
-- (_G.refinish_menu_locked), coal is released, and it is not engaged again
-- until the screen closes (menu_tick, engage_coal). Every save the player
-- asks the game for starts on that screen, and the game's simulation stands
-- still while it is up (refinish-save-hook.lua, THE PAUSE, HELD FROM UNLOAD
-- TO RELOAD), so the hold costs no hauling. Loose coal waiting it out holds
-- the stall clock, as soap's turn does, and no pile is written at the map
-- unload. Without the save hook (an ERROR at map load) there is no hold.
--
-- ==========================================
-- HIDING THE TWINS IN THE MENUS
-- ==========================================
-- decision (2026-09-27): hide the twins from the menus, keep the
-- menu label as the fallback. A twin is a tool made of its stone, which is
-- how vanilla would sort it, so no menu needs it as an entry of its own.
-- Two menus list them while a window lends the flags, and they are hidden
-- differently, because the game keeps running in one of them:
--
--   THE MATERIAL SELECTION MENU (game.main_interface.job_details). The
--     game does NOT pause there (in play: this contradicts DFHack's
--     World::ReadPauseState, which lists job_details.open among the states
--     it counts as paused). So the flags are never touched for it: hauling
--     goes on. Its rows hold no label strings, only parallel value vectors,
--     material (mat_type), matgloss (mat_index) and material_count, with
--     the unfiltered _master copies; DF draws each name from the material,
--     so a label there would mean renaming the material. Instead every row
--     that is a twin is ERASED from both sets of vectors, kept in step, on
--     the frame after DF builds or rebuilds the list (the lengths change),
--     so a twin shows for a frame at most.
--   THE STOCKPILE SETTINGS SCREEN (custom_stockpile). Its rows are
--     pointers to structs DF allocated, with separate size counters
--     (cur_spec_item_sz), so erasing them could make DF read past the end:
--     they are not erased. Instead, while the screen is open AND the game
--     has actually stopped (df.global.cur_year_tick unchanged for
--     HALT_FRAMES frames, measured, not taken from a pause list), the
--     window's flags are taken back: lists DF builds then carry no twins.
--     The flags are lent again the frame the tick moves or the screen
--     closes. If the game keeps running there, nothing is touched. Rows DF
--     built before the flags came off keep the menu label until DF
--     rebuilds the list.
--
-- Both run from the paused-capable subscription (MENU_KEY), every frame.
--
-- ==========================================
-- EDITING ROWS OUT (2026-09-28)
-- ==========================================
-- The flag take-back cannot reach every list. Coins lists every inorganic,
-- flags or not (839 of 839 rows, in play), so every twin showed there; and a
-- listed twin is stone for good. So the settings screen's rows are also
-- edited out directly, the way DF's own search filter hides a row.
-- MEASURED with refinish-menu-probe (2026-09-28):
--   * custom_stockpile.spec_item is a pool, one row per inorganic. DF never
--     allocates or frees a row while the screen is open: a list switch
--     reorders the pool so the list's rows come first and sets
--     cur_spec_item_sz to how many belong to it.
--   * The search filter moves nothing: it sets each live row's on flag (on
--     = the name matches, not the pile's setting) and sets
--     counted_cur_spec_item_sz to how many are left on.
--   * Rows turned off from outside, with that count lowered to match, stay
--     off (hundreds of frames with no keystroke) and vanish from the list:
--     no blank or repeated rows, toggling unaffected. A keystroke or a list
--     switch recomputes both and brings them back, until the next frame.
-- So on every frame the settings screen is open, each live row that is on
-- and toggles a twin's entry, or a hidden material's outside its keep
-- lists, is turned off, and the count is lowered by as many. A coal claim's
-- rows are left: coal is a real material the screen may list. Nothing is
-- moved, freed or erased. A row that is edited out carries its tag, so it
-- reads what it is if it ever shows; a row that stays listed never does,
-- since there it is the real entry and a tag would be a seam. DF reuses one
-- row per material across every list, so a tag a row picked up where it was
-- hidden comes off where it stays. The material selection menu erases hidden
-- materials' rows along with the twins': keep lists name settings lists
-- only. The flag take-back stays, since it also restores the
-- player's own Soap entries while the coal switch is on.
--
-- ==========================================
-- STOCKHOOK, WHEN IT IS IN THE WORLD
-- ==========================================
-- Stockhook (RM's stockpile hook: a DLL on DF's own stockpile check, with
-- its Lua in RM's scripts_modactive, refinish-stockhook.lua) can give an
-- item another material for the length of each stockpile check: a
-- MATERIAL ALIAS. A twin aliased to its source is filed by every pile
-- exactly as an item of the source would be, by the pile's own settings,
-- with no flags lent, no window, no mirror and no timers to chase. So
-- while its hook is live, every claimed twin with a source is handed to
-- Stockhook as an alias of that source (SH.hand), and the loop opens no
-- window at all. Everything below is the FALLBACK for when the hook is
-- not live: a DF build Stockhook does not know yet (after a DF update),
-- its DLL not installed yet (the first launch), or stockhook.disable. RM's
-- log says which, with a WARNING (SH.here).
--
-- What stays the same with Stockhook: the menus. Twins are still edited
-- out of the settings lists that show them (coins lists every inorganic),
-- hidden materials and labels as before (EDITING ROWS OUT, THE MENU
-- LABEL). What goes: the coal claim's soap switch. Making Fuel's coals are
-- Stockhook rows of their own in that world (its stockhook/coal.txt), so a
-- claim filed as coal has nothing to do there.
--
-- The aliases are handed over at every resolve, and only when they
-- changed, so a twin pushed later in the session follows at the next scan
-- or menu opening. stop() takes them back; a world unload drops them with
-- Stockhook's own state.
--
-- ==========================================
-- WHAT A WINDOW WAITS FOR
-- ==========================================
-- Stockpile settings and work orders, the screens that list materials by
-- name, where the stone twins would show as a second copy of every stone.
-- A window does not OPEN while one of them is up. One already open stays
-- open whatever the player looks at: closing it early is what strands
-- items. MEASURED 2026-09-27: the first build also waited on building
-- sheets and closed open windows for them, and windows shut eight times
-- across two sessions while worked on workshops, with nothing hauled.
--
-- ==========================================
-- THE FLAGS
-- ==========================================
-- Each twin gets its source's material flags, and an inorganic twin its
-- source's inorganic flags too, all but the two that make a stone an ore
-- (NOT AN ORE, below): what the assign copy leaves behind, less those.
-- Every change is recorded by material address and material id, and a
-- restore re-resolves the material and checks its id before writing, so a
-- twin rebuilt or removed in between is never written to.
--
-- NOT AN ORE (2026-10-16). SEEN in play: the smelter listed "smelt
-- magnetite ore" twice, one of them for magnetite's aggregate twin. A
-- stone is an ore by its flags and by its tables. The flags are METAL_ORE,
-- DF's SMELTABLE, and THREAD_METAL, its THREADABLE (df-structures,
-- df.matgloss.xml), the two DFHack's isOre reads
-- (inorganic_raw.methods.inc); lent with the rest, they make an ore's twin
-- an ore by DF's own flag for as long as a window is open. The tables came
-- across in the twin's copy (NOT AN ORE, refinish-material-aggregate.lua).
-- Which of the two DF's own lists read is not known, so a twin keeps
-- neither: these flags are never lent (NOT_LENT), and the aggregate takes
-- the tables off as it makes each twin. Gravel is filed as a finished
-- good, whose materials DFHack's stockpile rules choose by the material
-- flags IS_GEM, IS_METAL and IS_STONE alone (StockpileSerializer.cpp,
-- finished_goods_mat_is_allowed), so by those rules holding the ore flags
-- back costs the filing nothing.
--
-- ==========================================
-- LIFECYCLE
-- ==========================================
-- Loaded, started and stopped by refinish_steel.lua beside the organic
-- registrar; stop() closes an open window. The raws are rebuilt on every
-- data cycle and load, so the flags go with them; the record is dropped
-- unwritten on a world unload.
--
-- ==========================================
-- COMMANDS
-- ==========================================
--   refinish-stockpile-windows status    claims, the census, loose items,
--                                        the window, and the stuck diagnosis
--                                        when any item is loose; written to
--                                        the session log as well
--   refinish-stockpile-windows check [WORD]
--                                        THE FACTS, no interpretation, into
--                                        the log: how often the loop ran and
--                                        where each run stopped, what the
--                                        dispatcher holds for it, the screen
--                                        it sees, and for every twin item its
--                                        flags, references, holder and role.
--                                        Added 2026-09-27, when a third build
--                                        logged no census at all and the log
--                                        could not say why.
--                                        With WORD (GRAVEL, DUST, KINDLING):
--                                        also every tool item whose id holds
--                                        it and is off a pile, twin or not,
--                                        with its material and place.
--
--   refinish-stockpile-windows test [frames]
--                                        a held window with gravel moved to
--                                        the floor and DF's own answers; see
--                                        THE TEST COMMAND.
--   refinish-stockpile-windows menu      with a pile's settings open: each
--                                        row's labels and the entry it
--                                        toggles; see THE MENU LABEL.
--   refinish-stockpile-windows piles     every pile's own answer for a stone
--                                        and a wood twin, flags on and off,
--                                        and every pile's settings against
--                                        the newest pile's; see THE TEST'S
--                                        ANSWER.
--
-- A STUCK report writes the first STUCK_DETAIL stuck items the same way
-- and reads the sampled timers again TIMER_FOLLOWUP frames later, so a
-- failure is recorded when it happens without anyone typing a command.
--
-- The backstop scan also logs the CENSUS (DETAIL) whenever it changes:
-- every twin item by place, and the flags of the first one held by
-- nothing it could find.
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')

-- RM's tint maker, and the vanilla art it tints (the soap bar among it).
-- Resolved once at file scope: reqscript costs about 2 ms a call.
local art = nil
pcall(function() art = reqscript('refinish-sprite-art') end)
pcall(function() reqscript('refinish-sprite-art-vanilla') end)

-- ---- LOG IDENTITY, DECLARED HERE ----
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'STOCKPILE_WINDOWS'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- DETAIL for routine opening and closing; INFO for the stuck report a
-- player can act on; ERROR for faults.
local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
    else
        line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
            tostring(subject or '-'), tostring(typ or 'UNTYPED'), tostring(msg))
    end
    _G.refinish_log_event(line)
end

local function try(fn, dflt)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return dflt
end

-- A settings entry as a boolean. They read as 0 and 1 in play, and 0 is
-- true in Lua. See THE PILES' TWIN SLOTS.
local function truth(v)
    if type(v) == 'number' then return v ~= 0 end
    return v == true
end

-- ==========================================
-- CONSTANTS
-- ==========================================
local KEY          = 'refinish-stockpile-windows'
local TICK_FRAMES  = 25      -- the loop; nearly free while nothing is open
local SCAN_FRAMES  = 1000    -- the backstop scan for loose twin items
local RECOUNT      = 250     -- loose items recounted this often while open
local STALL_FRAMES = 3000    -- no haul this long with items loose: stuck
local FULL_FRAMES  = 4000    -- the twin items renewed at least this often (THE RENEWAL, A SLICE A TICK)
local RENEW_SLICE  = 2500    -- a renewal tick's budget: each item read costs 1, each twin placed RENEW_TWIN more
local RENEW_TWIN   = 3       -- a twin's classify, against an item's read
local RENEW_SHIFT  = 64      -- places a pass looks either way for the last item it read (KEPT IN STEP)
local BACKOFF_MIN  = 2000
local BACKOFF_MAX  = 32000
local STUCK_SAMPLE = 20      -- stuck items read for their storage timers
local STUCK_DETAIL = 5       -- stuck items written out in full at a STUCK
local TIMER_FOLLOWUP = 500   -- frames until sampled timers are read again
local TIMER_SPREAD = 10      -- a window sets countdowns 1..TIMER_SPREAD
local TIMER_DELAY  = 13      -- and delays to this, a fresh item's value
local TEST_FRAMES  = 6000    -- a test holds its window this long
local MENU_FRAMES  = 1       -- the menu watch runs this often, paused or not
local HALT_FRAMES  = 2       -- tick unchanged this many frames: the game has stopped
local MENU_KEY     = 'refinish-stockpile-windows-menu'

-- The pile settings vectors indexed by inorganic material, where a stone
-- twin can show while it has its stone's flags (df-structures, the
-- stockpile_parameter_* structs).
local INORG_LISTS = {
    { 'stone', 'mats' }, { 'ammo', 'mats' }, { 'coins', 'mats' },
    { 'bars_blocks', 'bars_mats' }, { 'bars_blocks', 'blocks_mats' },
    { 'gems', 'rough_mats' }, { 'gems', 'cut_mats' }, { 'finished_goods', 'mats' },
    { 'weapons', 'mats' }, { 'armor', 'mats' }, { 'furniture', 'mats' },
}
local TEST_DROP    = 3       -- gravel moved to the floor by a test

-- A building's own material (df-structures: TEMP 0, TEMP_PRINTHIDDEN 1,
-- PERM 2). Read from the enum, with its value as the fallback.
local ROLE_PERM = 2
pcall(function() ROLE_PERM = df.building_item_role_type.PERM end)

-- ---- ITEM FLAGS AS ONE NUMBER ----
-- MEASURED 2026-10-01 (section probe, 365 s): with 4,285 twin items a
-- count of the known twins cost 25.8 ms, about 4 microseconds an item,
-- most of it reads through DFHack. classify read up to seven of an item's
-- flags one at a time, each a read of its own. The flags are one word
-- (Lua_API: a bitfield's whole is its value as an integer), so classify
-- reads it once and tests the bits in Lua. The bit positions come from the
-- bitfield's own names, read here; if any cannot be read the masks stay
-- nil and classify reads the flags one by one, as before.
local F_ON_GROUND, F_IN_JOB, F_CONSTRUCTION, F_MARKED = nil, nil, nil, nil
pcall(function()
    local t = df.item_flags
    local on_ground, in_job, construction = 1 << t.on_ground, 1 << t.in_job, 1 << t.construction
    local marked = (1 << t.forbid) | (1 << t.dump) | (1 << t.garbage_collect) | (1 << t.removed)
    F_ON_GROUND, F_IN_JOB, F_CONSTRUCTION, F_MARKED = on_ground, in_job, construction, marked
end)

-- Screens that list materials by name (DFHack focus strings, matched as
-- prefixes). A window waits for these to close before it opens.
local WAIT_SCREENS = {
    'dwarfmode/Stockpile',
    'dwarfmode/Info/WORK_ORDERS',
}

-- The soap switch's addresses (COAL: THE SOAP SWITCH).
local SOAP_FLAG  = df.material_flags.SOAP
local SOAP_ENTRY = 4     -- df.stockpile_bar_mat.Soap
local COAL_ENTRY = 0     -- df.stockpile_bar_mat.Coal
pcall(function() SOAP_ENTRY = df.stockpile_bar_mat.Soap end)
pcall(function() COAL_ENTRY = df.stockpile_bar_mat.Coal end)

-- Soap's turn when it is wanted (SOAP GETS ITS TURN): the least number of
-- frames coal stays disengaged; it also waits while soap is in use.
local SOAP_TURN    = 2000
local UNMET_WARN   = 3       -- soap wanted this often running, none real: WARNING

-- The soap bar's tile in vanilla's graphics (SOAP KEEPS ITS LOOK).
local SOAP_PAGE, SOAP_X, SOAP_Y = 'ITEM_CONSTRUCTION', 1, 1

-- Jobs that use soap by their nature, whatever their filters say.
local SOAP_JOBS = {}
for _, name in ipairs({ 'CleanPatient', 'CleanSelf', 'StoreItemInLocation' }) do
    local v = df.job_type[name]
    if v then SOAP_JOBS[v] = name end
end

-- Jobs that only move an item.
local HAULING = {}
for _, name in ipairs({ 'StoreItemInStockpile', 'StoreItemInBin', 'StoreItemInBarrel',
                        'StoreItemInBag' }) do
    local v = df.job_type[name]
    if v then HAULING[v] = true end
end

-- ==========================================
-- STATE
-- ==========================================
-- Claims live in _G, so a script reload keeps what owners have claimed.
_G.refinish_stockpile_windows = _G.refinish_stockpile_windows or { claims = {} }
local S = _G.refinish_stockpile_windows
-- Hides (CLAIMING) live beside the claims; a table an older copy of this
-- file made has none yet.
S.hides = S.hides or {}
-- Labels (THE MENU LABEL) live beside them, the same way.
S.labels = S.labels or {}

local running  = false
local frame    = 0
local twins    = {}      -- mt -> mi -> { smt, smi }, from the last resolve
local unlisted = {}      -- mt -> mi -> { tag, keep }, the hides, same resolve
local labelled = {}      -- mt -> mi -> row text, the labels, same resolve
local types    = {}      -- item vector names to scan
local pending  = {}      -- item ids made since the last tick
local known    = nil     -- item id -> vector name: the twin items known (THE KNOWN TWINS)
local known_twins = nil  -- the twins table that list was last checked against
local known_sig = nil    -- the claims that list was built for, as one string
local last_full = 0      -- frame of the last full walk, or of the last renewal pass's start
local renew    = nil     -- the renewal pass under way, or nil (THE RENEWAL, A SLICE A TICK)
local new_bars = {}      -- mt -> mi -> true: bar materials made since the soap scan took them
local settled  = {}      -- item id -> true: a known twin last found stored (A STORED TWIN, LEFT STORED)
local in_shop  = {}      -- item id -> flags word: a known twin last found in a workshop (A TWIN IN A WORKSHOP, STILL THERE)
-- The places a twin stays in until something moves it (A STORED TWIN,
-- LEFT STORED). Declared up here because the full walk, which comes
-- before that section, records them too.
local SETTLED_PLACES = {
    ['on a pile'] = true,
    ['held elsewhere'] = true,          -- a detail-free count's container
    ['in a container'] = true,
    ['part of a construction'] = true,
    ['part of a building'] = true,
    ['held by another building'] = true,
}
local record   = nil     -- the open window's flag changes: { mt, mi, kind, id, i, old, new }
local hidden   = false   -- the window's flags taken back for the stockpile screen
local coal_on  = false   -- the soap switch engaged in the open window
local soap_saved = nil   -- pile id -> the player's own Soap entry, while switched
local soap_texpos = nil  -- the soap tile's texpos: nil unread, false not found
local soap_turn_until = 0   -- frame before which coal is not engaged (soap's turn)
local unmet_run = 0         -- soap wanted running with no real soap in the fort
local unmet_said = false    -- that WARNING given this session
local win      = nil     -- { opened, progress, loose, last_count, hauls = {} }
local next_scan, next_try, backoff = 0, 0, BACKOFF_MIN
local last_census = nil  -- the census line last logged, so it logs on change
local stuck_kinds = nil  -- loose twins at the last STUCK, as 'mt:mi:place' (THE RETRY WAIT GIVES WAY TO A CHANGE)
local stuck_piles = nil  -- the piles at the last STUCK, as one string (piles_sig)
local test = nil         -- a running test: { ends, tracked, dropped, piles }
local said = {}          -- error messages already logged, once each

-- ---- WHAT THE LOOP DID, FOR THE CHECK ----
-- Kept in the _G table, not in locals: a script run from the console is a
-- fresh copy with locals of its own, so only _G shows the running copy.
-- calls: runs of the loop. exits: how each run ended, by reason. The rest
-- mirrors the loop's state at its last run.
S.dbg = S.dbg or { calls = 0, exits = {}, scans = 0 }
local function note(reason)
    local e = S.dbg.exits
    e[reason] = (e[reason] or 0) + 1
    S.dbg.frame, S.dbg.next_scan, S.dbg.next_try = frame, next_scan, next_try
    S.dbg.window, S.dbg.last_census = record ~= nil, last_census
end

-- ==========================================
-- CLAIMS AND THE TWIN SET
-- ==========================================
function claim(owner, select, opts)
    if type(owner) ~= 'string' or type(select) ~= 'function' then
        log('ERROR', 'a claim needs an owner name and a select function.', 'CLAIM')
        return false
    end
    S.claims[owner] = { select = select, item_types = (opts and opts.item_types) or { 'TOOL' },
                        menu_tag = opts and opts.menu_tag or nil,
                        file_as = opts and opts.file_as or nil }
    log('DETAIL', owner .. ' claimed its twins.', 'CLAIM')
    return true
end

function unclaim(owner)
    S.claims[owner] = nil
end

-- See CLAIMING and EDITING ROWS OUT. keep_in is turned into a set of list
-- names once, here, so the per frame edit only looks names up.
function hide(owner, select, opts)
    if type(owner) ~= 'string' or type(select) ~= 'function' then
        log('ERROR', 'a hide needs an owner name and a select function.', 'HIDE')
        return false
    end
    local keep = {}
    for _, name in ipairs((opts and opts.keep_in) or {}) do keep[name] = true end
    S.hides[owner] = { select = select, keep = keep, menu_tag = opts and opts.menu_tag or nil }
    log('DETAIL', owner .. ' hid its materials from the menus.', 'HIDE')
    return true
end

function unhide(owner)
    S.hides[owner] = nil
end

-- See THE MENU LABEL and the label call in the header.
function label(owner, select)
    if type(owner) ~= 'string' or type(select) ~= 'function' then
        log('ERROR', 'a label needs an owner name and a select function.', 'LABEL')
        return false
    end
    S.labels[owner] = { select = select }
    log('DETAIL', owner .. " labelled its materials' menu rows.", 'LABEL')
    return true
end

function unlabel(owner)
    S.labels[owner] = nil
end

-- See tagged() in CLAIMING. Every select called afresh, as resolve() calls
-- them, but the list is handed back rather than kept: nothing a window or
-- a menu pass holds changes, so it is safe to ask at any moment.
function tagged()
    local out = {}
    for owner, c in pairs(S.claims) do
        -- Coal is a real material, not a twin: no tag goes on it.
        if c.menu_tag and c.file_as ~= 'coal' then
            local ok, list = pcall(c.select)
            if ok and type(list) == 'table' then
                for _, e in ipairs(list) do
                    local mt, mi = e.twin and e.twin[1], e.twin and e.twin[2]
                    if mt and mi then out[#out + 1] = { mt, mi, c.menu_tag } end
                end
            else
                log('ERROR', ("%s's select failed: %s"):format(owner, tostring(list)), 'CLAIM')
            end
        end
    end
    for owner, h in pairs(S.hides) do
        if h.menu_tag then
            local ok, list = pcall(h.select)
            if ok and type(list) == 'table' then
                for _, e in ipairs(list) do
                    if e[1] and e[2] then out[#out + 1] = { e[1], e[2], h.menu_tag } end
                end
            else
                log('ERROR', ("%s's hide select failed: %s"):format(owner, tostring(list)), 'HIDE')
            end
        end
    end
    return out
end

-- ==========================================
-- STOCKHOOK, THE CODE
-- ==========================================
-- See STOCKHOOK, WHEN IT IS IN THE WORLD in the header.
-- ONE LOCAL. A Lua chunk may hold at most 200 locals at its top level,
-- and this file stood at the limit: three variables and three functions
-- of their own failed the whole file to load ("too many local variables",
-- 2026-11-02). So everything here lives in the one table SH.
--   SH.owner       this file's name for its aliases in Stockhook
--   SH.mod         nil: not asked yet this session; false: not here; else
--                  Stockhook's module
--   SH.sig         the pairs last handed over, as one string
--   SH.here()      Stockhook's module, or nil
--   SH.hand()      the twins handed over as aliases
--   SH.take_back() the aliases taken back
local SH = { owner = 'refinish-stockpile-windows', mod = nil, sig = nil }

-- Stockhook's module when its hook is live, else nil. Asked once per
-- session (start() and a world unload clear it). Its scripts are in RM's
-- scripts_modactive, so they are on the path in every RM world;
-- available() is false when its DLL is not hooked.
function SH.here()
    if SH.mod == nil then
        SH.mod = false
        local ok, m = pcall(reqscript, 'refinish-stockhook')
        if ok and type(m) == 'table' and m.world_active and m.available and m.alias and m.commit then
            local ok_w, active = pcall(m.world_active)
            local ok_a, avail, why = pcall(m.available)
            if ok_w and active and ok_a and avail then
                SH.mod = m
                log('INFO', 'Stockhook is in this world: twins file as their sources through it,'
                    .. ' and no window opens.', 'STOCKHOOK')
            elseif ok_w and active then
                -- In the world, but its hook is not live (a DF update it
                -- does not know yet, most often): said here, in RM's own
                -- log, with Stockhook's reason, not only in stockhook.log.
                log('WARNING', ('Stockhook is in this world but its hook is not live (%s).'
                    .. " RM's stockpile windows run instead, and Stockhook's own rows file"
                    .. ' nothing until it is.'):format(ok_a and tostring(why) or tostring(avail)),
                    'STOCKHOOK')
            end
        end
    end
    return SH.mod or nil
end

-- Every twin with a source, as a Stockhook alias of that source, handed
-- over when the set differs from the last one handed over. A claim filed
-- as coal has no source and is left out.
function SH.hand()
    local sh = SH.here()
    if not sh then return end
    local list, keys = {}, {}
    for mt, by_mi in pairs(twins) do
        for mi, tw in pairs(by_mi) do
            if tw.smt and tw.smi then
                list[#list + 1] = { mt, mi, tw.smt, tw.smi }
                keys[#keys + 1] = ('%s:%s>%s:%s'):format(tostring(mt), tostring(mi),
                    tostring(tw.smt), tostring(tw.smi))
            end
        end
    end
    table.sort(keys)
    local sig = table.concat(keys, ',')
    if sig == SH.sig then return end
    local ok, err = pcall(function()
        sh.alias(SH.owner, #list > 0 and { pairs = list } or nil)
        sh.commit()
    end)
    if ok then
        SH.sig = sig
        log('DETAIL', ('%d twin material(s) handed to Stockhook as aliases of their sources.')
            :format(#list), 'STOCKHOOK')
    else
        local msg = 'handing the twins to Stockhook failed: ' .. tostring(err)
        if not said[msg] then
            said[msg] = true
            log('ERROR', msg, 'STOCKHOOK')
        end
    end
end

-- The aliases taken back (stop()). Stockhook commits at once, so the DLL
-- stops aliasing before RM's raws go.
function SH.take_back()
    if SH.mod and SH.sig then
        pcall(function()
            SH.mod.alias(SH.owner, nil)
            SH.mod.commit()
        end)
    end
    SH.mod, SH.sig = nil, nil
end

-- Rebuild the twin set from every claim. A claim that throws costs only
-- itself, named once per resolve. The menus' half, the labels and the
-- hides, follows in resolve_menus (THE MENUS' HALF, below), which this
-- ends with, so a scan builds all three as it always has.
local resolve_menus      -- defined below; resolve() ends with it
local function resolve()
    twins, types = {}, {}
    local n = 0
    for owner, c in pairs(S.claims) do
        local ok, list = pcall(c.select)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                local mt, mi = e.twin and e.twin[1], e.twin and e.twin[2]
                if mt and mi and e.source then
                    twins[mt] = twins[mt] or {}
                    twins[mt][mi] = { smt = e.source[1], smi = e.source[2], tag = c.menu_tag }
                    n = n + 1
                elseif mt and mi and c.file_as == 'coal' then
                    twins[mt] = twins[mt] or {}
                    twins[mt][mi] = { file_as = 'coal', tag = c.menu_tag }
                    n = n + 1
                end
            end
            for _, t in ipairs(c.item_types or { 'TOOL' }) do types[t] = true end
        else
            log('ERROR', ('%s\'s select failed: %s'):format(owner, tostring(list)), 'CLAIM')
        end
    end
    resolve_menus()
    -- With Stockhook in the world, the twins go to it as aliases
    -- (STOCKHOOK, WHEN IT IS IN THE WORLD).
    SH.hand()
    return n
end

-- ---- THE MENUS' HALF ----
-- The labels and the hides feed the menus alone, never a window, so they
-- are built on their own too: resolve() ends with this, and a menu that
-- opens runs it alone while a window is open, and for the material picker
-- (THE MENUS, RESOLVED AS THEY OPEN). Assigned to the local declared above
-- resolve(), so it stays this file's own.
function resolve_menus()
    -- The labels, the same way: a select that throws costs only itself.
    labelled = {}
    for owner, l in pairs(S.labels) do
        local ok, list = pcall(l.select)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                local mt, mi, text = e[1], e[2], e[3]
                if mt and mi and type(text) == 'string' then
                    labelled[mt] = labelled[mt] or {}
                    labelled[mt][mi] = text
                end
            end
        else
            log('ERROR', ("%s's label select failed: %s"):format(owner, tostring(list)), 'LABEL')
        end
    end
    -- The hides, the same way: a select that throws costs only itself.
    unlisted = {}
    for owner, h in pairs(S.hides) do
        local ok, list = pcall(h.select)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                local mt, mi = e[1], e[2]
                if mt and mi then
                    unlisted[mt] = unlisted[mt] or {}
                    unlisted[mt][mi] = { tag = h.menu_tag, keep = h.keep }
                end
            end
        else
            log('ERROR', ('%s\'s hide select failed: %s'):format(owner, tostring(list)), 'HIDE')
        end
    end
end

-- ---- ONE READ PER ITEM ----
-- MEASURED 2026-09-30 (walk probe, 20,190 bars): the twin test cost
-- 16.7 ms a walk of the bars when it read each field through try(), two
-- closures and two pcalls an item, and 9.6 ms reading them directly.
-- These tests also meet items of every class (a job's items include
-- corpses, which carry no mat_type), so a read that can throw stays
-- under a pcall: one pcall on a named function, which makes no closure.
local function mat_of(it) return it.mat_type, it.mat_index end
local function type_of(it) return it:getType() end
local function flags_of(it) return it.flags.whole end

-- An item's flags word, or nil when it cannot be read: then nothing is
-- recorded, and that twin is classified in full at every count (A TWIN
-- IN A WORKSHOP, STILL THERE).
local function word_of(it)
    local ok, w = pcall(flags_of, it)
    if ok then return w end
    return nil
end
local function soap_flag(info) return info.material.flags[SOAP_FLAG] end

local function is_twin(it)
    local ok, mt, mi = pcall(mat_of, it)
    if not ok then return false end
    local by = twins[mt]
    return by ~= nil and by[mi] ~= nil
end

-- Is this item one of a file_as = 'coal' claim's?
local function is_coal(it)
    local ok, mt, mi = pcall(mat_of, it)
    if not ok then return false end
    local tw = twins[mt] and twins[mt][mi]
    return tw and tw.file_as == 'coal' or false
end

-- Is this a bar of real soap: its material carries SOAP, and it is no claim's?
-- memo, when a walk passes one, keeps each material's answer, so a walk
-- of every bar decodes each material once instead of each bar.
-- MEASURED 2026-09-30: 62.5 ms a walk of 20,190 bars with no soap among
-- them, a decode per bar; the soap scan below, one decode per material,
-- measured 9.3 ms with direct reads.
local function is_real_soap(it, memo)
    local okt, ty = pcall(type_of, it)
    if not okt or ty ~= df.item_type.BAR then return false end
    local ok, mt, mi = pcall(mat_of, it)
    if not ok then return false end
    local row = memo and memo[mt]
    if row and row[mi] ~= nil then return row[mi] end
    local v = false
    local by = twins[mt]
    if not (by and by[mi]) then
        local okd, info = pcall(dfhack.matinfo.decode, it)
        if okd and info and info.material then
            local okf, f = pcall(soap_flag, info)
            v = okf and f == true
        end
    end
    if memo then
        if not row then row = {}; memo[mt] = row end
        row[mi] = v
    end
    return v
end

-- ==========================================
-- LOOSE
-- ==========================================
local function piles()
    local out = {}
    pcall(function()
        for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do out[#out + 1] = b end
    end)
    return out
end

-- Is this pile tile holding the item?
-- The pile whose tile holds the item, or nil.
-- ---- A PILE'S BOUNDS, READ ONCE PER LIST ----
-- MEASURED 2026-10-01 (section probe, 267 s, 1,459 twin items): a count
-- of the known twins cost 14.4 ms, of which 4.5 was building the pile
-- list and its bin room. Every item on the ground, and every bin, is
-- tested against every pile in the list, and each test read the pile's
-- z and corners, and the item's position, through DFHack again. A pile
-- does not move within a count, so its bounds are read once per pile
-- list and kept on it as plain numbers (.boxes), and the item's position
-- once per call. The same tests in the same order: containsTile still
-- decides every tile the bounds let through, and the first pile that
-- holds the item is the answer, as before. A pile list lives for one
-- count or one tick.
local function box_of(b) return { b.z, b.x1, b.x2, b.y1, b.y2 } end

local function on_pile(it, pile_list)
    local boxes = pile_list.boxes
    if not boxes then
        boxes = {}
        for i, b in ipairs(pile_list) do boxes[i] = box_of(b) end
        pile_list.boxes = boxes
    end
    local p = it.pos
    local px, py, pz = p.x, p.y, p.z
    for i, b in ipairs(pile_list) do
        local bx = boxes[i]
        if bx[1] == pz and px >= bx[2] and px <= bx[3] and py >= bx[4] and py <= bx[5]
           and dfhack.buildings.containsTile(b, px, py) then
            return b
        end
    end
    return nil
end

local function max_bins_of(b) return b.storage.max_bins end
local function volume_of(it) return it:getVolume() end

-- ---- BINS WITH ROOM ----
-- Free volume in each pile's bins, by pile id: bins lying on the pile's
-- tiles, not in a job or forbidden, in piles that allow bins. Kept on the
-- pile list as .room, for classify. See ON A PILE, BUT NOT BINNED.
-- ---- THE ROOM, SUMMED ONLY FOR PILES ASKED ABOUT ----
-- MEASURED 2026-10-01 (section probe, 365 s): building a count's pile list
-- and bin room took 7.6 ms, every bin's contents read and summed, while
-- the census held 19 twin items on piles, the only items whose place asks
-- for room. The walk of the bins now only finds which pile each bin lies
-- on. A pile's room is summed the first time an item on that pile asks,
-- from the same bins with the same reads, and kept for the rest of the
-- pile list's life. A pile with no bin room answers nothing, as before.
local function with_room(pile_list)
    local bins_on = {}
    pcall(function()
        for _, bin in ipairs(df.global.world.items.other.BIN) do
            local f = bin.flags
            if f.on_ground and not f.in_job and not f.forbid then
                local b = on_pile(bin, pile_list)
                -- NO CLOSURE PER READ: each guarded read is a pcall on a
                -- named function, where try() built a new closure for every
                -- bin and every item in it. Unreadable still counts as 0.
                local okm, mb = false, nil
                if b then okm, mb = pcall(max_bins_of, b) end
                if b and (okm and mb or 0) > 0 then
                    local list = bins_on[b.id]
                    if not list then list = {}; bins_on[b.id] = list end
                    list[#list + 1] = bin
                end
            end
        end
    end)
    pile_list.room = setmetatable({}, { __index = function(room, pile_id)
        local total = nil
        for _, bin in ipairs(bins_on[pile_id] or {}) do
            local okc, cap = pcall(dfhack.items.getCapacity, bin)
            if not okc or cap == nil then cap = 0 end
            local used = 0
            local okl, list = pcall(dfhack.items.getContainedItems, bin)
            if okl and list then
                for _, c in ipairs(list) do
                    local okv, v = pcall(volume_of, c)
                    if okv and v ~= nil then used = used + v end
                end
            end
            if cap > used then total = (total or 0) + (cap - used) end
        end
        rawset(room, pile_id, total or false)
        return total
    end })
    return pile_list
end

-- The item's role in the building holding it, or nil if it is not listed.
-- ---- ONE READ OF A BUILDING'S CONTENTS PER COUNT ----
-- MEASURED 2026-10-01 (section probe, 189 s): a count of the known twins
-- cost 63.9 ms a call, 110 ms at worst, with 690 to 732 of the fort's
-- 1,119 to 1,157 twin items in workshops (the census). For each of them
-- this read the workshop's contained_items from the start until it found
-- the item, so a count's cost grew with the square of what a workshop
-- holds. The same build had cost 41 ms a recount while 106 twins sat in
-- workshops.
--
-- Handed a roles table, the first item asked about a building reads that
-- building's list once and keeps every item's role by id; each later
-- item of the same building is one lookup. The first entry for an id is
-- the one kept, as the scan's first match was. classify keeps the table
-- on the pile list, which lives for one count or one tick, so no answer
-- outlives the count that read it. Without a table it scans, as before.
local function role_in(b, it, roles)
    if roles then
        local map = roles[b.id]
        if not map then
            map = {}
            for _, bi in ipairs(b.contained_items) do
                local item = bi.item
                if item and map[item.id] == nil then map[item.id] = bi.use_mode end
            end
            roles[b.id] = map
        end
        return map[it.id]
    end
    for _, bi in ipairs(b.contained_items) do
        if bi.item and bi.item.id == it.id then return bi.use_mode end
    end
    return nil
end

-- Where a twin item is, and whether that counts as loose. The place names
-- are what the census counts. Nothing off the ground is judged by its
-- flags: whatever holds it is asked (LOOSE, AND NEVER STRANDED).
-- ---- LOOSE ONLY: THE LAST TWO READS ARE FOR THE CENSUS ----
-- MEASURED 2026-10-01 (section probe, 367 s): with 3,773 twin items,
-- 3,206 of them in containers, a count of the known twins cost 24.8 ms
-- and the window service 10.8 ms/sec. An item no building holds is never
-- loose, whatever does hold it: the unit and container reads that follow
-- only name its place, for the census and the reports. loose_only (a
-- count without detail, the timers, the coal, the pending check) stops
-- there and answers 'held elsewhere'. Every loose answer, and the place
-- of every loose item, is the same either way.
local function classify(it, pile_list, loose_only)
    -- ITEM FLAGS AS ONE NUMBER: one read for all four tests; the reads one
    -- by one when the masks could not be built.
    local on_ground
    local w = F_MARKED and it.flags.whole
    if w then
        if w & F_IN_JOB ~= 0 then return 'in a job', false end
        if w & F_MARKED ~= 0 then return 'forbidden or marked', false end
        if w & F_CONSTRUCTION ~= 0 then return 'part of a construction', false end
        on_ground = w & F_ON_GROUND ~= 0
    else
        local f = it.flags
        if f.in_job then return 'in a job', false end
        if f.forbid or f.dump or f.garbage_collect or f.removed then return 'forbidden or marked', false end
        if f.construction then return 'part of a construction', false end
        on_ground = f.on_ground
    end
    if on_ground then
        local pb = on_pile(it, pile_list)
        if pb then
            local room = pile_list.room and pile_list.room[pb.id]
            if room then
                -- NO CLOSURE PER READ (BINS WITH ROOM): unreadable is 0.
                local okv, vol = pcall(volume_of, it)
                if not okv or vol == nil then vol = 0 end
                if room >= vol then return 'on a pile, to bin', true end
            end
            return 'on a pile', false
        end
        return 'on the floor', true
    end
    -- NO CLOSURE PER READ (BINS WITH ROOM): the holder reads are pcalls
    -- on DFHack's own functions; a read that fails answers nil, as try did.
    local okb, b = pcall(dfhack.items.getHolderBuilding, it)
    if not okb then b = nil end
    if b then
        -- ONE READ OF A BUILDING'S CONTENTS PER COUNT: the roles are kept
        -- on this pile list, made fresh for each count and each tick.
        local roles = nil
        if pile_list then
            roles = pile_list.roles
            if not roles then roles = {}; pile_list.roles = roles end
        end
        if role_in(b, it, roles) == ROLE_PERM then return 'part of a building', false end
        if df.building_workshopst:is_instance(b) or df.building_furnacest:is_instance(b) then
            return 'in a workshop', true
        end
        return 'held by another building', false
    end
    if loose_only then return 'held elsewhere', false end
    local oku, u = pcall(dfhack.items.getHolderUnit, it)
    if oku and u then return 'carried', false end
    local okc, c = pcall(dfhack.items.getContainer, it)
    if okc and c then return 'in a container', false end
    return 'held by nothing found', false
end

-- Every loose twin item. Returns the count, the number in workshops, and
-- with want_detail also a tally by name, up to STUCK_SAMPLE of the items
-- for the stuck report, and a tally of every twin item by place for the
-- census; want_detail 'census' gives the places and the odd item alone
-- (THE CENSUS ASKS ONLY FOR PLACES). Each item is read under its own
-- guard, so one that cannot be
-- read costs only itself, and the first such error is logged.
-- ---- ONE WALK OF THE BARS PER RECOUNT ----
-- MEASURED 2026-09-30 (walk probe, 20,190 bars): a recount walked the
-- bars twice, here and once more for the coal (loose_coal, or the soap
-- scan while coal is engaged), about 10 ms a walk even with direct reads.
-- This walk now also counts the loose coal among the bars (the seventh
-- answer, what loose_coal returns) and, handed a table, records every
-- bar material it passes, which is all the soap scan needs. The recount
-- asks for both and its second walk is gone. Callers that pass nothing
-- get exactly what they always got.
--
-- Since 2026-10-01 this walk is the backstop, not the loop's count: the
-- loop counts the twin items it already knows (count_twins) and walks
-- every item at least every FULL_FRAMES, since 2026-10-02 in a pass of a
-- slice a tick (THE RENEWAL, A SLICE A TICK). The walk records each twin
-- item it passes, and that record is the list the known count reads. See
-- THE KNOWN TWINS, below.

-- ---- ONE TWIN ITEM, COUNTED ----
-- The per item half of a count, shared by the full walk and the known
-- count, so the two cannot answer differently for the same item. acc
-- holds the running answers: n, in_shops and coal, and with want_detail
-- names, sample, places and odd.
local function new_count(want_detail)
    -- SECTION CLOCK (refinish-section-probe): the pile list and bin room.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    local pile_list = with_room(piles())
    if sc then sc.lap('windows: count setup (piles, bin room)', t0) end
    return { n = 0, in_shops = 0, coal = 0, want_detail = want_detail,
             names = want_detail == true and {} or nil,
             sample = want_detail == true and {} or nil,
             places = want_detail and {} or nil,
             kinds = want_detail and {} or nil,
             odd = nil, pile_list = pile_list }
end

-- What one loose twin adds to a count. count_one and the known count's
-- shortcut (A TWIN IN A WORKSHOP, STILL THERE) both tally through here,
-- so the two cannot answer differently for the same item.
local function tally_loose(acc, tw, is_bar, mt, mi, place)
    acc.n = acc.n + 1
    if place == 'in a workshop' then acc.in_shops = acc.in_shops + 1 end
    if is_bar and tw.file_as == 'coal' then acc.coal = acc.coal + 1 end
    -- What is loose, by twin material and place, for a count with
    -- detail (THE RETRY WAIT GIVES WAY TO A CHANGE).
    if acc.kinds then
        acc.kinds[tostring(mt) .. ':' .. tostring(mi) .. ':' .. place] = true
    end
end

local function count_one(acc, it, tw, is_bar, mt, mi)
    local ok, place, loose = pcall(classify, it, acc.pile_list, not acc.want_detail)
    if not ok then
        local msg = tostring(place)
        if not said[msg] then
            said[msg] = true
            log('ERROR', ('could not place twin item #%s: %s'):format(
                tostring(try(function() return it.id end, '?')), msg), 'SCAN')
        end
        return
    end
    if loose then tally_loose(acc, tw, is_bar, mt, mi, place) end
    if acc.want_detail then
        acc.places[place] = (acc.places[place] or 0) + 1
        -- The odd item is the lowest numbered one held by nothing found,
        -- not the first one met. The known list and the full walk meet
        -- items in different orders, the census line names the odd item,
        -- and a census that changed with the order alone would log a
        -- change that was not one and end a STUCK retry wait early (THE
        -- RETRY WAIT GIVES WAY TO A CHANGE).
        if place == 'held by nothing found' and (not acc.odd or it.id < acc.odd.id) then
            acc.odd = it
        end
        -- Names and the stuck sample only for a full detail count: the
        -- census leaves them out (THE CENSUS ASKS ONLY FOR PLACES).
        if loose and acc.names then
            local d = try(function() return dfhack.items.getDescription(it, 1) end, '?')
            acc.names[d] = (acc.names[d] or 0) + 1
            if #acc.sample < STUCK_SAMPLE then acc.sample[#acc.sample + 1] = it end
        end
    end
    -- Where it was, for A STORED TWIN, LEFT STORED. nil above, when the
    -- item could not be placed.
    return place
end

-- The seven answers, in the order count_loose has always returned them.
local function count_answers(acc)
    return acc.n, acc.in_shops, acc.names, acc.sample, acc.places, acc.odd, acc.coal, acc.kinds
end

local function id_of(it) return it.id end

-- The claims a known list was built for, as one string: every twin's
-- material and whether it files as coal, and every claimed type, sorted.
-- resolve() builds new tables at every scan and every window, so a list
-- is kept across a rebuild that changed nothing, and dropped by one that
-- changed anything.
local function claims_sig()
    local keys = {}
    for mt, row in pairs(twins) do
        for mi, tw in pairs(row) do
            keys[#keys + 1] = ('%s:%s:%s'):format(tostring(mt), tostring(mi),
                tw.file_as == 'coal' and 'coal' or '-')
        end
    end
    for t in pairs(types) do keys[#keys + 1] = 'type:' .. tostring(t) end
    table.sort(keys)
    return table.concat(keys, ',')
end

-- Is the known list good for the claims as they stand now?
local function known_good()
    if not known then return false end
    if known_twins ~= twins then
        if claims_sig() ~= known_sig then return false end
        known_twins = twins
    end
    return true
end

-- ---- ONE ITEM OF A WALK ----
-- What the full walk does with each item of a claimed type, shared with
-- the renewal pass (THE RENEWAL, A SLICE A TICK) so the two cannot record
-- an item differently. w is the walk's running state: acc (its counts),
-- bar_mats (or nil), found (every twin item it passes), n_found,
-- now_settled (of those, the ones found stored), now_in_shop (and the ones
-- found in a workshop, by flags word) and stale (kept as in a workshop,
-- flags unchanged, but elsewhere). Returns true for a twin item, the ones
-- that cost a classify.
local function walk_one(w, it, t, is_bar)
    -- is_twin, inline: the same one read, kept for the coal
    -- test and the material record below.
    local okm, mt, mi = pcall(mat_of, it)
    local bar_mats = w.bar_mats
    if okm and bar_mats and is_bar then
        local row = bar_mats[mt]
        if not row then row = {}; bar_mats[mt] = row end
        row[mi] = true
    end
    local tw = okm and twins[mt] and twins[mt][mi]
    if not tw then return false end
    local okid, id = pcall(id_of, it)
    if okid then
        w.found[id] = t
        w.n_found = w.n_found + 1
    end
    local place = count_one(w.acc, it, tw, is_bar, mt, mi)
    if okid and place and SETTLED_PLACES[place] then
        w.now_settled[id] = true
    end
    -- A TWIN IN A WORKSHOP, STILL THERE: recorded afresh. A
    -- twin the record held, its word unchanged, that is no
    -- longer in a workshop is one the shortcut has counted
    -- wrongly since. Counted here, so the size of that gap
    -- is measured, not assumed.
    local was = okid and in_shop[id]
    if okid and (was or place == 'in a workshop') then
        local wd = word_of(it)
        if place == 'in a workshop' then
            w.now_in_shop[id] = wd
        elseif was and wd == was then
            w.stale = w.stale + 1
        end
    end
    return true
end

-- ---- THE LIST, CHECKED AND RENEWED ----
-- The end of a full walk, and of a renewal pass. A twin item the walk
-- found that the list lacked was made without a created event (THE KNOWN
-- TWINS). Logged, so the gap is a number. One the walk found and lost
-- again before its end, which only a pass's ticks give time for, is read
-- again and left out. what names the walk in the log. keep, when given,
-- says which listed items the walk did not find stay listed, with their
-- records as they stand (THE RENEWAL, A SLICE A TICK); a full walk keeps
-- none, since what it did not find is gone.
local function renew_list(w, what, keep)
    if known_good() then
        local missed = 0
        for id in pairs(w.found) do
            if not known[id] then
                local it = df.item.find(id)
                if it and is_twin(it) then
                    missed = missed + 1
                else
                    w.found[id], w.now_settled[id], w.now_in_shop[id] = nil, nil, nil
                    w.n_found = w.n_found - 1
                end
            end
        end
        if missed > 0 then
            log('DETAIL', ('%s: %d twin item(s), %d of them not on the known list (made'
                .. ' without a created event); listed now.'):format(what, w.n_found, missed), 'KNOWN')
        end
        if keep then
            for id, t in pairs(known) do
                if not w.found[id] and keep(id) then
                    w.found[id] = t
                    if settled[id] then w.now_settled[id] = true end
                    if in_shop[id] then w.now_in_shop[id] = in_shop[id] end
                end
            end
        end
    end
    known, known_twins, known_sig, last_full = w.found, twins, claims_sig(), frame
    settled = w.now_settled
    in_shop = w.now_in_shop
    if w.stale > 0 then
        log('DETAIL', ('%s: %d twin item(s) kept as in a workshop, flags unchanged, were'
            .. ' elsewhere (A TWIN IN A WORKSHOP, STILL THERE).'):format(what, w.stale), 'KNOWN')
    end
    -- Either walk's end supersedes a pass under way.
    renew = nil
end

local function count_loose(want_detail, bar_mats)
    local w = { acc = new_count(want_detail), bar_mats = bar_mats, found = {}, n_found = 0,
                now_settled = {}, now_in_shop = {}, stale = 0 }
    for t in pairs(types) do
        local vec = try(function() return df.global.world.items.other[t] end)
        if vec then
            local is_bar = (t == 'BAR')
            for _, it in ipairs(vec) do walk_one(w, it, t, is_bar) end
        end
    end
    renew_list(w, 'full walk')
    -- Handed a table, this walk recorded every bar material there is, so
    -- the new bars waiting for the soap scan are in it already.
    if bar_mats then new_bars = {} end
    return count_answers(w.acc)
end

-- ==========================================
-- THE KNOWN TWINS
-- ==========================================
-- MEASURED 2026-10-01 (section probe, 486 s, a window open throughout):
-- the open window's recount cost 41.2 ms a call, 92 ms at worst, 15.2
-- ms/sec, nine tenths of this service. count_loose walks every item of
-- every claimed type to find the twins among them, and the fort's 548
-- twin items (its census) sat among tens of thousands of bars.
--
-- So the loop counts the twin items it KNOWS. The full walk records
-- every twin item it passes (count_loose). The created hook adds each
-- new twin item on the loop's next tick (A NEW ITEM, KNOWN), and a count
-- reads only the known items (count_known). A twin's material does not
-- change once it exists, and an item that is gone, or no longer a twin,
-- is not found and leaves the list.
--
-- THE BACKSTOP STAYS, at least every FULL_FRAMES: a full walk until
-- 2026-10-02, a renewal pass since (THE RENEWAL, A SLICE A TICK). The
-- created event fires for reactions, jobs and scripts, but not for
-- traders, migrants or invaders (SOURCES COVERED in
-- making-fuel-coal-watcher.lua), and the coal watcher's sweep turns an
-- existing bar into a coal twin without one. The backstop logs any twin
-- item the list lacked (THE LIST, CHECKED AND RENEWED), so the size of
-- that gap is measured, not assumed.
--
-- THE SOAP SCAN'S BAR MATERIALS. A full walk records every bar material
-- there is, as before. Between walks, the materials of bars made since
-- the scan last took them (new_bars) stand in, and a renewal pass adds
-- every bar material it passed to new_bars at its end. While coal is engaged,
-- every real soap material present was set aside when coal engaged
-- (engage_coal walks the bars itself) or at an earlier count, so only a
-- bar made since can bring a new one, and that bar's material is in
-- new_bars.
-- ==========================================
-- ---- A STORED TWIN, LEFT STORED ----
-- MEASURED 2026-10-01, refinish-section-probe, big fort, 437 s with a
-- window open: the open window's recount ran 147 times at 23.6 ms (45 at
-- worst), 7.94 ms/sec, the costliest line in the report. Each one read
-- every known twin item, around 5,000 here, and most of them were
-- stored: on a pile, in a bin, built into something. A stored twin is
-- not loose, so it adds nothing to the counts a recount uses (loose, in
-- workshops, loose coal).
--
-- So a count that finds a twin in one of SETTLED_PLACES (declared with
-- the state, above) records it in settled, and a count without detail skips it after that: no find, no
-- material, no classify. Only the twins that were loose, in a job,
-- marked, or held by nothing found are read again. Detail counts (the
-- census, a STUCK diagnosis) still read every item and renew the record,
-- and every full walk (count_loose) and renewal pass (at least every
-- FULL_FRAMES) builds it afresh.
--
-- What it can miss: a stored twin made loose again with no new item,
-- by a pile's settings changing or a bin being emptied, is unseen until
-- the next renewal. A window never closes on that: closing on nothing
-- loose takes a fresh full walk first.
--
-- ---- A TWIN IN A WORKSHOP, STILL THERE ----
-- MEASURED 2026-10-01, refinish-section-probe, big fort, 818 s with one
-- window open throughout: with stored twins skipped, the recount still
-- cost 16.9 ms a call, 12.9 over the first 169 s and 19.4 near the end.
-- The census as the window opened put 1,509 twins in workshops (3,333 in
-- containers, 21 on piles), 1,695 were loose 155 s later, and the backlog
-- kept growing. A twin in a workshop is loose, so every recount read each
-- one in full: about 7 us a twin over the first 169 s (12.9 ms less 1.5
-- of setup, over 1,527 to 1,695 loose), by inference mostly classify's
-- holder read, the walk of the workshop's contents for its role, and the
-- workshop and furnace tests.
--
-- So a count that finds a twin in a workshop keeps its item flags word in
-- in_shop, and a count without detail that reads the same word again
-- counts it loose in a workshop through tally_loose, without classify.
-- The ways a twin leaves a workshop change a flag classify reads: a haul
-- or a reaction takes it into a job (in_job), a removed workshop drops it
-- (on_ground), and forbidding, dumping or destroying it marks it. Any
-- other word gets the full classify, and so does every item of a count
-- with detail. The find and the material read stay, so an item that is
-- gone, or no longer a twin, still leaves the list.
--
-- What it can miss, inferred rather than measured: a twin moved from a
-- workshop into another building with its flags word unchanged, by a
-- script, or by a haul no count saw in progress. It stays counted as in a
-- workshop until the next renewal (at least every FULL_FRAMES), which
-- records afresh and logs how many it found (KNOWN). A window never
-- closes on one either way: closing takes a fresh full walk first.
local function count_known(want_detail, bar_mats)
    local acc = new_count(want_detail)
    for id, t in pairs(known) do
        if not want_detail and settled[id] then
            goto stored                  -- A STORED TWIN, LEFT STORED
        end
        do
            local it = df.item.find(id)
            local tw, mt, mi = nil, nil, nil
            if it then
                local okm
                okm, mt, mi = pcall(mat_of, it)
                tw = okm and twins[mt] and twins[mt][mi] or nil
            end
            if tw then
                -- A TWIN IN A WORKSHOP, STILL THERE: the same flags word as
                -- when it was found there, so it has not moved.
                local was = not want_detail and in_shop[id]
                if was and word_of(it) == was then
                    tally_loose(acc, tw, t == 'BAR', mt, mi, 'in a workshop')
                    goto stored
                end
                local place = count_one(acc, it, tw, t == 'BAR', mt, mi)
                settled[id] = (place and SETTLED_PLACES[place]) or nil
                in_shop[id] = (place == 'in a workshop') and word_of(it) or nil
            else
                known[id] = nil      -- gone, or no longer a twin
                settled[id] = nil
                in_shop[id] = nil
            end
        end
        ::stored::
    end
    if bar_mats then
        for mt, row in pairs(new_bars) do
            local into = bar_mats[mt]
            if not into then into = {}; bar_mats[mt] = into end
            for mi in pairs(row) do into[mi] = true end
        end
        new_bars = {}
    end
    return count_answers(acc)
end

-- The count the loop uses: the known list while it is good for the
-- claims; the full walk otherwise, which renews the list. Until
-- 2026-10-02 a count also came due for a full walk every FULL_FRAMES;
-- the renewal pass does that work now (THE RENEWAL, A SLICE A TICK).
local function count_twins(want_detail, bar_mats)
    -- SECTION CLOCK (refinish-section-probe): which way the count ran.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    if known_good() then
        local n, in_shops, names, sample, places, odd, coal, kinds = count_known(want_detail, bar_mats)
        if sc then sc.lap('windows: twins counted, known list', t0) end
        return n, in_shops, names, sample, places, odd, coal, kinds
    end
    local n, in_shops, names, sample, places, odd, coal, kinds = count_loose(want_detail, bar_mats)
    if sc then sc.lap('windows: twins counted, full walk', t0) end
    return n, in_shops, names, sample, places, odd, coal, kinds
end

-- ==========================================
-- THE RENEWAL, A SLICE A TICK
-- ==========================================
-- MEASURED 2026-10-02 (section probe, windows: twins counted, full walk):
-- 46 to 48 ms a call, 56 at worst, once every FULL_FRAMES while a window
-- was open (8 calls in 342 s, 5 in 219 s). The recount that came due for
-- the backstop read every item of every claimed type in one tick, so that
-- tick stalled for as long.
--
-- Now the backstop is a pass of its own, RENEW_SLICE a tick, and every
-- count reads the known list while it is good for the claims
-- (count_twins). A pass starts on the first tick at least FULL_FRAMES
-- after the last full walk or pass, does with each item exactly what the
-- full walk does (walk_one), and at its end renews the list and its
-- records as the full walk does (renew_list). The bar materials it passed
-- join new_bars, for the soap scan's next count.
--
-- What a pass changes, against the full walk it replaces:
--   * its reads are spread over the pass, about 20 ticks (500 frames),
--     not one. A record read early is that much older at the pass's end,
--     beside the FULL_FRAMES every record ages between renewals.
--   * the count that came due for the backstop reads the known list, so
--     a twin made without a created event is counted from the pass's end,
--     a few hundred frames later.
--   * its pile list (the piles, their bin room and the building roles)
--     is made at the pass's start and kept for the pass. Made each tick it
--     would cost about 2 ms a tick (windows: count setup) and read a
--     workshop's contents once a tick instead of once a pass. What it can
--     get wrong is what a renewal's records get wrong between renewals (A
--     STORED TWIN, LEFT STORED): an item whose pile or bin changed after
--     the list was made. A twin it places in a workshop that the workshop
--     took into itself meanwhile (a building finished during the pass) is
--     placed again by the next count: its flags word changed.
--
-- The full walk stays wherever a count must be fresh: the first count of
-- a session, a claims change, closing on nothing loose, the STUCK
-- diagnosis, the status command and the test. Each supersedes a pass
-- under way (renew_list).
--
-- KEPT IN STEP. A pass reads each vector by position across ticks, and an
-- item removed meanwhile below its place moves the rest down one, which
-- would pass one over. So each tick first checks that the last item it
-- read is still where it left it, and if not looks for it within
-- RENEW_SHIFT places either way and goes on after it. A pass that cannot
-- find it may have passed one over, so it is unsure: at its end it keeps
-- every listed item it did not find, with its records as they stand, and
-- the next pass takes out what is gone. An item made during the pass is
-- listed by the created hook (A NEW ITEM, KNOWN) and kept the same way.

-- One tick of the pass, started if one is due. Returns true when it read.
local function renew_step()
    if not renew then
        if frame - last_full < FULL_FRAMES or not known_good() then return false end
        local list = {}
        for t in pairs(types) do list[#list + 1] = t end
        table.sort(list)
        renew = { types = list, ti = 1, cursor = 0, last_id = nil, unsure = false,
                  start_id = df.global.item_next_id, start_frame = frame,
                  w = { acc = new_count(false), bar_mats = {}, found = {}, n_found = 0,
                        now_settled = {}, now_in_shop = {}, stale = 0 } }
    elseif not known_good() then
        -- The claims changed under the pass: the next count's full walk
        -- renews the list (count_twins).
        renew = nil
        return false
    end
    local r, w = renew, renew.w
    local budget = RENEW_SLICE
    while budget > 0 and r.ti <= #r.types do
        local t = r.types[r.ti]
        local vec = try(function() return df.global.world.items.other[t] end)
        local n = vec and #vec or 0
        local from = r.cursor
        -- ---- KEPT IN STEP ----
        if vec and from > 0 then
            local at = nil
            pcall(function()
                if from - 1 < n and vec[from - 1].id == r.last_id then
                    at = from - 1
                    return
                end
                for p = math.min(from - 1, n - 1), math.max(0, from - 1 - RENEW_SHIFT), -1 do
                    if vec[p].id == r.last_id then at = p; return end
                end
                for p = from, math.min(n - 1, from - 1 + RENEW_SHIFT) do
                    if vec[p].id == r.last_id then at = p; return end
                end
            end)
            if at then from = at + 1 else r.unsure = true end
        end
        -- ---- THIS TICK'S SHARE ----
        -- One closure a vector a tick, none an item. An item that throws
        -- past walk_one's own guards is passed over.
        local is_bar = (t == 'BAR')
        local i = from
        local ok = pcall(function()
            while i < n and budget > 0 do
                if walk_one(w, vec[i], t, is_bar) then
                    budget = budget - 1 - RENEW_TWIN
                else
                    budget = budget - 1
                end
                i = i + 1
            end
        end)
        if not ok then
            i = i + 1
            budget = budget - 1
        end
        if i > from and i <= n then
            local okl, id = pcall(id_of, vec[i - 1])
            r.last_id = okl and id or nil
        end
        if i >= n then
            r.ti, r.cursor, r.last_id = r.ti + 1, 0, nil
        else
            r.cursor = i
        end
    end
    if r.ti <= #r.types then return true end
    -- ---- THE PASS ENDS ----
    -- The next pass is due FULL_FRAMES after this one began, as the full
    -- walk was due FULL_FRAMES after the last one.
    local start_id, unsure = r.start_id, r.unsure
    renew_list(w, 'backstop pass', function(id) return unsure or id >= start_id end)
    last_full = r.start_frame
    for mt, row in pairs(w.bar_mats) do
        local into = new_bars[mt]
        if not into then into = {}; new_bars[mt] = into end
        for mi in pairs(row) do into[mi] = true end
    end
    return true
end

-- ---- A NEW ITEM, KNOWN ----
-- Each item the created hook reported, on the loop's next tick: by then
-- the hops have moved it onto its twin, and the coal watcher has turned
-- new coal into a module coal (it converts coal the frame it exists). A
-- twin of a claimed type joins the known list, and a new bar's material
-- waits in new_bars for the soap scan (THE KNOWN TWINS).
local function absorb(it)
    local okt, ty = pcall(type_of, it)
    local t = okt and df.item_type[ty] or nil
    if not (t and types[t]) then return end
    local okm, mt, mi = pcall(mat_of, it)
    if not okm then return end
    if t == 'BAR' then
        local row = new_bars[mt]
        if not row then row = {}; new_bars[mt] = row end
        row[mi] = true
    end
    if twins[mt] and twins[mt][mi] and known_good() then
        local okid, id = pcall(id_of, it)
        if okid then known[id] = t end
    end
end

-- ---- THE CENSUS ----
-- Every twin item by place, logged when it changes, from the backstop
-- scan. The evidence for what the service sees: when an item sits
-- unmoved, its place here says why it was not counted loose.
local function census_line(places, odd)
    local parts, total = {}, 0
    for place, c in pairs(places or {}) do
        parts[#parts + 1] = ('%d %s'):format(c, place)
        total = total + c
    end
    table.sort(parts)
    local line = ('%d twin item(s): %s.'):format(total, #parts > 0 and table.concat(parts, ', ') or 'none')
    if odd then
        local f = odd.flags
        line = line .. (' First held by nothing found: #%d, on_ground %s, in_inventory %s,'
            .. ' in_building %s.'):format(odd.id, tostring(f.on_ground), tostring(f.in_inventory),
            tostring(f.in_building))
    end
    return line
end

-- ---- THE PILES, AS ONE STRING ----
-- For THE RETRY WAIT GIVES WAY TO A CHANGE: every pile's id, categories,
-- bin, barrel and wheelbarrow allowances, links-only flag, and how many
-- links it has each way, sorted. A pile made, removed, or changed in any
-- of these changes the string. Its twin entries are left to the mirror,
-- which says how many it had to set.
local function pile_sig_of(b)
    local s, l = b.storage, b.links
    return ('%d:%d:%d:%d:%d:%d:%d:%d:%d:%d'):format(b.id, b.settings.flags.whole,
        s.max_bins, s.max_barrels, s.max_wheelbarrows, b.stockpile_flag.whole,
        #l.give_to_pile, #l.take_from_pile, #l.give_to_workshop, #l.take_from_workshop)
end

local function piles_sig()
    local parts = {}
    for _, b in ipairs(piles()) do
        local ok, s = pcall(pile_sig_of, b)
        parts[#parts + 1] = ok and s or ('?' .. tostring(try(function() return b.id end, '?')))
    end
    table.sort(parts)
    return table.concat(parts, ',')
end

-- Has anything changed since the last STUCK that could let its twins
-- move? mirrored: entries the mirror set this tick; then any number of
-- loose kind sets ('mt:mi:place' keys) to hold against what was stuck.
local function wait_given_way(mirrored, ...)
    if not stuck_kinds then return true end
    if (mirrored or 0) > 0 then return true end
    for i = 1, select('#', ...) do
        for key in pairs(select(i, ...) or {}) do
            if not stuck_kinds[key] then return true end
        end
    end
    return piles_sig() ~= stuck_piles
end

-- Hauling jobs holding a twin item right now, by job id.
local function twin_hauls()
    local out, n = {}, 0
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and HAULING[job.job_type] then
            pcall(function()
                for _, iref in ipairs(job.items) do
                    if iref.item and is_twin(iref.item) then
                        out[job.id] = true
                        n = n + 1
                        return
                    end
                end
            end)
        end
        link = link.next
    end
    return out, n
end

-- ---- NOTHING WASHES WITH COAL ----
-- While coal carries SOAP, a job that takes coal as soap is cancelled:
-- a job of a soap-using type, or one whose filter for that coal asks for
-- the SOAP flag. The next link is taken before a job is removed. Returns
-- the cancelled jobs' type names.
local function stop_soap_use()
    local stopped = {}
    local link = df.global.world.jobs.list.next
    while link do
        local nxt = link.next
        local job = link.item
        if job and not HAULING[job.job_type] then
            local why = nil
            pcall(function()
                for _, iref in ipairs(job.items) do
                    if iref.item and is_coal(iref.item) then
                        if SOAP_JOBS[job.job_type] then why = SOAP_JOBS[job.job_type]; return end
                        local ji = try(function() return job.job_items.elements[iref.job_item_idx] end)
                        if ji and (try(function() return ji.flags2.soap end, false)
                                   or try(function() return ji.flags3.soap end, false)) then
                            why = tostring(df.job_type[job.job_type]) .. ' (a soap filter)'
                            return
                        end
                    end
                end
            end)
            if why and pcall(dfhack.job.removeJob, job) then stopped[#stopped + 1] = why end
        end
        link = nxt
    end
    return stopped
end

-- ==========================================
-- WHY ITEMS ARE STUCK
-- ==========================================
-- Pile by pile, what DF would weigh: the finished goods category, the
-- tools slot, each stuck twin's material slot (a stone twin's own entry in
-- mats, a wood twin's Wood entry in other_mats), take-from-links-only,
-- free tiles (no item on them), the bin limit, and whether a stuck item
-- stands in the same walkable group as the pile. Then the stuck items'
-- storage timers, DF's own pacing of when it next tries to store each.
local function free_tiles(b)
    local n = 0
    for x = b.x1, b.x2 do
        for y = b.y1, b.y2 do
            if try(function() return dfhack.buildings.containsTile(b, x, y) end, false) then
                local block = try(function() return dfhack.maps.getTileBlock(x, y, b.z) end)
                if block and not try(function() return block.occupancy[x % 16][y % 16].item end, true) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

local function pile_group(b)
    for x = b.x1, b.x2 do
        for y = b.y1, b.y2 do
            if try(function() return dfhack.buildings.containsTile(b, x, y) end, false) then
                local g = try(function() return dfhack.maps.getWalkableGroup({ x = x, y = y, z = b.z }) end, 0)
                if g ~= 0 then return g end
            end
        end
    end
    return 0
end

local function yes(v) return v and 'yes' or 'no' end

-- A building's stockpile links, as DF keeps them: a workshop that gives to
-- linked piles sends its products only there. Read through the building's
-- own getStockpileLinks, which answers for workshops and furnaces alike.
local function links_of(b)
    local give, take = {}, {}
    pcall(function()
        local l = b:getStockpileLinks()
        if not l then return end
        for _, p in ipairs(l.give_to_pile) do
            give[#give + 1] = tostring(try(function() return p.stockpile_number end, p.id))
        end
        for _, p in ipairs(l.take_from_pile) do
            take[#take + 1] = tostring(try(function() return p.stockpile_number end, p.id))
        end
    end)
    return ('gives to piles %s; takes from piles %s'):format(
        #give > 0 and table.concat(give, ',') or 'none', #take > 0 and table.concat(take, ',') or 'none')
end

-- DF's own storage job and hauler counts, by hauler type, as one line.
local function storage_counts()
    local parts = {}
    pcall(function()
        local st = df.global.world.stockpile
        for i = 0, 9 do
            local jobs = try(function() return st.num_jobs[i] end, '?')
            local haulers = try(function() return st.num_haulers[i] end, '?')
            local name = tostring(try(function() return df.hauler_type[i] end, i))
            parts[#parts + 1] = ('%s %s/%s'):format(name, tostring(jobs), tostring(haulers))
        end
    end)
    return ('DF storage jobs/haulers by hauler type: %s.'):format(#parts > 0 and table.concat(parts, ', ')
        or 'unreadable')
end

-- Is DF's hauling queue full? Storage jobs at or above haulers on the Any
-- row (hauler_type 0), with haulers to count. Returns full, jobs, haulers.
-- See A FULL QUEUE HOLDS THE STALL CLOCK.
local function queue_full()
    local jobs = try(function() return df.global.world.stockpile.num_jobs[0] end)
    local haulers = try(function() return df.global.world.stockpile.num_haulers[0] end)
    if not jobs or not haulers then return false, jobs, haulers end
    return haulers > 0 and jobs >= haulers, jobs, haulers
end

-- Returns a LIST of lines: one per pile, one per building holding stuck
-- items, and one for the storage timers. The log cuts a line at 400
-- characters (refinish-log BODY_MAX), and the first STUCK reports lost
-- their timers to it, so no fact shares a line it could be cut from.
local function diagnose(sample)
    -- The stuck kinds by material address, and the walkable groups they
    -- stand in.
    local kinds, n_kinds, groups, holders = {}, 0, {}, {}
    local cd_lo, cd_hi, dl_lo, dl_hi = nil, nil, nil, nil
    local n_coal = 0
    for _, it in ipairs(sample) do
        local key = it.mat_type .. ':' .. it.mat_index
        -- Coal is filed by the bars entries, reported on its own below.
        if is_coal(it) then
            n_coal = n_coal + 1
        elseif not kinds[key] then
            kinds[key] = { mt = it.mat_type, mi = it.mat_index }; n_kinds = n_kinds + 1
        end
        local x, y, z = dfhack.items.getPosition(it)
        local g = x and try(function() return dfhack.maps.getWalkableGroup({ x = x, y = y, z = z }) end, 0) or 0
        groups[g] = true
        local hb = try(function() return dfhack.items.getHolderBuilding(it) end)
        if hb then holders[hb.id] = hb end
        local cd = try(function() return it.stockpile_countdown end)
        local dl = try(function() return it.stockpile_delay end)
        if cd then cd_lo = math.min(cd_lo or cd, cd); cd_hi = math.max(cd_hi or cd, cd) end
        if dl then dl_lo = math.min(dl_lo or dl, dl); dl_hi = math.max(dl_hi or dl, dl) end
    end

    local tool = df.item_type.TOOL
    local parts = {}
    for _, b in ipairs(piles()) do
        local s = b.settings
        local fg_on = truth(try(function() return s.flags.finished_goods end, false))
        local tools_on = fg_on and truth(try(function() return s.finished_goods.type[tool] end, 0))
        local takes, src_on = 0, 0
        if tools_on then
            for _, k in pairs(kinds) do
                local on, son
                if k.mt == 0 then
                    on = truth(try(function() return s.finished_goods.mats[k.mi] end, 0))
                    local t0 = twins[0] and twins[0][k.mi]
                    son = t0 and truth(try(function() return s.finished_goods.mats[t0.smi] end, 0))
                else
                    on = truth(try(function()
                        return s.finished_goods.other_mats[df.stockpile_finished_mat.Wood] end, 0))
                    son = on
                end
                if on then takes = takes + 1 end
                if son then src_on = src_on + 1 end
            end
        end
        local line = ('pile %s: finished goods %s'):format(tostring(try(function()
            return b.stockpile_number end, b.id)), yes(fg_on))
        if fg_on then
            line = line .. (', tools %s'):format(yes(tools_on))
            if tools_on then
                line = line .. (', twin entries on %d/%d (their stones\' %d/%d), links only %s, free tiles %d,'
                    .. ' bins allowed %s, reachable %s'):format(takes, n_kinds, src_on, n_kinds,
                    yes(try(function() return b.stockpile_flag.use_links_only end, false)),
                    free_tiles(b), tostring(try(function() return b.storage.max_bins end, '?')),
                    yes(groups[pile_group(b)] == true))
            end
        end
        parts[#parts + 1] = line
    end
    if n_coal > 0 then
        for _, b in ipairs(piles()) do
            local s = b.settings
            parts[#parts + 1] = ('%s, for %d stuck coal: bars and blocks %s, Coal entry %s, Soap entry'
                .. ' now %s, coal engaged %s.'):format('pile ' .. tostring(try(function()
                    return b.stockpile_number end, b.id)),
                n_coal, yes(truth(try(function() return s.flags.bars_blocks end, false))),
                yes(truth(try(function() return s.bars_blocks.bars_other_mats[COAL_ENTRY] end, 0))),
                yes(truth(try(function() return s.bars_blocks.bars_other_mats[SOAP_ENTRY] end, 0))),
                yes(coal_on))
        end
    end
    for id, hb in pairs(holders) do
        parts[#parts + 1] = ('held by building %d (%s): %s.'):format(id,
            tostring(try(function() return df.building_type[hb:getType()] end, '?')), links_of(hb))
    end
    parts[#parts + 1] = cd_lo and ('storage timers on %d stuck item(s): countdown %d to %d, delay %d to %d.')
        :format(#sample, cd_lo, cd_hi, dl_lo or -1, dl_hi or -1) or 'storage timers: none read.'
    parts[#parts + 1] = storage_counts()
    return parts
end

-- ==========================================
-- ONE ITEM'S FACTS, AND ITS TIMERS LATER
-- ==========================================
-- Shared by the check and the stuck report. A failure comes and goes
-- between loads (2026-09-27: the same 23 gravel sat through four windows on
-- one load and were all hauled on the next), so a STUCK writes these facts
-- itself, at the moment it happens.
local function flag_list(f)
    local out = {}
    for _, k in ipairs({ 'on_ground', 'in_job', 'in_inventory', 'in_building', 'container',
                         'forbid', 'dump', 'garbage_collect', 'removed', 'construction' }) do
        out[#out + 1] = k .. '=' .. tostring(try(function() return f[k] end, '?'))
    end
    return table.concat(out, ' ')
end

-- Two lines for one item, each under the log's cut, and its timers as
-- read now. Returns the lines, the timer record, and the holding building.
local function item_facts(it, pile_list)
    local refs = {}
    pcall(function()
        for _, r in ipairs(it.general_refs) do
            local rt = df.general_ref_type[r:getType()]
            local id = try(function() return r.building_id end)
                or try(function() return r.item_id end)
                or try(function() return r.unit_id end)
            refs[#refs + 1] = tostring(rt) .. (id and (' ' .. tostring(id)) or '')
        end
    end)
    local b = try(function() return dfhack.items.getHolderBuilding(it) end)
    local held = 'holder building none'
    if b then
        held = ('holder building %d (%s), workshop %s, furnace %s, role %s'):format(
            b.id, tostring(try(function() return df.building_type[b:getType()] end, '?')),
            tostring(df.building_workshopst:is_instance(b)),
            tostring(df.building_furnacest:is_instance(b)), tostring(role_in(b, it)))
    end
    local ok, place, loose = pcall(classify, it, pile_list)
    local x, y, z = dfhack.items.getPosition(it)
    local cd = try(function() return it.stockpile_countdown end, '?')
    local dl = try(function() return it.stockpile_delay end, '?')
    local lines = {
        ('item #%d "%s" at %s,%s,%s: %s.'):format(it.id,
            tostring(try(function() return dfhack.items.getDescription(it, 1) end, '?')),
            tostring(x), tostring(y), tostring(z), flag_list(it.flags)),
        ('  #%d: refs %s; %s; placed as %s; storage countdown %s, delay %s.'):format(
            it.id, #refs > 0 and table.concat(refs, ', ') or 'none', held,
            ok and (tostring(place) .. (loose and ', loose' or ', not loose'))
                or ('ERROR ' .. tostring(place)), tostring(cd), tostring(dl)),
    }
    return lines, { id = it.id, cd = cd, dl = dl }, b
end

-- Read the recorded timers again TIMER_FOLLOWUP unpaused frames from now
-- and write both readings, then>now, in lines under the cut. Whether DF is
-- counting an item down (the field's comment: -1 per 50 frames, then a
-- check whether it needs moving) is what this shows.
local function follow_timers(timed, subject, to_console)
    if #timed == 0 then return end
    dfhack.timeout(TIMER_FOLLOWUP, 'frames', function()
        local rows, window = {}, S.dbg and S.dbg.window
        for _, r in ipairs(timed) do
            local it = df.item.find(r.id)
            local cd = it and try(function() return it.stockpile_countdown end, '?') or 'gone'
            local dl = it and try(function() return it.stockpile_delay end, '?') or 'gone'
            rows[#rows + 1] = ('#%d %s/%s>%s/%s'):format(r.id, tostring(r.cd), tostring(r.dl),
                tostring(cd), tostring(dl))
        end
        local chunk = {}
        for i, row in ipairs(rows) do
            chunk[#chunk + 1] = row
            if #chunk >= 14 or i == #rows then
                local msg = ('timers %d frames later (countdown/delay then>now), window open %s: %s.')
                    :format(TIMER_FOLLOWUP, tostring(window), table.concat(chunk, ' '))
                if to_console then print(msg) end
                log('INFO', msg, subject)
                chunk = {}
            end
        end
    end)
end

-- ==========================================
-- THE SCREENS A WINDOW WAITS OUT
-- ==========================================
local function screen_waits()
    local vs = try(function() return dfhack.gui.getDFViewscreen(true) end)
    for _, fs in ipairs(WAIT_SCREENS) do
        if try(function() return dfhack.gui.matchFocusString(fs, vs) end, false) then return true end
    end
    return false
end

-- ==========================================
-- THE FLAGS
-- ==========================================
-- ---- NO CLOSURE PER FLAG ----
-- MEASURED 2026-10-01 (section probe): flags_on took 35 ms to lend 2,099
-- flags over 459 twins. Every flag of every twin was read twice, and
-- written where it differed, each through a new closure and a pcall. The
-- reads and the write stay guarded one by one, as before, through two
-- named functions instead, so no closure is built per flag.
local function get_flag(arr, i) return arr[i] end
local function set_flag(arr, i, v) arr[i] = v end

-- ---- NOT_LENT ----
-- The inorganic flags no twin is ever lent: the two that make a stone an
-- ore (NOT AN ORE, in the header). Kept by index, read off the enum by
-- name, so a name this DF lacks drops out instead of failing the load.
local NOT_LENT = {}
for _, name in ipairs({ 'METAL_ORE', 'THREAD_METAL' }) do
    local ok, i = pcall(function() return df.inorganic_flags[name] end)
    if ok and i ~= nil then NOT_LENT[i] = true end
end

-- held, when given: the flags of enum this never writes (NOT_LENT).
local function copy_flags(dst, src, enum, mt, mi, kind, id, held)
    local n = 0
    for i = enum._first_item, enum._last_item do
        if enum[i] and not (held and held[i]) then
            local ok_s, want = pcall(get_flag, src, i)
            local ok_d, had = pcall(get_flag, dst, i)
            if ok_s and ok_d and want ~= nil and had ~= nil and want ~= had then
                if pcall(set_flag, dst, i, want) then
                    record[#record + 1] = { mt = mt, mi = mi, kind = kind, id = id, i = i, old = had, new = want }
                    n = n + 1
                end
            end
        end
    end
    return n
end

local function flags_on()
    record = {}
    local n_twins, n_flags = 0, 0
    for mt, by_mi in pairs(twins) do
        for mi, t in pairs(by_mi) do
            local tw = t.smt and try(function() return dfhack.matinfo.decode(mt, mi) end)
            local src = t.smt and try(function() return dfhack.matinfo.decode(t.smt, t.smi) end)
            if tw and src and tw.material and src.material then
                local id = tostring(tw.material.id)
                n_flags = n_flags + copy_flags(tw.material.flags, src.material.flags,
                    df.material_flags, mt, mi, 'material', id)
                if tw.inorganic and src.inorganic then
                    -- All but the ore flags (NOT_LENT; NOT AN ORE in the header).
                    n_flags = n_flags + copy_flags(tw.inorganic.flags, src.inorganic.flags,
                        df.inorganic_flags, mt, mi, 'inorganic', id, NOT_LENT)
                end
                n_twins = n_twins + 1
            end
        end
    end
    return n_twins, n_flags
end

-- Put back every recorded flag, last change first. The material is found
-- again by address, and written only if it is still the same material.
-- Write every recorded flag as it was ('old') or as lent ('new'). The
-- material is found again by address and written only if it is still the
-- same material. One decode per material, not per flag.
local function write_record(which)
    if not record then return 0 end
    local n, cache = 0, {}
    for i = #record, 1, -1 do
        local r = record[i]
        local key = r.mt .. ':' .. r.mi
        local info = cache[key]
        if info == nil then
            info = try(function() return dfhack.matinfo.decode(r.mt, r.mi) end) or false
            cache[key] = info
        end
        if info and info.material and tostring(info.material.id) == r.id then
            if r.kind == 'field' then
                -- A plain material field, such as the bar_texpos slot.
                if pcall(function() info.material[r.field] = r[which] end) then n = n + 1 end
            else
                local arr = (r.kind == 'inorganic') and try(function() return info.inorganic.flags end)
                    or info.material.flags
                if arr and pcall(function() arr[r.i] = r[which] end) then n = n + 1 end
            end
        end
    end
    return n
end

local function flags_off()
    if not record then return 0 end
    local n = write_record('old')
    record, hidden = nil, false
    return n
end

-- ---- THE SOAP SWITCH ----
-- See COAL: THE SOAP SWITCH. The flag changes join the window's record,
-- so taking the flags back and lending them again carries them too.
local function set_soap(info, want)
    local arr = info.material.flags
    local had = arr[SOAP_FLAG]
    if had == want then return false end
    if pcall(function() arr[SOAP_FLAG] = want end) then
        -- Marked coal's: releasing coal alone puts these back (release_coal).
        record[#record + 1] = { mt = info.type, mi = info.index, kind = 'material',
                                id = tostring(info.material.id), i = SOAP_FLAG, old = had, new = want,
                                coal = true }
        return true
    end
    return false
end

-- ---- SOAP KEEPS ITS LOOK ----
-- The soap tile's texpos, read once per session from the page registry.
local function soap_tile()
    if soap_texpos ~= nil then return soap_texpos or nil end
    soap_texpos = false
    pcall(function()
        for _, pg in ipairs(df.global.texture.page) do
            if tostring(pg.token) == SOAP_PAGE then
                local idx = SOAP_Y * pg.page_dim_x + SOAP_X
                if idx >= 0 and idx < #pg.texpos and pg.texpos[idx] ~= 0 then
                    soap_texpos = pg.texpos[idx]
                end
                return
            end
        end
    end)
    if not soap_texpos then
        log('ERROR', ('the soap tile %s:%d:%d was not found: soap set aside will draw as a plain'
            .. ' bar.'):format(SOAP_PAGE, SOAP_X, SOAP_Y), 'COAL')
    end
    return soap_texpos or nil
end

-- A real soap material set aside keeps the soap tile in its bar slot,
-- recorded so it goes back with the flag. Art of its own is left alone.
local function keep_soap_look(info)
    -- RM's tint of the soap bar in this soap's own colour; the raw tile if
    -- that cannot be made.
    local tile = art and try(function() return art.texpos_for(info.material, 'vanilla_soap_bar') end)
    if not tile or tile == 0 then tile = soap_tile() end
    if not tile then return end
    local had = try(function() return info.material.bar_texpos end)
    if had ~= 0 then return end
    if pcall(function() info.material.bar_texpos = tile end) then
        record[#record + 1] = { mt = info.type, mi = info.index, kind = 'field', field = 'bar_texpos',
                                id = tostring(info.material.id), old = had, new = tile, coal = true }
    end
end

-- Each pile's Soap entry set to its own Coal entry; the player's own kept
-- the first time a pile is seen in this switch. Written in the vector's
-- own form (0 and 1, or false and true).
local function soap_switch_on()
    soap_saved = soap_saved or {}
    for _, b in ipairs(piles()) do
        pcall(function()
            local v = b.settings.bars_blocks.bars_other_mats
            if soap_saved[b.id] == nil then soap_saved[b.id] = v[SOAP_ENTRY] end
            local want, cur = truth(v[COAL_ENTRY]), v[SOAP_ENTRY]
            if truth(cur) ~= want then
                if type(cur) == 'number' then v[SOAP_ENTRY] = want and 1 or 0 else v[SOAP_ENTRY] = want end
            end
        end)
    end
end

local function soap_switch_off()
    if not soap_saved then return end
    for _, b in ipairs(piles()) do
        local old = soap_saved[b.id]
        if old ~= nil then
            pcall(function() b.settings.bars_blocks.bars_other_mats[SOAP_ENTRY] = old end)
        end
    end
    soap_saved = nil
end

-- A job holding a real soap bar: carried, fetched or in use.
local function soap_in_use()
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job then
            local found = false
            pcall(function()
                for _, iref in ipairs(job.items) do
                    if iref.item and is_real_soap(iref.item) then found = true; return end
                end
            end)
            if found then return true end
        end
        link = link.next
    end
    return false
end

-- Real soap materials present on bars lose SOAP; newly seen ones too, at
-- each recount while the switch is on. Returns how many were changed.
local function soap_off_everywhere(bar_mats)
    local n, seen = 0, {}
    -- Handed the bar materials a recount's walk already saw (ONE WALK OF
    -- THE BARS PER RECOUNT), it decodes from those, one per material, as
    -- the walk below does; called alone it walks the bars itself.
    if bar_mats then
        for mt, row in pairs(bar_mats) do
            for mi in pairs(row) do
                if not (twins[mt] and twins[mt][mi]) then
                    local info = try(function() return dfhack.matinfo.decode(mt, mi) end)
                    if info and info.material
                       and try(function() return info.material.flags[SOAP_FLAG] end, false) == true
                       and set_soap(info, false) then
                        keep_soap_look(info)
                        n = n + 1
                    end
                end
            end
        end
        return n
    end
    pcall(function()
        for _, it in ipairs(df.global.world.items.other.BAR) do
            -- One decode per material, keyed before decoding: the material
            -- read once, under one pcall, and kept by type then index, so
            -- no string is built per bar (measured 22.7 ms a walk as it
            -- was, 9.3 ms reading the fields directly; ONE READ PER ITEM).
            local ok, mt, mi = pcall(mat_of, it)
            local row = nil
            if ok then
                row = seen[mt]
                if not row then row = {}; seen[mt] = row end
            end
            if row and not row[mi] then
                row[mi] = true
                if not is_twin(it) then
                    local info = try(function() return dfhack.matinfo.decode(it) end)
                    if info and info.material
                       and try(function() return info.material.flags[SOAP_FLAG] end, false) == true
                       and set_soap(info, false) then
                        keep_soap_look(info)
                        n = n + 1
                    end
                end
            end
        end
    end)
    return n
end

-- Engage coal in the open window: coal is soap, soap is not, the Coal
-- entries rule. Returns true when engaged. Never while the options screen
-- is up (THE OPTIONS SCREEN HOLDS COAL OFF, in the header).
local function engage_coal()
    if coal_on or not record or hidden or _G.refinish_menu_locked then return false end
    local n_coal = 0
    for mt, by_mi in pairs(twins) do
        for mi, tw in pairs(by_mi) do
            if tw.file_as == 'coal' then
                local info = try(function() return dfhack.matinfo.decode(mt, mi) end)
                if info and info.material and set_soap(info, true) then n_coal = n_coal + 1 end
            end
        end
    end
    local n_soap = soap_off_everywhere()
    soap_switch_on()
    coal_on = true
    log('DETAIL', ('coal engaged: %d coal material(s) carry SOAP, %d real soap material(s) set aside;'
        .. ' each pile\'s Soap entry follows its Coal entry.'):format(n_coal, n_soap), 'COAL')
    return true
end

-- Release coal alone, the window staying open for the rest: the player's
-- Soap entries back, then every coal-marked record entry written back and
-- dropped from the record. See SOAP GETS ITS TURN. turn: the frames soap is
-- given, when coal is released because soap is wanted; the options screen's
-- release gives none (THE OPTIONS SCREEN HOLDS COAL OFF), and the log says
-- which.
local function release_coal(why, turn)
    if not coal_on then return end
    soap_switch_off()
    if record then
        local keep, n = {}, 0
        for _, r in ipairs(record) do
            if r.coal then
                local info = try(function() return dfhack.matinfo.decode(r.mt, r.mi) end)
                if info and info.material and tostring(info.material.id) == r.id then
                    local ok
                    if r.kind == 'field' then
                        ok = pcall(function() info.material[r.field] = r.old end)
                    else
                        ok = pcall(function() info.material.flags[r.i] = r.old end)
                    end
                    if ok then n = n + 1 end
                end
            else
                keep[#keep + 1] = r
            end
        end
        record = keep
    end
    coal_on = false
    log('DETAIL', ('coal released (%s)%s.'):format(why, turn and ('; soap has at least the next %d'
        .. ' frames, and coal waits while soap is in use'):format(turn) or ''), 'COAL')
end


-- ==========================================
-- OPENING AND CLOSING
-- ==========================================
-- ---- THE MIRROR ----
-- Every stone twin's finished goods entry set equal to its stone's, in
-- every pile. See THE PILES' TWIN SLOTS. Writes only entries that differ,
-- in the vector's own form (0 and 1, or false and true). Returns how many
-- entries were set and in how many piles.
local function mirror_slots()
    local by_mi = twins[0]
    if not by_mi then return 0, 0 end
    local n, n_piles = 0, 0
    for _, b in ipairs(piles()) do
        local changed = false
        pcall(function()
            local mats = b.settings.finished_goods.mats
            local len = #mats
            for ti, tw in pairs(by_mi) do
                if ti < len and tw.smi < len then
                    local want = truth(mats[tw.smi])
                    local cur = mats[ti]
                    if truth(cur) ~= want then
                        if type(cur) == 'number' then mats[ti] = want and 1 or 0 else mats[ti] = want end
                        n, changed = n + 1, true
                    end
                end
            end
        end)
        if changed then n_piles = n_piles + 1 end
    end
    if n > 0 then
        log('DETAIL', ('%d stone twin entr%s set to match %s in %d pile(s).'):format(n,
            n == 1 and 'y' or 'ies', n == 1 and 'its stone' or 'their stones', n_piles), 'MIRROR')
    end
    return n, n_piles
end

-- Every loose twin item's storage timer set short, AFTER the flags are
-- on, so DF's next look at each lands inside this window. See DF'S
-- STORAGE TIMER. Returns how many were set.
-- ---- THE KNOWN TWINS, WHEN THE LIST IS GOOD ----
-- MEASURED 2026-10-01 (section probe): 24 ms at a window opening, a walk
-- of every item of every claimed type. It also runs inside an open window
-- each time DF's hauling queue frees, at most once per RECOUNT. With the
-- known list good for the claims (known_good), it reads those items
-- alone: the same twins the walk finds (THE KNOWN TWINS), each timer set
-- the same way. The spread follows the list's order instead of the
-- vectors', so an item may draw a different step of TIMER_SPREAD; the
-- timers are spread across it either way. Without a good list it walks,
-- as before.
local function short_timer(it, n)
    it.stockpile_countdown = 1 + (n % TIMER_SPREAD)
    it.stockpile_delay = TIMER_DELAY
end

local function timers_short()
    local n, pile_list = 0, with_room(piles())
    local function one(it)
        if is_twin(it) then
            local ok, _, loose = pcall(classify, it, pile_list, true)
            if ok and loose then
                n = n + 1
                pcall(short_timer, it, n)
            end
        end
    end
    if known_good() then
        for id in pairs(known) do
            local it = df.item.find(id)
            if it then one(it) end
        end
        return n
    end
    for ty in pairs(types) do
        local vec = try(function() return df.global.world.items.other[ty] end)
        if vec then
            for _, it in ipairs(vec) do one(it) end
        end
    end
    return n
end

-- Loose coal: the switch is engaged only when there is some.
-- THE KNOWN TWINS, WHEN THE LIST IS GOOD (timers_short): the known bars
-- alone, where the walk read every bar in the fort. MEASURED 2026-10-01:
-- the coal check at a window opening took 34 ms, with the engage.
local function loose_coal()
    local n, pile_list = 0, with_room(piles())
    if known_good() then
        for id, t in pairs(known) do
            if t == 'BAR' then
                local it = df.item.find(id)
                if it and is_coal(it) then
                    local ok, _, loose = pcall(classify, it, pile_list, true)
                    if ok and loose then n = n + 1 end
                end
            end
        end
        return n
    end
    pcall(function()
        for _, it in ipairs(df.global.world.items.other.BAR) do
            if is_coal(it) then
                local ok, _, loose = pcall(classify, it, pile_list, true)
                if ok and loose then n = n + 1 end
            end
        end
    end)
    return n
end

local function open_window(loose, in_shops)
    if record then return end
    -- SECTION CLOCK (refinish-section-probe): one lap per step. A window
    -- opening measured 133 ms (2026-10-01), on the same tick as the scan
    -- that found it, 272 ms together.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()
    if resolve() == 0 then return end
    mirror_slots()
    if sc then t0 = sc.lap('windows: opening, resolve and mirror', t0) end
    local n_twins, n_flags = flags_on()
    if sc then t0 = sc.lap('windows: opening, flags_on', t0) end
    if frame >= soap_turn_until and loose_coal() > 0 and not soap_in_use() then engage_coal() end
    if sc then t0 = sc.lap('windows: opening, coal check and engage', t0) end
    local n_timed = timers_short()
    if sc then t0 = sc.lap('windows: opening, timers_short', t0) end
    win = { opened = frame, progress = frame, loose = loose, last_count = frame, hauls = {} }
    log('DETAIL', ('window open: %d loose twin item(s), %d of them in workshops; %d twin(s) lent'
        .. ' %d flag(s); %d storage timer(s) set short.'):format(loose, in_shops or 0, n_twins,
        n_flags, n_timed), 'WINDOW')
end

local function close_window(why)
    -- The player's Soap entries go back before the flags do.
    if coal_on then soap_switch_off() end
    local stopped = win and win.soap_stopped or 0
    local n = flags_off()
    if coal_on then
        coal_on = false
        log('DETAIL', ('coal released; %d job(s) stopped from using coal as soap in this window.')
            :format(stopped), 'COAL')
    end
    local lasted = win and (frame - win.opened) or 0
    local resets = win and win.resets or 0
    win = nil
    log('DETAIL', ('window closed after %d frames (%s); %d flag(s) put back%s.'):format(lasted, why, n,
        resets > 0 and ('; timers set short %d time(s) as the hauling queue freed'):format(resets) or ''),
        'WINDOW')
end

-- ==========================================
-- THE MENU LABEL, THE CODE
-- ==========================================
-- See THE MENU LABEL in the header.

-- An address, from a DFHack reference: sizeof() returns size, address.
local function addr_of(ref)
    local ok, _, a = pcall(function() return ref:sizeof() end)
    return ok and a or nil
end

-- The inorganic lists of the settings being edited, as base address and
-- length, so a row's set_pointer can be turned back into an index.
local function list_spans(sp)
    local spans = {}
    for _, pair in ipairs(INORG_LISTS) do
        local v = try(function() return sp[pair[1]][pair[2]] end)
        local n = v and try(function() return #v end, 0) or 0
        if n > 0 then
            local base = try(function() return addr_of(v:_field(0)) end)
            if base then spans[#spans + 1] = { base = base, len = n, name = pair[1] .. '.' .. pair[2] } end
        end
    end
    return spans
end

-- The stone twin a row toggles, or nil: its index and twin record.
local function row_twin(row, spans)
    local p = try(function() return row.set_pointer end)
    local a = p and addr_of(p)
    if not a then return nil end
    local by_mi = twins[0]
    if not by_mi then return nil end
    for _, s in ipairs(spans) do
        local i = a - s.base
        if i >= 0 and i < s.len then
            local tw = by_mi[i]
            if tw then return i, tw, s.name end
            return nil
        end
    end
    return nil
end

-- ---- THE STOCKPILE SETTINGS: EDIT ROWS OUT, LABEL THE REST ----
-- See EDITING ROWS OUT and THE MENU LABEL in the header. One pass over the
-- rows, every frame the screen is open. Logged once per list per opening.
local edited_said = {}

-- A row's list and index, whoever owns the entry (row_twin answers only
-- for twins).
local function row_entry(row, spans)
    local p = try(function() return row.set_pointer end)
    local a = p and addr_of(p)
    if not a then return nil end
    for _, s in ipairs(spans) do
        local i = a - s.base
        if i >= 0 and i < s.len then return i, s.name end
    end
    return nil
end

local function label_row(row, tag)
    local suffix = ' (' .. tag .. ')'
    for _, field in ipairs({ 'name', 'simple_name' }) do
        local s = try(function() return row[field] end)
        if s and s:sub(-#suffix) ~= suffix then
            pcall(function() row[field] = s .. suffix end)
        end
    end
end

local function unlabel_row(row, tag)
    local suffix = ' (' .. tag .. ')'
    for _, field in ipairs({ 'name', 'simple_name' }) do
        local s = try(function() return row[field] end)
        if s and s:sub(-#suffix) == suffix then
            pcall(function() row[field] = s:sub(1, #s - #suffix) end)
        end
    end
end

-- A labelled material's row reads its label in place of the material's
-- name, in both of the row's strings (THE MENU LABEL). Each string keeps
-- the case DF gave its first letter: DF capitalises the names it shows, and
-- a label written as given read "fresh mash" beside "Granite".
local function name_row(row, text)
    for _, field in ipairs({ 'name', 'simple_name' }) do
        local s = try(function() return row[field] end)
        if s and s ~= '' then
            local first, want = s:sub(1, 1), text
            if first:upper() == first and first:lower() ~= first then
                want = text:sub(1, 1):upper() .. text:sub(2)
            end
            if s ~= want then pcall(function() row[field] = want end) end
        end
    end
end

-- ---- NOTHING CHANGED, NOTHING TO DO (2026-11-03) ----
-- MEASURED (test 38, 2026-11-03, THE MENU PASS'S OWN TIMING): this pass at
-- 635 ms/sec over a minute with a pile's settings open, 131 ms in the
-- worst frame. It walked every row of the pool every frame, each read
-- through try() (a closure and a pcall per field), though nearly every
-- frame the list is exactly as the last pass left it.
--
-- So the pass keeps, in S.menu_seen (this file is at Lua's 200 top-level
-- locals: ONE LOCAL, STOCKHOOK, THE CODE, so nothing new is a local here):
--   * a signature: the settings, the list, the live and shown counts, the
--     pool's length, the search text and the entries of the first and last
--     live rows;
--   * the pool's row pointers, compared with one memcmp (DF reorders and
--     swaps rows when it builds a list), copied in S.menu_buf;
--   * the twin, hide and label tables it read (resolve builds new ones);
--   * the rows that matter: each row the pass named, labelled or may edit
--     out, with its entry's address.
-- While all of it holds, only the rows that matter are looked at, each
-- first checked to still aim at its entry (one that does not runs the
-- whole pass), and each given exactly what the whole pass gives it.
-- Otherwise the whole pass runs, as before, reading each row directly
-- inside one pcall. Recorded after the pass, so its own writes are not read
-- as a change. Scrolling changes none of this, so it costs nothing.
local function settings_rows()
    local cs = try(function() return df.global.game.main_interface.custom_stockpile end)
    if not cs or not try(function() return cs.open end, false) then
        if next(edited_said) then edited_said = {} end
        S.menu_seen = nil
        return
    end
    local sp = try(function() return cs.sp end)
    if not sp then return end
    local by_tw, by_un = twins[0] or {}, unlisted[0] or {}
    local by_lb = labelled[0] or {}

    -- One row, as the pass has always treated it: its label, its tag, and
    -- edited out where it goes. idx and list: its entry; i: its place in
    -- the pool; live: the live count; c: the rows turned off, and where.
    -- True when the row matters (NOTHING CHANGED, NOTHING TO DO).
    -- a: the row's entry address.
    --
    -- ROWS STOCKHOOK OWNS (2026-11-03): Stockhook's moved rows (a material
    -- shown in its group's other materials list, refinish-stockhook-rows.lua,
    -- MOVED MATERIALS) aim at DF's own entry, so this pass took one for a
    -- row of its own whenever a hide named the material: it turned the row
    -- off and lowered the shown count, and Stockhook's search filter turned
    -- it on again, frame after frame (suspected, test 43: the shown count
    -- moving alone). Stockhook publishes the moved rows of the list on
    -- screen (_G.stockhook_rows_owned, by entry address); those are left to
    -- it, and said once each in the log.
    local owned = _G.stockhook_rows_owned
    local function do_row(row, idx, list, i, live, c, a)
        if owned and a and owned[a] then
            if not said['owned:' .. list .. ':' .. idx] then
                said['owned:' .. list .. ':' .. idx] = true
                log('DETAIL', ('%s entry %d is a Stockhook row here; left to it.'):format(list, idx), 'MENU')
            end
            return false
        end
        local lb = by_lb[idx]
        if lb then name_row(row, lb) end
        local tw, un = by_tw[idx], by_un[idx]
        if tw or un then
            local go = (tw and not tw.file_as) or (un and not un.keep[list])
            -- Labelled only where edited out: on a row that stays listed a
            -- tag would be a seam, and one it picked up in another list comes
            -- off (DF reuses one row per material across lists).
            local tag = (tw and tw.tag) or (un and un.tag)
            if tag then
                if go then label_row(row, tag) elseif un then unlabel_row(row, tag) end
            end
            if go and i < live and row.on then
                if pcall(function() row.on = false end) then c.off, c.where = c.off + 1, list end
            end
        end
        return lb ~= nil or tw ~= nil or un ~= nil
    end

    local function entry_of(p)
        local _, a = p:sizeof()
        return a
    end

    local function sig_now()
        local n = cs.cur_spec_item_sz
        local a0, a1 = 0, 0
        if n > 0 then
            local p0, p1 = cs.spec_item[0].set_pointer, cs.spec_item[n - 1].set_pointer
            a0 = p0 and entry_of(p0) or 0
            a1 = p1 and entry_of(p1) or 0
        end
        local _, spa = sp:sizeof()
        return ('%x|%d|%d|%d|%d|%s|%x|%x'):format(spa, cs.cur_sub_mode, n,
            cs.counted_cur_spec_item_sz, #cs.spec_item, tostring(cs.spec_filter or ''), a0, a1)
    end

    -- The pool's row pointer array (the vector's first word), eight bytes a row.
    local function pool_data()
        local _, va = cs.spec_item:sizeof()
        return df.reinterpret_cast('uint64_t', va).value
    end

    local function pool_same(n)
        if not S.menu_buf or S.menu_n ~= n then return false end
        if n == 0 then return true end
        return dfhack.internal.memcmp(S.menu_buf, pool_data(), n * 8) == 0
    end

    local function pool_keep(n)
        local bytes = math.max(n * 8, 8)
        if not S.menu_buf or (S.menu_cap or 0) < bytes then
            if S.menu_buf then pcall(df.delete, S.menu_buf) end
            S.menu_buf, S.menu_cap = df.new('uint8_t', bytes), bytes
        end
        if n > 0 then dfhack.internal.memmove(S.menu_buf, pool_data(), n * 8) end
        S.menu_n = n
    end

    -- The rows that matter alone. nil when one no longer aims at its entry.
    local function quick_pass(watch)
        local live = cs.cur_spec_item_sz
        local c = { off = 0 }
        for _, wr in ipairs(watch) do
            local p = wr.row.set_pointer
            if not p or entry_of(p) ~= wr.a then return nil end
            do_row(wr.row, wr.idx, wr.list, wr.i, live, c, wr.a)
        end
        return c
    end

    -- Every live row, each read directly. LIVE ROWS ONLY (2026-11-03):
    -- the pass walked the whole pool, which DF sizes to the longest list
    -- built since the screen opened (2408 rows after Food: fat, test 17),
    -- so a 35-row list cost a walk of thousands. DF draws, clicks and
    -- searches only the live rows (0 .. cur_spec_item_sz - 1); a row past
    -- them is named again by DF when it builds a list that uses it, and
    -- this pass then finds it live. MEASURED (test 40): 40 to 56 ms a
    -- whole pass.
    local function full_pass()
        local spans = list_spans(sp)
        if #spans == 0 then return nil end
        local live = cs.cur_spec_item_sz
        local c, watch = { off = 0 }, {}
        for i = 0, live - 1 do
            local row = cs.spec_item[i]
            local p = row.set_pointer
            if p then
                local a = entry_of(p)
                for _, s in ipairs(spans) do
                    local idx = a - s.base
                    if idx >= 0 and idx < s.len then
                        if do_row(row, idx, s.name, i, live, c, a) then
                            watch[#watch + 1] = { row = row, a = a, idx = idx, list = s.name, i = i }
                        end
                        break
                    end
                end
            end
        end
        return c, watch
    end

    local M = S.menu_seen
    local c, watch, quick = nil, nil, false
    local ok, err = pcall(function()
        if M and M.twins == twins and M.unlisted == unlisted and M.labelled == labelled
                and M.sig == sig_now() and pool_same(#cs.spec_item) then
            c = quick_pass(M.watch)
            if c then watch, quick = M.watch, true end
        end
        if not c then c, watch = full_pass() end
    end)
    if not ok then
        S.menu_seen = nil
        if not said['menu rows'] then
            said['menu rows'] = true
            log('ERROR', 'the settings rows pass failed: ' .. tostring(err), 'MENU')
        end
        return
    end
    if not c then S.menu_seen = nil; return end

    if c.off > 0 then
        -- The count DF's filter keeps, lowered by exactly the rows turned off.
        pcall(function() cs.counted_cur_spec_item_sz = cs.counted_cur_spec_item_sz - c.off end)
        if not edited_said[c.where] then
            edited_said[c.where] = true
            log('DETAIL', ('%d row(s) edited out of %s.'):format(c.off, c.where), 'MENU')
        end
    end
    -- Recorded after the pass. The rows that matter alone, with nothing
    -- turned off, changed nothing to record.
    if quick and c.off == 0 then return end
    pcall(function()
        local n = #cs.spec_item
        pool_keep(n)
        S.menu_seen = { sig = sig_now(), twins = twins, unlisted = unlisted,
                        labelled = labelled, watch = watch }
    end)
end

-- ---- THE MATERIAL SELECTION MENU: ERASE THE TWIN ROWS ----
-- See HIDING THE TWINS IN THE MENUS. The two sets of parallel vectors are
-- pruned together, last row first, only when their lengths change (DF
-- built or rebuilt the list), and only if the three in a set are the same
-- length; otherwise the set is left alone and that is logged once.
local JD_SETS = {
    { 'material', 'matgloss', 'material_count' },
    { 'material_master', 'matgloss_master', 'material_count_master' },
}
local jd_seen = nil      -- the lengths last pruned, so a pass runs only on a change

local function prune_job_details()
    local jd = try(function() return df.global.game.main_interface.job_details end)
    if not jd or not try(function() return jd.open end, false) then jd_seen = nil; return end
    local sig = ''
    for _, set in ipairs(JD_SETS) do
        sig = sig .. tostring(try(function() return #jd[set[1]] end, -1)) .. ','
    end
    if sig == jd_seen then return end
    local removed = 0
    for _, set in ipairs(JD_SETS) do
        local mv = try(function() return jd[set[1]] end)
        local iv = try(function() return jd[set[2]] end)
        local cv = try(function() return jd[set[3]] end)
        local n = mv and #mv or 0
        if mv and iv and cv and #iv == n and #cv == n then
            for i = n - 1, 0, -1 do
                local mt, mi = mv[i], iv[i]
                local tw = twins[mt] and twins[mt][mi]
                local un = unlisted[mt] and unlisted[mt][mi]
                -- Coal is a real material the menu may list on its own;
                -- its rows go only while the switch has made it soap. A
                -- hidden material's go whatever its keep lists say: they
                -- name settings lists only (EDITING ROWS OUT).
                if un or (tw and (tw.file_as ~= 'coal' or coal_on)) then
                    mv:erase(i); iv:erase(i); cv:erase(i)
                    removed = removed + 1
                end
            end
        elseif n > 0 and not said['jd:' .. set[1]] then
            said['jd:' .. set[1]] = true
            log('ERROR', ('the material menu\'s %s vectors differ in length; left alone.'):format(set[1]), 'MENU')
        end
    end
    -- The signature after pruning, so the pass does not repeat on its own work.
    sig = ''
    for _, set in ipairs(JD_SETS) do
        sig = sig .. tostring(try(function() return #jd[set[1]] end, -1)) .. ','
    end
    jd_seen = sig
    if removed > 0 then
        log('DETAIL', ('%d twin or hidden row(s) removed from the material selection menu.'):format(removed), 'MENU')
    end
end

-- ---- THE STOCKPILE SETTINGS: TAKE THE FLAGS BACK WHILE THE GAME IS STOPPED ----
local last_tick, still = nil, 0

local function game_stopped()
    local tk = try(function() return df.global.cur_year_tick end)
    if tk == nil then return false end
    if tk == last_tick then still = still + 1 else still = 0 end
    last_tick = tk
    return still >= HALT_FRAMES
end

local function settings_hide()
    local open = try(function() return df.global.game.main_interface.custom_stockpile.open end, false)
    local stopped = game_stopped()
    if record and not hidden and open and stopped then
        -- The player's own Soap entries first, so the screen shows them.
        if coal_on then soap_switch_off() end
        write_record('old')
        hidden = true
        log('DETAIL', 'flags taken back while the stockpile settings are open and the game is stopped.', 'MENU')
    elseif hidden and (not open or not stopped or not record) then
        if record then
            write_record('new')
            -- The Coal entries may have changed on that screen.
            if coal_on then soap_switch_on() end
        end
        hidden = false
        log('DETAIL', 'flags lent again.', 'MENU')
    end
end

-- ==========================================
-- THE MENUS, RESOLVED AS THEY OPEN
-- ==========================================
-- The menu pass runs paused, but what it reads (twins, labelled,
-- unlisted) is built by resolve(), which the loop runs at its backstop
-- scan or as a window opens, neither of which happens while the game is
-- paused or a stockpile or work orders screen is up (WHAT IT READS, in the
-- header). So on the frame a menu opens, its tables are built there and
-- then, before any row is touched:
--   * the stockpile settings, no window open: resolve(), what the scan
--     runs. The twins are wanted there too: coins lists every inorganic,
--     flags or not (EDITING ROWS OUT), so a twin shows in it with no
--     window open.
--   * the stockpile settings, a window open: resolve_menus() alone. The
--     window resolved as it opened, and its twins must stay the set it
--     lent flags to: a twin added now would be counted loose with no
--     flags lent for DF to file it by.
--   * the material picker: resolve_menus() alone. It lists a twin only
--     while a window lends it flags, and that window resolved as it
--     opened. The picker opens at every material choice, so no claim's
--     select runs for it.
-- Once per opening, not per frame: each menu's state on the last frame
-- is kept, and only a closed to open change resolves.
local sp_was_open, jd_was_open = false, false

local function resolve_on_open()
    local mi = try(function() return df.global.game.main_interface end)
    if not mi then return end
    local sp_open = try(function() return mi.custom_stockpile.open end, false)
    local jd_open = try(function() return mi.job_details.open end, false)
    if sp_open and not sp_was_open then
        if record then resolve_menus() else resolve() end
    elseif jd_open and not jd_was_open then
        resolve_menus()
    end
    sp_was_open, jd_was_open = sp_open, jd_open
end

-- ---- THE MENU PASS'S OWN TIMING (2026-11-03) ----
-- SEEN 2026-11-03: this pass at 56 to 140 ms/sec in some minutes, with
-- nothing in RM's log to say which part. So each part is timed (os.clock),
-- and every 10 s of clock, if the pass cost WARM ms per second or more,
-- RM's log gets each part's cost and which menus were open.
--
-- TWO LEVELS, THE LOOP COST PANEL'S OWN (2026-11-06), as in
-- refinish-stockhook-rows.lua (THE LOOP'S OWN TIMING). These were
-- WARNINGs from 5 ms/sec, so ordinary menu use put yellow WARNINGs in the
-- log's Quiet view, where a player looks for faults (SEEN, session log
-- 2026-11-05: 14 reports, 5.1 to 10.8 ms/sec). Now they keep to the levels
-- RM's loop cost panel paints a loop by (refinish-panel-status.lua,
-- WARM_MS_S 20 and HOT_MS_S 100, in ms per second):
--   warm  the figures, at DETAIL: debugging material, shown in Debug;
--   hot   a WARNING first, one line in plain words for the player, then
--         the same figures at DETAIL, kept in RM's session log.
-- Kept in S.perf and written inside menu_tick: this file is at Lua's 200
-- top-level locals (ONE LOCAL, STOCKHOOK, THE CODE), so no new local here.
-- The two levels are locals of menu_tick for the same reason.
local function menu_tick()
    local P = S.perf
    if not P then
        P = { t = {}, max = {}, n = 0, open = {}, since = os.clock() }
        S.perf = P
    end
    local function lap(name, t0)
        local t1 = os.clock() * 1000
        local d = t1 - t0
        P.t[name] = (P.t[name] or 0) + d
        if d > (P.max[name] or 0) then P.max[name] = d end
        return t1
    end
    local t0 = os.clock() * 1000
    local t = t0
    -- First, so the rows below are written from tables built this frame.
    resolve_on_open()
    t = lap('resolve on open', t)
    -- THE OPTIONS SCREEN HOLDS COAL OFF (header). Here because this runs
    -- every frame, paused included.
    if coal_on and _G.refinish_menu_locked then
        release_coal('the options screen is up; coal engages again once it closes')
    end
    settings_hide()
    t = lap('settings flags hide', t)
    prune_job_details()
    t = lap('material picker', t)
    settings_rows()
    t = lap('settings rows', t)
    lap('whole pass', t0)
    P.n = P.n + 1
    local mi = df.global.game.main_interface
    local which = (mi.custom_stockpile.open and 'settings ' or '') .. (mi.job_details.open and 'picker' or '')
    if which == '' then which = 'none' end
    P.open[which] = (P.open[which] or 0) + 1
    local secs = os.clock() - P.since
    if secs >= 10 then
        local whole = P.t['whole pass'] or 0
        local per_s = whole / secs      -- ms of the whole pass per second of clock
        -- TWO LEVELS, THE LOOP COST PANEL'S OWN (the comment above menu_tick).
        local WARM, HOT = 20, 100
        if per_s >= WARM then
            -- HOT: the player's line, in plain words, before the figures.
            -- ms/sec over ten is the percentage of the time.
            if per_s >= HOT then
                log('WARNING', ("RM's work on the stockpile and material menus took %.0f%% of the"
                    .. " game's time over the last %.0f seconds, which slows the game. That is not"
                    .. " normal; please report it with refinish_session.log, in DF's folder, which"
                    .. " holds the details.")
                    :format(per_s / 10, secs), 'PERF')
            end
            local parts, states = {}, {}
            for name, v in pairs(P.t) do
                parts[#parts + 1] = ('%s %.1f ms/sec, %.2f max'):format(name, v / secs, P.max[name] or 0)
            end
            table.sort(parts)
            for k, v in pairs(P.open) do states[#states + 1] = k .. ' ' .. v end
            table.sort(states)
            log('DETAIL', ('menu pass timing: %.1f ms/sec over %.0f s, %d pass(es); menus open by'
                .. ' frame: %s.'):format(per_s, secs, P.n, table.concat(states, ', ')), 'PERF')
            log('DETAIL', 'menu pass by part: ' .. table.concat(parts, '; ') .. '.', 'PERF')
        end
        S.perf = nil
    end
end

local function guarded_menu()
    local ok, err = pcall(menu_tick)
    if not ok then
        local msg = tostring(err)
        if not said[msg] then
            said[msg] = true
            log('ERROR', 'the menu label failed: ' .. msg, 'MENU')
        end
    end
end

-- ==========================================
-- THE TEST
-- ==========================================
-- See THE TEST COMMAND in the header.
local function tlog(msg) log('INFO', msg, 'TEST') end

-- A free floor tile beside building b, in walkable group g: outside the
-- building's rectangle, no building on it. nil if none.
local function floor_beside(b, g)
    for x = b.x1 - 1, b.x2 + 1 do
        for y = b.y1 - 1, b.y2 + 1 do
            if x < b.x1 or x > b.x2 or y < b.y1 or y > b.y2 then
                local pos = { x = x, y = y, z = b.z }
                if try(function() return dfhack.maps.isValidTilePos(pos) end, false)
                   and try(function() return dfhack.maps.getWalkableGroup(pos) end, 0) == g
                   and not try(function() return dfhack.buildings.findAtTile(pos) end) then
                    return pos
                end
            end
        end
    end
    return nil
end

local function pile_ids()
    local out = {}
    for _, b in ipairs(piles()) do out[b.id] = true end
    return out
end

local function start_test(frames)
    frames = tonumber(frames) or TEST_FRAMES
    resolve()
    if not record then
        local loose, in_shops = count_loose()
        open_window(loose, in_shops)
    end
    if not record then
        tlog('no twin material is claimed, so no window could open; the test did not run.')
        return
    end
    tlog(('%d storage timer(s) set short; the window is held %d unpaused frames.'):format(
        timers_short(), frames))
    tlog(storage_counts())

    -- ---- MOVE A FEW GRAVEL TO THE FLOOR ----
    local pile_list, dropped, kept, control = piles(), {}, nil, nil
    for ty in pairs(types) do
        local vec = try(function() return df.global.world.items.other[ty] end)
        if vec then
            for _, it in ipairs(vec) do
                local id = try(function() return it.subtype.id end, '')
                if is_twin(it) and id:find('GRAVEL', 1, true) then
                    local ok, place = pcall(classify, it, pile_list)
                    if ok and place == 'in a workshop' then
                        if #dropped < TEST_DROP then
                            local b = try(function() return dfhack.items.getHolderBuilding(it) end)
                            local x, y, z = dfhack.items.getPosition(it)
                            local g = x and try(function()
                                return dfhack.maps.getWalkableGroup({ x = x, y = y, z = z }) end, 0) or 0
                            local pos = b and floor_beside(b, g)
                            if pos and try(function() return dfhack.items.moveToGround(it, pos) end, false) then
                                dropped[#dropped + 1] = it
                                tlog(('moved #%d out of building %d to the floor at %d,%d,%d.'):format(
                                    it.id, b.id, pos.x, pos.y, pos.z))
                            else
                                tlog(('could not move #%d out of building %s: %s.'):format(it.id,
                                    tostring(b and b.id), pos and 'the move failed' or 'no free floor tile beside it'))
                            end
                        elseif not kept then
                            kept = it
                        end
                    end
                elseif not control and not is_twin(it) then
                    local ok, place, loose = pcall(classify, it, pile_list)
                    if ok and loose and (id:find('DUST', 1, true) or id:find('GRAVEL', 1, true)) then
                        control = it
                    end
                end
            end
        end
    end

    local tracked = {}
    for _, it in ipairs(dropped) do tracked[#tracked + 1] = { id = it.id, as = 'moved to the floor' } end
    if kept then tracked[#tracked + 1] = { id = kept.id, as = 'left in its workshop' } end
    if control then tracked[#tracked + 1] = { id = control.id, as = 'non-twin control' } end
    test = { ends = frame + frames, tracked = tracked, piles = pile_ids() }
    tlog(('running: %d item(s) tracked. Make a new pile now to test a pile made with the flags on.')
        :format(#tracked))
end

local function end_test()
    local pile_list = piles()
    for _, r in ipairs(test.tracked) do
        local it = df.item.find(r.id)
        local place = 'gone (used or destroyed)'
        if it then
            local ok, p = pcall(classify, it, pile_list)
            place = ok and tostring(p) or ('unplaced: ' .. tostring(p))
        end
        tlog(('#%d, %s at the start: now %s.'):format(r.id, r.as, place))
    end
    local new = {}
    for _, b in ipairs(pile_list) do
        if not test.piles[b.id] then
            new[#new + 1] = tostring(try(function() return b.stockpile_number end, b.id))
        end
    end
    tlog(('piles made during the test: %s.'):format(#new > 0 and table.concat(new, ', ') or 'none'))
    local loose, in_shops = count_loose()
    tlog(('loose twin items at the end: %d, %d of them in workshops.'):format(loose, in_shops))
    tlog(storage_counts())
    test = nil
    backoff, next_try = BACKOFF_MIN, 0
    close_window('the test ended')
end

-- ==========================================
-- THE PILES COMMAND
-- ==========================================
-- See THE TEST'S ANSWER in the header.
local function plog(msg) log('INFO', msg, 'PILES') end

-- A settings tree flattened to path -> value. Structs by field, containers
-- by index, bitfields by flag. Links and linked stops hold pointers to
-- other buildings, and are not read.
local function flatten(ref, path, out, depth)
    if depth > 8 then return end
    local kind = try(function() return ref._kind end)
    if kind == 'struct' then
        for k, v in pairs(ref) do
            local sub = path .. '.' .. tostring(k)
            if type(v) == 'userdata' then flatten(v, sub, out, depth + 1) else out[sub] = v end
        end
    elseif kind == 'container' then
        local n = #ref
        out[path .. '#len'] = n
        for i = 0, n - 1 do
            local v = ref[i]
            local sub = path .. '[' .. i .. ']'
            if type(v) == 'userdata' then flatten(v, sub, out, depth + 1) else out[sub] = v end
        end
    elseif kind == 'bitfield' then
        for k, v in pairs(ref) do out[path .. '.' .. tostring(k)] = v end
    else
        out[path] = tostring(ref)
    end
end

local function pile_tree(b)
    local out = {}
    pcall(flatten, b.settings, 'settings', out, 0)
    pcall(flatten, b.storage, 'storage', out, 0)
    pcall(flatten, b.stockpile_flag, 'stockpile_flag', out, 0)
    return out
end

local function pile_name(b)
    return 'pile ' .. tostring(try(function() return b.stockpile_number end, b.id))
end

-- Index lists as ranges: 3,4,5,9 -> 3-5,9.
local function ranges(list)
    table.sort(list)
    local out, i = {}, 1
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        out[#out + 1] = (i == j) and tostring(list[i]) or (list[i] .. '-' .. list[j])
        i = j + 1
    end
    return table.concat(out, ',')
end

local function run_piles()
    resolve()
    local list = piles()
    if #list == 0 then plog('no piles.'); return end
    plog(('window open %s; %d pile(s).'):format(tostring(record ~= nil), #list))

    -- ---- EACH PILE'S TWIN ENTRIES AGAINST THEIR STONES' ----
    local by_mi = twins[0] or {}
    for _, b in ipairs(list) do
        local on, src_on, differ, n = 0, 0, 0, 0
        pcall(function()
            local mats = b.settings.finished_goods.mats
            for ti, tw in pairs(by_mi) do
                n = n + 1
                local a = truth(try(function() return mats[ti] end, 0))
                local c = truth(try(function() return mats[tw.smi] end, 0))
                if a then on = on + 1 end
                if c then src_on = src_on + 1 end
                if a ~= c then differ = differ + 1 end
            end
        end)
        plog(('%s (id %d): stone twin entries on %d of %d, their stones\' on %d; %d differ from their stone.')
            :format(pile_name(b), b.id, on, n, src_on, differ))
    end

    -- ---- EVERY PILE AGAINST THE NEWEST ----
    local newest = list[1]
    for _, b in ipairs(list) do if b.id > newest.id then newest = b end end
    local tb = pile_tree(newest)
    local n_vals = 0
    for _ in pairs(tb) do n_vals = n_vals + 1 end
    local stone_twin = twins[0] or {}
    for _, b in ipairs(list) do
        if b ~= newest then
            local ta = pile_tree(b)
            local groups, order = {}, {}
            local function note_diff(key)
                local base, idx = key:match('^(.-)%[(%d+)%]$')
                local g = base or key
                if not groups[g] then groups[g] = { idx = {}, plain = false }; order[#order + 1] = g end
                if idx then table.insert(groups[g].idx, tonumber(idx)) else groups[g].plain = true end
            end
            for k, v in pairs(ta) do if tb[k] ~= v then note_diff(k) end end
            for k in pairs(tb) do if ta[k] == nil then note_diff(k) end end
            table.sort(order)
            plog(('%s vs %s (newest): %d field group(s) differ, of %d values read.'):format(
                pile_name(b), pile_name(newest), #order, n_vals))
            for _, g in ipairs(order) do
                local e = groups[g]
                local line
                if #e.idx > 0 then
                    local tw = 0
                    for _, i in ipairs(e.idx) do if stone_twin[i] then tw = tw + 1 end end
                    local first = e.idx[1]
                    local r = ranges(e.idx)
                    if #r > 160 then r = r:sub(1, 160) .. '...' end
                    line = ('  %s: %d index(es) differ, %d of them stone twin indices: %s; e.g. [%d] %s vs %s.')
                        :format(g, #e.idx, tw, r, first, tostring(ta[g .. '[' .. first .. ']']),
                        tostring(tb[g .. '[' .. first .. ']']))
                else
                    line = ('  %s: %s vs %s.'):format(g, tostring(ta[g]), tostring(tb[g]))
                end
                plog(line)
            end
        end
    end
end

-- ==========================================
-- THE LOOP
-- ==========================================
local function tick()
    if not dfhack.isMapLoaded() or not running then note('not running or no map'); return end
    if df.global.pause_state then note('paused'); return end
    frame = frame + TICK_FRAMES

    -- ---- STOCKHOOK HAS THE TWINS ----
    -- No window, no renewal, no counts: the twins file through Stockhook's
    -- aliases (STOCKHOOK, WHEN IT IS IN THE WORLD). The scan's resolve
    -- stays, so a twin pushed later in the session is handed over too.
    if SH.here() then
        if record then close_window('Stockhook has the twins') end
        pending = {}
        if frame >= next_scan then
            next_scan = frame + SCAN_FRAMES
            S.dbg.scans = S.dbg.scans + 1
            resolve()
        end
        note('stockhook')
        return
    end
    -- SECTION CLOCK (refinish-section-probe): laps between the sections
    -- below, quiet while the probe is off. A return part way leaves the
    -- later laps unrecorded: those sections did not run.
    local sc = _G.refinish_section_clock
    local t0 = sc and sc.now()

    -- ---- THE RENEWAL, A SLICE A TICK ----
    -- First, so a pass that ends here renews the list for this tick's
    -- counts. Guarded: a fault costs this tick's slice, not the tick.
    do
        local okr, did = pcall(renew_step)
        if not okr then
            local msg = 'the renewal failed: ' .. tostring(did)
            if not said[msg] then
                said[msg] = true
                log('ERROR', msg, 'KNOWN')
            end
            renew = nil
        elseif did and sc then
            t0 = sc.lap('windows: renewal slice', t0)
        end
    end

    -- A piles request posted from the console runs here, in the running copy.
    if S.piles_request then
        S.piles_request = nil
        local ok, err = pcall(run_piles)
        if not ok then plog('the piles command failed: ' .. tostring(err)) end
    end

    -- A test posted from the console starts here, in the running copy.
    if S.test_request then
        local req = S.test_request
        S.test_request = nil
        start_test(req.frames)
    end

    if record then
        -- ---- A WINDOW IS OPEN ----
        -- Items made while it is open need no queue of their own: the
        -- recount sees them, and so does the fresh count taken before it
        -- closes. Each joins the known twins first (A NEW ITEM, KNOWN).
        for id in pairs(pending) do
            local it = df.item.find(id)
            if it then absorb(it) end
        end
        pending = {}
        local hauls, n_hauls = twin_hauls()
        if sc then t0 = sc.lap('windows: open, twin_hauls (job walk)', t0) end
        for id in pairs(hauls) do
            if not win.hauls[id] then win.hauls[id] = true; win.progress = frame end
        end

        -- ---- A FULL QUEUE HOLDS THE STALL CLOCK ----
        -- The stall is measured from win.progress, so moving it forward by
        -- each tick's frames keeps the elapsed stall where it was. The hold
        -- is logged once per window; a release, at most once per RECOUNT.
        local full, jobs, haulers = queue_full()
        if full then
            win.progress = win.progress + TICK_FRAMES
            if not win.full then
                win.full = true
                if not win.said_full then
                    win.said_full = true
                    log('DETAIL', ("stall clock held while DF's hauling queue is full (%s of %s).")
                        :format(tostring(jobs), tostring(haulers)), 'WINDOW')
                end
            end
        elseif win.full then
            win.full = false
            -- Every look DF took while it was full raised a delay: the
            -- timers go short again, at most once per RECOUNT frames. While
            -- DF hauls, the queue flips between full and one short every
            -- few seconds (MEASURED 2026-09-27: about 80 releases in one five
            -- minute window), so only the first is logged and close_window
            -- reports the count.
            if frame - (win.last_short or -RECOUNT) >= RECOUNT then
                win.last_short = frame
                win.resets = (win.resets or 0) + 1
                local n = timers_short()
                if win.resets == 1 then
                    log('DETAIL', ('hauling queue free again (%s of %s); %d storage timer(s) set short.'
                        .. ' Later releases in this window are counted, not logged.')
                        :format(tostring(jobs), tostring(haulers), n), 'WINDOW')
                end
            end
        end

        -- ---- SOAP'S TURN HOLDS IT TOO ----
        -- Loose coal waiting out soap's turn is waiting, not stuck (SOAP'S
        -- TURN HOLDS THE STALL CLOCK in the header). win.soap_wait is set at
        -- each recount below. A tick the full queue already held is not
        -- held twice.
        if win.soap_wait and not full then win.progress = win.progress + TICK_FRAMES end

        -- ---- COAL ----
        -- Soap use stopped every tick while coal is soap; the switch kept up
        -- (new piles, new soap) and engaged late at the recount.
        if coal_on and not hidden then
            local stopped = stop_soap_use()
            if #stopped > 0 then
                win.soap_stopped = (win.soap_stopped or 0) + #stopped
                if not win.said_soap then
                    win.said_soap = true
                    log('DETAIL', ('stopped %s: it took coal as soap. Later ones in this window are'
                        .. ' counted, not logged.'):format(table.concat(stopped, ', ')), 'COAL')
                end
                -- ---- SOAP GETS ITS TURN ----
                -- One stop and soap is wanted: coal hands it back now, so
                -- no reposted soap job can meet coal again.
                release_coal(('soap wanted by %s'):format(table.concat(stopped, ', ')), SOAP_TURN)
                soap_turn_until = frame + SOAP_TURN
                -- ---- THE ONE SLOW REPEAT LEFT ----
                -- With the flags back, is there real soap to meet it?
                -- One decode per material, not per bar (is_real_soap).
                local real, memo = 0, {}
                pcall(function()
                    for _, it in ipairs(df.global.world.items.other.BAR) do
                        if is_real_soap(it, memo) then real = real + 1; return end
                    end
                end)
                unmet_run = (real == 0) and unmet_run + 1 or 0
                if unmet_run >= UNMET_WARN and not unmet_said then
                    unmet_said = true
                    log('WARNING', ('soap has been wanted %d times running with no real soap in the fort'
                        .. ' (last by %s). Each coal turn cancels one such job; making soap ends it.')
                        :format(unmet_run, table.concat(stopped, ', ')), 'COAL')
                end
            end
        end
        if sc then t0 = sc.lap('windows: open, queue and coal soap watch', t0) end
        -- ONE WALK OF THE BARS PER RECOUNT (count_loose): the loose count,
        -- the loose coal and the bar materials for the soap scan, in one
        -- pass, taken before the coal decision and the mirror. Neither
        -- changes what it counts: classify reads where an item is and what
        -- holds it, and these write soap flags and pile settings. Since
        -- 2026-10-01 the count reads the known twins (count_twins, THE
        -- KNOWN TWINS), and since 2026-10-02 at every recount while the
        -- list is good, the backstop being a pass of its own (THE RENEWAL,
        -- A SLICE A TICK). The bar materials are then the new bars' alone.
        local recount = frame - win.last_count >= RECOUNT
        local loose_now, coal_now, bar_mats = 0, 0, nil
        if recount then
            bar_mats = {}
            local r = { count_twins(false, bar_mats) }
            loose_now, coal_now = r[1], r[7]
        end
        if sc and recount then t0 = sc.lap('windows: open, recount count_twins', t0) end
        if recount then
            if coal_on and not hidden then
                soap_off_everywhere(bar_mats)
                soap_switch_on()
                win.soap_wait = false
            elseif not coal_on then
                -- Loose coal engages now, or waits out soap's turn. The wait
                -- holds the stall clock (above) and is logged once a window.
                local waiting = false
                if coal_now > 0 then
                    -- It also waits while the options screen is up (THE OPTIONS
                    -- SCREEN HOLDS COAL OFF), so no save finds coal engaged.
                    local menu = _G.refinish_menu_locked
                    if not menu and frame >= soap_turn_until and not soap_in_use() then
                        engage_coal()
                    else
                        waiting = true
                        if not win.said_soap_wait then
                            win.said_soap_wait = true
                            log('DETAIL', ('stall clock held while coal waits: %s.'):format(menu
                                and 'the options screen is up'
                                or frame < soap_turn_until
                                    and ("soap's turn, %d frame(s) of it left"):format(soap_turn_until - frame)
                                or 'a job holds real soap'), 'COAL')
                        end
                    end
                end
                win.soap_wait = waiting
            end
        end

        if sc and recount then t0 = sc.lap('windows: open, recount soap and coal switch', t0) end
        if recount then
            win.last_count = frame
            mirror_slots()
            local loose = loose_now
            if loose < win.loose then win.progress = frame end
            win.loose = loose
        end
        if sc and recount then t0 = sc.lap('windows: open, recount mirror', t0) end
        if test then
            -- ---- A TEST HOLDS THE WINDOW ----
            if frame >= test.ends then end_test() end
            note('test')
            return
        end
        if n_hauls == 0 then
            -- A fresh count before closing on "nothing loose", so an item
            -- made since the last recount is not left behind.
            if win.loose == 0 then win.loose = count_loose() end
            if win.loose == 0 then
                backoff = BACKOFF_MIN
                close_window('nothing loose or in a haul')
            elseif frame - win.progress >= STALL_FRAMES then
                -- Diagnosed while the flags are still on, as DF sees it.
                local n, in_shops, names, sample, places, odd, _coal, kinds = count_loose(true)
                -- THE RETRY WAIT GIVES WAY TO A CHANGE: what was stuck, by
                -- material and place, and the piles it met.
                stuck_kinds, stuck_piles = kinds or {}, piles_sig()
                local list = {}
                for name, c in pairs(names or {}) do list[#list + 1] = ('%d %s'):format(c, name) end
                table.sort(list)
                log('INFO', ('%d twin item(s) could not be stockpiled (%d in workshops): %s.'
                    .. ' Retrying in %d frames.'):format(n, in_shops, table.concat(list, ', '),
                    backoff), 'STUCK')
                for _, line in ipairs(diagnose(sample or {})) do log('INFO', line, 'STUCK') end
                local pile_list, timed = piles(), {}
                for i, it in ipairs(sample or {}) do
                    local ok, lines, rec = pcall(item_facts, it, pile_list)
                    if ok then
                        timed[#timed + 1] = rec
                        if i <= STUCK_DETAIL then
                            for _, line in ipairs(lines) do log('INFO', line, 'STUCK') end
                        end
                    end
                end
                follow_timers(timed, 'STUCK', false)
                close_window('nothing hauled for ' .. STALL_FRAMES .. ' frames')
                next_try = frame + backoff
                backoff = math.min(backoff * 2, BACKOFF_MAX)
            end
        end
        if sc then sc.lap('windows: open, close checks, stuck, close', t0) end
        note('window open')
        return
    end

    -- ---- NO WINDOW: SHOULD ONE OPEN? ----
    if screen_waits() then note('screen'); return end
    local want, in_shops = 0, 0
    local new_kinds, scan_kinds, mirrored = nil, nil, 0
    if next(pending) then
        local pile_list = piles()
        for id in pairs(pending) do
            local it = df.item.find(id)
            if it then absorb(it) end
            if it and is_twin(it) then
                local ok, place, loose = pcall(classify, it, pile_list, true)
                if ok and loose then
                    want = want + 1
                    if place == 'in a workshop' then in_shops = in_shops + 1 end
                    -- Its kind, for THE RETRY WAIT GIVES WAY TO A CHANGE.
                    local okm, mt, mi = pcall(mat_of, it)
                    if okm then
                        new_kinds = new_kinds or {}
                        new_kinds[tostring(mt) .. ':' .. tostring(mi) .. ':' .. place] = true
                    end
                end
            end
        end
        pending = {}
    end
    if sc then t0 = sc.lap('windows: closed, screen and new items', t0) end
    if frame >= next_scan then
        next_scan = frame + SCAN_FRAMES
        S.dbg.scans = S.dbg.scans + 1
        resolve()
        mirrored = mirror_slots() or 0
        local names, sample, places, odd, scan_coal
        -- ---- THE CENSUS ASKS ONLY FOR PLACES ----
        -- MEASURED 2026-10-01 (section probe): the scan that opened a
        -- window took 105 ms with 559 twins loose. A full detail count
        -- reads every loose twin's description for the STUCK report's
        -- names, and this scan never used them: it logs the census (the
        -- places and the odd item) and passes on the loose count. 'census'
        -- asks for those alone; the STUCK report still asks for all (true).
        want, in_shops, names, sample, places, odd, scan_coal, scan_kinds = count_twins('census')
        local line = census_line(places, odd)
        if line ~= last_census then
            last_census = line
            log('DETAIL', line, 'CENSUS')
        end
        if sc then t0 = sc.lap('windows: closed, scan (resolve, mirror, count_twins)', t0) end
    end
    if want > 0 then
        -- The retry wait holds until its time is up, unless something has
        -- changed that could let the stuck twins move. See THE RETRY WAIT
        -- GIVES WAY TO A CHANGE.
        if frame < next_try and not wait_given_way(mirrored, scan_kinds, new_kinds) then
            note('waiting to retry')
            return
        end
        local t_open = sc and sc.now()
        open_window(want, in_shops)
        if sc then sc.lap('windows: closed, open_window', t_open) end
    end
    note('ran')
end

-- The loop under a guard that reports: an error is logged once per
-- message instead of vanishing (the first two builds swallowed them).
local function guarded_tick()
    S.dbg.calls = S.dbg.calls + 1
    -- SECTION CLOCK (refinish-section-probe): the whole tick, named by
    -- whether a window was open when it began.
    local sc = _G.refinish_section_clock
    local t0, was_open = sc and sc.now(), record ~= nil
    local ok, err = pcall(tick)
    if sc then
        sc.lap(was_open and 'windows: whole tick, window open'
            or 'windows: whole tick, no window', t0)
    end
    if not ok then
        local msg = tostring(err)
        if not said[msg] then
            said[msg] = true
            log('ERROR', 'the loop failed: ' .. msg, 'LOOP')
        end
    end
end

-- New items are checked on the next tick, after the hops have moved them.
local function on_created(item_id)
    if running then pending[item_id] = true end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start()
    if running then return end
    running, frame, pending, next_scan, next_try, backoff = true, 0, {}, 0, 0, BACKOFF_MIN
    -- THE KNOWN TWINS start empty: the first count is a full walk.
    known, known_twins, known_sig, last_full, new_bars, renew = nil, nil, nil, 0, {}, nil
    settled = {}     -- A STORED TWIN, LEFT STORED: renewed by the first full walk
    in_shop = {}     -- A TWIN IN A WORKSHOP, STILL THERE: likewise
    last_census, said, stuck_kinds, test, hidden, jd_seen = nil, {}, nil, nil, false, nil
    stuck_piles = nil
    SH.mod, SH.sig = nil, nil      -- Stockhook asked afresh (STOCKHOOK, THE CODE)
    coal_on, soap_saved, soap_texpos = false, nil, nil
    soap_turn_until, unmet_run, unmet_said = 0, 0, false
    S.test_request, S.piles_request = nil, nil
    S.dbg = { calls = 0, exits = {}, scans = 0 }
    eventful.onItemCreated[KEY] = on_created
    pcall(function() eventful.enableEvent(eventful.eventType.ITEM_CREATED, 0) end)
    local api = _G.refinish_dispatch_api
    if api and api.subscribe and api.subscribe(KEY, { every = TICK_FRAMES, fn = guarded_tick }) then
        repeatUtil.cancel(KEY)
    else
        repeatUtil.scheduleEvery(KEY, TICK_FRAMES, 'frames', guarded_tick)
    end
    -- The menu label runs while paused: DF counts the settings screen as
    -- paused. Without the dispatcher there is no label.
    if api and api.subscribe then
        api.subscribe(MENU_KEY, { every = MENU_FRAMES, paused = true, fn = guarded_menu })
    end
    local n = 0
    for _ in pairs(S.claims) do n = n + 1 end
    log('DETAIL', ('started, %d claim(s).'):format(n), 'START')
end

function stop()
    if record then close_window('RM stopping') end
    SH.take_back()
    running = false
    eventful.onItemCreated[KEY] = nil
    repeatUtil.cancel(KEY)
    local api = _G.refinish_dispatch_api
    if api and api.unsubscribe then api.unsubscribe(KEY); api.unsubscribe(MENU_KEY) end
    log('DETAIL', 'stopped.', 'STOP')
end

-- ---- REGISTERED BY THE LOADED COPY ONLY ----
-- refinish_steel loads this file with reqscript, as a module. A console
-- command runs a fresh copy, which must not take over the unload hook or
-- the claim handle from the copy that is running.
if dfhack_flags and dfhack_flags.module then
    -- The raws go with the world, so an open window's flags need no
    -- putting back, and must not be written to. The piles' Soap entries are
    -- not raws, and a save carries them: soap_saved is dropped here
    -- unwritten, so they must already be the player's own, which THE
    -- OPTIONS SCREEN HOLDS COAL OFF sees to for a save & quit. Never count
    -- on stop() running before this: DFHack calls state change handlers in
    -- an arbitrary order, and refinish_steel.lua's map unload handler is
    -- the one that calls stop().
    dfhack.onStateChange.refinish_stockpile_windows = function(code)
        if code == SC_WORLD_UNLOADED or code == SC_MAP_UNLOADED then
            record, win, pending, test, hidden = nil, nil, {}, nil, false
            coal_on, soap_saved = false, nil
            -- Stockhook's own state goes with the world: nothing to take back.
            SH.mod, SH.sig = nil, nil
        end
    end
    _G.refinish_window_api = { claim = claim, unclaim = unclaim, hide = hide, unhide = unhide,
                               label = label, unlabel = unlabel, tagged = tagged }
end

-- ==========================================
-- COMMANDS
-- ==========================================
-- status: what the service sees now, into the session log (INFO) and the
-- console: the claims, the census, and with items loose the stuck
-- diagnosis. Read with the flags as they stand.
local function status()
    local function say(msg)
        print(msg)
        log('INFO', msg, 'STATUS')
    end
    local owners = {}
    for owner in pairs(S.claims) do owners[#owners + 1] = owner end
    table.sort(owners)
    local n_twins = resolve()
    local loose, in_shops, names, sample, places, odd = count_loose(true)
    say(('claims: %s; %d twin material(s); window %s; running %s.'):format(
        #owners > 0 and table.concat(owners, ', ') or 'none', n_twins,
        record and 'OPEN' or 'closed', tostring(running)))
    say(census_line(places, odd))
    say(('%d loose, %d of them in workshops.'):format(loose, in_shops))
    if loose > 0 then
        for _, line in ipairs(diagnose(sample or {})) do say(line) end
    end
end

-- check: facts only, each on its own line, into the session log (INFO) and
-- the console. See COMMANDS. Every line stays under the log's 400
-- characters. The storage timers of the items shown are read again
-- TIMER_FOLLOWUP frames later, so the log shows whether DF is counting
-- them down (the field's comment: -1 per 50 frames, then a check whether
-- the item needs moving).
local CHECK_ITEMS    = 30
local WORD_ITEMS     = 40

local function check(word)
    local function say(msg)
        print(msg)
        log('INFO', msg, 'CHECK')
    end

    -- ---- THE LOOP, AS THE RUNNING COPY RECORDED IT ----
    local d = S.dbg or {}
    local exits = {}
    for reason, c in pairs(d.exits or {}) do exits[#exits + 1] = reason .. ' ' .. c end
    table.sort(exits)
    say(('loop: %s run(s); ended by: %s; scans %s; frame %s, next scan %s, next try %s;'
        .. ' window open %s.'):format(tostring(d.calls), #exits > 0 and table.concat(exits, ', ')
        or 'nothing yet', tostring(d.scans), tostring(d.frame), tostring(d.next_scan),
        tostring(d.next_try), tostring(d.window)))
    say('last census: ' .. tostring(d.last_census))

    -- ---- THE DISPATCHER ----
    local D = _G.refinish_dispatch
    if not D then
        say('dispatcher: no state in _G.refinish_dispatch.')
    else
        local sub = D.subs and D.subs[KEY]
        local in_group = false
        for _, g in ipairs(D.groups or {}) do
            for _, s in ipairs(g.subs or {}) do
                if s.name == KEY then in_group = g.every end
            end
        end
        say(('dispatcher: running %s, frame %s; subscription %s; in the schedule %s; errored %s.')
            :format(tostring(D.running), tostring(D.frame),
            sub and ('every ' .. tostring(sub.every) .. ', paused ' .. tostring(sub.paused)) or 'NOT FOUND',
            in_group and ('every ' .. tostring(in_group)) or 'NO',
            tostring(D.errored and D.errored[KEY] or false)))
    end
    say(storage_counts())
    say(('pause: df.global.pause_state %s; dfhack.world.ReadPauseState() %s.'):format(
        tostring(try(function() return df.global.pause_state end, 'unreadable')),
        tostring(try(function() return dfhack.world.ReadPauseState() end, 'unreadable'))))

    -- ---- THE SCREEN ----
    local vs = try(function() return dfhack.gui.getDFViewscreen(true) end)
    local focus = try(function() return dfhack.gui.getFocusStrings(vs) end, {})
    local fl = {}
    for _, s in ipairs(focus) do fl[#fl + 1] = tostring(s) end
    say(('screen: focus %s; a window would wait %s.'):format(#fl > 0 and table.concat(fl, ', ')
        or 'none read', tostring(screen_waits())))

    -- ---- THE TWINS ----
    local n_twins = resolve()
    local tl = {}
    for ty in pairs(types) do tl[#tl + 1] = ty end
    say(('twins: %d material(s) from %d claim(s); item vectors %s.'):format(n_twins,
        (function() local n = 0 for _ in pairs(S.claims) do n = n + 1 end return n end)(),
        #tl > 0 and table.concat(tl, ', ') or 'none'))

    -- ---- EVERY TWIN ITEM ----
    local pile_list = piles()
    local shown, total, holders, timed = 0, 0, {}, {}
    for ty in pairs(types) do
        local vec = try(function() return df.global.world.items.other[ty] end)
        if vec then
            for _, it in ipairs(vec) do
                if is_twin(it) then
                    total = total + 1
                    if shown < CHECK_ITEMS then
                        shown = shown + 1
                        local ok, lines, rec, b = pcall(item_facts, it, pile_list)
                        if ok then
                            for _, line in ipairs(lines) do say(line) end
                            timed[#timed + 1] = rec
                            if b then holders[b.id] = b end
                        else
                            say(('item #%s could not be read: %s'):format(
                                tostring(try(function() return it.id end, '?')), tostring(lines)))
                        end
                    end
                end
            end
        end
    end
    say(('%d twin item(s) in all, %d shown.'):format(total, shown))

    -- ---- WHAT EACH HOLDING BUILDING LISTS ----
    for id, b in pairs(holders) do
        local rows = {}
        pcall(function()
            for _, bi in ipairs(b.contained_items) do
                local it = bi.item
                rows[#rows + 1] = ('role %s #%s%s'):format(tostring(bi.use_mode),
                    tostring(try(function() return it.id end, '?')), is_twin(it) and ' (twin)' or '')
            end
        end)
        say(('building %d (%s): %s.'):format(id,
            tostring(try(function() return df.building_type[b:getType()] end, '?')), links_of(b)))
        -- The list can be long: in chunks, so no line runs past the cut.
        local chunk = {}
        local function flush()
            if #chunk > 0 then say(('building %d holds: %s.'):format(id, table.concat(chunk, '; '))) end
            chunk = {}
        end
        for _, r in ipairs(rows) do
            chunk[#chunk + 1] = r
            if #chunk >= 12 then flush() end
        end
        flush()
        if #rows == 0 then say(('building %d holds nothing listed.'):format(id)) end
    end

    -- ---- THE SAME TIMERS, LATER ----
    -- Unpaused frames, so a paused game delays the second reading.
    if #timed > 0 then
        follow_timers(timed, 'CHECK', true)
        say(('the timers of these %d item(s) are read again in %d unpaused frames.'):format(#timed,
            TIMER_FOLLOWUP))
    end

    -- ---- EVERY TOOL ITEM BY ID, TWIN OR NOT ----
    -- check WORD: every tool item whose definition id contains WORD (GRAVEL,
    -- DUST, KINDLING...) and is not on a pile, whatever its material, so an
    -- item seen sitting in play can be matched to its facts. The census
    -- counts only twins; this does not.
    if word and word ~= '' then
        local want = word:upper()
        local n, shown_w = 0, 0
        pcall(function()
            for _, it in ipairs(df.global.world.items.other.TOOL) do
                local id = try(function() return it.subtype.id end, '')
                if id:find(want, 1, true) then
                    local ok, place = pcall(classify, it, pile_list)
                    if not (ok and place == 'on a pile') then
                        n = n + 1
                        if shown_w < WORD_ITEMS then
                            shown_w = shown_w + 1
                            local b = try(function() return dfhack.items.getHolderBuilding(it) end)
                            say(('%s #%d "%s": material %s, %s; %s%s.'):format(id, it.id,
                                tostring(try(function() return dfhack.items.getDescription(it, 1) end, '?')),
                                tostring(try(function() return dfhack.matinfo.decode(it):getToken() end, '?')),
                                is_twin(it) and 'a twin' or 'not a twin',
                                ok and tostring(place) or ('unplaced: ' .. tostring(place)),
                                b and (' in building %d (%s)'):format(b.id,
                                    tostring(try(function() return df.building_type[b:getType()] end, '?'))) or ''))
                        end
                    end
                end
            end
        end)
        say(('%d tool item(s) with %s in their id are off a pile; %d shown.'):format(n, want, shown_w))
    end
end

-- menu: the settings screen's rows, as DF holds them, into the log and
-- the console. Run from the DFHack console while a pile's settings are
-- open (the game is paused there, so it runs at once). For each row: its
-- label strings, the settings entry it toggles, and whether that entry
-- is a stone twin's. MENU_ROWS rows at most, twin rows first.
local MENU_ROWS = 40

local function menu_dump()
    local function say(msg) print(msg); log('INFO', msg, 'MENU') end
    resolve()
    local jd = try(function() return df.global.game.main_interface.job_details end)
    if jd and try(function() return jd.open end, false) then
        for _, set in ipairs(JD_SETS) do
            local mv, iv = try(function() return jd[set[1]] end), try(function() return jd[set[2]] end)
            local n, tw, shown = mv and #mv or 0, 0, {}
            for i = 0, n - 1 do
                local mt, mi = mv[i], iv and iv[i]
                if twins[mt] and twins[mt][mi] then tw = tw + 1 end
                if #shown < 12 then
                    shown[#shown + 1] = ('%s:%s'):format(tostring(mt), tostring(mi))
                end
            end
            say(('material menu %s: %d row(s), %d of them twins; first rows %s.'):format(set[1], n, tw,
                table.concat(shown, ' ')))
        end
    end
    local cs = try(function() return df.global.game.main_interface.custom_stockpile end)
    if not cs or not try(function() return cs.open end, false) then
        say('the stockpile settings screen is not open.')
        return
    end
    local sp = try(function() return cs.sp end)
    local spans = sp and list_spans(sp) or {}
    local names = {}
    for _, s in ipairs(spans) do names[#names + 1] = s.name .. ' ' .. s.len end
    say(('rows %d; window open %s; lists addressed: %s.'):format(try(function() return #cs.spec_item end, 0),
        tostring(S.dbg and S.dbg.window), #names > 0 and table.concat(names, ', ') or 'none'))
    local rows, twin_rows = {}, 0
    for i, row in ipairs(cs.spec_item) do
        local idx, tw, list = row_twin(row, spans)
        local line = ('[%d] "%s" / "%s": %s%s; race %s itype %s istype %s isc1 %s isc2 %s.'):format(i,
            tostring(try(function() return row.name end, '?')), tostring(try(function() return row.simple_name end, '?')),
            idx and (list .. '[' .. idx .. ']') or 'no inorganic entry',
            tw and (' (stone twin, tag ' .. tostring(tw.tag) .. ')') or '',
            tostring(try(function() return row.race end, '?')), tostring(try(function() return row.itype end, '?')),
            tostring(try(function() return row.istype end, '?')), tostring(try(function() return row.isc1 end, '?')),
            tostring(try(function() return row.isc2 end, '?')))
        if tw then twin_rows = twin_rows + 1; table.insert(rows, 1, line) else rows[#rows + 1] = line end
    end
    for i = 1, math.min(#rows, MENU_ROWS) do say(rows[i]) end
    say(('%d row(s) toggle a stone twin\'s entry.'):format(twin_rows))
end

if dfhack_flags and dfhack_flags.module then return end
local args = { ... }
if args[1] == 'status' then
    status()
elseif args[1] == 'check' then
    check(args[2])
elseif args[1] == 'menu' then
    menu_dump()
elseif args[1] == 'piles' then
    S.piles_request = true
    local msg = 'piles requested: it runs on the next unpaused tick.'
    print(msg)
    log('INFO', msg, 'PILES')
elseif args[1] == 'test' then
    -- Posted for the running copy, which holds the window; it starts on
    -- the next unpaused tick. See THE TEST COMMAND.
    S.test_request = { frames = tonumber(args[2]) or TEST_FRAMES }
    local msg = ('test requested: it starts on the next unpaused tick and holds a window %d frames.')
        :format(S.test_request.frames)
    print(msg)
    log('INFO', msg, 'TEST')
else
    print('refinish-stockpile-windows status | check [WORD] | test [frames] | piles | menu')
end