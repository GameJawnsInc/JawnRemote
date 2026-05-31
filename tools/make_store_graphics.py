"""Generate Play Store listing graphics for JawnRemote:
  play/icon-512.png                  (512x512, required)
  play/feature-graphic-1024x500.png  (1024x500, required)
"""
import os
from PIL import Image, ImageDraw, ImageFont

SRC = r"C:\gd\mouse_kb_android\app\assets\icon\icon.png"
OUT = r"C:\gd\mouse_kb_android\play"
os.makedirs(OUT, exist_ok=True)

# --- 512x512 icon (downscaled from the 1024 master) ---
Image.open(SRC).convert("RGBA").resize((512, 512), Image.LANCZOS) \
    .save(os.path.join(OUT, "icon-512.png"))
print("wrote icon-512.png")

# --- 1024x500 feature graphic ---
W, H, SS = 1024, 500, 2
TOP, BOT = (96, 150, 255), (33, 78, 200)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(w, h, top, bot):
    base = Image.new("RGB", (1, h))
    for y in range(h):
        base.putpixel((0, y), lerp(top, bot, y / (h - 1)))
    return base.resize((w, h))


img = gradient(W * SS, H * SS, TOP, BOT).convert("RGBA")
d = ImageDraw.Draw(img)

# Wireless-cursor mark (same arrow as the app icon), white, on the left.
CURSOR = [(0, 0), (0, 16), (4, 12), (7, 18.5), (9.2, 17.6), (6.2, 11.2), (11, 11)]
ox, oy, sc = 145 * SS, 205 * SS, 10 * SS
for rr in (7, 12, 17):
    r = rr * sc
    d.arc([ox - r, oy - r, ox + r, oy + r], start=-58, end=20,
          fill=(255, 255, 255, 160), width=int(2.4 * sc))
d.polygon([(ox + x * sc, oy + y * sc) for (x, y) in CURSOR], fill=(255, 255, 255, 255))

# Text.
try:
    title_font = ImageFont.truetype("C:/Windows/Fonts/segoeuib.ttf", 88 * SS)
    sub_font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 34 * SS)
except OSError:
    title_font = ImageFont.load_default()
    sub_font = ImageFont.load_default()

tx = 370 * SS
d.text((tx, 175 * SS), "JawnRemote", font=title_font, fill=(255, 255, 255))
d.text((tx, 290 * SS), "Your phone is the mouse & keyboard",
       font=sub_font, fill=(228, 236, 255))

img.convert("RGB").resize((W, H), Image.LANCZOS) \
    .save(os.path.join(OUT, "feature-graphic-1024x500.png"))
print("wrote feature-graphic-1024x500.png")
