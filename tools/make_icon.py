"""Generate the JawnRemote app icon assets with Pillow.

Produces (1024x1024):
  app/assets/icon/icon.png        opaque, gradient bg + cursor   (legacy/iOS)
  app/assets/icon/background.png  opaque gradient                (adaptive bg)
  app/assets/icon/foreground.png  transparent, cursor, safe-zone (adaptive fg)
"""
import os
from PIL import Image, ImageDraw, ImageFilter

OUT = r"C:\gd\mouse_kb_android\app\assets\icon"
os.makedirs(OUT, exist_ok=True)

S = 1024
SS = 2          # supersample for smooth edges
W = S * SS

TOP = (96, 150, 255)   # brand blue (light)
BOT = (33, 78, 200)    # brand blue (dark)

# Classic arrow-cursor outline in a unit grid (w=11, h=18.5).
CURSOR = [(0, 0), (0, 16), (4, 12), (7, 18.5),
          (9.2, 17.6), (6.2, 11.2), (11, 11)]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(w, h, top, bot):
    base = Image.new("RGB", (1, h))
    for y in range(h):
        base.putpixel((0, y), lerp(top, bot, y / (h - 1)))
    return base.resize((w, h))


def draw_cursor(img, height_frac, cx_frac=0.52, cy_frac=0.5):
    """Draw a white cursor with a soft shadow onto an RGBA image."""
    w, h = img.size
    scale = (h * height_frac) / 18.5
    bw, bh = 11 * scale, 18.5 * scale
    ox = w * cx_frac - bw / 2
    oy = h * cy_frac - bh / 2
    pts = [(ox + x * scale, oy + y * scale) for (x, y) in CURSOR]

    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ds = ImageDraw.Draw(shadow)
    off = 7 * SS
    ds.polygon([(x + off, y + off) for (x, y) in pts], fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(10 * SS))
    img.alpha_composite(shadow)

    d = ImageDraw.Draw(img)
    # subtle wireless arcs near the cursor tip
    ax, ay = ox, oy
    for rr in (10, 17, 24):
        r = rr * scale
        d.arc([ax - r, ay - r, ax + r, ay + r],
              start=-58, end=20, fill=(255, 255, 255, 150), width=int(2.4 * scale))
    d.polygon(pts, fill=(255, 255, 255, 255))


def save(img, name):
    img.resize((S, S), Image.LANCZOS).save(os.path.join(OUT, name))
    print("wrote", name)


# --- background.png (opaque gradient) ---
bg = gradient(W, W, TOP, BOT).convert("RGBA")
save(bg, "background.png")

# --- icon.png (gradient + cursor, full bleed) ---
icon = bg.copy()
draw_cursor(icon, height_frac=0.46)
save(icon, "icon.png")

# --- foreground.png (transparent, cursor in adaptive safe zone) ---
fg = Image.new("RGBA", (W, W), (0, 0, 0, 0))
draw_cursor(fg, height_frac=0.34)   # smaller: launchers crop adaptive icons
save(fg, "foreground.png")

print("done")
