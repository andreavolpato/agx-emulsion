#!/usr/bin/env python3
"""Measure a window capture against the drawing.

    Tools/compare-layout.py design/snapshots/window-16x9.png

Finds the four card-coloured (#2c2d2b) regions in the capture and reports
each one's rectangle in points next to the SVG's rectangle (÷2), plus the
delta. Anything over 2 pt is drift worth looking at. The capture must be a
1920×1080 window at 2× (3840×2160 px), which is the drawing's own frame.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

CARD = np.array([0x2C, 0x2D, 0x2B])
# From sample_frontend.svg, ÷2: (name, x, y, w, h)
DRAWING = {
    "left":  (17.9 / 2, 14.1 / 2, 656.9 / 2, 2131.8 / 2),
    "top":   (690.5 / 2, 15.5 / 2, 2547.9 / 2, 82.7 / 2),
    "strip": (690.5 / 2, 1895.3 / 2, 2547.9 / 2, 250.6 / 2),
    "right": (3250.1 / 2, 15.5 / 2, 572.3 / 2, 2131.8 / 2),
}


def boxes(mask: np.ndarray, scale: float):
    """Bounding boxes of the large card-coloured regions, by column/row scans."""
    from scipy import ndimage
    lab, n = ndimage.label(mask)
    out = []
    for i in range(1, n + 1):
        ys, xs = np.where(lab == i)
        if len(xs) < 20000:
            continue
        out.append((xs.min() / scale, ys.min() / scale, (xs.max() - xs.min() + 1) / scale, (ys.max() - ys.min() + 1) / scale))
    return out


def main() -> None:
    path = Path(sys.argv[1])
    im = np.asarray(Image.open(path).convert("RGB")).astype(int)
    scale = im.shape[1] / 1920
    mask = (np.abs(im - CARD).sum(axis=2) < 12)
    found = boxes(mask, scale)
    ok = True
    for name, (x, y, w, h) in DRAWING.items():
        # Nearest by origin, but only if it is plausibly the same rectangle.
        # Without the size check a missing card matches whichever card is
        # closest and reports drift instead of absence -- which is what
        # happened when a collapsed filmstrip was matched against the top bar.
        candidates = [b for b in found if abs(b[2] - w) < max(40.0, w * 0.15)
                      and abs(b[3] - h) < max(40.0, h * 0.15)]
        best = min(candidates, key=lambda b: abs(b[0] - x) + abs(b[1] - y)) if candidates else None
        if best is None:
            print(f"{name:6s} MISSING -- no region of about {w:.0f}x{h:.0f} pt"); ok = False; continue
        d = [best[i] - (x, y, w, h)[i] for i in range(4)]
        flag = "" if max(abs(v) for v in d) <= 2.5 else "   <-- drift"
        if flag: ok = False
        print(f"{name:6s} drawing x={x:7.1f} y={y:6.1f} w={w:7.1f} h={h:7.1f} | capture x={best[0]:7.1f} y={best[1]:6.1f} w={best[2]:7.1f} h={best[3]:7.1f} | Δ {d[0]:+.1f} {d[1]:+.1f} {d[2]:+.1f} {d[3]:+.1f}{flag}")
    print("OK" if ok else "DRIFT")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
