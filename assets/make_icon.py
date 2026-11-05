"""agent-courier icon: an original chunky block-pixel courier bird carrying a letter. Run: python3 assets/make_icon.py .claude-plugin/icon.png (needs Pillow)."""
import sys
from PIL import Image, ImageDraw

OUT = sys.argv[1]
S = 1024

# 14 x 10 grid. Legend:
# B body  W wing  T wing tip  E eye  O beak  L letter  S seal  F feet  . empty
GRID = [
    "..............",
    "..TT..........",
    "..TWW....BBBB.",
    "...WWW..BBEBOO",
    "B...WWWBBBBBLL",
    "BB..WWBBBBBBLS",
    ".BBBBBBBBBBB..",
    "..BBBBBBBBB...",
    "....BBBBB.....",
    ".....F..F.....",
]
COLORS = {
    "B": (92, 200, 170),
    "W": (52, 142, 128),
    "T": (36, 104, 98),
    "E": (24, 26, 34),
    "O": (246, 170, 74),
    "L": (246, 244, 236),
    "S": (226, 92, 84),
    "F": (246, 170, 74),
}
BG = (26, 28, 38)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=BG + (255,))

cols, rows = len(GRID[0]), len(GRID)
cell = int(S * 0.74 / cols)
ox = (S - cell * cols) // 2
oy = (S - cell * rows) // 2 + int(cell * 0.3)
gap = 0  # solid chunky blocks
for r, row in enumerate(GRID):
    assert len(row) == cols, (r, len(row))
    for c, ch in enumerate(row):
        if ch in COLORS:
            x0, y0 = ox + c * cell, oy + r * cell
            d.rectangle([x0 + gap, y0 + gap, x0 + cell - gap - 1, y0 + cell - gap - 1], fill=COLORS[ch] + (255,))

img.save(OUT, optimize=True)
print(OUT, cell)
