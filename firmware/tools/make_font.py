#!/usr/bin/env python3
"""Rasterize OFL Noto Sans CJK SC to a constant-space LVGL 9.5 BMP font.
Dependencies: Pillow==11.3.0, fonttools==4.59.1. No device access.
"""
import argparse
import hashlib
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
cmap = TTFont(args.source).getBestCmap()
font = ImageFont.truetype(str(args.source), 16)
# One 33-byte record per BMP codepoint: advance (0=absent), 32-byte packed mask.
# All mapped BMP glyphs, including common Chinese and Extension A; no RAM index.
records = bytearray(65536 * 33)
for cp in sorted(cmap):
    if cp > 0xFFFF or cp < 32 or 0xD800 <= cp <= 0xDFFF:
        continue
    advance = min(16, max(1, round(font.getlength(chr(cp)))))
    image = Image.new("1", (16, 16), 0)
    draw = ImageDraw.Draw(image)
    # Noto's ideographic em box sits between baseline-14 and baseline+2.
    draw.text((0, 14), chr(cp), font=font, fill=1, anchor="ls", stroke_width=0)
    bitmap = image.tobytes()
    offset = cp * 33
    records[offset] = advance
    records[offset + 1:offset + 1 + len(bitmap)] = bitmap
args.output.write_bytes(records)
print("source SHA256:", hashlib.sha256(args.source.read_bytes()).hexdigest())
print("font SHA256:", hashlib.sha256(records).hexdigest())
print("bytes:", len(records))
