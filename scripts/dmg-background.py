# Draws the picture behind the disk image's window (Resources/DiskImage/dmg-background.png and @2x): the line
# "Drag Murmur into Applications" and the arrow between the two icons. Only needed when the wording or the layout
# changes; the pictures are kept in the repository.
#
#   python3 scripts/dmg-background.py <MontaguSlab variable .ttf> Resources/DiskImage
#
# Needs Pillow. The font is Montagu Slab (SIL Open Font License), from fonts.google.com.
import sys, math
from PIL import Image, ImageDraw, ImageFont
font_path, out = sys.argv[1], sys.argv[2]
W, H, K = 660, 500, 4            # drawn at 4x, saved at 2x and 1x
cream, ink, soft, coral = (251, 247, 242), (34, 30, 28), (107, 95, 88), (255, 111, 97)
im = Image.new("RGB", (W * K, H * K), cream)
d = ImageDraw.Draw(im)
def font(size, weight):
    f = ImageFont.truetype(font_path, size * K)
    axes = f.get_variation_axes()
    f.set_variation_by_axes([weight if b"eight" in (a["name"] if isinstance(a["name"], bytes) else a["name"].encode()) else
                             min(a["maximum"], max(a["minimum"], size * 2)) for a in axes])
    return f
def centred(text, y, f, fill):
    w = d.textlength(text, font=f)
    d.text(((W * K - w) / 2, y * K), text, font=f, fill=fill)
centred("Drag Murmur into Applications", 84, font(31, 560), ink)
centred("Then open it from there. This disk can be ejected.", 136, font(13, 430), soft)
# The arrow between the two icons (their centres: 170 and 490 across, 300 down): a shallow curve and a head.
pts = []
x0, x1, y = 268, 392, 300
for i in range(0, 201):
    t = i / 200
    pts.append(((x0 + (x1 - x0) * t) * K, (y + 9 * math.sin(math.pi * t) ) * K))
r = 2.6 * K
for (px, py) in pts: d.ellipse((px - r, py - r, px + r, py + r), fill=coral)
hx, hy = pts[-1]
for ang in (150, -150):
    a = math.radians(ang) + math.atan2(pts[-1][1] - pts[-12][1], pts[-1][0] - pts[-12][0])
    ex, ey = hx + 15 * K * math.cos(a), hy + 15 * K * math.sin(a)
    for i in range(0, 61):
        t = i / 60
        px, py = hx + (ex - hx) * t, hy + (ey - hy) * t
        d.ellipse((px - r, py - r, px + r, py + r), fill=coral)
im.resize((W * 2, H * 2), Image.LANCZOS).save(out + "/dmg-background@2x.png", optimize=True)
im.resize((W, H), Image.LANCZOS).save(out + "/dmg-background.png", optimize=True)
