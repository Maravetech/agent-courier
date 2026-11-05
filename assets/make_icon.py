"""agent-courier icon: a paper plane carries a message along a dashed arc from a sender dot to a delivered check.

Drawn at 4096 px and downsampled to 1024 px for clean edges.
"""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096
OUT = sys.argv[1]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


# --- background: rounded square, diagonal gradient deep indigo -> teal
top, bottom = (36, 38, 92), (14, 132, 140)
grad = Image.new("RGB", (S, S))
gp = grad.load()
for y in range(S):
    for x in range(0, S, 4):
        t = min(1, max(0, (x * 0.35 + y * 0.65) / S))
        c = lerp(top, bottom, t)
        for dx in range(4):
            gp[x + dx, y] = c
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)

WHITE = (255, 255, 255, 255)
SOFT = (255, 255, 255, 150)
MINT = (120, 240, 200, 255)

# --- route: dashed arc from sender (left-low) to receiver (right-low)
sx, sy = int(S * 0.20), int(S * 0.70)
rx, ry = int(S * 0.80), int(S * 0.70)
cx, cy = (sx + rx) / 2, int(S * 0.30)  # control point (quadratic bezier)


def bez(t):
    x = (1 - t) ** 2 * sx + 2 * (1 - t) * t * cx + t * t * rx
    y = (1 - t) ** 2 * sy + 2 * (1 - t) * t * cy + t * t * ry
    return x, y


w = int(S * 0.028)
n = 15
for i in range(n):
    t0, t1 = i / n + 0.012, (i + 0.55) / n
    if t1 > 0.86:
        break
    if 0.36 < t0 < 0.62:  # leave room under the plane
        continue
    pts = [bez(t0 + (t1 - t0) * k / 8) for k in range(9)]
    d.line(pts, fill=SOFT, width=w, joint="curve")

# --- sender dot
r = int(S * 0.065)
d.ellipse([sx - r, sy - r, sx + r, sy + r], fill=WHITE)

# --- receiver: mint circle with a check (delivered + confirmed)
R = int(S * 0.115)
d.ellipse([rx - R, ry - R, rx + R, ry + R], fill=MINT)
cw = int(S * 0.034)
check = [(rx - R * 0.48, ry + R * 0.02), (rx - R * 0.12, ry + R * 0.38), (rx + R * 0.52, ry - R * 0.36)]
d.line(check, fill=(20, 70, 90, 255), width=cw, joint="curve")
for p in (check[0], check[-1]):
    d.ellipse([p[0] - cw / 2, p[1] - cw / 2, p[0] + cw / 2, p[1] + cw / 2], fill=(20, 70, 90, 255))

# --- paper plane at the top of the arc, pointing along the tangent
px, py = bez(0.5)
ang = math.radians(-10)
L = S * 0.36


def rot(x, y):
    return (px + x * math.cos(ang) - y * math.sin(ang), py + x * math.sin(ang) + y * math.cos(ang))


nose = rot(L * 0.55, 0)
tail_top = rot(-L * 0.45, -L * 0.38)
tail_bot = rot(-L * 0.45, L * 0.30)
fold = rot(-L * 0.18, L * 0.04)
# shadow
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).polygon([(x + S * 0.012, y + S * 0.02) for x, y in (nose, tail_top, fold, tail_bot)], fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.012))
img = Image.alpha_composite(img, shadow)
d = ImageDraw.Draw(img)
d.polygon([nose, tail_top, fold], fill=WHITE)  # upper wing
d.polygon([nose, fold, tail_bot], fill=(214, 232, 246, 255))  # lower wing, shaded
d.line([nose, fold], fill=(170, 200, 225, 255), width=int(S * 0.008))

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(OUT, optimize=True)
print(OUT, img.size)
