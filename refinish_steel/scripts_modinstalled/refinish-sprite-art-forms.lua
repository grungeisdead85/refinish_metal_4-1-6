--@ module = true
-- refinish-sprite-art-forms.lua
-- =====================================================================
-- RM CHAR MAPS: THE CATALOG'S FORMS
-- =====================================================================
-- Art for RM's own catalog forms that has to take the material's
-- colour. A form's tool declares "tint" naming one of these, and
-- refinish-sprite-tool-tint dresses it per material.
--
-- Every pattern here came from Making Fuel's making-fuel-sprite-art-
-- tools.lua with its form (gravel first, then the heaps 2026-09-25),
-- and that file's notes came with them, below, verbatim. It held nothing
-- else, so it is gone.
--
-- A PNG cell can be handed to DF but its pixels can never be read back,
-- so anything WE tint has to live here as char map data.
--
-- GRAVEL is converted from making_fuel_byproducts.png, cell 0:1 (RM's
-- copy: refinish_byproducts.png, same cell). The sheet is 128 by 128
-- RGBA on a transparent background, so cells are 32 by 32 and the
-- silhouette comes straight off the alpha channel. Conversion rules, for
-- the next cell brought over:
--   alpha 128 or more is art, below that is not;
--   1:1 pixels, no resampling, no smoothing, no re-ranking. A median
--       pass smears a pile into a blob and rank matching against
--       another sprite's histogram throws the local shading away;
--   values are the artist's own, nearest ramp step, capped at 199;
--   disconnected clusters under 12 pixels are splatter and go;
--   '.' is the CAST SHADOW, under the mass only. Measured on
--       boulders_0_3: never around the silhouette. Ringing a sprite
--       with it makes the shadow wear the material's colour.
--
-- GRAVEL was relit 2026-09-26: it read as a flat colour, darker at the
-- bottom, rather than light and shadow on stones (it used levels 0 to 5
-- and almost nothing above 4). The stones are as drawn. Mids are lifted
-- a step; each stone's top and left rim is a step lighter, two where
-- they meet; its bottom and right rim a step darker; a little grain
-- inside; so it uses the whole ramp. The 199 cap above held for the
-- conversion; the relight goes past it on purpose.
--
-- The HEAPS are drawn here rather than converted, because
-- what they replace was a boulder and a smooth hill. Built the way the
-- vanilla powder pile at ITEM_CONSTRUCTION 2:3 is built: a heap made of
-- many small grains, each with a lit crown, a body and a dark
-- underside, a dark seam wherever a grain meets a gap, and loose grains
-- around the base. That structure is what reads as powder; a shaded
-- mound reads as a hill whatever colour it takes.
--
--   sawdust   a mound of fine flakes filling the tile, redrawn
--             2026-09-26. The heap it replaced (coarse angular fines,
--             grains of 1 and 2, mid dark body) was drawn as cinders for
--             Making Fuel's cinders tool, named for them until moved
--             sawdust onto it that day, and sat in 20 by 12 pixels of
--             the cell. Making Concrete's cement wears it too (its tool
--             declares tint 'sawdust').
-- A second sawdust, flakes rather than grains (diamonds, not discs), a
-- lighter body and a looser heap, was retired the same day: it read
-- badly in palette mode.
--
-- Making Fuel's own heap of fine granules, drawn for coke breeze and
-- worn by its binder tool since 2026-09-28, lives in
-- making-fuel-sprite-art.lua under the name binder.
--
-- Loaded by refinish_steel at its own load, so the art is registered
-- before any tool asks for it.
-- =====================================================================

-- ---- HARDCOPY ----
-- refinish_sprite_art_forms.png, in refinish_steel/data/images, is these
-- char maps drawn onto a real sheet: 32 by 32 cells on the palette's own
-- key greys, so DF would recolour it exactly as it does its own sheets.
-- Every sprite we create keeps one, even unused, in case it is ever
-- needed as a file (2026-09-26). hardcopy.py writes it from this
-- file; run it again whenever a map here changes.
-- Cells: gravel 0:0, sawdust 1:0.
-- A changed map can be kept as its own cell, beside the sheet and
-- without reprinting it: hardcopy.py FILE --cell NAME.

local art = reqscript('refinish-sprite-art')

local ART = {
    gravel = {
        -- Relit 2026-09-26 (GRAVEL, above): mean level 2.89, from 2.10.
        '',
        '',
        '',
        '',
        '',
        '',
        '            8877630',
        '            8654510  650',
        '            33655430 600',
        '           8555531166430',
        '        4775522165454410',
        '        07655551165443330',
        '         7466541065411110',
        '         3555112322100000',
        '         7321076655530',
        '      677652276655551076530',
        '    47765552266552455664410',
        '    07645541075555455543210',
        '     7555141316511115453310',
        '     35422100031000054311160',
        '   607452410 .000...31100050',
        '   003544410 ...... 0000  00',
        '     03111130 ...   .60',
        '      0000000        060',
        '       ......        .00',
        '            .         ..',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    sawdust = {
        -- A height field lit from the top left, the way the vanilla
        -- powder pile uses the tile: 350 pixels over 28 by 18, against the
        -- pile's 323 over 27 by 22. Fine flakes (strokes of 2 or 3, lit,
        -- a thin shadow under each), a few shadowed crevices, glints on
        -- the crest, loose flakes at the foot, the cast shadow down and
        -- right. The whole ramp, light as well as shadow; mean level
        -- 4.07, pale like the real thing.
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '             676',
        '           687665  766',
        '          66675668877568',
        '         7667764476865535',
        '       6668668886666776533',
        '     676668687877866454332',
        '     6766676656656775643333',
        '    677876888686675774756536',
        '    5666666667667686455547523',
        '   54766685786754564522453422',
        '   25466745663435516454313251',
        '    132434543445444454634242',
        '     11111144456534334452422',
        '      ...1113543332432434323',
        '       .....55433334433310452',
        '           .13344242114222231',
        '             1212321 .112112 .',
        '              .121 .. ....... .',
        '               .... ..  ......',
        '                 ...      ...',
        '',
        '',
        '',
    },
}

-- ---- HOW THE FORMS TINT ----
-- Gravel and sawdust are neutral forms of mostly neutral materials, and
-- the shared knobs put back the art's own luminance whatever the
-- material, so every grey stone wore one dark grey (2026-09-25). They
-- register a profile (refinish-sprite-art.lua, A PROFILE PER ART) that
-- lands each sprite at its material's own lightness.
--
-- Whether these numbers are used is THE MODE's call (refinish-sprite-
-- art.lua), one switch for every art: palette, the default since
-- 2026-09-25, is DF's own colours from each material's palette row and
-- does not read them; blend, our own colours, does. No multiply at any
-- setting matched DF's dull colours beside them, because DF's hue is the
-- palette's, not the descriptor's, so the switch lets either look be the
-- one everywhere.
-- Tunable here, or live with refinish-tint (refinish-tint gravel dark=60
-- light=210), which reports a line to copy back. One FORM_PROFILE serves
-- both arts; give either its own table if they part ways. The numbers:
--   desat, strength   the hue: how pure, and how much of it
--   dark, light       the mean luminance a black and a white
--                     descriptor's sprite lands at, out of 255
local FORM_PROFILE = { desat = 0.3, strength = 0.9, dark = 50, light = 200 }
local PROFILED = { gravel = true, sawdust = true }

for name, charmap in pairs(ART) do
    art.register(name, charmap, PROFILED[name] and FORM_PROFILE or nil)
end

-- ---- HOW LIGHT THE FORMS SIT ----
-- In palette mode each symbol takes its own column, so an art drawn
-- darker than DF draws lands darker (refinish-sprite-art.lua, LIGHTER
-- OR DARKER ALONG THE PALETTE). Measured on the nine step ramp, against
-- DF's own item art at a median of 3.12. Gravel sat at 2.10 and was
-- moved a step lighter (2026-09-25); relit the next day it sits at
-- 2.89 and needs no shift, so that +1 is gone. Sawdust, redrawn the same
-- day, sits at 4.07, pale like the real thing (the heap before it 2.87,
-- the retired flakes 4.48). Tunable live with refinish-tint gravel
-- shift=1, which also reports each art's level.

-- Exposed so a probe or the panel can list what this file contributed
-- without reaching into the shared registry.
function names()
    local out = {}
    for k in pairs(ART) do table.insert(out, k) end
    table.sort(out)
    return out
end