"""Draw the app icon and build AppIcon.icns. Run: .venv/bin/python scripts/make_icon.py"""
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "macapp"
SCALE = 2
SIZE = 1024

INK = (23, 26, 33, 255)
PAPER = (250, 247, 240, 255)
AMBER = (245, 185, 66, 255)
BLUE = (90, 169, 255, 255)
LINE = (200, 196, 188, 255)


def canvas(size: int) -> Image.Image:
    return Image.new("RGBA", (size, size), (0, 0, 0, 0))


def rounded(draw: ImageDraw.ImageDraw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def draw_icon(size: int) -> Image.Image:
    s = size / 1024
    img = canvas(size)
    d = ImageDraw.Draw(img)

    # macOS-style squircle with the usual margin.
    rounded(d, [88 * s, 88 * s, 936 * s, 936 * s], 190 * s, INK)

    # A sheet of paper, slightly rotated by drawing a polygon.
    paper = [(322 * s, 216 * s), (702 * s, 216 * s), (742 * s, 256 * s),
             (742 * s, 808 * s), (322 * s, 808 * s)]
    d.polygon(paper, fill=PAPER)
    d.polygon([(702 * s, 216 * s), (702 * s, 256 * s), (742 * s, 256 * s)], fill=(222, 217, 207, 255))

    # Text lines; the middle one is the amber "current phrase".
    x0, x1 = 366 * s, 698 * s
    for i, y in enumerate(range(320, 720, 58)):
        colour = AMBER if i == 3 else (BLUE if i == 4 else LINE)
        height = 22 * s if i == 3 else 14 * s
        end = x1 - (60 * s if i in (2, 5) else 0)
        rounded(d, [x0, y * s, end, y * s + height], height / 2, colour)

    # A little voice wave under the sheet.
    for i, height in enumerate((18, 34, 50, 34, 18)):
        x = (392 + i * 62) * s
        rect = [x, (852 - height / 2) * s, x + 26 * s, (852 + height / 2) * s]
        rounded(d, rect, 13 * s, AMBER)

    return img


def main() -> None:
    # Soft shadow layer for the 1024 source.
    base = draw_icon(SIZE * SCALE).resize((SIZE, SIZE), Image.LANCZOS)
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([88, 88, 936, 936], radius=190, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    icon = Image.alpha_composite(shadow, base)

    iconset = OUT / "AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir(parents=True)
    for name, px in (
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ):
        icon.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    icon.save(OUT / "AppIcon.png")


if __name__ == "__main__":
    main()
