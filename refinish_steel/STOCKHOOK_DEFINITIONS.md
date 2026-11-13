# Stockhook definition files

Stockhook is Refinish Metal's stockpile system. It lets a mod (or a
player) give items stockpile entries that Dwarf Fortress does not have, and
decide which piles take them. No scripting is
needed: entries are written in plain text files, in the same style as DF's
raws.

## Where the files go

| Who | Folder | Entry ids become |
|---|---|---|
| A mod | `<your mod folder>/stockhook/` | `YOURMODID:ENTRY` |
| A player, for every world that uses Refinish Metal | `dfhack-config/stockhook/` in DF's folder | `USER:ENTRY` |
| A player, for one world | `stockhook/` inside that world's save folder | `WORLD:ENTRY` |

Stockhook only runs in a world that has Refinish Metal in its load order,
and a mod's files are only read while that mod is in the world's load order
too. Nothing
carries from one world to another.

Any file ending in `.txt` in those folders is read. Do not put these files
in your mod's `objects` folder: DF would try to read them as raws.

Files are read every time a fort is loaded. After editing one with a fort
open, run `refinish-stockhook reload` in the DFHack console.

## An entry

Everything outside square brackets is a comment, as in DF's raws.

```
These are Making Fuel's cinders.

[STOCKHOOK_ENTRY:CINDERS]
    [LABEL:Cinders]
    [CATEGORY:BARS_OTHER]
    [CONTAINER:BIN]
    [ITEM:BAR]
    [MATERIAL:PLANT_MAT:MAKING_FUEL_COAL_HOST:CINDER]
```

| Token | Meaning |
|---|---|
| `[STOCKHOOK_ENTRY:ID]` | Starts an entry. The id is unique within your mod: letters, digits and underscores. |
| `[ITEM:TYPE]` or `[ITEM:TYPE:SUBTYPE]` | Which items. `BAR`, `BLOCKS`, `TOOL`... as DF names item types; `TOOL:ITEM_TOOL_BRANCH` for one kind of tool. Repeat for several. Required. |
| `[MATERIAL:TOKEN]` | Which materials, as DF writes them: `INORGANIC:GRANITE`, `PLANT_MAT:OAK:WOOD`, `CREATURE_MAT:DOG:BONE`, `COAL:COKE`. A token ending in `NONE` names that material with no index and nothing else: `COAL:NONE` is refined coal, not every coal. Repeat for several. Leave out for any material. |
| `[LABEL:text]` | The row's name in a pile's settings. Defaults to the id. |
| `[CATEGORY:LIST]` | Which list in a pile's settings shows the row, named as DF names its lists (case and underscores ignored): `BARS_OTHER` (beside Coal and Soap), `BLOCKS_OTHER`, `GOODS_TYPE` (beside Tools), `GOODS_OTHER` (beside Wood), `FURNITURE_TYPE`, `STONE_OTHER`, `WEAPONS_TYPE`, and so on. Without it the row exists but shows in no list. |
| `[CONTAINER:BIN]` or `[CONTAINER:BARREL]` | When the row is switched on for a pile that allows no bins (or barrels), the pile is given some, as DF does for its own entries. |

An entry covers every combination of its ITEMs and MATERIALs.

## The three kinds of entry

**A row of its own** (the example above): each pile has its own on/off switch
for it, saved with the fort. A pile with nothing but this row on takes these
items and nothing else.

**Following a vanilla entry**: the items go wherever one of DF's own settings
would send them. Replace LABEL and CATEGORY with:

```
[STOCKHOOK_ENTRY:COAL]
    [FOLLOW:BARS:COAL]
    [ITEM:BAR]
    [MATERIAL:PLANT_MAT:MAKING_FUEL_COAL_HOST:COKE]
    [MATERIAL:PLANT_MAT:MAKING_FUEL_COAL_HOST:CHARCOAL]
```

Here the coke and charcoal go to every pile whose Coal entry is on.

| FOLLOW group | Key | The entry it follows |
|---|---|---|
| `BARS` | `COAL`, `POTASH`, `ASH`, `PEARLASH`, `SOAP` | Bars, other materials |
| `BARS_MATERIAL` | an inorganic id (`IRON`) | Bars, metals |
| `BLOCKS` | `WOOD`, `GLASSGREEN`, `GLASSCLEAR`, `GLASSCRYSTAL` | Blocks, other materials |
| `BLOCKS_MATERIAL` | an inorganic id | Blocks, stone and metal |
| `FINISHED_GOODS` | `WOOD`, `PLANT`, `BONE`, `TOOTH`, `HORN`, `PEARL`, `SHELL`, `LEATHER`, `SILK`, `AMBER`, `CORAL`, `GLASSGREEN`, `GLASSCLEAR`, `GLASSCRYSTAL`, `YARN`, `WAX` | Finished goods, other materials |
| `FINISHED_GOODS_MATERIAL` | an inorganic id (`GRANITE`) | Finished goods, stone, metal and gems |
| `FINISHED_GOODS_TYPE` | an item type (`FIGURINE`, `TOOL`) | Finished goods, types |
| `FURNITURE` | as FINISHED_GOODS, less WAX | Furniture, other materials |
| `FURNITURE_MATERIAL` | an inorganic id | Furniture, stone and metal |
| `FURNITURE_TYPE` | a furniture type (`BED`, `CHAIR`, `SAND_BAG`) | Furniture, types |
| `STONE` | an inorganic id | Stone |
| `COINS` | an inorganic id | Coins |
| `GEMS_ROUGH`, `GEMS_CUT` | `GLASS_GREEN`, `GLASS_CLEAR`, `GLASS_CRYSTAL` | Gems, rough or cut glass |
| `GEMS_ROUGH_MATERIAL`, `GEMS_CUT_MATERIAL` | an inorganic id | Gems, rough or cut gems and stone |
| `AMMO` | `WOOD`, `BONE` | Ammo, other materials |
| `AMMO_MATERIAL` | an inorganic id | Ammo, metal |
| `AMMO_TYPE` | an ammo id (`ITEM_AMMO_BOLTS`) | Ammo, types |
| `WEAPONS` | `WOOD`, `PLANT`, `BONE`, `SHELL`, `LEATHER`, `SILK`, `GLASSGREEN`, `GLASSCLEAR`, `GLASSCRYSTAL`, `YARN` | Weapons, other materials |
| `WEAPONS_MATERIAL` | an inorganic id | Weapons, metal and stone |
| `WEAPONS_TYPE` | a weapon id (`ITEM_WEAPON_AXE_BATTLE`) | Weapons, types |
| `TRAPCOMP_TYPE` | a trap component id (`ITEM_TRAPCOMP_GIANTAXEBLADE`) | Weapons, trap components |
| `ARMOR` | as WEAPONS | Armor, other materials |
| `ARMOR_MATERIAL` | an inorganic id | Armor, metal |
| `ARMOR_BODY`, `ARMOR_HEAD`, `ARMOR_FEET`, `ARMOR_HANDS`, `ARMOR_LEGS`, `ARMOR_SHIELD` | an armor, helm, shoes, gloves, pants or shield id | Armor, types |
| `WOOD` | a plant id (`OAK`) | Wood |
| `ANIMALS` | a creature id (`DOG`) | Animals |
| `CORPSES` | a creature id | Corpses |
| `REFUSE_TYPE` | an item type | Refuse, items |
| `REFUSE_CORPSES`, `REFUSE_BODY_PARTS`, `REFUSE_SKULLS`, `REFUSE_BONES`, `REFUSE_HAIR`, `REFUSE_SHELLS`, `REFUSE_TEETH`, `REFUSE_HORNS` | a creature id | Refuse, by creature |

| `FOOD_MEAT`, `FOOD_PLANTS`, `FOOD_DRINK_PLANT`, `FOOD_DRINK_ANIMAL`, `FOOD_CHEESE_PLANT`, `FOOD_CHEESE_ANIMAL`, `FOOD_SEEDS`, `FOOD_LEAVES`, `FOOD_POWDER_PLANT`, `FOOD_POWDER_CREATURE`, `FOOD_GLOB`, `FOOD_PASTE`, `FOOD_PRESSED`, `FOOD_LIQUID_PLANT`, `FOOD_LIQUID_ANIMAL`, `FOOD_LIQUID_MISC` | a material token (`CREATURE_MAT:COW:TALLOW`, `PLANT_MAT:MUSHROOM_HELMET_PLUMP:DRINK`) | Food, by list |
| `FOOD_FISH`, `FOOD_UNPREPARED_FISH`, `FOOD_EGG` | a creature and caste (`FISH_COD:MALE`) | Food, fish and eggs |
| `LEATHER` | a material token (`CREATURE_MAT:COW:LEATHER`) | Leather |
| `THREAD_SILK`, `THREAD_PLANT`, `THREAD_YARN`, `THREAD_METAL`, `CLOTH_SILK`, `CLOTH_PLANT`, `CLOTH_YARN`, `CLOTH_METAL` | a material token | Cloth, thread and cloth by fibre |
| `SHEET_PAPER`, `SHEET_PARCHMENT` | a material token | Sheets |

Plain switches (prepared meals, dyed, undyed) and quality levels are not
lists and cannot be followed.

Keys are matched without regard to case.

**Never stored**: `[NEVER]` in place of LABEL or FOLLOW. No pile takes these
items, whatever its settings.

**A part of a vanilla entry**: a row of its own that splits one of DF's
entries, with `[PART_OF:<group>:<key>]` (the same group and key a FOLLOW
would use) added to a row of its own. Stockhook itself splits DF's Coal row
this way:

```
[STOCKHOOK_ENTRY:COKE]
    [LABEL:Coke]
    [CATEGORY:BARS_OTHER]
    [ITEM:BAR]
    [MATERIAL:COAL:COKE]
    [PART_OF:BARS:COAL]
```

- The items the part names are decided by the part's own row: a pile with
  Coal on and Coke off takes no coke.
- The vanilla row stays the wildcard: every item it covers that no part
  names still follows it.
- Clicking the vanilla row sets all its parts to the same value.
- In every existing pile, a new part starts at that pile's vanilla setting,
  so adding one changes nothing a pile already takes.
- A hauling route stop has no rows of its own: there the vanilla entry
  decides, as it always did.

Add `[VANILLA_ITEM]` to a part whose items DF itself already files under
that vanilla entry (oak beds under Beds, coke under Coal, a kind of tool
under Tools). The part's row then decides only whether the pile wants
that part; the pile's other settings (materials, quality, and so on) still
apply to those items, exactly as they would to the vanilla entry's. Leave it
out for a mod's own items that DF could never file there (Making Fuel's
coals, which DF does not count as coal): for those the row alone decides.

## Hiding another source's entry

`[STOCKHOOK_HIDE:MODID:ENTRY]`, anywhere in a file, stops that entry loading
at all: no row, no claims, whatever the load order. For a mod whose world
never holds what the entry covers, or that covers it itself. Making Fuel
hides Stockhook's coke, charcoal and refined coal rows, since its coal
watcher replaces every builtin coal bar with its own materials.

## Generated rows

`[STOCKHOOK_GENERATE:TOOL_TYPES]`, `[STOCKHOOK_GENERATE:ITEM_KINDS]`,
`[STOCKHOOK_GENERATE:ARMOR_CLOTHING]` and `[STOCKHOOK_GENERATE:WOODS]`,
anywhere in a file, work from the world's own raws. Stockhook's own
`vanilla.txt` uses all four, so every world gets them:

- **TOOL_TYPES**: every tool kind, vanilla or modded, as an item type of its
  own in the list DF files it under: beside Tools in Finished goods: type, or
  beside Other large tools in Furniture: type for a furniture tool, labelled
  with the tool's plural name. Minecarts, wheelbarrows and large pots (their
  own Furniture entries) and the instrument pieces each world generates are
  left out. A tool kind any file names itself (an `[ITEM:TOOL:...]` token) is
  left to that file, so a mod can label its own tools, or mark them NEVER.
- **ITEM_KINDS**: the kinds of an item type that a list shows only as a
  whole, as rows of their own beside it, labelled with each kind's plural
  name. In Finished goods: type, every clothing kind of body wear,
  headwear, footwear, handwear and legwear, and every toy (Coats and Robes
  beside "Armor (all)"); armor kinds (an ARMORLEVEL above 0) are left out,
  as Finished goods never takes them. In Refuse: items, every kind of tool, weapon, trap
  component, ammo, siege ammo, armor, clothing, shield and toy. A type with
  fewer than two kinds gets no rows. A kind a file names itself in a list
  is left to that file there, and its rows in other lists take that file's
  label.
- **ARMOR_CLOTHING**: makes no rows; hides DF's own rows for clothing kinds
  (no armor level) in the Armor group's item lists, since DF refuses
  clothing in armor piles. `[STOCKHOOK_ARMOR_KEEP:TYPE:KIND]`, anywhere in a
  file, keeps a kind that DF still files as armor in some material:
  Stockhook's own file keeps `HELM:ITEM_HELM_CAP`, since a metal cap goes to
  armor. A hidden row's setting decides nothing, so Stockhook keeps it
  matching the rest of its list, and the category's colour stays true.
- **WOODS**: every tree as a material of its own beside Wood in each list
  with a Wood entry (finished goods, furniture, blocks, ammo, weapons,
  armor), labelled with the tree's name, each for its own list only.

The rows made are parts with `[VANILLA_ITEM]`: the pile's other settings still apply.

## Settings that decide nothing

`[STOCKHOOK_FREE:INORGANIC_ID]`, anywhere in a file, names a material whose
own entries in the material lists decide nothing where its row is hidden:
a hidden twin made only as tools, for instance. Where its row is hidden,
Stockhook keeps its entry matching the rest of that list, so the list's
category colour stays true after ALL or NONE. A shown row is never touched.
A trailing `*` names every material whose id starts with the rest:
Making Fuel's `[STOCKHOOK_FREE:MAKING_FUEL_BINDER_*]` covers a binder of
any clay, modded ones included.

## Materials that file as another

`[STOCKHOOK_ALIAS_PLANT:FROM:TO]`, anywhere in a file: on every plant that
has both materials, items made of FROM are filed as if made of TO. For a
mod's hidden twin materials, which DF would never file: Making Fuel's
kindling and tinder are made of a twin of their tree's wood
(`MAKING_FUEL_FUELWOOD`), and `[STOCKHOOK_ALIAS_PLANT:MAKING_FUEL_FUELWOOD:WOOD]`
has oak kindling filed as oak, by every pile's ordinary material settings.
Only how piles see the item changes, and only for the moment a pile is
asked; the item itself keeps its material.

## Moving a material out of the stone lists

`[STOCKHOOK_MOVE:INORGANIC_ID:Label]`, anywhere in a file (the label may be
left off, for the material's own name): DF's rows for that material leave
every list that holds stone, and in each group with an other materials list
(finished goods, furniture, blocks, ammo, weapons, armor) it is shown there
instead, under the label. In the Stone and Gems groups, which have no such
list, its rows are only hidden. For a material made IS_STONE only so its
items would stockpile at all: Making Fuel's dung, straw, papers and soaps.

The row is still DF's own setting, the same one the hidden stone row
flipped, so DF files the items exactly as before. Only where the row is
drawn changes.

## When two entries cover the same item

The more specific one wins: an entry naming the exact material beats one
with no MATERIAL token, and one naming a tool kind beats one naming only
TOOL. Between entries equally specific, the one read LAST wins: files are
read for each mod in the world's load order, then the player's files, then
the world's own, so a later mod overrides an earlier one and the player
overrides every mod, as in DF's own load order. An entry
id defined twice in one mod is reported by `refinish-stockhook reload` and the second
is ignored.

## Materials made while the game runs

Some mods create materials after the world loads. A MATERIAL token that does
not exist yet is retried for about a minute of play. If it never appears,
`refinish-stockhook reload` prints which tokens are missing.

## Console commands

| Command | What it does |
|---|---|
| `refinish-stockhook` or `refinish-stockhook status` | Whether Stockhook is active, and every entry loaded |
| `refinish-stockhook reload` | Read every definition file again, and list any problems |
| `refinish-stockhook piles` | Every pile's number and which rows are on |
| `refinish-stockhook set <pile number> <entry id> on\|off` | Switch a row for one pile. The pile number is the one DF shows: "Stockpile #12" is 12. |

A row with a CATEGORY appears in each pile's own settings screen, in that
list, and is switched there like DF's own rows; the console commands do the
same from the DFHack console.