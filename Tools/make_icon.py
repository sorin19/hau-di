#!/usr/bin/env python3
"""Generates the app icon (AppIcon.appiconset) without external dependencies.

Run: python3 Tools/make_icon.py

The "blue" variant from design/hau-di-icons-preview.html: the shape from cx-ro-logo.svg (without text),
drawn with 19 white stripes (30% of the pitch) on a blue gradient from the logo palette.

The image is opaque over the whole surface (full-bleed): macOS 26 crops it to its own icon shape.
An icon with transparent margins (the old 824x824 template) would be shown smaller, on a gray background.
The geometry is the same as in hau-di/Core/LogoGeometry.swift.
"""
import json
import math
import os
import struct
import zlib

SIZE = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "hau-di", "Assets.xcassets", "AppIcon.appiconset")

STRIPES = 19
RATIO = 0.30
# In the preview, the logo is 640 px wide in a rounded 824 px square; keep the same proportion.
LOGO_WIDTH = SIZE * 640 / 824

# The cx.ro logo data (as in hau-di/Core/BrandMark.swift) is NOT covered by the GPL license; see BRANDING.md.
# The generated icons (AppIcon.appiconset) are excluded from the license too.
HALF_W = 4361.0
OUTER = (4359.0, 2449.0, 1633.0, 2271.0)  # rx, ry, end of the arm (x, y)
HOLE = (3376.0, 1897.0, 2124.0, 1475.0)


def hsl(h, s, l):
    c = (1 - abs(2 * l - 1)) * s
    hp = (h % 360) / 60
    x = c * (1 - abs(hp % 2 - 1))
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][min(int(hp), 5)]
    m = l - c / 2
    return ((r + m) * 255, (g + m) * 255, (b + m) * 255)


TOP = hsl(219, 0.99, 0.62)
BOTTOM = hsl(219, 0.99, 0.45)
FG = (255.0, 255.0, 255.0)


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def sector_sdf(u, v, sector):
    """Approximate distance (in logo units) to the right-hand sector; positive = outside."""
    rx, ry, tx, ty = sector
    k = ty / tx
    arms = (abs(v) - k * u) / math.sqrt(1 + k * k)
    g = (u / rx) ** 2 + (v / ry) ** 2 - 1
    grad = math.hypot(2 * u / (rx * rx), 2 * v / (ry * ry)) or 1e-9
    return max(arms, g / grad)


def shape_sdf(u, v):
    u = abs(u)
    return max(sector_sdf(u, v, OUTER), -sector_sdf(u, v, HOLE))


def render():
    scale = LOGO_WIDTH / (2 * HALF_W)  # pixels per logo unit
    cx = cy = SIZE / 2
    pitch = 2 * HALF_W / STRIPES
    stripes = []
    for i in range(STRIPES):
        x0 = -HALF_W + i * pitch + pitch * (1 - RATIO) / 2
        stripes.append((cx + x0 * scale, cx + (x0 + pitch * RATIO) * scale))
    top_limit = cy - 2300 * scale
    bottom_limit = cy + 2300 * scale

    pixels = bytearray(SIZE * SIZE * 4)
    for y in range(SIZE):
        py = y + 0.5
        t = py / SIZE
        bg = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]
        in_band = top_limit <= py <= bottom_limit
        for x in range(SIZE):
            cover = 0.0
            if in_band:
                for sx0, sx1 in stripes:
                    if sx1 <= x or sx0 >= x + 1:
                        continue
                    horizontal = min(x + 1, sx1) - max(x, sx0)
                    d = shape_sdf((x + 0.5 - cx) / scale, (py - cy) / scale) * scale
                    cover += horizontal * clamp(0.5 - d)
            cover = clamp(cover)
            i = (y * SIZE + x) * 4
            for c in range(3):
                pixels[i + c] = int(round(clamp(bg[c] + (FG[c] - bg[c]) * cover, 0, 255)))
            pixels[i + 3] = 255
    return pixels


def downsample(pixels, size):
    half = size // 2
    out = bytearray(half * half * 4)
    for y in range(half):
        for x in range(half):
            acc = [0, 0, 0, 0]
            for dy in (0, 1):
                for dx in (0, 1):
                    i = ((2 * y + dy) * size + (2 * x + dx)) * 4
                    for c in range(4):
                        acc[c] += pixels[i + c]
            o = (y * half + x) * 4
            for c in range(4):
                out[o + c] = (acc[c] + 2) // 4
    return out


def write_png(path, pixels, size):
    raw = b"".join(b"\x00" + bytes(pixels[y * size * 4:(y + 1) * size * 4]) for y in range(size))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    levels = {SIZE: render()}
    size = SIZE
    while size > 16:
        levels[size // 2] = downsample(levels[size], size)
        size //= 2

    images = []
    for point in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = point * scale
            name = f"icon_{point}x{point}{'@2x' if scale == 2 else ''}.png"
            write_png(os.path.join(OUT, name), levels[px], px)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{point}x{point}"})

    with open(os.path.join(OUT, "Contents.json"), "w") as fh:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, fh, indent=2)
    print("Icon generated in", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
