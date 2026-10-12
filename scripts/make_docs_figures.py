#!/usr/bin/env python3
"""Builds the example images and the measurement chart for docs/index.html.

    python3 scripts/make_docs_figures.py

1. Paints two illustrated half-frame pair scans (a normal one and one with a
   dark night frame) into docs/img/.
2. Runs the plug-in's own Lua detection (HFSImage + HFSDetect, via lua5.1)
   on them, exactly as the plug-in does on a 1200 px preview.
3. Writes the measured brightness profile as an SVG chart, and the detected
   cut positions, into docs/index.html between the <!-- fig:... --> markers.

Needs lua5.1 and Python 3 with numpy and Pillow.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
IMG = os.path.join(DOCS, "img")
PLUGIN = os.path.join(ROOT, "HalfFrameSplitter.lrplugin")

FRAME_W, FRAME_H, GAP = 726, 968, 48  # two 18x24 mm frames and the gap between
FILM_BLACK = (9, 9, 11)


def gradient(h, w, top, bottom, curve=1.0):
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None] ** curve
    top, bottom = np.array(top, np.float32), np.array(bottom, np.float32)
    return np.broadcast_to(top + (bottom - top) * t, (h, w, 3)).copy()


def ridge(rng, w, base, amp, rough):
    """A mountain ridge line (y for every x)."""
    pts = np.cumsum(rng.normal(0, rough, w // 8 + 2))
    pts = (pts - pts.min()) / (np.ptp(pts) + 1e-6)
    ys = base - amp * pts
    return np.interp(np.arange(w), np.linspace(0, w, len(ys)), ys)


def mountains(rng):
    w, h = FRAME_W, FRAME_H
    img = gradient(h, w, (120, 165, 205), (250, 214, 170), 1.4)
    yy, xx = np.mgrid[0:h, 0:w]
    sun = np.exp(-(((xx - w * 0.68) ** 2 + (yy - h * 0.40) ** 2) / (2 * 38.0 ** 2)))
    glow = np.exp(-(((xx - w * 0.68) ** 2 + (yy - h * 0.40) ** 2) / (2 * 160.0 ** 2)))
    img += (sun[..., None] * np.array([255, 240, 200]) * 0.9 + glow[..., None] * np.array([90, 60, 20]))
    horizon = int(h * 0.66)
    layers = [((150, 160, 180), 0.47, 0.20, 1.0), ((92, 104, 128), 0.55, 0.18, 1.3), ((48, 58, 74), 0.66, 0.16, 1.7)]
    for color, base, amp, rough in layers:
        line = ridge(rng, w, h * base, h * amp, rough)
        mask = yy >= line[None, :]
        img[mask] = img[mask] * 0.15 + np.array(color, np.float32) * 0.85
    # lake: darkened mirror of the scene above the shore
    lake = img[horizon - (h - horizon):horizon][::-1] * 0.62 + np.array([10, 18, 30])
    img[horizon:] = lake[: h - horizon]
    img[horizon:horizon + 3] = img[horizon:horizon + 3] * 0.6
    return img


def city(rng, dusk_level=1.0):
    w, h = FRAME_W, FRAME_H
    img = gradient(h, w, (34, 48, 92), (236, 140, 82), 1.8) * dusk_level
    draw_mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(draw_mask)
    windows = []
    x = -10
    while x < w:
        bw = int(rng.integers(70, 150))
        top = int(h * rng.uniform(0.28, 0.58))
        d.rectangle([x, top, x + bw, h], fill=255)
        for wy in range(top + 18, h - 40, 26):
            for wx in range(x + 10, x + bw - 14, 22):
                if rng.random() < 0.45:
                    windows.append((wx, wy))
        x += bw + int(rng.integers(-6, 10))
    m = np.asarray(draw_mask, np.float32)[..., None] / 255
    img = img * (1 - m) + np.array([22, 26, 40], np.float32) * m
    for wx, wy in windows:
        img[wy:wy + 11, wx:wx + 8] = (255, 205, 120)
    # street
    img[int(h * 0.88):] = img[int(h * 0.88):] * 0.5 + np.array([30, 30, 36])
    return img


def night(rng):
    w, h = FRAME_W, FRAME_H
    img = gradient(h, w, (14, 16, 26), (6, 6, 9), 0.8)
    for _ in range(140):
        y, x = int(rng.integers(0, int(h * 0.6))), int(rng.integers(0, int(w * 0.62)))
        b = rng.uniform(80, 230)
        img[y:y + 2, x:x + 2] = b
    yy, xx = np.mgrid[0:h, 0:w]
    moon = ((xx - w * 0.24) ** 2 + (yy - h * 0.22) ** 2) < 30 ** 2
    img[moon] = (232, 228, 210)
    # black hills
    line = ridge(rng, w, h * 0.80, h * 0.10, 1.2)
    img[yy >= line[None, :]] = (5, 5, 7)
    return img


def finish(frame, rng):
    h, w = frame.shape[:2]
    yy = np.linspace(-1, 1, h, dtype=np.float32)[:, None]
    xx = np.linspace(-1, 1, w, dtype=np.float32)[None, :]
    frame = frame * (1 - 0.28 * np.clip((xx ** 2 + yy ** 2) / 2, 0, 1))[..., None]
    return frame


def pair(left, right, rng):
    out = np.zeros((FRAME_H, FRAME_W * 2 + GAP, 3), np.float32)
    out[:] = FILM_BLACK
    out[:, :FRAME_W] = finish(left, rng)
    out[:, FRAME_W + GAP:] = finish(right, rng)
    out += rng.normal(0, 3.5, out.shape)  # film grain
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")
    return img.filter(ImageFilter.GaussianBlur(0.6))


def measure(img):
    """Runs the plug-in's detection on a sips-like 1200 px preview."""
    w, h = img.size
    s = 1200 / max(w, h)
    small = img.resize((round(w * s), round(h * s)), Image.LANCZOS)
    with tempfile.TemporaryDirectory() as tmp:
        bmp = os.path.join(tmp, "preview.bmp")
        small.save(bmp, "BMP")
        lua = r"""
package.path = arg[1] .. '/?.lua;' .. package.path
local I, D = require 'HFSImage', require 'HFSDetect'
local f = assert(io.open(arg[2], 'rb')); local data = f:read('*a'); f:close()
local img = assert(I.decodeBMPHistograms(data, 32))
local det = D.analyze(img, {})
local p90 = D.percentileProfile(img.colHist, img.width, img.bins, 0.9)
local out = {}
for i = 1, #p90 do out[i] = string.format('%.1f', p90[i]) end
print(string.format('{"width": %d, "found": %s, "confident": %s, "usableGuess": %s, "gapStart": %.5f, "gapEnd": %.5f, "lineLevel": %.2f, "contrast": %.2f, "reasons": "%s", "p90": [%s]}',
  img.width, tostring(det.found), tostring(det.confident), tostring(det.usableGuess or false),
  det.gapStart or -1, det.gapEnd or -1, det.lineLevel or -1, det.contrast or -1,
  table.concat(det.reasons, '; '), table.concat(out, ',')))
"""
        res = subprocess.run(["lua5.1", "-", PLUGIN, bmp], input=lua, capture_output=True, text=True, check=True)
    return json.loads(res.stdout)


def chart_svg(m):
    """Brightness profile chart, coloured through the page's CSS classes."""
    W, H = 720, 250
    left, right, top, bottom = 52, 16, 18, 44
    pw, ph = W - left - right, H - top - bottom
    p = m["p90"]
    n = len(p)
    buckets = 360
    pts = []
    for b in range(buckets):
        a, z = b * n // buckets, max(b * n // buckets + 1, (b + 1) * n // buckets)
        v = min(p[a:z])  # keep the dip visible
        x = left + pw * (b + 0.5) / buckets
        y = top + ph * (1 - v / 255)
        pts.append("%.1f,%.1f" % (x, y))
    g0 = left + pw * m["gapStart"]
    g1 = left + pw * m["gapEnd"]
    thr = m["lineLevel"] + 0.5 * m["contrast"]
    ty = top + ph * (1 - thr / 255)
    parts = [
        '<svg class="chart" viewBox="0 0 %d %d" role="img" aria-labelledby="chart-title chart-desc">' % (W, H),
        '<title id="chart-title">Brightness of every column of the example scan</title>',
        '<desc id="chart-desc">The line stays high across both pictures and drops to almost black between '
        '%.1f%% and %.1f%% of the width: the gap between the frames.</desc>' % (m["gapStart"] * 100, m["gapEnd"] * 100),
        '<rect class="chart-band" x="%.1f" y="%d" width="%.1f" height="%d"/>' % (g0, top, max(g1 - g0, 1), ph),
    ]
    for v, label in ((0, "0"), (128, "128"), (255, "255")):
        y = top + ph * (1 - v / 255)
        parts.append('<line class="chart-grid" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>' % (left, left + pw, y, y))
        parts.append('<text class="chart-tick" x="%d" y="%.1f" text-anchor="end">%s</text>' % (left - 8, y + 4, label))
    for v in (0, 25, 50, 75, 100):
        x = left + pw * v / 100
        parts.append('<text class="chart-tick" x="%.1f" y="%d" text-anchor="middle">%d%%</text>' % (x, top + ph + 18, v))
    parts.append('<line class="chart-threshold" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>' % (left, left + pw, ty, ty))
    parts.append('<polyline class="chart-line" points="%s"/>' % " ".join(pts))
    for x in (g0, g1):
        parts.append('<line class="chart-cut" x1="%.1f" x2="%.1f" y1="%d" y2="%d"/>' % (x, x, top - 6, top + ph))
    parts.append('<text class="chart-label" x="%.1f" y="%.1f" text-anchor="start">halfway level</text>' % (left + 6, ty - 6))
    parts.append('<text class="chart-axis" x="%.1f" y="%d" text-anchor="middle">position across the scan</text>' % (left + pw / 2, H - 4))
    parts.append('<text class="chart-axis" transform="translate(13 %.1f) rotate(-90)" text-anchor="middle">brightness</text>' % (top + ph / 2))
    parts.append("</svg>")
    return "\n".join(parts)


def replace_marker(html, name, content):
    pattern = re.compile(r"(<!-- fig:%s -->)(.*?)(<!-- /fig:%s -->)" % (name, name), re.S)
    if not pattern.search(html):
        raise SystemExit("marker fig:%s not found in docs/index.html" % name)
    return pattern.sub(lambda mt: mt.group(1) + "\n" + content + "\n" + mt.group(3), html)


def main():
    os.makedirs(IMG, exist_ok=True)
    rng = np.random.default_rng(35)
    normal = pair(mountains(rng), city(rng), rng)
    rng = np.random.default_rng(17)
    dark = pair(night(rng), city(rng, 0.9), rng)
    normal.save(os.path.join(IMG, "pair-example.jpg"), "JPEG", quality=84, optimize=True, progressive=True)
    dark.save(os.path.join(IMG, "pair-night.jpg"), "JPEG", quality=84, optimize=True, progressive=True)

    m1 = measure(normal)
    m2 = measure(dark)
    print("example:", {k: m1[k] for k in ("found", "confident", "gapStart", "gapEnd", "contrast")})
    print("night:  ", {k: m2[k] for k in ("found", "confident", "usableGuess", "gapStart", "gapEnd", "reasons")})
    if not m1["confident"]:
        raise SystemExit("the example scan should be detected confidently")
    if m2["confident"] or not m2["usableGuess"]:
        raise SystemExit("the night scan should be unclear but have a usable guess")

    path = os.path.join(DOCS, "index.html")
    with open(path, encoding="utf-8") as f:
        html = f.read()
    html = replace_marker(html, "chart", chart_svg(m1))
    html = replace_marker(html, "cuts", (
        '<script>window.HFS_EXAMPLE = %s;</script>' % json.dumps({
            "example": {"gapStart": round(m1["gapStart"], 4), "gapEnd": round(m1["gapEnd"], 4)},
            "night": {"guess": round((m2["gapStart"] + m2["gapEnd"]) / 2 * 100, 1),
                      "gapStart": round(m2["gapStart"], 4), "gapEnd": round(m2["gapEnd"], 4)},
        })))
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)
    print("updated", path)


if __name__ == "__main__":
    sys.exit(main())
