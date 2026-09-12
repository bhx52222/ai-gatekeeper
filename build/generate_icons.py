#!/usr/bin/env python3
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
ICONSET = ASSETS / "icon.iconset"
ASSETS.mkdir(exist_ok=True)
ICONSET.mkdir(exist_ok=True)


def make_icon(size):
    scale = size / 1024
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    margin = int(70 * scale)
    radius = int(215 * scale)
    draw.rounded_rectangle((margin, margin, size - margin, size - margin), radius=radius, fill=(11, 22, 43, 255), outline=(67, 126, 226, 255), width=max(1, int(18 * scale)))
    shield = [(512, 196), (766, 285), (723, 644), (512, 824), (301, 644), (258, 285)]
    shield = [(int(x * scale), int(y * scale)) for x, y in shield]
    draw.polygon(shield, fill=(69, 205, 166, 255))
    check = [(376, 508), (468, 603), (658, 398)]
    check = [(int(x * scale), int(y * scale)) for x, y in check]
    draw.line(check, fill=(7, 23, 38, 255), width=max(2, int(55 * scale)), joint="curve")
    return image


for size, names in {
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
}.items():
    icon = make_icon(size)
    for name in names:
        icon.save(ICONSET / name)

subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ASSETS / "icon.icns")], check=True)
make_icon(256).save(ASSETS / "icon.ico", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
print(ASSETS / "icon.icns")
print(ASSETS / "icon.ico")
