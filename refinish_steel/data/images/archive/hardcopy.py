#!/usr/bin/env python3
# hardcopy.py
# =====================================================================
# HARDCOPY: EVERY CHAR MAP SPRITE ON A REAL SHEET
# =====================================================================
# RM's tinted art lives in Lua as char maps (refinish-sprite-art.lua
# reads them; a PNG handed to DF can never be read back). Every sprite
# we create also keeps a real sheet copy, even unused, in case it is
# ever needed as a file (2026-09-26). This writes one sheet per art
# file, straight from the char maps, so the copy can never drift from
# what the game draws.
#
# The sheet is drawn on DF's own palette key greys: '0' to '8' are ramp
# B's nine keys (palettes.png row 0, columns 9 to 17, the RAMP table in
# refinish-sprite-art.lua), '.' is '0' at half alpha, the cast shadow,
# and a space is transparent. So the sheet is not a picture of the art,
# it IS the art: DF recolours it exactly as it recolours its own sheets.
#
# LAYOUT
#   Art named <sheet>_<column>_<row> (boulders_1_13, skins_4_2) sits at
#   the cell its name gives, which is where it sat on the vanilla sheet
#   it was retoned from, so the copy lines up with its source.
#   Anything else is laid out in file order, four cells to a row.
#   Cells are 32 by 32.
#
# USE
#   python hardcopy.py FILE.lua [FILE.lua ...] [--out DIR]
#   One sheet per file: making-fuel-sprite-art.lua writes
#   making_fuel_sprite_art.png. The cell of every art is printed, for
#   the file's HARDCOPY note. Only the Python standard library is used.
#
# Run it again whenever a char map changes.
# =====================================================================
import os
import re
import struct
import sys
import zlib

CELL = 32
COLUMNS = 4

# RAMP from refinish-sprite-art.lua: the palette's ramp B keys, '.' is
# '0' at half alpha. Kept here so the tool runs on its own; if the ramp
# there ever changes, change it here too.
RAMP = {
    '.': (0x2F, 0x30, 0x38, 128),
    '0': (0x2F, 0x30, 0x38, 255),
    '1': (0x3C, 0x3E, 0x46, 255),
    '2': (0x49, 0x4C, 0x54, 255),
    '3': (0x5A, 0x5E, 0x65, 255),
    '4': (0x6B, 0x70, 0x76, 255),
    '5': (0x8A, 0x90, 0x91, 255),
    '6': (0xA5, 0xA6, 0xA5, 255),
    '7': (0xC7, 0xC4, 0xB4, 255),
    '8': (0xFF, 0xFF, 0xFF, 255),
}

# One char map: four spaces, a name, then its rows as quoted strings,
# closed by four spaces and a brace. Comment lines inside are skipped
# because only quoted strings are read.
ENTRY = re.compile(r"^    ([A-Za-z_][A-Za-z_0-9]*) = \{\n(.*?)\n    \},", re.S | re.M)
ROW = re.compile(r"^\s*'([^']*)',?\s*$", re.M)
COORD = re.compile(r"^(.+)_(\d+)_(\d+)$")


def read_maps(path):
    """Every char map in an art file, in file order, as (name, rows)."""
    text = open(path, encoding='utf-8').read().replace('\r\n', '\n')
    maps = []
    for m in ENTRY.finditer(text):
        rows = ROW.findall(m.group(2))
        if rows:
            maps.append((m.group(1), rows))
    return maps


def layout(maps):
    """Cell (column, row) for every map, and the sheet's size in cells."""
    coords = [COORD.match(name) for name, _ in maps]
    if maps and all(coords) and len({c.group(1) for c in coords}) == 1:
        cells = {name: (int(c.group(2)), int(c.group(3))) for (name, _), c in zip(maps, coords)}
    else:
        cells = {name: (i % COLUMNS, i // COLUMNS) for i, (name, _) in enumerate(maps)}
    cols = max(c for c, _ in cells.values()) + 1
    rows = max(r for _, r in cells.values()) + 1
    return cells, cols, rows


def write_png(path, width, height, pixels):
    """RGBA PNG from a flat list of (r, g, b, a), standard library only."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixels[y * width + x])

    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def sheet_name(path):
    return os.path.splitext(os.path.basename(path))[0].replace('-', '_') + '.png'


def hardcopy(path, out_dir):
    maps = read_maps(path)
    if not maps:
        print('%s: no char maps found' % path)
        return
    cells, cols, rows = layout(maps)
    width, height = cols * CELL, rows * CELL
    pixels = [(0, 0, 0, 0)] * (width * height)
    for name, lines in maps:
        cx, cy = cells[name]
        for y, line in enumerate(lines[:CELL]):
            for x, ch in enumerate(line[:CELL]):
                if ch in RAMP:
                    pixels[(cy * CELL + y) * width + cx * CELL + x] = RAMP[ch]
                elif ch != ' ':
                    print('%s: %s has an unknown symbol %r, left clear' % (path, name, ch))
    out = os.path.join(out_dir, sheet_name(path))
    write_png(out, width, height, pixels)
    print('%s -> %s (%d by %d, %d art)' % (os.path.basename(path), out, width, height, len(maps)))
    for name, _ in maps:
        print('    %-20s %d:%d' % (name, cells[name][0], cells[name][1]))


def main(argv):
    out_dir = '.'
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == '--out' and i + 1 < len(argv):
            out_dir = argv[i + 1]
            i += 2
        else:
            files.append(argv[i])
            i += 1
    if not files:
        print(__doc__ or 'usage: python hardcopy.py FILE.lua [FILE.lua ...] [--out DIR]')
        print('usage: python hardcopy.py FILE.lua [FILE.lua ...] [--out DIR]')
        return 1
    os.makedirs(out_dir, exist_ok=True)
    for f in files:
        hardcopy(f, out_dir)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
