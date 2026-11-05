"""agent-courier icon: an original chunky block-pixel courier bird with a letter in its beak.
Run: python3 assets/make_icon.py .claude-plugin/icon.png (needs Pillow)."""
import sys
from PIL import Image, ImageDraw

OUT = sys.argv[1]
S = 1024

# 14 x 12 grid. Legend:
# B body  W wing  D wing shadow  E eye  O beak  L letter  R seal  F feet  . empty
GRID = [
    ".........BBB..",
    "........BBBBB.",
    ".......BBBEBOO",
    "..WW..BBBBBBLL",
    "..WWWWWWBBBBLR",
    "B.DWWWWWWBBBB.",
    "BBDDWWWWBBBBB.",
    ".BBDDDDBBBBB..",
    "..BBBBBBBBB...",
    "...BBBBBBBB...",
    "....BBBBBB....",
    ".....F..F.....",
]
COLORS = {
    "B": (94, 208, 176),
    "W": (46, 128, 116),
    "D": (24, 94, 86),
    "E": (18, 20, 32),
    "O": (246, 166, 64),
    "L": (244, 242, 232),
    "R": (236, 96, 90),
    "F": (246, 166, 64),
}
BG = (18, 20, 32)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=BG + (255,))

cols, rows = len(GRID[0]), len(GRID)
cell = 40
ox = (S - cell * cols) // 2
oy = (S - cell * rows) // 2 + cell // 2
for r, row in enumerate(GRID):
    assert len(row) == cols, (r, len(row))
    for c, ch in enumerate(row):
        if ch in COLORS:
            x0, y0 = ox + c * cell, oy + r * cell
            d.rectangle([x0, y0, x0 + cell - 1, y0 + cell - 1], fill=COLORS[ch] + (255,))

img.save(OUT, optimize=True)
print(OUT)
