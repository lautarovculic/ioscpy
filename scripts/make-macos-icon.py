#!/usr/bin/env python3
"""Shape the square source logo into a standard macOS rounded app icon.

macOS app icons are not full squares. The artwork sits on a rounded rectangle
inset within the canvas. This follows the Big Sur grid: an 824px rounded body
centered in a 1024px canvas (about 100px of clear margin), with a corner radius
near 22.5% of the body.
"""
from PIL import Image, ImageDraw

SRC = "host/assets/ioscpyIcon.png"
OUT = "host/assets/AppIcon.png"

CANVAS = 1024
BODY = 824
MARGIN = (CANVAS - BODY) // 2
RADIUS = 186

src = Image.open(SRC).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)

mask = Image.new("L", (BODY, BODY), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, BODY - 1, BODY - 1], radius=RADIUS, fill=255)

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
canvas.paste(src, (MARGIN, MARGIN), mask)
canvas.save(OUT)
print(f"wrote {OUT} ({CANVAS}x{CANVAS}, body {BODY}, radius {RADIUS})")
