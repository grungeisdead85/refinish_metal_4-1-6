# RM Module Guide

How to add materials, reactions, tools, plants and buildings to Dwarf Fortress
using Refinish Metal's module system.

---

## Contents

1. [What this system is](#1-what-this-system-is)
2. [Anatomy of a module](#2-anatomy-of-a-module)
3. [Your first module](#3-your-first-module)
4. [The materials file](#4-the-materials-file)
5. [The reactions file](#5-the-reactions-file)
6. [Reagents and products in depth](#6-reagents-and-products-in-depth)
7. [Tools, plants and buildings](#7-tools-plants-and-buildings)
8. [The advanced Lua shell](#8-the-advanced-lua-shell)
9. [Working with other modules](#9-working-with-other-modules)
   - [RM's catalog: `requires`](#rms-catalog-requires)
   - [RM's services](#rms-services)
10. [Troubleshooting](#10-troubleshooting)
11. [Rules and conventions](#11-rules-and-conventions)
- [Appendix A: every reagent type](#appendix-a-every-reagent-type)
- [Appendix B: vectors and tool uses](#appendix-b-vectors-and-tool-uses)

---

## 1. What this system is

### The problem

Dwarf Fortress reads raw files once, when a world is generated. Materials and
reactions added afterwards do not exist in that world. Adding content to an
existing save means regenerating the world, and removing a mod from a save
corrupts it.

### What RM does instead

Refinish Metal writes content directly into the game's memory at load time,
after the world is already open, and sweeps it back out before the game saves.
Nothing your module injects (materials, reactions, categories, tools, plants,
building definitions) is written into the save.

That gives you two things raws cannot:

- **Content works on existing saves.** No regeneration.
- **Nothing has to be decided at worldgen.** Your module can read the loaded
  world and adapt to it.

### What this does not mean

**A module cannot be fully uninstalled from a save.** This is worth being
precise about, because the distinction is easy to overstate.

Your module is still a DF mod. Once it is active for a world, DF records it in
that save's mod list and keeps its `info.txt`, exactly as it does for RM itself.
Delete the mod from disk and the save loses a mod it expects to find.

What RM's approach actually buys is that **the injected content is not part of
the save**. That is what makes existing saves usable and what stops a
half-removed mod from corrupting one. It is not the same as leaving no trace.

The realistic lifecycle is **dormancy, not removal**. A module that stops
responding to RM's token call injects nothing, and the save continues to work
without its materials. The mod entry stays. Design for that: assume a player
may turn your content off, and make sure nothing you leave behind depends on it
coming back.

### What you write

A module is one small Lua file and the JSON data files it points RM at: a
materials file and a reactions file, plus, when you need them, a tools file, a
plants file and a buildings file. Every JSON file goes in the module's `data`
folder, and the PNG sheets they name go in an `images` folder inside `data`.
You do not write engine code. You describe your content in a schema, and RM
builds it.

### What this system is not for

RM adds content. It does not remove or rewrite content that already exists:
if you need to change a vanilla material or delete a vanilla reaction, that
still belongs in raw files. The one edit RM offers on existing materials is a
reaction class given at run time and taken back before every save, through its
material classes service (section 9, RM's services).

---

## 2. Anatomy of a module

```
my_module/
  info.txt
  scripts_modinstalled/
    my_module.lua
  data/
    my_module_materials.json
    my_module_reactions.json
    my_module_tools.json
    my_module_plants.json
    my_module_buildings.json
    images/
      my_module_sheet.png
```

| File | What it holds |
|---|---|
| `info.txt` | Standard DF mod metadata |
| `scripts_modinstalled/my_module.lua` | Registers with RM and points it at the JSON |
| `data/my_module_materials.json` | Your materials |
| `data/my_module_reactions.json` | Your reactions and categories |
| `data/my_module_tools.json` | Optional: your tools |
| `data/my_module_plants.json` | Optional: your host plants and the materials they carry |
| `data/my_module_buildings.json` | Optional: your workshops and furnaces |
| `data/images/` | Optional: the PNG sheets your JSON names |

Every JSON file goes in `data`, and `images` goes inside `data`. Image paths in
your JSON are written relative to `data`, as `images/my_module_sheet.png`.

### How the pieces connect at runtime

1. DF loads a world. DFHack runs every script in `scripts_modinstalled/`.
2. Your Lua file registers a **listener** with RM's module engine
   (`register_listener(name, callback, mod_id)`) and returns immediately.
   Nothing else happens yet.
3. RM starts up and broadcasts a **token call** to every registered listener.
   A listener that gave a `mod_id` is only called when that mod is active in
   the loaded world. A `mod_id` that matches no installed mod is called anyway,
   with a warning to correct it.
4. Your listener responds with your data, either as file paths or as already
   parsed tables (section 8.1).
5. RM validates the data one entry at a time. A bad material, reaction,
   category or tool is left out and named in the log, and the rest of your
   module still loads. The module is refused whole only when it cannot be
   identified or nothing valid is left (section 10).
6. RM injects modules in dependency order, RM's own catalog forms first. For
   each module, in this order: tools, plants, materials, your
   `on_materials_injected` function if you returned one, buildings,
   categories, reactions.
7. Once every module is in: `reaction_products` that name other modules'
   materials are resolved, saved jobs on module reactions are pointed back at
   their reactions, and each accepted module's `start` function runs, if it
   returned one. Civilization permissions are granted after that, in RM's own
   startup.
8. Before every save, at a shutdown and at the map unload, RM runs your `stop`
   function if it ran your `start`, then sweeps everything back out. After a
   save it injects again and runs `start` again.

A refused module is never started: its `start` never runs, and the log says so
under its name. That is why a module's scripts belong in `start` and never in
the listener itself: the listener runs before validation, so a script started
there keeps running for a module RM then refuses, and polls on through every
save while the module's data is out of RAM. `start` and `stop` are optional.

Registration is deliberately cheap. Your listener is a callback that is stored
and called later, once the world raws exist. That ordering is why you cannot
read `df.global.world` at the top of your Lua file.

### The prefix

Every module owns a **prefix**, a string ending in an underscore. RM stamps it
onto everything you inject.

| You write | RM creates |
|---|---|
| material key `GOLDBRONZE` | inorganic `MYMOD_GOLDBRONZE` |
| reaction key `MAKE_GOLDBRONZE` | reaction `MYMOD_RXN_MAKE_GOLDBRONZE` |
| category key `ALLOYS` | category `MYMOD_CAT_ALLOYS` |
| tool key `CRUCIBLE` | tool itemdef `MYMOD_CRUCIBLE` |
| plant key `DYE_HOST` | plant `MYMOD_DYE_HOST` |
| building key `KILNETTE` | building `MYMOD_KILNETTE` |

The prefix is how RM tells your content apart from everyone else's, including
during cleanup. Two rules follow from that:

- **No two modules may have overlapping prefixes.** Not just identical ones.
  `THISMOD_` overlaps `THISMOD_TOO_`, because a sweep for the first also selects
  the second, and one module's shutdown would delete the other's materials.
  RM refuses the overlap at registration.
- **`REFINISH_STEEL_` is reserved** for RM's own finishes, and RM's own content
  registers through the same engine under `REFINISH_CORE_`, `REFINISH_BRICK_`,
  `REFINISH_DYE_` and the catalog prefixes (`REFINISH_GRAVEL_` and the rest,
  section 9). The overlap rule keeps you off all of them. Do not start a prefix
  with `REFINISH_`.

Pick something specific. `MYMOD_` is fine. `METAL_` is asking for trouble.

---

## 3. Your first module

### Step 1: info.txt

Standard DF mod metadata. The `[ID:...]` value is the one that matters here,
because your Lua file uses it to find your own folder on disk, and it is the
`mod_id` your listener can pass so RM only calls it in worlds that have your
mod.

```
[ID:my_module]
[NAME:My Module]
[DESCRIPTION:Adds a new alloy.]
[NUMERIC_VERSION:1]
[DISPLAYED_VERSION:1.0]
[EARLIEST_COMPATIBLE_NUMERIC_VERSION:1]
[EARLIEST_COMPATIBLE_DISPLAYED_VERSION:1.0]
[REQUIRES_ID:refinish_steel]
[STEAM_TITLE:My Module]
[STEAM_DESCRIPTION:Adds a new alloy.]
```

`[REQUIRES_ID:refinish_steel]` declares the dependency on Refinish Metal
itself. Every module needs this line. Your Lua file does nothing but register
a listener, so without RM there to call it, the mod loads and then sits inert
with no way for the player to tell why. Declaring the dependency puts that in
front of them instead.

### Step 2: the JSON files

Copy `rm-module-materials-template.json` and
`rm-module-reactions-template.json` into `data/`. Rename them. Change the
`module` block in **both** files to your own prefix, name, and version.

Tools, plants and buildings have templates of their own:
`rm-module-tools-template.json`, `rm-module-plants-template.json` and
`rm-module-buildings-template.json`. Each starts with a reference entry
showing every field it accepts, annotated, then a short working example.

The `module` block:

| Field | Required | Notes |
|---|---|---|
| `prefix` | Yes | Ends in an underscore. Must not contain `REFINISH_STEEL_`. |
| `name` | Yes | What the log calls your module. |
| `version` | Yes | A non-empty string. |
| `depends_on` | No | Prefixes of modules to inject before yours (section 9). |
| `requires` | No | RM catalog forms your module uses (section 9). |

`prefix`, `name` and `version` are checked in the materials and the reactions
file. The two prefixes must match, or RM refuses the module. The module's name
and `depends_on` are read from the materials block first, then from the
reactions block. `requires` is gathered from every file's block. A tools,
plants or buildings file carries a `module` block too; a tools or buildings
file can supply the prefix for a module that has no materials or reactions.

### Step 3: the Lua file

Copy `rm-module-template.lua` into `scripts_modinstalled/`, rename it, and set
four values at the top:

```lua
local MODULE_ID      = "my_module"                   -- from info.txt
local MODULE_NAME    = "My Module"                   -- for log output
local MATERIALS_FILE = "my_module_materials.json"
local REACTIONS_FILE = "my_module_reactions.json"
```

That is the whole file. Everything below the configuration block is
boilerplate you should not need to touch.

Use `rm-module-template-advanced.lua` instead if you need to inspect or edit
your data before RM sees it, start helper scripts, or ship tools, plants or
buildings. Section 8 covers when that applies.

### Step 4: preflight

`preflight.py` checks your JSON offline, without launching DF. It parses the
type tables in `refinish-module-types.lua` rather than carrying its own copies,
and it checks your files against the same rules as the engine's validator.

Put the script, the types file and your JSON in one folder and run it:

```
preflight.py
refinish-module-types.lua        copied from your RM install
my_module_materials.json
my_module_reactions.json
```

```
python3 preflight.py
```

It finds `*_materials.json`, `*_reactions.json` and `*_reactions_*.json` on its
own, and the optional `*_tools.json`, `*_plants.json` and `*_buildings.json`.
Pass paths explicitly if you keep them elsewhere:

```
python3 preflight.py path/to/mats.json path/to/rxns.json --tools path/to/tools.json --plants path/to/plants.json --buildings path/to/buildings.json --types path/to/types.lua
```

Several reactions files may be passed after the materials file.

**Errors fail the run. Warnings do not.** An error is something the validator
refuses: in game that entry is left out, or the whole module when the error is
in its `module` block. A warning is either something the script cannot verify
offline, or something legal that is a known way to shoot yourself: a colour with
no fallback, a reaction with no skill, an `in_container` reagent with nothing
declaring it contains it, a `to_container` bag that is not preserved, a dye
declared as an inorganic.

Warnings are grouped by kind with a count, because a large module can produce
hundreds of the same one. `--verbose` prints them all. `--strict` makes them
fail the run, which is useful in a build script.

Beyond the validator, it also cross-checks references the engine resolves
silently: a `mat_id` carrying your prefix that no material declares, a category
written as the bare key where the full ID is required, a `PLANT_MAT:` token
naming a plant or material your plants file does not declare, and tools,
buildings and the image files they name. Those resolve to nothing in game and
produce content that quietly matches nothing, which is the worst failure mode
to debug from inside DF.

**One thing to know about nulls.** If you use the runtime resolution pattern
(section 8.4), write `"mat_id": null` explicitly rather than omitting the key.
Preflight treats an explicit null as a deliberate sentinel and warns; it treats
a missing key as a mistake and errors. That distinction is the only signal it
has.

Re-copy `refinish-module-types.lua` from your RM install whenever RM updates.
Preflight is only as current as that file.

### Step 5: test it

Enable the mod, load a save, and open RM's log panel. You are looking for a line
naming your module in RM's startup output. If anything was left out or the
module was refused, the message names the exact field.

Two things to know before you start iterating:

- **Restart fully between tests.** Quit DF, clear the cache, relaunch. A
  partially reloaded script environment produces failures that have nothing to
  do with your change.
- **`refinish-find` and `refinish-path`** are RM's diagnostic commands. Use
  them to confirm what actually landed in memory rather than assuming.

---

## 4. The materials file

A material is one inorganic: a metal, a stone, a gem, a ceramic, a glass, a
soil or a liquid.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "materials": [
        { "key": "GOLDBRONZE", "name": "gold bronze", "material_class": "METAL" }
    ]
}
```

Three fields are required: `key`, `name`, `material_class`. `key` is uppercase
with no spaces. Every field:

| Field | Type | Notes |
|---|---|---|
| `key` | string | Required. Uppercase, no spaces. Gets the prefix. |
| `name` | string | Required. The material's name in every state unless `names` says otherwise. |
| `material_class` | string | Required. Section 4.1. |
| `names` | table | Optional per-state names: `solid`, `liquid`, `gas`, `powder`, `paste`, `pressed`. Defaults: `name`, `molten <name>`, `boiling <name>`, then `name` for the rest. |
| `color` | string | A descriptor colour ID: the material's colour (section 4.3). |
| `fallback_colors` | array | Descriptor colour IDs tried in order when `color` is not loaded. |
| `liquid_color` | string | A descriptor colour ID for the liquid state. |
| `gas_color` | string | A descriptor colour ID for the gas state. |
| `dye_color` | string | A descriptor colour ID: the colour a DYE material dyes with (section 4.1). |
| `display_color` | array | ASCII mode only: the colour of the material's tile, an ANSI triple. |
| `build_color` | array | ASCII mode only: the colour of constructions built from it, an ANSI triple. |
| `tile` | number | ASCII mode only: the code of the material's tile character. |
| `value` | number | Material value. |
| `solid_density` | number | |
| `liquid_density` | number | |
| `molar_mass` | number | |
| `heat` | table | Section 4.4. |
| `strength` | table | Section 4.6. |
| `gem_names` | array | Exactly two strings. Required when `material_class` is `GEM`. |
| `block_name` | array | Exactly two strings, singular and plural: what blocks of this material are called (`["brick", "bricks"]` reads "fire clay bricks"). |
| `stone_name` | string | One string, already plural: what boulders of this material are called. |
| `soap_level` | number | |
| `reaction_classes` | array | Section 4.5. |
| `reaction_products` | array | Section 4.5. |
| `material_flags` | table | Material flags to set or clear by name, applied over the class preset. |
| `inorganic_flags` | table | Inorganic flags to set or clear by name. |
| `graphics` | table | Sprite sources for the material's slots (section 4.7). |
| `organic_category` | string | Files the material in an organic stockpile category: `Glob`, `PlantPowder` or `CreatureCheese` (section 9, RM's services). |

### 4.1 Material classes

`material_class` does two things: it picks which flags your material gets, and
it tells RM what kind of existing material to clone for structure.

| Class | Produces | Capabilities |
|---|---|---|
| `METAL` | Bars | Weapons, armour, ammo, diggers, anvils, furniture |
| `STONE` | Boulders | Construction, furniture, quern stones |
| `CERAMIC` | Boulders | Construction, furniture, tools. No weapons or armour |
| `GEM` | Rough gems | Cutting, encrusting. Requires `gem_names` |
| `GLASS` | Rough glass | Construction, furniture, trap components, crafts. No weapons or armour |
| `SOIL` | Boulders | Clears every metal, gem, ceramic and glass flag and every item capability, then sets `IS_STONE` |
| `LIQUID` | Nothing solid | Clears the same flags and capabilities, then sets `LIQUID_MISC_OTHER` |
| `DYE` | Powder (`POWDER_MISC`) | A dye every dye job takes. Declare it on a plant host, not as an inorganic (see 7.2) |
| `RAW` | Nothing by default | No preset at all. You set every flag yourself |

**On `GLASS`:** vanilla's green, clear and crystal glass are builtin material
types, not inorganics, so no vanilla world holds an `IS_GLASS` inorganic for RM
to clone. RM falls back to a ceramic donor, and the `GLASS` preset then clears
`IS_CERAMIC` and sets `IS_GLASS`. None of that is visible in play. The material
is glass.

Note that since glass is builtin, not inorganic, simply injecting a new glass
material will not automatically populate the glass furnace with reactions,
unlike inorganics such as smelted metals. Glass furnace reactions must be built
individually the way vanilla builds glass: one reaction per material per item,
at the glass furnace, taking sand straight through to the finished object.
Vanilla has no green glass bar that gets worked afterwards, and your material
does not need one either. The cost is volume, not difficulty: a full item
range runs to roughly three dozen reactions per material.

**On `DYE`:** the preset sets `IS_DYE` and the two plant powder flags every
vanilla dye carries, and RM writes the dye colour (`powder_dye`) from the
material's colour, or from `dye_color` when you set it. Declare dyes on a plant
host in your plants file (section 7.2). DF files a powder by the type of its
material: an inorganic dye is either stranded where it was made (with the plant
flags) or stored as an empty bag under Furniture and listed nowhere (without
them). Preflight warns when a dye is declared as an inorganic.

**On `RAW`:** no flags are cleared and none are set, so whatever RM cloned
carries through untouched and `material_flags` is your only control. It exists
for cases where the presets get in the way. If you are not sure you need it,
you do not.

### 4.2 Why "null" is not "zero"

Every optional field accepts `null`, and `null` means **do not write this
field**. The value from RM's clone donor stays in place.

That donor is chosen at runtime by scanning the loaded world, so it can differ
between worlds and between mod sets. A null density does not give you zero
density. It gives you an unpredictable one.

Write real numbers. The only field where null is routinely correct is `value`,
and only when you are computing it in Lua (section 8.3).

### 4.3 Colour

| Field | What it sets | Value |
|---|---|---|
| `color` | The material's colour, in every state unless `liquid_color` or `gas_color` says otherwise | A descriptor colour ID |
| `fallback_colors` | Tried in order when `color` is not loaded in the world | Descriptor colour IDs |
| `liquid_color`, `gas_color` | The liquid and gas states' colour | A descriptor colour ID |
| `dye_color` | What a DYE material dyes with, when it should not be the material's own colour | A descriptor colour ID |
| `display_color` | ASCII mode only: the colour of the material's tile | ANSI triple, each 0 to 7 |
| `build_color` | ASCII mode only: the colour of constructions built from it | ANSI triple, each 0 to 7 |
| `tile` | ASCII mode only: the material's tile character | A character code |

```json
"color": "METALLIC_BRONZE",
"fallback_colors": ["BRONZE", "DARK_GOLD", "ORANGE"]
```

`color` is the colour that matters in the graphical game. It is a descriptor
colour ID from `descriptor_color_standard.txt` (or another mod's descriptor
raws), matched case-insensitively against the colours loaded in that world.
RM writes it as the material's state colour: the colour DF tints a sprite
with where it tints one, and a dye's colour unless `dye_color` gives another.

**An ID that is not loaded fails silently.** RM tries `fallback_colors` in
order, and if none of those is loaded either, the material takes descriptor
colour 7, with no error printed anywhere. `fallback_colors` is the only
protection you get. Always supply at least one. An unloaded `dye_color` is
logged, and the material's own colour is used instead.

`display_color`, `build_color` and `tile` are ASCII-mode fields: the classic
display draws a material's tile in its colour, and nothing in the graphical
game reads them. RM writes `display_color` and `build_color` only together with
`color`; when `color` is set and they are not, RM writes a default triple.

If you use a colour ID your own raws half defines, verify it at load time. The
advanced template has a `color_exists` helper for this.

### 4.4 Temperatures

`heat` takes seven optional numbers: `spec_heat`, `melting_point`,
`boiling_point`, `ignite_point`, `heatdam_point`, `colddam_point`,
`mat_fixed_temp`.

```json
"heat": { "spec_heat": 450, "melting_point": 12718, "boiling_point": 14877 }
```

DF temperatures are in urists, not degrees. The scale is Fahrenheit offset by
9968, so 9968 U is 0 degrees F.

| Reference point | Urists |
|---|---|
| Water freezes and ice melts | 10000 |
| Comfortable room temperature | 10036 |
| Water boils | 10180 |
| Magma | 12000 |

The first row is the one to anchor on: 10000 is **freezing**, not room
temperature. Vanilla `WATER` carries `MELTING_POINT:10000` and
`BOILING_POINT:10180`, which is where those two numbers come from.

Magma sits at 12000, so a material needs a melting point **above** 12000 to
survive contact with it. Vanilla iron melts at 12718 and boils at 14877; those
are useful reference points for positioning a metal.

### 4.5 Reaction classes and reaction products

These two fields are what let materials participate in chains without anyone
hardcoding anything.

**`reaction_classes`** is a list of tags. A reagent can then say "accept
anything carrying tag X" instead of naming materials. This is the only
supported way for modules to interact. Section 9 covers it properly.

```json
"reaction_classes": ["THERMALLY_PROCESSED", "CALCIUM_SILICATE"]
```

An empty array is meaningful and worth writing: it explicitly clears anything
inherited from the clone donor.

**`reaction_products`** are named derivations. They answer the question "when a
reaction asks this material for product X, what does it hand back?" Each entry
needs `id` and `mat_id`.

```json
"reaction_products": [
    { "id": "FIRED_MAT", "mat_id": "MYMOD_STONEWARE" }
]
```

This is how vanilla fires clay. The reaction does not name any clay. It says
"any boulder that declares a FIRED_MAT product", and the output says "whatever
that material's FIRED_MAT is." One reaction then handles every clay in the
world, including clays from mods that have never heard of it.

`mat_id` must be the **full prefixed ID**. Cross-module references are resolved
in a final pass after every module has injected, so they work in either
direction, including between two modules that reference each other.

### 4.6 Strength

`strength` takes three groups, `yield`, `fracture` and `strain_at_yield`, each
with any of `IMPACT`, `COMPRESSIVE`, `TENSILE`, `TORSION`, `SHEAR` and
`BENDING`, plus a single `max_edge` and a single `absorption` (how much a
porous material such as clay or ceramic absorbs). Every value is a number or
null.

```json
"strength": {
    "yield":    { "IMPACT": 1505, "COMPRESSIVE": 1505 },
    "fracture": { "IMPACT": 2520, "COMPRESSIVE": 2520 },
    "max_edge": 10000
}
```

### 4.7 Graphics

`graphics` writes sprites into the material's own slots: `bar`, `boulder`,
`wood`, `rough`, `cheese` and `texflag`. Each slot takes a source string, or a
table with `donor` (a source string) and an optional `offset` (a number).

```json
"graphics": { "boulder": "PAGE:BOULDERS:1:15", "bar": { "donor": "INORGANIC:IRON#bar" } }
```

A source names where an existing sprite lives:

| Source | Meaning |
|---|---|
| `TEXPOS:<n>` | A literal texture position. Changes between sessions; debugging only |
| `TOOL:<itemdef code>` | A tool itemdef's sprite fields |
| `INFO:<table>:<n>` | An entry in one of DF's `*_graphics_info` tables |
| `PAGE:<page>:<x>:<y>` | A cell of a loaded tile page, by the coordinates the raws use |
| `FILE:<path>:<x>:<y>[:<width>]` | A cell of a PNG on disk, its path relative to your `data` folder (`images/...`). `<width>` is the sheet's width in tiles, for a sheet RM cannot measure on its own |
| `BUILTIN:<material>#<slot>` | A builtin material's slot |
| `INORGANIC:<id>#<slot>` | Any inorganic's slot |
| `TINT:<art name>` | Art registered with RM's sprite art, tinted to this material's colour |

A material slot does not take on the material's colour by itself: a sprite
written there shows exactly as drawn. `TINT:` is how a material gets art in its
own colour; the art is registered from Lua with `refinish-sprite-art`.

---

## 5. The reactions file

A reaction is one job: what it consumes, what it makes, where it appears, who
can do it.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "categories": [ ... ],
    "reactions": [ ... ]
}
```

### 5.1 Reaction fields

| Field | Required | Notes |
|---|---|---|
| `key` | Yes | Unique in this file. Gets the prefix. |
| `name` | Yes | What the player reads. Lowercase, verb first. |
| `building` | Yes | Where the job appears (section 5.2). |
| `skill` | No, but set it | What the worker trains (section 5.3). |
| `fuel` | No | Default false. True makes the job burn fuel; magma buildings are exempt. |
| `category` | No | The **full prefixed** category ID. |
| `description` | No | Text shown in the task pane under the job's Produces and Requires lines. A string is one entry; an array is one entry per element. |
| `building_hotkey` | No | The job's hotkey at its building, as a `df.interface_key` name. An unknown name is logged. |
| `permissions` | No | Default AUTO. Which civilizations get it (section 5.5). |
| `reaction_flags` | No | Currently just `fortress_mode`. |
| `fallback_template` | No | Override RM's structural donor choice. |
| `reagents` | Yes | At least one. Codes must be unique within the reaction. |
| `products` | Yes | At least one. |

**Always set `skill`.** RM builds a reaction by cloning an existing one for its
C++ structure, then zeroing every semantic field and rebuilding from your
definition. If you omit `skill`, the donor's skill survives, and which donor
got picked is not something you control.

`fallback_template` exists to override that donor choice by naming a vanilla
reaction code. You almost certainly do not need it. The neutral reset means a
suboptimal donor is a cosmetic issue, not a functional one.

### 5.2 Buildings

All twenty-two entries in `BUILDING_TYPES`:

| Name | Building | Type and subtype | Custom code |
|---|---|---|---|
| `WOOD_FURNACE` | Wood furnace | type {5}, subtype {0} |  |
| `SMELTER` | Smelter and magma smelter | type {5, 5}, subtype {1, 4} |  |
| `GLASS_FURNACE` | Glass furnace and magma glass furnace | type {5, 5}, subtype {2, 5} |  |
| `KILN` | Kiln and magma kiln | type {5, 5}, subtype {3, 6} |  |
| `MASON` | Mason's workshop | type {13}, subtype {2} |  |
| `CRAFTSMAN` | Craftsdwarf's workshop | type {13}, subtype {3} |  |
| `JEWELER` | Jeweler's workshop | type {13}, subtype {4} |  |
| `FORGE` | Metalsmith's forge and magma forge | type {13, 13}, subtype {5, 6} |  |
| `MECHANIC` | Mechanic's workshop | type {13}, subtype {8} |  |
| `STILL` | Still | type {13}, subtype {15} |  |
| `FARMERS` | Farmer's workshop | type {13}, subtype {1} |  |
| `KITCHEN` | Kitchen | type {13}, subtype {19} |  |
| `MILL` | Quern and millstone | type {13, 13}, subtype {17, 22} |  |
| `ASHERY` | Ashery | type {13}, subtype {20} |  |
| `DYER` | Dyer's shop | type {13}, subtype {21} |  |
| `TANNER` | Tanner's shop | type {13}, subtype {12} |  |
| `SOAP_MAKER` | Soap maker's workshop (vanilla, built as a custom workshop) | type {13}, subtype {23} | `SOAP_MAKER` |
| `SCREW_PRESS` | Screw press (vanilla, built as a custom workshop) | type {13}, subtype {23} | `SCREW_PRESS` |
| `CHEMIST` | ArgMOD's chemist; needs ArgMOD's raws | type {13}, subtype {23} | `CHEMIST` |
| `COMPOUNDER` | ArgMOD's compounder; needs ArgMOD's raws | type {13}, subtype {23} | `COMPOUNDER` |
| `RETORT` | Making Fuel's retort, a custom furnace; needs Making Fuel | type {5}, subtype {7} | `MAKING_FUEL_RETORT` |
| `NONE` | No building | none |  |

Magma variants are automatic. You do not write two reactions.

A custom workshop or furnace is a raw object rather than an enum entry, so RM
finds it by `custom_code` at build time, because its index shifts with mod load
order. A reaction assigned to one that is not installed has nowhere to appear
and vanishes without comment, so check for it (section 8.2).

To put reactions in a workshop or furnace of your own, including one your
buildings file injects (section 7.3), add an entry to `BUILDING_TYPES` in
`refinish-module-types.lua`: type `{ 13 }`, subtype `{ 23 }` for a workshop or
type `{ 5 }`, subtype `{ 7 }` for a furnace, `custom = { -1 }`, and
`custom_code` naming the building's full code.

### 5.3 Skills

All thirty-six entries in `SKILL_MAP`:

`WOOD_BURNING`, `SMELT`, `GLASSMAKER`, `POTTERY`, `CHEMISTRY`, `MASONRY`, `STONECRAFT`, `KNAPPING`, `CUT_STONE`, `CARVE_STONE`, `FORGE_WEAPON`, `FORGE_ARMOR`, `FORGE_FURNITURE`, `METALCRAFT`, `GEM_CUTTING`, `GEM_SETTING`, `WOODCRAFT`, `BONECARVE`, `LEATHERWORK`, `TANNER`, `CARPENTRY`, `MECHANICS`, `BREWING`, `COOK`, `PLANT`, `WEAVING`, `CLOTHESMAKING`, `STRAND_EXTRACT`, `SOAP_MAKING`, `MILLING`, `LYE_MAKING`, `PRESSING`, `PAPERMAKING`, `GLAZING`, `POTASH_MAKING`, `PROCESSPLANTS`

Match the skill to the building. A `SMELT` reaction at a mason's workshop will
inject and run, but the wrong dwarves will be assigned to it.

### 5.4 Categories

Categories are the collapsible headings in a workshop's job list. Optional.

```json
"categories": [
    { "key": "ALLOYS", "name": "Alloys", "parent": "" },
    { "key": "BRONZES", "name": "Bronzes", "parent": "ALLOYS" }
]
```

| Field | Required | Notes |
|---|---|---|
| `key` | Yes | Unique in this file. Becomes `<prefix>CAT_<key>`. |
| `name` | Yes | The folder's caption. |
| `parent` | Yes | An empty string means top level. A child names its parent's **bare key**, unprefixed. |
| `description` | No | A string. |
| `hotkey` | No | A string. |

There is one asymmetry worth memorising: a reaction's `category` field takes
the **full prefixed ID**, not the bare key.

```json
"category": "MYMOD_CAT_BRONZES"
```

Naming a category your module does not declare leaves the string alone, which
is how you nest under a category that already exists.

### 5.5 Permissions

Permissions decide which **civilizations** know the reaction. This affects what
caravans bring, what invaders carry, and what other sites produce. It is not
about your fortress.

**`AUTO`** (the default) evaluates every civilization and grants the reaction to
any that can operate the building (its capability gate in
`BUILDING_CAPABILITY_GATES`) and knows the metals the reaction works. A civ that
cannot smelt does not receive smelting reactions. This is right for ordinary
content.

```json
"permissions": { "mode": "AUTO" }
```

**`ENTITY_CODE`** grants only to the entity codes you name, in a non-empty
`entities` array. The same capability gate still applies on top, so naming a
civ that cannot use the building does not force it through. Codes are whatever
is loaded, vanilla or modded. `entities` is refused with any other mode.

```json
"permissions": { "mode": "ENTITY_CODE", "entities": ["MOUNTAIN", "PLAINS"] }
```

**`NONE`** grants to nobody.

```json
"permissions": { "mode": "NONE" },
"reaction_flags": { "fortress_mode": true }
```

`fortress_mode` is easy to read backwards. It is a **bypass, not a
restriction**. True means the player's own civilization type can run the
reaction *without* an explicit permit. Combined with `NONE`, the result is a
recipe the player has and no other off-type civilization does, so it never
shows up in off-type caravan stock or on a goblin's back.

Default is false, meaning the player needs a permit like everyone else.

Your buildings and tools need no permissions written: RM permits every building
definition carrying your prefix to every civilization, so it appears in the
build menu, and gives your tools to the fort's civilization.

---

## 6. Reagents and products in depth

### 6.1 Codes are local, material IDs are global

A reagent's `code` is a private label inside one reaction. It is how products
and container links point back at a slot. It never leaves the reaction and
never takes a prefix. Lowercase by convention. Two reagents in one reaction may
not share a code.

Anywhere you write `mat_id` or `metal_id`, you are naming a real loaded
inorganic. Vanilla materials use their bare ID (`IRON`, `GYPSUM`,
`QUICKLIME`). Module materials use the full prefixed ID (`MYMOD_GOLDBRONZE`).
`mat_token` names any material by its full token (section 6.9).

### 6.2 Reagent fields

| Field | Notes |
|---|---|
| `code` | Required. Unique within the reaction. |
| `type` | Required. An entry in `REAGENT_TYPES` (section 6.3, Appendix A). |
| `quantity` | Required. A number. Powders and liquids count in dimension units, where 150 is one full bag or bucket. |
| `mat_id` | An inorganic ID. Types that need a specific material require `mat_id` or `mat_token`. |
| `mat_token` | Any material by its full token (section 6.9). |
| `metal_id` | The metal an `ORE_OF` reagent's ore smelts to. |
| `tool_id` | The tool itemdef a `TOOL` reagent takes, by code: a module's, RM's catalog's (`REFINISH_SAWDUST_TOOL`), or vanilla's. |
| `reaction_class` | Accept only materials carrying this class. |
| `has_material_reaction_product` | Accept only materials that declare this product (section 6.5). |
| `has_tool_use` | A `df.tool_uses` name (Appendix B). Overrides the type's own tool use. An unknown name is logged. |
| `vector_id` | A `df.job_item_vector_id` name (Appendix B): which of DF's item lists the job searches. An unknown name is logged and the reagent keeps its default. |
| `sand_bearing` | True: the material must be sand. Sits on the reagent itself, not in `flags`. |
| `contains` | On a container: the code of the reagent it holds (section 6.4). |
| `reads` | The words DF prints for this reagent in the job's hover text and in a red row's objection, in place of its reaction class or code. |
| `flags` | A table of flags, below. |

Flags, each true or false:

| Group | Flags |
|---|---|
| Reagent | `preserve`, `in_container`, `does_not_determine_product_amount` |
| Container and item | `empty`, `non_economic`, `building_material`, `fire_safe`, `magma_safe`, `allow_melt_dump`, `unrotten`, `not_bin`, `solid`, `furniture`, `finished_goods`, `ammo`, `unimproved`, `any_raw_material` |
| Material | `wood`, `stone`, `metal`, `hard`, `woven`, `glass_material`, `grown_not_crafted`, `non_artifact` |
| Body and organic | `body_part`, `bone`, `shell`, `horn`, `pearl`, `ivory_tooth`, `totemable`, `leather`, `silk`, `yarn`, `hair_wool`, `soap`, `plant` |
| DF flags1 | `improvable`, `butcherable`, `millable`, `allow_buryable`, `undisturbed`, `collected`, `sharpenable`, `murdered`, `processable`, `cookable`, `extract_bearing_plant`, `extract_bearing_fish`, `extract_bearing_vermin`, `processable_to_vial`, `processable_to_barrel`, `tameable_vermin`, `nearby`, `milk`, `milkable`, `lye_bearing` |
| DF flags2 | `dye`, `dyeable`, `dyed`, `sewn_imageless`, `glass_making`, `screw`, `deep_material`, `melt_designated`, `allow_artifact`, `plaster_containing`, `lye_milk_free`, `blunt`, `unengraved` |
| DF flags3 | `non_absorbent`, `non_pressed`, `allow_liquid_powder`, `any_craft`, `food_storage`, `sand`, `can_use_location_reserved`, `written_on`, `edged`, `on_ground`, `divine`, `crafted_artifact`, `gem`, `empty_or_water` |

`non_artifact` belongs on every reagent that consumes its input, and above all
on a reagent of item type -1: without it, a wildcard reagent will eventually
eat an artifact. `allow_artifact` and `crafted_artifact` do the opposite and
are dangerous.

### 6.3 Choosing a reagent type

`REAGENT_TYPES` holds 252 entries. Appendix A lists every one with its item
type, material and what it needs. The ones you reach for most, grouped by what
they match:

**Bars**

| Type | Matches | Also needs |
|---|---|---|
| `BAR` | One specific metal | `mat_id` or `mat_token` |
| `BAR_ANY` | Any bar at all | |
| `BAR_COAL` | Any coal bar: coke or charcoal | |
| `BAR_COKE` | Coke | |
| `BAR_CHARCOAL` | Charcoal | |
| `BAR_POTASH` | A potash bar | |
| `BAR_ASH` | An ash bar | |
| `BAR_PEARLASH` | A pearlash bar | |

**Stones and ores**

| Type | Matches | Also needs |
|---|---|---|
| `BOULDER` | One specific stone | `mat_id` or `mat_token` |
| `BOULDER_ANY` | Any inorganic, with material picker | usually `flags.non_economic` |
| `BOULDER_UNTYPED` | Any boulder, filtered by tag | `reaction_class` |
| `FLUX` | Any flux-bearing stone | |
| `ORE_OF` | Any ore that smelts to a metal | `metal_id` |
| `ROCK` | A rock item | |

**Powders, liquids, and their containers**

| Type | Matches | Also needs |
|---|---|---|
| `POWDER` | A powder | `mat_id` or `mat_token`, optional |
| `POWDER_ANY` | Any inorganic powder | no material picker; see 6.7 |
| `WATER` | Water | a container reagent |
| `LIQUID` | A non-water builtin liquid | |
| `LIQUID_INORGANIC` | A specific inorganic liquid | `mat_id` or `mat_token` |
| `LIQUID_INORGANIC_ANY` | Any inorganic liquid, by tag | `reaction_class` |
| `BAG` | A bag | |
| `BUCKET` | A bucket | |
| `BARREL` | A barrel | |
| `JUG` | A jug | |
| `LARGE_POT` | A large pot | |
| `CONTAINER` | Anything at all. Do not use | |

**Worked items and tools**

| Type | Matches | Also needs |
|---|---|---|
| `BLOCKS` | Blocks of one material | `mat_id` or `mat_token` |
| `BLOCKS_ANY` | Blocks of anything | |
| `ROUGH` | A specific rough gem | `mat_id` or `mat_token` |
| `ROUGH_ANY` | Any rough gem, by tag | `reaction_class` |
| `STATUE` | A statue | |
| `CRAFT_ANY` | Any craft item | a `reaction_class`, always |
| `BODY_PART` | Bone, shell, horn | the creature flags, always |
| `TOOL` | One tool itemdef | `tool_id` |
| `HAS_<USE>` | Any tool with that tool use, such as `HAS_LIQUID_CONTAINER` | |

Every other entry is an item type by name, from `AXE_BATTLE` to `WINDOW`, and
matches that item in any material. Appendix A has them all.

Renamed in v4: `METAL_BAR` is now `BAR`, `COKE` is `BAR_COAL`, `ANY_ITEM` is
`ANY`, and `ANY_CRAFT` is `CRAFT_ANY`. The old names are refused.

Three traps worth naming:

- **Never use `CONTAINER`.** It is item type -1 and DF will happily grab a
  metal bar or a weapon as a "container." Use `BUCKET` or `BARREL`.
- **`ORE_OF` takes the metal, not the ore.** `"metal_id": "COPPER"` matches
  malachite, tetrahedrite, and any modded copper ore without naming any of them.
- **`CRAFT_ANY`, `BODY_PART` and `ANY` are item type -1.** They match
  everything until something narrows them. `CRAFT_ANY` needs a `reaction_class`;
  `BODY_PART` needs `flags.body_part` plus at least one of `bone`, `shell`,
  `horn`. Dropping the narrowing turns the slot into a wildcard over every item
  in the fortress.

### 6.4 The container pattern

Powders and liquids always travel in something, so they are always two
reagents. Which flags go where depends on direction.

**Output into a container.** The bag is preserved and must be empty; the
product names it.

```json
"reagents": [
    { "code": "limestone", "type": "FLUX", "quantity": 2 },
    { "code": "bag", "type": "BAG", "quantity": 1,
      "flags": { "preserve": true, "empty": true } }
],
"products": [
    { "type": "POWDER_MISC", "mat_id": "MYMOD_LIME", "count": 4,
      "dimension": 150, "to_container": "bag" }
]
```

**Input from a container.** The powder is `in_container`; the bag is preserved
and `contains` the powder.

```json
"reagents": [
    { "code": "lime", "type": "POWDER", "mat_id": "MYMOD_LIME",
      "quantity": 150, "flags": { "in_container": true } },
    { "code": "bag", "type": "BAG", "quantity": 1,
      "flags": { "preserve": true }, "contains": "lime" }
]
```

Read the pairing as: the bag **contains** the powder, the powder is **in** a
container. Put `contains` on the container, pointing at the contents. A
`contains` naming a code the reaction does not have is refused.

**A hard limit:** one slot must be satisfied by the contents of **one bag
alone**. DF will not aggregate several bags to fill a single slot. If you need
four bags' worth, that is four reagent slots.

### 6.5 The four ways a product picks its material

Exactly one. Not zero, not two.

**`mat_id`** names an inorganic output directly.

```json
{ "type": "BAR", "mat_id": "MYMOD_GOLDBRONZE", "count": 4 }
```

**`mat_token`** names any material by its token, plant materials included
(section 6.9).

**`get_material_same`** copies the material of a reagent item straight through.
The knapping pattern: the sharp rock is made of whatever rock was knapped.

```json
{ "type": "ROCK", "get_material_same": "stone", "count": 2, "force_edge": true }
```

**`get_material_product`** asks a reagent's material what it derives into, using
a product code that material declared (section 4.5). Both `reagent_code` and
`product_code` are required. This is the strongest of the four, and the one
most worth learning.

```json
"reagents": [
    { "code": "clay", "type": "BOULDER_ANY", "quantity": 1,
      "has_material_reaction_product": "FIRED_MAT" }
],
"products": [
    { "type": "BOULDER",
      "get_material_product": { "reagent_code": "clay", "product_code": "FIRED_MAT" },
      "count": 1, "dimension": 600 }
]
```

Nothing here names a clay. The reagent accepts anything that knows how to be
fired, and the product asks that same material what it fires into. One
reaction, every clay in the world, including ones added after you shipped.

When a reagent slot holds several materials, RM shares a
`get_material_same` or `get_material_product` output over the materials that
slot actually held, by volume, instead of making it all in the first item's
material. That holds for every custom reaction.

### 6.6 Product options

| Field | Default | Notes |
|---|---|---|
| `count` | 1 | How many items. With `measure`, how many stacks |
| `dimension` | 150 | 150 for a bar or a bag of powder; 600 for a boulder |
| `probability` | 100 | Percent chance. Use it for byproducts |
| `to_container` | none | Names a reagent code |
| `subtype` | none | An itemdef code such as `ITEM_TOOL_JUG`, or a module or catalog tool such as `REFINISH_CORE_DUST`. A code that does not resolve skips the product, with a log line |
| `force_edge` | false | Marks the output as edged |
| `paste` | false | Marks the output as a paste, as vanilla's paper slurry is |
| `measure` | false | With a tool `subtype`: the amount is measured from the volume that went in, in that tool's own unit, with the part under one unit banked per workshop for the next job |
| `whole` | false | With `measure`: nothing is banked, and only whole units are paid |

Product types (`PRODUCT_TYPES`): `BAR`, `BAR_COAL`, `BLOCKS`, `ROUGH`, `BOULDER`, `LIQUID_MISC`, `POWDER_MISC`, `ROCK`, `LIQUID_MISC_INORGANIC`, `BAR_POTASH`, `GLOB`, `BAR_ASH`, `BAR_PEARLASH`, `TOOL`, `CRAFTS`, `IMPROVEMENT`, or any plain `df.item_type`
name such as `TABLE`, `ANVIL`, or `WINDOW`.

Exceptions to the "exactly one material source" rule:

- **`BAR_ASH` and `BAR_PEARLASH`** carry their material in the type itself, so
  they name none at all. `BAR_COAL` and `BAR_POTASH` still take a material
  source; `BAR_COAL`'s `mat_id` names the coal: `COKE`, `CHARCOAL` or `COAL`.
- **`IMPROVEMENT`** is not an item product. See below.

New items of a tool whose definition says `"stack": true` (section 7.1) are
merged into one stack per material when a reaction makes them.

### 6.7 Improvement products

An improvement decorates an existing item rather than creating one. Glazing is
the vanilla case. It is a different C++ class with a different field set, so it
follows different rules:

```json
{
    "type": "IMPROVEMENT",
    "improvement_type": "GLAZED",
    "target_reagent": "pot",
    "get_material_product": { "reagent_code": "glaze", "product_code": "GLAZE_MAT" },
    "probability": 100
}
```

| Field | Required | Notes |
|---|---|---|
| `improvement_type` | Yes | `GLAZED` or a `df.improvement_type` name |
| `target_reagent` | Yes | The reagent code being decorated |
| `get_material_product` | Yes | Not optional here, unlike item products |
| `improvement_specific_type` | No | Default 0 |
| `probability` | No | Default 100 |

`mat_id` and `get_material_same` are **refused** on an improvement product.
RM clones a live improvement for its structure and keeps that donor's material
mode flags, which are set for material-from-reagent. Any other mode would be
injecting against flags nobody set, so validation refuses it rather than
guessing.

The reagent being decorated normally wants `flags.unimproved` so a glazed pot
cannot be glazed a second time.

### 6.8 The magnifying glass

The magnifying glass icon lets the player choose which specific material a job
uses. It appears for `BAR`, `BLOCKS`, `BOULDER`, `ROUGH`, and `SMALLGEM`
reagents when the material is left as any inorganic. `BOULDER_ANY` is built for
exactly this.

It does **not** appear for `POWDER_MISC`, in any configuration, and a `TOOL`
reagent gets none either. That is a DF engine limit, not something runtime
injection can work around. If your design needs the player to pick the
material of a powder or a tool, it needs one reaction per material.

### 6.9 One more trap: economic stone

`BOULDER_ANY` with `flags.non_economic` grabs every non-economic inorganic in
the world, and that includes processed materials your own module produced.
A grinding reaction meant for raw stone will happily eat your finished output.

The fix is to give processed materials a `reaction_class`. Carrying one makes a
material economic, which takes it out of the `non_economic` net.

### 6.10 Naming any material: `mat_token`

`mat_id` names an inorganic only. `mat_token` names any material by its full
token, the way the raws do, and it works on reagents as well as products:

```json
{ "code": "log", "type": "WOOD", "quantity": 1,
  "mat_token": "PLANT_MAT:ACACIA:WOOD" }
```

```json
{ "type": "POWDER_MISC", "mat_token": "PLANT_MAT:MYMOD_DYE_HOST:MY_DYE",
  "to_container": "bag", "count": 1, "dimension": 150 }
```

A material on your own host plant is `PLANT_MAT:<prefix + plant key>:<material
key>`. Preflight checks those against your plants file; tokens for vanilla or
another mod's plants resolve when the reaction is built.

A reagent token that does not resolve closes the slot: the reagent is given a
reaction class no material carries, so the reaction shows and cannot run, and
the log names the token. It never falls back to "any material", which would let
a slot meant for one tree's logs take every log in the fort. Give a token or a
`mat_id`, not both; if both are there, the token wins and the log says so.

---

## 7. Tools, plants and buildings

Each of these is an optional JSON file with its own `module` block, handed to
RM by your listener (section 8.1).

### 7.1 Tools

A tool is an itemdef: a hollow item form whose material comes from whatever it
is made of. Reactions take it with a `TOOL` reagent's `tool_id` and make it
with a product's `subtype`, both naming its full ID.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "tools": [
        { "key": "CRUCIBLE", "name": "crucible", "name_plural": "crucibles",
          "size": 600, "value": 1, "stack": false,
          "flags": { "hard_mat": true, "no_default_job": true },
          "tool_use": ["LIQUID_CONTAINER"] }
    ]
}
```

| Field | Notes |
|---|---|
| `key` | Required. Uppercase, no spaces. The tool's ID is `<prefix><key>`. |
| `name` | Required. |
| `name_plural`, `adjective` | Strings. Preflight requires `name_plural`. |
| `value`, `tile`, `size`, `material_size`, `capacity` | Numbers. `capacity` is the container capacity. |
| `flags` | Any of `furniture`, `inverted_tile`, `no_default_job`, `incomplete_item`, `unimprovable`, `no_default_improvements`, `hard_mat`, `metal_mat`, `soft_mat`, `stone_mat`, `wood_mat`, `sheet_mat`, `metal_weapon_mat`. |
| `tool_use` | An array of `df.tool_uses` names (Appendix B). |
| `graphics` | The tool's sprite. `donor` copies every sprite field of another tool, named as a source (section 4.7), for example `{ "donor": "TOOL:ITEM_TOOL_JUG" }`. `fields` writes named itemdef sprite fields (`texpos_item`, `texpos_stone` and the rest) one by one, each a source string or a table of `donor`, `offset` and `fill`. |
| `tint` | The name of art registered with `refinish-sprite-art`, drawn in each material's own colour. For tools whose art DF's own tint renders badly. |
| `stack` | True: a reaction's new items of this tool merge into one stack per material. |

RM builds each tool as a new, empty itemdef: a field you leave out is not
written, and nothing comes from another tool unless `graphics` names a donor.
`rm-module-tools-template.json` annotates every field.

Tools are validated one at a time like materials. A reaction with a product
whose `subtype` names a tool that was left out is left out with it, and a
reagent whose `tool_id` names no injected tool leaves its reaction out when it
is built. The tool record RM
keeps across saves is what brings your tool items back as the right tool.

### 7.2 Plants

A plant file declares host plants: plants that exist to carry materials, such
as dyes, which DF only stores and lists properly as plant materials.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "plants": [
        { "key": "DYE_HOST", "name": "dye host", "name_plural": "dye hosts",
          "materials": [
              { "key": "MY_DYE", "name": "my dye", "material_class": "DYE",
                "color": "COBALT", "fallback_colors": ["BLUE"] }
          ] }
    ]
}
```

| Field | Notes |
|---|---|
| `key` | The plant's ID is `<prefix><key>`. |
| `name`, `name_plural` | Strings. |
| `donor_plant` | The ID of a plant to clone for structure. Without it RM picks one. |
| `plant_flags` | A table of plant flags to set or clear by name; an unknown flag is logged. |
| `materials` | The host's materials. |

A plant material takes `key`, `name`, `names`, `material_class`, `color`,
`fallback_colors`, `display_color`, `build_color`, `dye_color`, `value`,
`solid_density`, `heat`, `strength`, `reaction_classes` and `graphics`, as in
section 4. Its token is `PLANT_MAT:<prefix><plant key>:<material key>`, so a
material key is written without your prefix. Always set `color`: a plant
material whose `color` and `fallback_colors` are all missing or unloaded takes
descriptor colour 7. A host that declares no materials keeps its donor's.
`rm-module-plants-template.json` annotates every field.

Plants are not checked by RM's validator: the injector guards each definition
and logs what it could not do. Run preflight, which checks them.

### 7.3 Buildings

A buildings file injects workshop and furnace definitions, graphics included,
with no raws.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "buildings": [
        { "key": "KILNETTE", "name": "Kilnette", "class": "FURNACE",
          "dim": [3, 3], "workloc": [1, 1],
          "block": [[0, 0, 0], [0, 1, 0], [0, 0, 0]],
          "build_items": [ { "type": "BLOCKS", "quantity": 3 } ],
          "build_labors": ["MASON"],
          "graphics": { "image": "images/kilnette.png", "tile_dim": 32 } }
    ]
}
```

| Field | Default | Notes |
|---|---|---|
| `key` | | Required. The building's code is `<prefix><key>`. |
| `name` | the key | Preflight requires it. |
| `class` | `WORKSHOP` | `WORKSHOP` or `FURNACE`. Preflight requires it written. |
| `dim` | `[3, 3]` | Width and height in tiles. |
| `workloc` | the centre | Where the worker stands. |
| `block` | none | Rows of 0 and 1: the tiles that block movement. |
| `build_stages` | 3 | |
| `build_key` | 0 | A `df.interface_key` name or number; an unknown name is logged. |
| `needs_magma` | false | |
| `build_labors` | `["MASON"]` | Labor names. |
| `labor_description` | none | |
| `tooltip` | none | An array of lines. |
| `name_color` | `[0, 7, 1]` | |
| `build_items` | none | Each: `type` (a `df.item_type` name; `NONE` takes any item, narrowed by flags), `subtype` (a tool ID or a number), `mat` (a material token; one that does not resolve stops the building injecting), `quantity` (default 1), `reaction_class`, and `flags1`, `flags2`, `flags3` (DF's job item flags by name, each true or false). Preflight requires at least one. |
| `graphics` | none | `image` (a PNG path relative to your `data` folder, such as `images/kilnette.png`), `tile_dim` (default 32), `sheet_dim` (`[columns, rows]`, default `[8 x width, height + 1]`), `origin` (`[column, row]`), `overlay` (default true), `list_icon` (`[column, row]` on the sheet), or `icon_image` and `icon_dim` for a separate icon file, which wins when both are set. |

The sheet holds the building in blocks of width x (height + 1) tiles. The
first four blocks, left to right, are build stages 3, 2, 1 and 0; with
`overlay` on, four more blocks follow for the overlay layer.
`rm-module-buildings-template.json` annotates every field.

Buildings are not checked by RM's validator: the injector guards each
definition and logs what it could not do. A sheet whose cell count does not
match its declared size is not used: the building is injected without
graphics, and the log gives both counts. RM permits your
buildings to every civilization and puts their icons in the build menu.

Reactions reach your building through a `BUILDING_TYPES` entry (section 5.2).

---

## 8. The advanced Lua shell

The basic template hands RM two file paths. That is correct whenever your JSON
is complete on disk and nothing in it depends on the world that just loaded.

The advanced template loads the JSON itself, edits the parsed tables in memory,
and hands RM finished data. Use it when you need to ask a question your JSON
cannot answer, start helper scripts, or ship tools, plants or buildings:

- Which sand does this world have?
- Is my raws half actually installed?
- What should this alloy be worth, given local metal prices?

Every system in that template is independent. Delete what you do not need.

### 8.1 The listener contract

Register once, at load, with `register_listener(name, callback, mod_id)` on
`refinish-module-engine`. Both templates do this for you (`register_with_rm`
in the advanced one).

`MODULE_ID` is your `info.txt` ID. With it, RM only calls your listener in
worlds where your mod is active. Without it, your listener is called in every
world.

RM calls your listener once per startup, after world raws are loaded, before
injection. Return a table holding any of:

| Key | What it is |
|---|---|
| `materials_json`, `reactions_json`, `tools_json`, `plants_json`, `buildings_json` | Paths to your JSON files |
| `materials`, `reactions`, `categories`, `tools`, `plants`, `buildings` | Finished tables instead of paths, alongside a `module` block on the same table |
| `module` | The module block, for finished tables |
| `buildings_dir` | With finished `buildings`: the folder their image paths are relative to |
| `data_dir` | With no JSON path to take it from: the folder `FILE:` sprite sources are relative to |
| `start` | A function RM runs once your module is accepted and injected |
| `stop` | A function RM runs before your assets leave RAM |
| `on_materials_injected` | A function RM runs once your materials are in the array, before your buildings, categories and reactions |

```lua
return { materials_json = path1, reactions_json = path2,
         start = start_helpers, stop = stop_helpers }
```

A file that will not parse refuses the module. A listener that errors, or
returns nothing, refuses it too, and the log says which; the usual cause of
nothing is a `MODULE_ID` that does not match `info.txt`, which leaves the
module unable to find its own folder. Return nothing on any failure that would
otherwise inject partial content.

### 8.2 Raw dependency checks

Injection is forgiving in the worst possible way. A missing material resolves
to index -1 and the reaction silently accepts nothing. A missing colour resolves
to grey. The player gets a half-working mod and no way to find out why.

The template has three checks: `inorganic_exists`, `color_exists`,
`workshop_exists`, run by `check_raw_dependencies`. Fill in the lists, and a
missing dependency becomes one clear message instead of a mystery.

Two notes on how to use them:

- **Pick sentinels, not exhaustive lists.** One material that only your raws
  half defines proves the whole file loaded. Checking all twenty-six just makes
  a longer message.
- **Report, do not gate.** A missing dependency degrades the module; it does
  not disable it. Say what is wrong and load anyway.

### 8.3 Computing values

A hardcoded alloy value is a guess about a world you have not seen. Metal
prices shift with the mods installed, and an alloy priced against vanilla iron
can end up worth less than its own ingredients.

```json
"value": null,
"value_from_reaction": "MAKE_GOLDBRONZE"
```

`value_from_reaction` is not part of RM's schema. RM ignores unknown fields, so
it passes through untouched and your Lua file reads it. The template's
`calculate_weighted_value` averages the live material values of the reaction's
`BAR` reagents, weighted by quantity.

### 8.4 Resolving materials at runtime

Sand is the standard case. Vanilla ships five sand materials and mods add or
remove more, so your JSON cannot name one. But it cannot leave the slot as a
wildcard either: a `POWDER` reagent with no material matches *any* powder in a
bag, and once two such slots sit in one reaction, DF has nothing to tell them
apart and reagent matching goes non-deterministic.

The pattern:

1. Write `"mat_id": null` as a sentinel meaning "resolve at load time."
2. Scan the live raws for something matching a property, such as the
   `SOIL_SAND` flag.
3. Write the real ID into the parsed table before returning it.
4. If nothing matches, **remove the affected content** so the module degrades
   cleanly instead of injecting jobs that can never start.

The engine never sees the null.

Nothing in `resolve_target_id` is sand-specific except the flag it tests. Swap
that test and reuse the shape.

### 8.5 Helper scripts

Some things the schema cannot express: injecting a button into a workshop's
order list, hooking job completion, fixing up created items. Those go in
companion scripts exposing `start()` and `stop()`, listed in `HELPER_SCRIPTS`.

The template returns `start = start_helpers` and `stop = stop_helpers`. RM runs
`start` only once your module is accepted and injected, and runs `stop` before
every save, at a shutdown and at the map unload, before your assets leave RAM.
So no helper outlives the data it reads, and a module RM refuses starts
nothing. You need no map unload hook of your own.

Never start a script from the listener itself: it runs before validation, and
before your data is in RAM.

---

## 9. Working with other modules

### The rule

**Avoid direct reference to another module's material by `mat_id`.**

If that module is not installed, your reagent resolves to nothing and the
reaction silently accepts no input. The player sees a job that never starts.

### The mechanism

Modules interact best through shared `reaction_class` tags.

A material opts in by carrying a tag:

```json
{
    "key": "SLAG",
    "reaction_classes": ["THERMALLY_PROCESSED", "BYPRODUCT"]
}
```

A reaction anywhere asks for the tag, not the material:

```json
{
    "code": "slag",
    "type": "BOULDER_UNTYPED",
    "quantity": 3,
    "reaction_class": "THERMALLY_PROCESSED"
}
```

Neither side knows the other exists. If the producing module is not installed,
the reaction simply finds no input; it does not break. If three modules produce
tagged materials, all three feed the same reaction.

Name tags after the **process**, not after your material. `THERMALLY_PROCESSED`
invites participation. `MYMOD_SLAG` does not.

### `depends_on`

When you genuinely must name another module's material, declare it:

```json
"module": {
    "prefix": "MYNEWMOD_",
    "name": "My New Module",
    "version": "1.0",
    "depends_on": ["MYOLDMOD_"]
}
```

Each entry is a prefix ending in an underscore, and not your own. RM injects
the named modules first. A module whose dependency is missing is skipped, and
the log names what it needed. This is for `reaction_products` links and similar
hard references, not a substitute for reaction classes.

Cross-module `reaction_products` are resolved in a final pass after every module
has injected, so they work in either direction, including mutual references.

### RM's catalog: `requires`

RM carries a catalog of general item forms that any module may use: dust
(`REFINISH_CORE_DUST`, always present) and forms injected only when an accepted
module asks for them, each a tool named `REFINISH_<FORM>_TOOL`:

- `GRAVEL`, with its crush reactions at the mason's workshop and the stone
  aggregate twins (`REFINISH_CORE_AGG_<stone>`) that carry the AGGREGATE class;
- the byproduct forms `SAWDUST`, `BARK`, `SCRAP`, `CULLET` and `CRUST` (with
  its gall material);
- `HEAP`, a bar sized heap (600) for loose bulk, carrying the slag
  material: while it is injected RM pays an ore smelt's whole loss as slag
  heaps, and recipes take slag by `AGGREGATE` or `SLAG`.

A form is a hollow item type; what it is comes from the material you put on
it. Ask for one rather than defining your own, so players never carry two of
the same thing. The catalog holds only content many modules can use:
anything that only makes sense inside your module stays in your module.

Reaction keys (`refinish-reaction-keys`) are the exception to sharing: give
your keys a tool of your own, because a watcher sweeps its key tool by subtype
and removes keys it does not recognise.

Ask for the forms you use in any of your module blocks:

```json
"module": {
    "prefix": "MYMOD_",
    "name": "My Module",
    "version": "1.0",
    "requires": ["GRAVEL", "SAWDUST"]
}
```

RM injects every requested form before your module, so your reactions can name
`REFINISH_SAWDUST_TOOL` as a `tool_id`. A name that is not in the catalog this
session is logged as an error naming your module, and your module runs without
it.

If your module is a Lua listener returning one table, put `requires` in that
table's module block, or gather it there from your other files' blocks (see how
`making_fuel.lua` does it).

### RM's services

RM runs shared systems once for every module. Each publishes a handle on `_G`
(or is a script you `reqscript`), and the table below lists its calls.
Make your calls from `start` and undo them in `stop`.

| Service | Handle | Calls |
|---|---|---|
| Byproducts | `_G.refinish_byproducts_api` | `register(owner, spec)`, `unregister(owner)`, `credit(mode, form, building_id, amount)`. Pays your streams from the material a job measurably destroys; RM's dust, and gravel while `GRAVEL` is registered, are paid first and your streams share what is left. |
| Adaptive reactions | `_G.refinish_adaptive_api` | `register(owner, { valuation = ..., reactions = ... })`, `unregister(owner)`, `register_alias(clone_code, base_code)`, `resweep_orphans()`. Product counts written from the value of what went in. |
| Loop dispatcher | `_G.refinish_dispatch_api` | `subscribe(name, { tier or every, jobs, fn, paused })`, `unsubscribe(name)`. Tiers: `frame` 1, `fast` 5, `steady` 10, `slow` 100 frames. One shared walk of the job list. |
| Material classes | `_G.refinish_class_api` | `grant(owner, { class = ..., ids = { ... } })`. Gives existing materials a reaction class while RM's data is loaded; every grant is taken back before a save. |
| Organic stockpiles | `_G.refinish_organic_api` | `claim(owner, category, select, opts)`, `unclaim(owner)`. Or `organic_category` on a material (section 4). |
| Stockpile windows | `_G.refinish_window_api` | `claim`, `unclaim`, `hide`, `unhide`, `label`, `unlabel`, `tagged`. Lets hidden twin materials stockpile as their sources, hides materials from menus, relabels stockpile rows. A claim's or hide's `menu_tag` also goes on its twins' names while a work order's conditions are open, since a condition's Material list draws each row from the material's name: "clay (binder)". `tagged()` lists every tagged material. |
| Fertilize service | `_G.refinish_fertilize_api` | `request(owner)`, `withdraw(owner)`. Off unless a module requests it: DF's fertilize jobs then take any tool whose material carries the `FERTILIZER` class, potash last. |
| Bank readout | `_G.refinish_bank_providers` | Set `.<name> = { order = n, fn = function(building) ... end }`. Rows on the panel beside a building's sheet. |
| Module settings | `refinish-module-config` | `register(module_id, spec)`, `get(module_id, key)`, `set`, `cycle`, `list`, `refused`. Settings pages on RM's HUD (below). |
| Persistent banks | `refinish-persist-banks` | `open(name)`: a table saved with the fort, under site data `refinish_bank:<name>`. |
| Reaction keys | `refinish-reaction-keys` | `ledger()`, `sites(kind_fn)`, `scrap(item)`, `busy(item)`, `at_pos(item, pos)`. A reaction that lights only where something is present. |
| Job surgery | `refinish-job-surgery` | `holds_nothing(job)`, `count(job, owns)`, `append(job, proto)`, `erase(job, owns, opts)`. The safe way to change a live job's item filters. |
| Lookups | `refinish-resolve` | `material(token)`, `material_index(token)`, `tool_subtype(code, item_type)`, `reaction(code)`, `reactions_prefixed(prefix)`, `invalidate()`. |
| Sprites | `refinish-sprite-art`, `refinish-sprite-engine` | `register(name, charmap, profile)` for `TINT:` art; `apply_to_material`, `apply_to_tool`, `apply_edits`. |
| Logging | `refinish-log` | `compose(system, subsystem, subject, type, message)`: a line in RM's log grammar, for `_G.refinish_log_event`. |

**Module settings.** `register(module_id, spec)` puts a section on RM's HUD
settings pages. `spec` has `title`, an optional `on_change(key, value, old)`
that may refuse a change by returning false and a reason, and `settings`: each
with `key` (upper case), `label`, `kind` (`toggle`, `choice` or `number`),
`options` (each `{ value = ..., label = ... }`; a toggle may leave them out),
`default` (one of the options), `applies` (`now`, `restart` or `reload`;
default `now`), `restart_note` and `description`. Limits: a module ID of 1 to
48 letters, digits or underscores; up to 16 settings; a title of up to 24
characters, a key of 32, a label of 22, 2 to 12 options of up to 14 characters,
a description of up to 600 and a restart note of up to 48. A spec that breaks a
limit is refused whole with an error, and `get` then answers nil: treat nil as
"use your default". Values are stored per fort.

---

## 10. Troubleshooting

### Module never appears in the log

The listener never registered or never returned. Check in order:

- Is the Lua file in `scripts_modinstalled/`?
- Does `MODULE_ID` exactly match `[ID:...]` in info.txt? A mismatch makes the
  path lookup fail, and, when passed as `mod_id`, the log warns that it
  matches no installed mod.
- Is RM itself installed and enabled?

### "Rejected", "Omitted" and "left out"

RM checks your materials, reactions, categories and tools one entry at a time.
A bad entry is **omitted** and named, and the rest of your module still runs. A
reaction that names an omitted material (by `mat_id` or an `INORGANIC:`
`mat_token`), or names an omitted tool as a product `subtype`, is omitted with
it.

The module is **rejected** whole when its listener errors or returns nothing,
when a JSON file will not parse, when its materials or reactions `module` block
is invalid, when nothing valid is left in its materials or reactions, when the
materials and reactions prefixes differ, when no file carries a prefix, or when
its prefix overlaps another module's or `REFINISH_STEEL_`.

The message names the exact field. Common causes:

- `module.prefix` does not end in an underscore.
- The materials and reactions prefixes differ.
- A material or tool `key` has lowercase letters or a space.
- A `material_class` of `GEM` with no `gem_names`.
- A product with zero or two material sources.
- A `contains` naming a reagent code that does not exist.
- A reagent type that no longer exists (section 6.3, renamed in v4).

### "prefix overlaps"

Another module's prefix is a stem of yours or vice versa. Rename.

### Material is the wrong colour

`color` names a descriptor colour ID that is not loaded in this world, and no
`fallback_colors` entry is loaded either, so RM used descriptor colour 7. Add
`fallback_colors`, and add a `color_exists` check so it stops being silent.

### Reaction appears but never starts

Almost always a reagent that matches nothing:

- A `mat_id` naming a material that does not exist. Check with `refinish-find`.
- A `mat_token` that did not resolve: the log names it, and the slot is closed.
- A container slot needing more than one bag's contents.
- A `reaction_class` no loaded material carries.
- Conflicting filters, such as a `mat_id` and `sand_bearing` on the same slot.

### Reaction does not appear at all

- It was omitted: the log says why.
- The `category` is not the full prefixed ID.
- The building is a custom workshop that is not installed.
- Permissions excluded the player's civilization, and `fortress_mode` is false.

### Reaction eats the wrong thing

A `BOULDER_ANY` with `non_economic` is catching your own processed materials.
Give those a `reaction_class` (section 6.9).

### Diagnostics

- `preflight.py` catches schema and reference problems before you launch DF.
  Run it first; it is faster than any in-game test.
- `refinish-find` locates injected content in memory.
- `refinish-path` traces how something was built.
- RM's log panel records every injection decision, including which structural
  template each reaction cloned. Set Log Detail to Debug to see all of it.

---

## 11. Rules and conventions

### Hard rules

1. **Never reference another module's material by `mat_id`** without declaring
   `depends_on`. Use reaction classes.
2. **Your prefix must not overlap anyone else's**, in either direction, nor
   RM's own.
3. **Verify vanilla assets you depend on.** Another mod may have cut them.
4. **Start your scripts in `start` and stop them in `stop`**, never from the
   listener.

### Naming

- **Material, tool, plant and building keys:** uppercase, underscores, no
  spaces. Descriptive of the thing, not the process. `GOLDBRONZE`, not
  `ALLOY_3`.
- **Reaction keys:** uppercase, verb first. `MAKE_GOLDBRONZE`, `GRIND_CEMENT`.
- **Reaction names:** lowercase, verb first, the way vanilla phrases it.
  `make gold bronze bars`.
- **Reagent codes:** lowercase, local, descriptive. `copper_bar`, `sand_bag_1`.

### Content

- Set `skill` on every reaction.
- Set real numbers rather than leaving nulls, except where you compute them.
- Always supply `fallback_colors`.
- Give processed materials a `reaction_class`, both for interoperation and to
  keep them out of `non_economic` filters.
- Put `non_artifact` on every reagent that consumes a wildcard input.

### Reference files

| File | What it is |
|---|---|
| `refinish-module-types.lua` | The authoritative list of every reagent type, product type, building, skill, material class, item vector and tool use |
| `rm-module-materials-template.json` | Annotated materials template |
| `rm-module-reactions-template.json` | Annotated reactions template |
| `rm-module-tools-template.json` | Annotated tools template |
| `rm-module-plants-template.json` | Annotated plants template |
| `rm-module-buildings-template.json` | Annotated buildings template |
| `rm-module-template.lua` | Basic Lua shell |
| `rm-module-template-advanced.lua` | Full Lua shell with runtime helpers and start and stop hooks |
| `preflight.py` | Offline schema and reference checker |

When this guide and `refinish-module-types.lua` disagree, the Lua file is
correct. It is what the engine actually reads.

---

## Appendix A: every reagent type

All 252 entries in `REAGENT_TYPES`, as the code defines them. Item is the item
type the slot takes (-1 is any item). Material is the material class: any,
inorganic, or a builtin material. Notes are what the entry needs or sets.

| Type | Item | Material | Notes |
|---|---|---|---|
| `ALTAR` | TOOL | any | item_subtype `ITEM_TOOL_ALTAR` |
| `AMMO` | AMMO | any |  |
| `AMULET` | AMULET | any |  |
| `ANIMALTRAP` | ANIMALTRAP | any |  |
| `ANVIL` | ANVIL | any |  |
| `ANY` | -1 | any |  |
| `ARMORSTAND` | ARMORSTAND | any |  |
| `ARMOR` | ARMOR | any |  |
| `ARROWS` | AMMO | any | item_subtype `ITEM_AMMO_ARROWS` |
| `AXE_BATTLE` | WEAPON | any | item_subtype `ITEM_WEAPON_AXE_BATTLE` |
| `AXE_GREAT` | WEAPON | any | item_subtype `ITEM_WEAPON_AXE_GREAT` |
| `AXE_TRAINING` | WEAPON | any | item_subtype `ITEM_WEAPON_AXE_TRAINING` |
| `BACKPACK` | BACKPACK | any |  |
| `BAG` | BAG | any |  |
| `BALLISTAARROWHEAD` | BALLISTAARROWHEAD | any |  |
| `BALLISTAPARTS` | BALLISTAPARTS | any |  |
| `BARREL` | BARREL | any |  |
| `BAR_ANY` | BAR | any |  |
| `BAR_ASH` | BAR | builtin 9 |  |
| `BAR_CHARCOAL` | BAR | builtin 7 |  |
| `BAR_COAL` | BAR | builtin 7 |  |
| `BAR_COKE` | BAR | builtin 7 |  |
| `BAR_PEARLASH` | BAR | builtin 10 |  |
| `BAR_POTASH` | BAR | builtin 8 |  |
| `BAR` | BAR | inorganic | `mat_id` or `mat_token` |
| `BED` | BED | any |  |
| `BIN` | BIN | any |  |
| `BLOCKS_ANY` | BLOCKS | any |  |
| `BLOCKS` | BLOCKS | inorganic | `mat_id` or `mat_token` |
| `BLOWDARTS` | AMMO | any | item_subtype `ITEM_AMMO_BLOWDARTS` |
| `BLOWGUN` | WEAPON | any | item_subtype `ITEM_WEAPON_BLOWGUN` |
| `BODY_PART` | -1 | any |  |
| `BOLTS` | AMMO | any | item_subtype `ITEM_AMMO_BOLTS` |
| `BOLT_THROWER_PARTS` | BOLT_THROWER_PARTS | any |  |
| `BOOKCASE` | TOOL | any | item_subtype `ITEM_TOOL_BOOKCASE` |
| `BOOK_BINDING` | TOOL | any | item_subtype `ITEM_TOOL_BOOK_BINDING` |
| `BOOK` | BOOK | any |  |
| `BOOTS_LOW` | SHOES | any | item_subtype `ITEM_SHOES_BOOTS_LOW` |
| `BOOTS` | SHOES | any | item_subtype `ITEM_SHOES_BOOTS` |
| `BOULDER_ANY` | BOULDER | inorganic |  |
| `BOULDER_UNTYPED` | 4 | any |  |
| `BOULDER` | BOULDER | inorganic | `mat_id` or `mat_token` |
| `BOWL` | TOOL | any | item_subtype `ITEM_TOOL_BOWL` |
| `BOW` | WEAPON | any | item_subtype `ITEM_WEAPON_BOW` |
| `BOX` | BOX | any |  |
| `BRACELET` | BRACELET | any |  |
| `BRAIES` | PANTS | any | item_subtype `ITEM_PANTS_BRAIES` |
| `BRANCH` | BRANCH | any |  |
| `BREASTPLATE` | ARMOR | any | item_subtype `ITEM_ARMOR_BREASTPLATE` |
| `BUCKET` | BUCKET | any |  |
| `CABINET` | CABINET | any |  |
| `CAGE` | CAGE | any |  |
| `CAPE` | ARMOR | any | item_subtype `ITEM_ARMOR_CAPE` |
| `CAP` | HELM | any | item_subtype `ITEM_HELM_CAP` |
| `CATAPULTPARTS` | CATAPULTPARTS | any |  |
| `CAULDRON` | TOOL | any | item_subtype `ITEM_TOOL_CAULDRON` |
| `CHAIN` | CHAIN | any |  |
| `CHAIR` | CHAIR | any |  |
| `CHAUSSE` | SHOES | any | item_subtype `ITEM_SHOES_CHAUSSE` |
| `CHEESE` | CHEESE | any |  |
| `CLOAK` | ARMOR | any | item_subtype `ITEM_ARMOR_CLOAK` |
| `CLOTH` | CLOTH | any |  |
| `COAT` | ARMOR | any | item_subtype `ITEM_ARMOR_COAT` |
| `COFFIN` | COFFIN | any |  |
| `COIN` | COIN | any |  |
| `CONTAINER` | -1 | any |  |
| `CORPSEPIECE` | CORPSEPIECE | any |  |
| `CORPSE` | CORPSE | any |  |
| `CRAFT_ANY` | -1 | any | sets flags3.any_craft |
| `CROSSBOW` | WEAPON | any | item_subtype `ITEM_WEAPON_CROSSBOW` |
| `CROWN` | CROWN | any |  |
| `CRUTCH` | CRUTCH | any |  |
| `DAGGER_LARGE` | WEAPON | any | item_subtype `ITEM_WEAPON_DAGGER_LARGE` |
| `DIE` | TOOL | any | item_subtype `ITEM_TOOL_DIE` |
| `DISPLAY_CASE` | TOOL | any | item_subtype `ITEM_TOOL_DISPLAY_CASE` |
| `DOOR` | DOOR | any |  |
| `DRESS` | ARMOR | any | item_subtype `ITEM_ARMOR_DRESS` |
| `DRINK` | DRINK | any |  |
| `EARRING` | EARRING | any |  |
| `EGG` | EGG | any |  |
| `ENORMOUSCORKSCREW` | TRAPCOMP | any | item_subtype `ITEM_TRAPCOMP_ENORMOUSCORKSCREW` |
| `FIGURINE` | FIGURINE | any |  |
| `FISH_RAW` | FISH_RAW | any |  |
| `FISH` | FISH | any |  |
| `FLAIL` | WEAPON | any | item_subtype `ITEM_WEAPON_FLAIL` |
| `FLASK` | FLASK | any |  |
| `FLOODGATE` | FLOODGATE | any |  |
| `FLUX` | BOULDER | any | class FLUX |
| `FOOD` | FOOD | any |  |
| `FOOTWEAR_ANY` | SHOES | any |  |
| `FORK_CARVING` | TOOL | any | item_subtype `ITEM_TOOL_FORK_CARVING` |
| `GAUNTLETS` | GLOVES | any | item_subtype `ITEM_GLOVES_GAUNTLETS` |
| `GEM_ANY` | GEM | any |  |
| `GEM` | GEM | inorganic | `mat_id` or `mat_token` |
| `GIANTAXEBLADE` | TRAPCOMP | any | item_subtype `ITEM_TRAPCOMP_GIANTAXEBLADE` |
| `GLOB` | GLOB | any |  |
| `GLOVES` | GLOVES | any | item_subtype `ITEM_GLOVES_GLOVES` |
| `GOBLET` | GOBLET | any |  |
| `GRATE` | GRATE | any |  |
| `GREAVES` | PANTS | any | item_subtype `ITEM_PANTS_GREAVES` |
| `HALBERD` | WEAPON | any | item_subtype `ITEM_WEAPON_HALBERD` |
| `HAMMER_WAR` | WEAPON | any | item_subtype `ITEM_WEAPON_HAMMER_WAR` |
| `HANDWEAR_ANY` | GLOVES | any |  |
| `HAS_BOOKCASE` | TOOL | any | tool use BOOKCASE |
| `HAS_CONTAIN_WRITING` | TOOL | any | tool use CONTAIN_WRITING |
| `HAS_DISPLAY_OBJECT` | TOOL | any | tool use DISPLAY_OBJECT |
| `HAS_DIVINATION` | TOOL | any | tool use DIVINATION |
| `HAS_FOOD_STORAGE` | TOOL | any | tool use FOOD_STORAGE |
| `HAS_GAMES_OF_CHANCE` | TOOL | any | tool use GAMES_OF_CHANCE |
| `HAS_GRIND_POWDER_RECEPTACLE` | TOOL | any | tool use GRIND_POWDER_RECEPTACLE |
| `HAS_HEAVY_OBJECT_HAULING` | TOOL | any | tool use HEAVY_OBJECT_HAULING |
| `HAS_HIVE` | TOOL | any | tool use HIVE |
| `HAS_HOLD_MEAT_FOR_CARVING` | TOOL | any | tool use HOLD_MEAT_FOR_CARVING |
| `HAS_LIQUID_CONTAINER` | TOOL | any | tool use LIQUID_CONTAINER |
| `HAS_LIQUID_COOKING` | TOOL | any | tool use LIQUID_COOKING |
| `HAS_LIQUID_SCOOP` | TOOL | any | tool use LIQUID_SCOOP |
| `HAS_MEAL_CONTAINER` | TOOL | any | tool use MEAL_CONTAINER |
| `HAS_MEAT_BONING` | TOOL | any | tool use MEAT_BONING |
| `HAS_MEAT_CARVING` | TOOL | any | tool use MEAT_CARVING |
| `HAS_MEAT_CLEAVING` | TOOL | any | tool use MEAT_CLEAVING |
| `HAS_MEAT_SLICING` | TOOL | any | tool use MEAT_SLICING |
| `HAS_NEST_BOX` | TOOL | any | tool use NEST_BOX |
| `HAS_PLACE_OFFERING` | TOOL | any | tool use PLACE_OFFERING |
| `HAS_PROTECT_FOLDED_SHEETS` | TOOL | any | tool use PROTECT_FOLDED_SHEETS |
| `HAS_ROLL_UP_SHEET` | TOOL | any | tool use ROLL_UP_SHEET |
| `HAS_SMALL_OBJECT_STORAGE` | TOOL | any | tool use SMALL_OBJECT_STORAGE |
| `HAS_STAND_AND_WORK_ABOVE` | TOOL | any | tool use STAND_AND_WORK_ABOVE |
| `HAS_TRACK_CART` | TOOL | any | tool use TRACK_CART |
| `HATCH_COVER` | HATCH_COVER | any |  |
| `HEADWEAR_ANY` | HELM | any |  |
| `HELM` | HELM | any | item_subtype `ITEM_HELM_HELM` |
| `HELVE` | TOOL | any | item_subtype `ITEM_TOOL_HELVE` |
| `HIVE` | TOOL | any | item_subtype `ITEM_TOOL_HIVE` |
| `HONEYCOMB` | TOOL | any | item_subtype `ITEM_TOOL_HONEYCOMB` |
| `HOOD` | HELM | any | item_subtype `ITEM_HELM_HOOD` |
| `INSTRUMENT` | INSTRUMENT | any |  |
| `JUG` | TOOL | any | item_subtype `ITEM_TOOL_JUG` |
| `KNIFE_BONING` | TOOL | any | item_subtype `ITEM_TOOL_KNIFE_BONING` |
| `KNIFE_CARVING` | TOOL | any | item_subtype `ITEM_TOOL_KNIFE_CARVING` |
| `KNIFE_MEAT_CLEAVER` | TOOL | any | item_subtype `ITEM_TOOL_MEAT_CLEAVER` |
| `KNIFE_SLICING` | TOOL | any | item_subtype `ITEM_TOOL_KNIFE_SLICING` |
| `LADLE` | TOOL | any | item_subtype `ITEM_TOOL_LADLE` |
| `LARGESERRATEDDISC` | TRAPCOMP | any | item_subtype `ITEM_TRAPCOMP_LARGESERRATEDDISC` |
| `LARGE_POT` | TOOL | any | item_subtype `ITEM_TOOL_LARGE_POT` |
| `LEATHER_ARMOR` | ARMOR | any | item_subtype `ITEM_ARMOR_LEATHER_ARMOR` |
| `LEGGINGS` | PANTS | any | item_subtype `ITEM_PANTS_LEGGINGS` |
| `LEGWEAR_ANY` | PANTS | any |  |
| `LIQUID_INORGANIC_ANY` | LIQUID_MISC | inorganic |  |
| `LIQUID_INORGANIC` | LIQUID_MISC | inorganic | `mat_id` or `mat_token` |
| `LIQUID_MISC` | LIQUID_MISC | any |  |
| `LIQUID` | LIQUID_MISC | nil |  |
| `LOINCLOTH` | PANTS | any | item_subtype `ITEM_PANTS_LOINCLOTH` |
| `LYE` | LIQUID_MISC | builtin LYE |  |
| `MACE` | WEAPON | any | item_subtype `ITEM_WEAPON_MACE` |
| `MAIL_SHIRT` | ARMOR | any | item_subtype `ITEM_ARMOR_MAIL_SHIRT` |
| `MASK` | HELM | any | item_subtype `ITEM_HELM_MASK` |
| `MAUL` | WEAPON | any | item_subtype `ITEM_WEAPON_MAUL` |
| `MEAT` | MEAT | any |  |
| `MENACINGSPIKE` | TRAPCOMP | any | item_subtype `ITEM_TRAPCOMP_MENACINGSPIKE` |
| `MILLSTONE` | MILLSTONE | any |  |
| `MINECART` | TOOL | any | item_subtype `ITEM_TOOL_MINECART` |
| `MITTENS` | GLOVES | any | item_subtype `ITEM_GLOVES_MITTENS` |
| `MORNINGSTAR` | WEAPON | any | item_subtype `ITEM_WEAPON_MORNINGSTAR` |
| `MORTAR` | TOOL | any | item_subtype `ITEM_TOOL_MORTAR` |
| `NEST_BOX` | TOOL | any | item_subtype `ITEM_TOOL_NEST_BOX` |
| `ORE_OF` | BOULDER | any | `metal_id` |
| `ORTHOPEDIC_CAST` | ORTHOPEDIC_CAST | any |  |
| `PANTS` | PANTS | any |  |
| `PEDESTAL` | TOOL | any | item_subtype `ITEM_TOOL_PEDESTAL` |
| `PESTLE` | TOOL | any | item_subtype `ITEM_TOOL_PESTLE` |
| `PET` | PET | any |  |
| `PICK_GREAT` | WEAPON | any | item_subtype `ITEM_WEAPON_PICK_GREAT` |
| `PICK` | WEAPON | any | item_subtype `ITEM_WEAPON_PICK` |
| `PIKE` | WEAPON | any | item_subtype `ITEM_WEAPON_PIKE` |
| `PIPE_SECTION` | PIPE_SECTION | any |  |
| `PLANT_GROWTH` | PLANT_GROWTH | any |  |
| `PLANT` | PLANT | any |  |
| `POUCH` | TOOL | any | item_subtype `ITEM_TOOL_POUCH` |
| `POWDER_ANY` | POWDER_MISC | inorganic |  |
| `POWDER` | POWDER_MISC | nil |  |
| `QUERN` | QUERN | any |  |
| `QUIRE` | TOOL | any | item_subtype `ITEM_TOOL_QUIRE` |
| `QUIVER` | QUIVER | any |  |
| `REMAINS` | REMAINS | any |  |
| `RING` | RING | any |  |
| `ROBE` | ARMOR | any | item_subtype `ITEM_ARMOR_ROBE` |
| `ROCK_ANY` | ROCK | any |  |
| `ROCK` | ROCK | inorganic |  |
| `ROUGH_ANY` | ROUGH | any |  |
| `ROUGH` | ROUGH | inorganic | `mat_id` or `mat_token` |
| `SANDAL` | SHOES | any | item_subtype `ITEM_SHOES_SANDAL` |
| `SCARF_HEAD` | HELM | any | item_subtype `ITEM_HELM_SCARF_HEAD` |
| `SCEPTER` | SCEPTER | any |  |
| `SCIMITAR` | WEAPON | any | item_subtype `ITEM_WEAPON_SCIMITAR` |
| `SCOURGE` | WEAPON | any | item_subtype `ITEM_WEAPON_SCOURGE` |
| `SCROLL_ROLLERS` | TOOL | any | item_subtype `ITEM_TOOL_SCROLL_ROLLERS` |
| `SCROLL` | TOOL | any | item_subtype `ITEM_TOOL_SCROLL` |
| `SEEDS` | SEEDS | any |  |
| `SHEET` | SHEET | any |  |
| `SHIELD_ANY` | SHIELD | any |  |
| `SHIELD_BUCKLER` | SHIELD | any | item_subtype `ITEM_SHIELD_BUCKLER` |
| `SHIELD` | SHIELD | any | item_subtype `ITEM_SHIELD_SHIELD` |
| `SHIRT` | ARMOR | any | item_subtype `ITEM_ARMOR_SHIRT` |
| `SHOES` | SHOES | any |  |
| `SIEGEAMMO_BALLISTA` | SIEGEAMMO | any | item_subtype `ITEM_SIEGEAMMO_BALLISTA` |
| `SIEGEAMMO` | SIEGEAMMO | any |  |
| `SKIN_TANNED` | SKIN_TANNED | any |  |
| `SKIRT_LONG` | PANTS | any | item_subtype `ITEM_PANTS_SKIRT_LONG` |
| `SKIRT_SHORT` | PANTS | any | item_subtype `ITEM_PANTS_SKIRT_SHORT` |
| `SKIRT` | PANTS | any | item_subtype `ITEM_PANTS_SKIRT` |
| `SLAB` | SLAB | any |  |
| `SMALLGEM_ANY` | SMALLGEM | any |  |
| `SMALLGEM` | SMALLGEM | inorganic | `mat_id` or `mat_token` |
| `SOCKS` | SHOES | any | item_subtype `ITEM_SHOES_SOCKS` |
| `SPEAR_TRAINING` | WEAPON | any | item_subtype `ITEM_WEAPON_SPEAR_TRAINING` |
| `SPEAR` | WEAPON | any | item_subtype `ITEM_WEAPON_SPEAR` |
| `SPIKEDBALL` | TRAPCOMP | any | item_subtype `ITEM_TRAPCOMP_SPIKEDBALL` |
| `SPLINT` | SPLINT | any |  |
| `STATUE` | STATUE | any |  |
| `STEPLADDER` | TOOL | any | item_subtype `ITEM_TOOL_STEPLADDER` |
| `STONE_AXE` | TOOL | any | item_subtype `ITEM_TOOL_STONE_AXE` |
| `SWORD_2H` | WEAPON | any | item_subtype `ITEM_WEAPON_SWORD_2H` |
| `SWORD_LONG` | WEAPON | any | item_subtype `ITEM_WEAPON_SWORD_LONG` |
| `SWORD_SHORT_TRAINING` | WEAPON | any | item_subtype `ITEM_WEAPON_SWORD_SHORT_TRAINING` |
| `SWORD_SHORT` | WEAPON | any | item_subtype `ITEM_WEAPON_SWORD_SHORT` |
| `TABLE` | TABLE | any |  |
| `THONG` | PANTS | any | item_subtype `ITEM_PANTS_THONG` |
| `THREAD` | THREAD | any |  |
| `TOGA` | ARMOR | any | item_subtype `ITEM_ARMOR_TOGA` |
| `TOOL` | TOOL | any | `tool_id` |
| `TOTEM` | TOTEM | any |  |
| `TOY_AXE` | TOY | any |  |
| `TOY_BOAT` | TOY | any |  |
| `TOY_HAMMER` | TOY | any |  |
| `TOY_MINIFORGE` | TOY | any |  |
| `TOY_PUZZLEBOX` | TOY | any |  |
| `TOY` | TOY | any |  |
| `TRACTION_BENCH` | TRACTION_BENCH | any |  |
| `TRAPCOMP` | TRAPCOMP | any |  |
| `TRAPPARTS` | TRAPPARTS | any |  |
| `TUNIC` | ARMOR | any | item_subtype `ITEM_ARMOR_TUNIC` |
| `TURBAN` | HELM | any | item_subtype `ITEM_HELM_TURBAN` |
| `VEIL_FACE` | HELM | any | item_subtype `ITEM_HELM_VEIL_FACE` |
| `VEIL_HEAD` | HELM | any | item_subtype `ITEM_HELM_VEIL_HEAD` |
| `VEST` | ARMOR | any | item_subtype `ITEM_ARMOR_VEST` |
| `WATER` | LIQUID_MISC | builtin 6 |  |
| `WEAPONRACK` | WEAPONRACK | any |  |
| `WEAPON` | WEAPON | any |  |
| `WHEELBARROW` | TOOL | any | item_subtype `ITEM_TOOL_WHEELBARROW` |
| `WHIP` | WEAPON | any | item_subtype `ITEM_WEAPON_WHIP` |
| `WINDOW` | WINDOW | any |  |
| `WOOD` | WOOD | any |  |

## Appendix B: vectors and tool uses

`vector_id` names (`JOB_ITEM_VECTORS`): `ANY`, `IN_PLAY`, `ANY_ARTIFACT`, `WEAPON`, `ANY_WEAPON`, `ANY_SPIKE`, `ANY_TRUE_ARMOR`, `ANY_ARMOR_HELM`, `ANY_ARMOR_SHOES`, `SHIELD`, `ANY_ARMOR_GLOVES`, `ANY_ARMOR_PANTS`, `QUIVER`, `SPLINT`, `ORTHOPEDIC_CAST`, `CRUTCH`, `BACKPACK`, `AMMO`, `WOOD`, `BOULDER`, `ROCK`, `ANY_REFUSE`, `ANY_GOOD_FOOD`, `ANY_AUTO_CLEAN`, `ANY_EXTRACTABLE`, `ANY_BUTCHERABLE`, `ANY_FURNITURE`, `ANY_CAGE_OR_TRAP`, `ANY_EDIBLE_RAW`, `ANY_EDIBLE_CARNIVORE`, `ANY_EDIBLE_BONECARN`, `ANY_EDIBLE_VERMIN`, `ANY_EDIBLE_VERMIN_BOX`, `ANY_CAN_ROT`, `ANY_MURDERED`, `ANY_DEAD_DWARF`, `ANY_GOES_IN_CHEST`, `ANY_GOES_IN_CABINET`, `ANY_GOES_IN_WEAPONRACK`, `ANY_GOES_IN_ARMORSTAND`, `DOOR`, `FLOODGATE`, `HATCH_COVER`, `GRATE`, `CAGE`, `FLASK`, `WINDOW`, `GOBLET`, `INSTRUMENT`, `TOY`, `BUCKET`, `BARREL`, `CHAIN`, `ANIMALTRAP`, `BED`, `TRACTION_BENCH`, `CHAIR`, `COFFIN`, `TABLE`, `STATUE`, `QUERN`, `MILLSTONE`, `BOX`, `BIN`, `ARMORSTAND`, `WEAPONRACK`, `CABINET`, `ANVIL`, `CATAPULTPARTS`, `BALLISTAPARTS`, `SIEGEAMMO`, `TRAPPARTS`, `ANY_WEBS`, `PIPE_SECTION`, `ANY_ENCASED`, `ANY_IN_CONSTRUCTION`, `DRINK`, `ANY_DRINK`, `LIQUID_MISC`, `POWDER_MISC`, `ANY_COOKABLE`, `ANY_GLASSABLE`, `VERMIN`, `PET`, `ANY_CRITTER`, `COIN`, `GLOB`, `ANY_RECENTLY_DROPPED`, `ANY_MELT_DESIGNATED`, `TRAPCOMP`, `BAR`, `SMALLGEM`, `BLOCKS`, `ROUGH`, `CORPSE`, `FIGURINE`, `AMULET`, `SCEPTER`, `CROWN`, `RING`, `EARRING`, `BRACELET`, `GEM`, `CORPSEPIECE`, `REMAINS`, `MEAT`, `FISH`, `FISH_RAW`, `SEEDS`, `PLANT`, `SKIN_TANNED`, `PLANT_GROWTH`, `THREAD`, `CLOTH`, `TOTEM`, `PANTS`, `CHEESE`, `FOOD`, `BALLISTAARROWHEAD`, `ARMOR`, `SHOES`, `HELM`, `GLOVES`, `TOOL`, `SLAB`, `EGG`, `POSSIBLE_CONTAINER`, `ANY_CORPSE`, `BOOK`, `FOOD_STORAGE`, `INSTRUMENT_STATIONARY`, `SHEET`, `BRANCH`, `BAG`, `MAGICAL`, `BOLT_THROWER_PARTS`.

`has_tool_use` and `tool_use` names (`TOOL_USES`): `NONE`, `LIQUID_COOKING`, `LIQUID_SCOOP`, `GRIND_POWDER_RECEPTACLE`, `GRIND_POWDER_GRINDER`, `MEAT_CARVING`, `MEAT_BONING`, `MEAT_SLICING`, `MEAT_CLEAVING`, `HOLD_MEAT_FOR_CARVING`, `MEAL_CONTAINER`, `LIQUID_CONTAINER`, `FOOD_STORAGE`, `HIVE`, `NEST_BOX`, `SMALL_OBJECT_STORAGE`, `TRACK_CART`, `HEAVY_OBJECT_HAULING`, `STAND_AND_WORK_ABOVE`, `ROLL_UP_SHEET`, `PROTECT_FOLDED_SHEETS`, `CONTAIN_WRITING`, `BOOKCASE`, `DISPLAY_OBJECT`, `PLACE_OFFERING`, `DIVINATION`, `GAMES_OF_CHANCE`.
