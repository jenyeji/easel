"""Builds Resources/AppIcon-1024.png from Resources/AppIcon.svg, adding soft shadows.

Run from the Easel folder:  python3 Resources/make-icon.py
Needs:  pip3 install cairosvg pillow
"""
import io
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
SIZE = 1024
TILE = (100, 100, 924, 924)      # the rounded square
TILE_RADIUS = 185
PAINTING = (182, 282, 842, 742)  # the painting's edges


def shadow(box, radius, blur, offset, opacity):
    mask = Image.new("L", (SIZE, SIZE), 0)
    x0, y0, x1, y1 = box
    ImageDraw.Draw(mask).rounded_rectangle((x0, y0 + offset, x1, y1 + offset), radius, fill=int(255 * opacity))
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    layer.putalpha(mask)
    return layer


svg = (HERE / "AppIcon.svg").read_bytes()
art = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg, output_width=SIZE, output_height=SIZE))).convert("RGBA")

# Shadow of the painting, kept inside the tile.
tile_mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(tile_mask).rounded_rectangle(TILE, TILE_RADIUS, fill=255)
painting_shadow = shadow(PAINTING, 0, 18, 18, 0.55)
painting_shadow.putalpha(Image.composite(painting_shadow.getchannel("A"), Image.new("L", (SIZE, SIZE), 0), tile_mask))

icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.alpha_composite(shadow(TILE, TILE_RADIUS, 16, 12, 0.45))   # tile shadow
tile_only = Image.composite(art, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), tile_mask)
icon.alpha_composite(tile_only)
icon.alpha_composite(painting_shadow)
# Everything drawn on top of the tile (painting, frame, handles).
overlay_svg = svg.replace(b'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)"/>', b"") \
                 .replace(b'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#glow)"/>', b"") \
                 .replace(b'<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="3"/>', b"")
overlay = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=overlay_svg, output_width=SIZE, output_height=SIZE))).convert("RGBA")
icon.alpha_composite(overlay)

icon.save(HERE / "AppIcon-1024.png")
print("Saved", HERE / "AppIcon-1024.png")
