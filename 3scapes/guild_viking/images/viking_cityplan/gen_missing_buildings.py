"""The ten city-plan buildings that never got a tile, drawn with the shipped
generator's kit (gen_building_tiles.py: G primitives, muted base, 2px black
frame, speckles) so they sit with the framed tiles already in the set.
Run it beside the original gen_building_tiles.py (from the LEGACY images
bundle), saved as gbt.py; it reuses that file's G primitives and render().
Usage: gen_missing_buildings.py <outdir>
"""
import os
import sys

import gbt  # gen_building_tiles.py, the generator the shipped tiles came from
from gbt import G, BLACK, WOOD, WOOD_D, SAND, SAND_D, FIRE, FIRE_L, SILVER, blend, darken, lighten

WHITE = (0xE8, 0xE4, 0xD8)
WOOL = (0xD8, 0xD2, 0xC0)
PINK = (0xD8, 0x90, 0x88)
PINK_D = (0xA8, 0x60, 0x5C)
MUD = (0x4A, 0x34, 0x1C)
MEAT = (0xB0, 0x30, 0x2C)
SMOKE = (0x90, 0x90, 0x94)
HEN = (0xB8, 0x70, 0x30)
COMB = (0xD0, 0x30, 0x20)
THREAD = (0xC0, 0x40, 0x40)
THREAD2 = (0x40, 0x70, 0xB0)


def fence(g, x0, y0, x1, y1):
    """A paddock rail: posts and two rails."""
    rail, post = lighten(WOOD, 0.3), lighten(WOOD_D, 0.25)
    g.hline(x0, x1, y0, rail, w=2)
    g.hline(x0, x1, y0 + 6, rail, w=2)
    for x in range(x0, x1 + 1, 7):
        g.vline(x, y0 - 2, y1, post, w=2)


def g_sheepfold(g):
    fence(g, 12, 40, 51, 52)
    for cx, cy in ((24, 32), (38, 30)):
        g.dot(cx, cy, 6, WOOL)
        g.dot(cx - 2, cy - 2, 2, WHITE)
        g.dot(cx + 6, cy - 1, 3, g.dark)          # head
        g.vline(cx - 3, cy + 5, cy + 9, g.dark)   # legs
        g.vline(cx + 3, cy + 5, cy + 9, g.dark)


def g_henhouse(g):
    g.house(14, 18, 37, 46, g.dark, WOOD)
    g.dline(37, 44, 47, 52, WOOD_D, w=2)          # ramp
    g.dot(44, 38, 5, HEN)                         # hen
    g.dot(48, 33, 3, HEN)
    g.rect(48, 29, 49, 30, COMB)
    g.rect(51, 33, 52, 34, SAND)                  # beak
    g.rect(41, 43, 41, 47, SAND_D)
    g.rect(46, 43, 46, 47, SAND_D)


def g_piggery(g):
    g.rect(10, 42, 53, 53, MUD)                   # wallow
    fence(g, 10, 44, 53, 54)
    g.dot(30, 32, 9, PINK)                        # pig body
    g.dot(40, 30, 5, PINK)                        # head
    g.rect(44, 29, 47, 32, PINK_D)                # snout
    g.rect(39, 24, 41, 26, PINK_D)                # ear
    g.vline(24, 39, 43, PINK_D, w=2)
    g.vline(34, 39, 43, PINK_D, w=2)


def g_byre(g):
    g.roof_up(10, 16, 53, 32, g.dark)
    g.rect(12, 32, 51, 54, lighten(WOOD, 0.2))
    g.rect(26, 38, 37, 54, WOOD_D)                # barn door
    g.dline(26, 38, 37, 54, WOOD, w=1)
    g.dline(26, 54, 37, 38, WOOD, w=1)
    g.rect(15, 38, 22, 46, WHITE)                 # cow at the window
    g.rect(15, 38, 17, 41, BLACK)
    g.rect(20, 43, 22, 46, BLACK)
    g.rect(16, 36, 16, 37, SAND)                  # horns
    g.rect(21, 36, 21, 37, SAND)


def g_stable(g):
    g.roof_up(10, 16, 53, 30, g.dark)
    g.rect(12, 30, 51, 54, lighten(WOOD, 0.2))
    for x0 in (15, 34):
        g.rect(x0, 36, x0 + 14, 54, WOOD_D)       # stall
        g.hline(x0, x0 + 14, 44, WOOD)            # half door
    g.rect(20, 34, 25, 44, darken(SAND, 0.4))     # horse head
    g.rect(18, 40, 21, 46, darken(SAND, 0.4))
    g.rect(22, 31, 24, 34, BLACK)                 # mane
    g.rect(23, 37, 23, 37, BLACK)                 # eye


def g_butchery(g):
    g.hline(12, 51, 16, WOOD_D, w=3)              # hanging rail
    for x in (18, 32, 46):
        g.vline(x, 19, 23, SILVER)                # hooks
        g.dot(x, 30, 5, MEAT)
        g.dot(x, 30, 2, PINK)
        g.vline(x, 34, 38, WHITE)                 # bone
    g.rect(16, 44, 47, 47, WOOD)                  # block
    g.rect(30, 38, 41, 42, SILVER)                # cleaver
    g.rect(38, 42, 40, 46, WOOD_D)


def g_weaver(g):
    g.vline(14, 16, 54, WOOD, w=3)                # loom frame
    g.vline(47, 16, 54, WOOD, w=3)
    g.hline(14, 49, 16, WOOD_D, w=3)
    g.hline(14, 49, 46, WOOD_D, w=3)
    for x in range(19, 46, 3):
        g.vline(x, 19, 45, WOOL)                  # warp
    for y in range(22, 44, 4):
        g.hline(18, 45, y, THREAD if y % 8 else THREAD2, w=2)   # weft bands
    g.rect(22, 48, 41, 51, SAND)                  # shuttle


def g_smokehouse(g):
    g.house(16, 22, 47, 54, g.dark, WOOD)
    g.rect(38, 14, 42, 26, darken(SILVER, 0.5))   # chimney
    for i, (x, y) in enumerate(((40, 10), (44, 6), (37, 5))):
        g.dot(x, y, 2 + i % 2, SMOKE)
    for x in (22, 28, 34):                        # fish hung to cure
        g.vline(x, 34, 36, WOOD_D)
        g.tri(x - 2, 37, x + 2, 45, "s", SAND_D)
    g.rect(28, 48, 35, 51, FIRE)                  # embers
    g.rect(30, 49, 33, 50, FIRE_L)


def g_creamery(g):
    g.rect(20, 22, 37, 52, WOOD)                  # churn
    g.rect(20, 22, 37, 24, WOOD_D)
    g.rect(20, 50, 37, 52, WOOD_D)
    g.hline(20, 37, 37, WOOD_D, w=2)              # hoop
    g.vline(28, 10, 22, WOOD_D, w=2)              # dasher
    g.hline(24, 33, 12, WOOD_D, w=2)
    g.dot(45, 46, 5, WHITE)                       # cheese wheel / milk pail
    g.dot(45, 46, 2, SAND)
    g.rect(40, 30, 50, 38, WHITE)                 # butter block
    g.rect(40, 30, 50, 31, SAND)


def g_matbur(g):
    # A stabbur: food store raised on posts, with a turf roof.
    g.roof_up(14, 12, 49, 26, darken((0x44, 0x6A, 0x30), 0.1))
    g.hline(12, 51, 26, g.dark, w=2)
    g.rect(16, 28, 47, 42, WOOD)
    for x in range(18, 46, 5):
        g.vline(x, 28, 42, WOOD_D)                # planks
    g.rect(28, 32, 35, 42, g.dark)                # door
    for x in (17, 30, 44):
        g.rect(x, 43, x + 2, 54, WOOD_D)          # stilts
        g.rect(x - 1, 46, x + 3, 47, SILVER)      # rat stones
    g.dline(36, 54, 44, 42, WOOD, w=2)            # steps


# Base colours follow the building's MATERIAL, the way the shipped set does
# (gen_building_tiles.py keeps each emblem's dominant colour: timber brown,
# stone grey, thatch tan, brick red-brown). Each value below is a colour an
# existing tile already shows, divided back by render()'s 18% mute so the
# output lands on that exact shade.
def shipped(hexrgb, like):
    """`like` names the shipped tile this shade is taken from."""
    r, g, b = (int(hexrgb[i:i + 2], 16) for i in (0, 2, 4))
    return tuple(min(255, round(v / 0.82)) for v in (r, g, b))


TIMBER = shipped("2D1A06", "fishing_wharf")
TIMBER_L = shipped("351F0A", "trading_post")
THATCH = shipped("574522", "tannery")
CLAY = shipped("8B763F", "salting_house")
BRICK = shipped("52210A", "smelter")
SOOT = shipped("262626", "mine")
LOOM = shipped("231406", "weaving_hall")

TILES = {
    "sheepfold":  (TIMBER, g_sheepfold),     # wooden paddock
    "henhouse":   (TIMBER_L, g_henhouse),    # plank coop
    "piggery":    (THATCH, g_piggery),       # mud and straw
    "byre":       (TIMBER, g_byre),          # timber barn
    "stable":     (TIMBER_L, g_stable),      # timber stalls
    "butchery":   (BRICK, g_butchery),       # brick shop, like the smelter
    "weaver":     (LOOM, g_weaver),          # as the weaving hall
    "smokehouse": (SOOT, g_smokehouse),      # sooted
    "creamery":   (CLAY, g_creamery),        # whitewashed dairy
    "matbur":     (TIMBER_L, g_matbur),      # raised timber store
}


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, (base, glyph) in TILES.items():
        gbt.GLYPHS[name] = glyph
        gbt.render(name, base, out)
    print("wrote %d tiles to %s" % (len(TILES), out))


if __name__ == "__main__":
    main()
