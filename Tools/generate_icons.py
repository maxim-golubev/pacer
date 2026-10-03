#!/usr/bin/env python3
"""Generate Pacer's icons: a speedometer gauge whose needle shows the mode.

Writes into ../Resources:
  - MenuBarIcon{Full,Balanced,Eco}Template.png / @2x.png
        monochrome menu-bar templates, needle at 97 / 70 / 20 %
        (the app swaps them as the mode changes)
  - AppIcon.icns
        white gauge (needle at 70 %, the Balanced sweet spot) on a
        green→teal gradient

Run:  python3 Tools/generate_icons.py
"""
import math
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

RES = Path(__file__).resolve().parent.parent / "Resources"

# PIL angles: 0° at 3 o'clock, increasing clockwise (y axis points down).
# Classic speedometer: bottom-left → over the top → bottom-right.
SWEEP_START, SWEEP_END = 135.0, 405.0
APP_DUTY = 0.70                                # app icon: the Balanced default
MODE_DUTY = {"Full": 0.97, "Balanced": 0.70, "Eco": 0.20}
# Vertical anchor of the gauge centre. The glyph's bounding box is balanced
# around 0.5 at ~0.55, but the hub/needle mass below centre makes that read
# low — pull up a touch for the optical centre.
CY = 0.535


def polar(cx, cy, r, deg):
    rad = math.radians(deg)
    return cx + r * math.cos(rad), cy + r * math.sin(rad)


def draw_gauge(side, color, duty, faint_rest=True):
    """Gauge glyph with the needle at `duty`, on a transparent square canvas.

    Draw large (PIL has no antialiasing) and let the caller downscale."""
    img = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = side / 2.0, side * CY
    R = side * 0.40                            # arc outer radius
    W = R * 0.26                               # arc band width (strokes inward)
    needle_deg = SWEEP_START + duty * (SWEEP_END - SWEEP_START)

    def arc(a0, a1, alpha):
        col = (*color, alpha)
        d.arc([cx - R, cy - R, cx + R, cy + R], a0, a1,
              fill=col, width=int(round(W)))
        rm = R - W / 2.0                       # round caps on the band ends
        for a in (a0, a1):
            x, y = polar(cx, cy, rm, a)
            d.ellipse([x - W / 2, y - W / 2, x + W / 2, y + W / 2], fill=col)

    if faint_rest:                             # un-swept remainder, ghosted
        arc(needle_deg, SWEEP_END, 110)
    arc(SWEEP_START, needle_deg if faint_rest else SWEEP_END, 255)

    # tapered needle from the hub toward needle_deg, stopping short of the band
    col = (*color, 255)
    tip_r = R - 1.55 * W
    bw, tw = side * 0.030, side * 0.009        # half-widths at base and tip
    a = math.radians(needle_deg)
    ux, uy = math.cos(a), math.sin(a)
    px, py = -uy, ux
    tx, ty = cx + tip_r * ux, cy + tip_r * uy
    d.polygon([(cx + bw * px, cy + bw * py), (tx + tw * px, ty + tw * py),
               (tx - tw * px, ty - tw * py), (cx - bw * px, cy - bw * py)],
              fill=col)
    hub = side * 0.062
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=col)
    return img


def menu_bar_icons() -> None:
    """Black-on-transparent templates; AppKit tints them to match the menu
    bar. One per mode — the needle position is the mode indicator."""
    for mode, duty in MODE_DUTY.items():
        glyph = draw_gauge(800, (0, 0, 0), duty)
        for size, suffix in [(20, ""), (40, "@2x")]:
            name = f"MenuBarIcon{mode}Template{suffix}.png"
            glyph.resize((size, size), Image.LANCZOS).save(RES / name)
            print(f"wrote {name}")


def app_icon() -> None:
    """macOS rounded-rect icon: white gauge on a green→teal gradient."""
    S, margin, radius = 1024, 100, 186
    rect = S - 2 * margin

    tt = np.linspace(0.0, 1.0, rect)[:, None]
    top = np.array([74, 222, 128])             # light green
    bot = np.array([15, 118, 110])             # deep teal
    grad = np.zeros((rect, rect, 4), dtype=np.uint8)
    for ch in range(3):
        grad[..., ch] = (top[ch] * (1 - tt) + bot[ch] * tt).astype(np.uint8)
    grad[..., 3] = 255

    mask = Image.new("L", (rect, rect), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, rect - 1, rect - 1], radius=radius, fill=255)

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.paste(Image.fromarray(grad, "RGBA"), (margin, margin), mask)

    gside = int(round(rect * 0.96))
    glyph = draw_gauge(2880, (255, 255, 255), APP_DUTY).resize(
        (gside, gside), Image.LANCZOS)
    off = margin + (rect - gside) // 2
    canvas.paste(glyph, (off, off), glyph)

    iconset = RES / "Pacer.iconset"
    if iconset.exists():
        for f in iconset.iterdir():
            f.unlink()
    else:
        iconset.mkdir(parents=True)
    for s in (16, 32, 128, 256, 512):
        canvas.resize((s, s), Image.LANCZOS).save(iconset / f"icon_{s}x{s}.png")
        canvas.resize((s * 2, s * 2), Image.LANCZOS).save(
            iconset / f"icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(RES / "AppIcon.icns")], check=True)
    for f in iconset.iterdir():
        f.unlink()
    iconset.rmdir()
    print("wrote AppIcon.icns")


def main() -> None:
    RES.mkdir(parents=True, exist_ok=True)
    menu_bar_icons()
    app_icon()


if __name__ == "__main__":
    main()
