"""Generate the Windows .ico and the Android launcher icons from the app icon."""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "..", "app", "public", "icon-512.png")
src = Image.open(SRC).convert("RGBA")

ico = os.path.join(ROOT, "heylogan.ico")
src.save(ico, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                                   (64, 64), (128, 128), (256, 256)])
print("wrote", ico, os.path.getsize(ico), "bytes")

for size in (48, 96, 192, 256, 512):
    out = os.path.join(ROOT, f"heylogan-{size}.png")
    src.resize((size, size), Image.LANCZOS).save(out, format="PNG")
    print("wrote", out)

densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
for name, size in densities.items():
    d = os.path.join(ROOT, "android", f"mipmap-{name}")
    os.makedirs(d, exist_ok=True)
    src.resize((size, size), Image.LANCZOS).save(os.path.join(d, "ic_launcher.png"), "PNG")

for name, size in {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}.items():
    d = os.path.join(ROOT, "android", f"mipmap-{name}")
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * 0.66)
    art = src.resize((inner, inner), Image.LANCZOS)
    off = (size - inner) // 2
    canvas.paste(art, (off, off), art)
    canvas.save(os.path.join(d, "ic_launcher_foreground.png"), "PNG")
print("android icons done")
