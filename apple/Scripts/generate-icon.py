#!/usr/bin/env python3
"""Generate the Prismo DNS iOS AppIcon set.

Master 1024×1024 icon:
  - vertical blue/indigo gradient background (top lighter, bottom deeper)
  - one white, tapered, gently curved brush stroke across the middle
  - subtle drop shadow under the stroke for a 3D "lift" effect
  - light brush-edge speckle so the stroke does not read as a solid blob

Renders into every iOS AppIcon slot declared in
Sources/PrismoApp/Assets.xcassets/AppIcon.appiconset/Contents.json.
"""

from __future__ import annotations

import json
import math
import random
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
APPICON_DIR = (HERE / "../Sources/PrismoApp/Assets.xcassets/AppIcon.appiconset").resolve()

MASTER = 1024


def make_gradient_background(size: int) -> Image.Image:
    """Vertical blue/indigo gradient with a touch of horizontal warmth."""
    top = (78, 140, 255)
    bottom = (37, 64, 178)
    img = Image.new("RGB", (size, size), bottom)
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        for x in range(size):
            # Mild radial highlight near upper-left, very subtle.
            hx = (x - size * 0.25) / size
            hy = (y - size * 0.20) / size
            d2 = hx * hx + hy * hy
            warmth = max(0.0, 0.10 - d2 * 0.6)
            px[x, y] = (
                min(255, r + int(warmth * 35)),
                min(255, g + int(warmth * 25)),
                min(255, b + int(warmth * 15)),
            )
    return img


def quadratic_bezier(p0, p1, p2, t):
    inv = 1.0 - t
    x = inv * inv * p0[0] + 2 * inv * t * p1[0] + t * t * p2[0]
    y = inv * inv * p0[1] + 2 * inv * t * p1[1] + t * t * p2[1]
    return x, y


def make_brushstroke(size: int) -> Image.Image:
    """Tapered white brush stroke on a transparent canvas, same size as bg."""
    # Use a high-resolution work canvas, then downsample for smooth edges.
    scale = 2
    W = size * scale
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer, "RGBA")

    # Bezier control points (relative to canvas, scaled up).
    p0 = (W * 0.22, W * 0.62)   # start: pointed tip, lower-left
    p1 = (W * 0.52, W * 0.32)   # control: arcs upward
    p2 = (W * 0.82, W * 0.58)   # end: pointed tip, lower-right

    peak_width = W * 0.085      # widest part of the stroke

    samples = 600
    rng = random.Random(42)

    for i in range(samples):
        t = i / (samples - 1)
        x, y = quadratic_bezier(p0, p1, p2, t)

        # Width tapers from 0 -> peak -> 0 along the curve, with a slight
        # asymmetry that mimics a real brush (peak biased toward 45%).
        bias = t / 0.45 if t < 0.45 else (1.0 - t) / 0.55
        w = peak_width * max(0.0, math.sin(min(1.0, bias) * math.pi / 2)) ** 1.1

        # Pre-shadow disc (offset below for a soft drop shadow).
        sd = w * 0.95
        draw.ellipse(
            (x - sd + W * 0.012, y - sd + W * 0.018,
             x + sd + W * 0.012, y + sd + W * 0.018),
            fill=(20, 10, 0, 70),
        )

    # Now stroke body in white on top of the shadow.
    for i in range(samples):
        t = i / (samples - 1)
        x, y = quadratic_bezier(p0, p1, p2, t)
        bias = t / 0.45 if t < 0.45 else (1.0 - t) / 0.55
        w = peak_width * max(0.0, math.sin(min(1.0, bias) * math.pi / 2)) ** 1.1
        # Tiny per-sample jitter for a brush-like edge.
        jitter = (rng.random() - 0.5) * w * 0.05
        ww = max(0.0, w + jitter)
        draw.ellipse((x - ww, y - ww, x + ww, y + ww), fill=(255, 255, 255, 255))

    # Soften shadow with blur on the shadow only: we re-extract by isolating
    # darker non-white pixels. Simpler: blur the whole layer slightly to
    # round microscopic stair-steps, then composite a sharper white pass
    # on top of it.
    soft = layer.filter(ImageFilter.GaussianBlur(radius=W * 0.0035))

    # Bristle texture: a few faint streaks running along the stroke.
    bristles = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bristles, "RGBA")
    for streak in range(8):
        offset = (streak - 3.5) * peak_width * 0.18
        for i in range(0, samples, 3):
            t = i / (samples - 1)
            x, y = quadratic_bezier(p0, p1, p2, t)
            bias = t / 0.45 if t < 0.45 else (1.0 - t) / 0.55
            w = peak_width * max(0.0, math.sin(min(1.0, bias) * math.pi / 2)) ** 1.1
            if w <= 0:
                continue
            # Perpendicular offset.
            if i + 1 < samples:
                x2, y2 = quadratic_bezier(p0, p1, p2, (i + 1) / (samples - 1))
                dx, dy = x2 - x, y2 - y
                nrm = math.hypot(dx, dy) or 1.0
                nx, ny = -dy / nrm, dx / nrm
            else:
                nx, ny = 0, 1
            cx = x + nx * offset
            cy = y + ny * offset
            r = max(0.5, w * 0.05)
            bd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 110))

    bristles = bristles.filter(ImageFilter.GaussianBlur(radius=W * 0.001))
    combined = Image.alpha_composite(soft, bristles)

    # Downsample back to target size for crisp edges.
    return combined.resize((size, size), Image.LANCZOS)


def render_master() -> Image.Image:
    bg = make_gradient_background(MASTER).convert("RGBA")
    stroke = make_brushstroke(MASTER)
    return Image.alpha_composite(bg, stroke)


def render_all():
    contents_path = APPICON_DIR / "Contents.json"
    with contents_path.open() as f:
        manifest = json.load(f)

    master = render_master()
    for image in manifest["images"]:
        filename = image.get("filename")
        if not filename:
            continue
        size_str = image["size"]
        scale = int(image["scale"].rstrip("x"))
        side = float(size_str.split("x")[0])
        pixel_side = int(round(side * scale))
        resized = master.resize((pixel_side, pixel_side), Image.LANCZOS)
        out = resized.convert("RGB")
        out_path = APPICON_DIR / filename
        out.save(out_path, format="PNG", optimize=True)
        print(f"wrote {out_path.name}  ({pixel_side}x{pixel_side})")


if __name__ == "__main__":
    render_all()
