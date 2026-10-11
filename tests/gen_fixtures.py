#!/usr/bin/env python3
"""Generates synthetic half-frame pair scans for the unit tests.

Writes into tests/fixtures/ (git-ignored):
  * <case>.bmp      - the image as `sips -Z 1200 -s format bmp` would hand it to the plugin
  * orient_*.jpg/.tif - small files with known EXIF/TIFF orientation tags
  * manifest.lua    - expected results, loaded by run_tests.lua

Needs Python 3 with numpy and Pillow. Deterministic (fixed seeds).
"""
import os
import struct
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")
ANALYSIS_MAX = 1200


def smooth_noise(rng, h, w, scale):
    """Low-frequency random field in 0..1 (cheap 'natural' texture)."""
    sh, sw = max(2, h // scale), max(2, w // scale)
    small = rng.random((sh, sw)).astype(np.float32)
    img = Image.fromarray((small * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32) / 255.0


def scene(rng, h, w, kind, vignette=0.0):
    """Returns an RGB float image (0..255) for one frame."""
    y = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    base = (
        0.5 * smooth_noise(rng, h, w, 8)
        + 0.3 * smooth_noise(rng, h, w, 30)
        + 0.2 * smooth_noise(rng, h, w, 120)
    )
    if kind == "normal":
        lum = 60 + 150 * base + 30 * (1 - y)  # brighter sky at the top
    elif kind == "night":
        lum = 8 + 30 * base ** 3
        # a few bright lights
        for _ in range(25):
            cy, cx = rng.integers(0, h), rng.integers(0, w)
            r = rng.integers(3, 15)
            lum[max(0, cy - r):cy + r, max(0, cx - r):cx + r] = 200
    elif kind == "highkey":
        lum = 180 + 60 * base
    elif kind == "dim":
        lum = 70 + 90 * base
    elif kind == "dusk":
        lum = 15 + 70 * base ** 2
        for _ in range(40):
            cy, cx = rng.integers(0, h), rng.integers(0, w)
            r = rng.integers(3, 20)
            lum[max(0, cy - r):cy + r, max(0, cx - r):cx + r] = 220
    elif kind == "black":
        lum = 6 + 4 * base
    else:
        raise ValueError(kind)
    if vignette:
        yy = np.linspace(-1, 1, h, dtype=np.float32)[:, None]
        xx = np.linspace(-1, 1, w, dtype=np.float32)[None, :]
        lum = lum * (1 - vignette * np.clip((xx ** 2 + yy ** 2) / 2, 0, 1))
    tint = np.stack([lum * 1.05, lum, lum * 0.9], axis=-1)
    return np.clip(tint, 0, 255)


def make_pair(rng, case):
    """Builds a full-resolution pair scan; returns (rgb uint8 array, truth dict)."""
    H = case.get("H", 2400)
    W = case.get("W", 3600)
    gap_frac = case.get("gap", 0.03)
    pos = case.get("pos", 0.5)
    gap_level = case.get("gap_level", 8)
    border = case.get("border", 0.0)

    img = np.zeros((H, W, 3), dtype=np.float32)
    img[:] = gap_level

    bx = int(round(W * border))
    by = int(round(H * border))
    inner_w = W - 2 * bx
    gap_px = int(round(W * gap_frac))
    g0 = bx + int(round(inner_w * pos - gap_px / 2))
    g1 = g0 + gap_px

    kinds = case.get("kinds", ("normal", "normal"))
    if g0 - bx > 0:
        img[by:H - by, bx:g0] = scene(rng, H - 2 * by, g0 - bx, kinds[0], case.get("vignette", 0))
    if W - bx - g1 > 0:
        img[by:H - by, g1:W - bx] = scene(rng, H - 2 * by, W - bx - g1, kinds[1], case.get("vignette", 0))

    if case.get("pole"):
        # dark vertical object spanning the full height inside the left frame
        px = bx + int((g0 - bx) * 0.75)
        img[by:H - by, px:px + int(W * 0.012)] = 22

    if case.get("leak"):
        # light leak fogging the top 20% of the gap and the frame edges near it
        lh = int(H * 0.2)
        img[:lh, g0 - 40:g1 + 40] = np.array([230, 140, 60], dtype=np.float32)

    if case.get("dust"):
        for _ in range(40):
            yy = rng.integers(0, H)
            xx = rng.integers(g0, max(g0 + 1, g1))
            img[yy:yy + 4, xx:xx + 4] = 250
        img[int(H * 0.3):int(H * 0.7), (g0 + g1) // 2] = 255  # long thin scratch

    # film grain
    img += rng.normal(0, case.get("grain", 4), img.shape).astype(np.float32)
    img = np.clip(img, 0, 255).astype(np.uint8)

    pil = Image.fromarray(img, "RGB")
    if case.get("rotate"):
        pil = pil.rotate(case["rotate"], resample=Image.BICUBIC, expand=False, fillcolor=(gap_level,) * 3)

    truth = {"axis": "x", "gapStart": g0 / W, "gapEnd": g1 / W}
    if case.get("portrait"):
        # rotate the whole scan 90 degrees: the line becomes horizontal
        pil = pil.transpose(Image.ROTATE_90)  # counter-clockwise
        # x' = y, y' = W - 1 - x  => gap rows run from (W-g1) to (W-g0)
        truth = {"axis": "y", "gapStart": (W - g1) / W, "gapEnd": (W - g0) / W}
    if case.get("grey"):
        pil = pil.convert("L")
    return pil, truth


def sips_like(pil):
    """What `sips -Z 1200` does: fit the long side into 1200 px."""
    w, h = pil.size
    s = ANALYSIS_MAX / max(w, h)
    return pil.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)


def write_bmp_v5_32(pil, path, top_down=False):
    """32-bit BMP with a BITMAPV5HEADER and BI_BITFIELDS (as ImageIO may write)."""
    rgba = np.asarray(pil.convert("RGBA"))
    h, w = rgba.shape[:2]
    bgra = rgba[:, :, [2, 1, 0, 3]]
    rows = bgra if top_down else bgra[::-1]
    pixels = rows.tobytes()
    header_size = 124
    offset = 14 + header_size
    file_header = b"BM" + struct.pack("<IHHI", offset + len(pixels), 0, 0, offset)
    info = struct.pack(
        "<IiiHHIIiiII",
        header_size, w, -h if top_down else h, 1, 32, 3, len(pixels), 2835, 2835, 0, 0,
    )
    masks = struct.pack("<IIII", 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    rest = b"sRGB"[::-1] + b"\0" * (124 - 40 - 16 - 4)
    with open(path, "wb") as f:
        f.write(file_header + info + masks + rest + pixels)


def write_bmp_16_565(pil, path):
    """16-bit BMP, BI_BITFIELDS 5-6-5 (exercises the generic decoding path)."""
    rgb = np.asarray(pil.convert("RGB")).astype(np.uint32)
    h, w = rgb.shape[:2]
    v = ((rgb[:, :, 0] >> 3) << 11) | ((rgb[:, :, 1] >> 2) << 5) | (rgb[:, :, 2] >> 3)
    stride = ((16 * w + 31) // 32) * 4
    data = bytearray()
    for row in v[::-1]:
        b = row.astype("<u2").tobytes()
        data += b + b"\0" * (stride - len(b))
    offset = 14 + 40 + 12
    file_header = b"BM" + struct.pack("<IHHI", offset + len(data), 0, 0, offset)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 16, 3, len(data), 2835, 2835, 0, 0)
    masks = struct.pack("<III", 0xF800, 0x07E0, 0x001F)
    with open(path, "wb") as f:
        f.write(file_header + info + masks + bytes(data))


def tiff_with_orientation(path, orientation, big_endian=False, ifd_at_end=False):
    """Minimal 4x2 greyscale TIFF with an orientation tag."""
    e = ">" if big_endian else "<"
    w, h = 4, 2
    pixels = bytes(range(0, 8 * 30, 30))
    entries = [
        (256, 3, w), (257, 3, h), (258, 3, 8), (259, 3, 1), (262, 3, 1),
        (273, 4, 0), (274, 3, orientation), (277, 3, 1), (278, 3, h), (279, 4, len(pixels)),
    ]
    ifd_len = 2 + 12 * len(entries) + 4
    if ifd_at_end:
        data_off, ifd_off = 8, 8 + len(pixels)
    else:
        ifd_off, data_off = 8, 8 + ifd_len
    out = (b"MM" if big_endian else b"II") + struct.pack(e + "HI", 42, ifd_off)
    ifd = struct.pack(e + "H", len(entries))
    for tag, typ, val in entries:
        if tag == 273:
            val = data_off
        if typ == 3:
            ifd += struct.pack(e + "HHIHH", tag, typ, 1, val, 0)
        else:
            ifd += struct.pack(e + "HHII", tag, typ, 1, val)
    ifd += struct.pack(e + "I", 0)
    if ifd_at_end:
        out += pixels + ifd
    else:
        out += ifd + pixels
    with open(path, "wb") as f:
        f.write(out)


CASES = [
    # name, settings, expectation
    ("basic", {}, "confident"),
    ("offset", {"pos": 0.43, "gap": 0.025}, "confident"),
    ("dusk", {"kinds": ("dusk", "dusk")}, "confident"),
    ("onedusk", {"kinds": ("dusk", "highkey")}, "confident"),
    ("vignette", {"vignette": 0.7}, "confident"),
    ("highkey", {"kinds": ("highkey", "highkey"), "gap_level": 20}, "confident"),
    # near-black night frames have the same density as the unexposed gap
    ("night", {"kinds": ("night", "night")}, "not_confident"),
    ("onenight", {"kinds": ("night", "highkey")}, "guess_end"),
    ("onenight_r", {"kinds": ("highkey", "night")}, "guess_start"),
    ("thin", {"gap": 0.008}, "confident"),
    ("greygap", {"kinds": ("dim", "dim"), "gap_level": 45}, "confident"),
    ("portrait", {"portrait": True}, "confident"),
    ("rotated", {"rotate": 0.6, "gap": 0.035}, "confident"),
    ("leak", {"leak": True, "gap": 0.035}, "confident"),
    ("dust", {"dust": True}, "confident"),
    ("borders", {"border": 0.05}, "confident"),
    ("bw", {"grey": True}, "confident"),
    ("nogap", {"gap": 0.0}, "not_confident"),
    ("blankframe", {"kinds": ("normal", "black")}, "not_confident"),
    ("pole", {"pole": True}, "any"),
    ("squareish", {"W": 2700, "H": 2400}, "confident"),
]


def lua_str(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(float(v))
    return '"%s"' % v


def main():
    os.makedirs(OUT, exist_ok=True)
    lines = ["return {", "  cases = {"]
    for i, (name, case, expect) in enumerate(CASES):
        rng = np.random.default_rng(1000 + i)
        pil, truth = make_pair(rng, case)
        small = sips_like(pil)
        path = os.path.join(OUT, name + ".bmp")
        small.save(path, "BMP")  # 24-bit (RGB) or 8-bit palette (L)
        border = case.get("border", 0.0)
        lines.append(
            "    { name = %s, file = %s, expect = %s, axis = %s, gapStart = %s, gapEnd = %s, border = %s },"
            % (lua_str(name), lua_str(name + ".bmp"), lua_str(expect), lua_str(truth["axis"]),
               lua_str(truth["gapStart"]), lua_str(truth["gapEnd"]), lua_str(border))
        )

    # BMP format variants of the basic case
    rng = np.random.default_rng(1000)
    pil, truth = make_pair(rng, {})
    small = sips_like(pil)
    write_bmp_v5_32(small, os.path.join(OUT, "fmt_v5_32.bmp"))
    write_bmp_v5_32(small, os.path.join(OUT, "fmt_v5_32_topdown.bmp"), top_down=True)
    write_bmp_16_565(small, os.path.join(OUT, "fmt_16_565.bmp"))
    small.convert("RGBA").save(os.path.join(OUT, "fmt_pil_rgba.bmp"), "BMP")
    small.convert("P", palette=Image.ADAPTIVE, colors=16).save(os.path.join(OUT, "fmt_4bit.bmp"), "BMP")
    small.convert("1").save(os.path.join(OUT, "fmt_1bit.bmp"), "BMP")
    lines.append("  },")
    lines.append("  formats = {")
    for f in ["fmt_v5_32.bmp", "fmt_v5_32_topdown.bmp", "fmt_16_565.bmp", "fmt_pil_rgba.bmp", "fmt_4bit.bmp"]:
        lines.append("    { file = %s, gapStart = %s, gapEnd = %s }," % (lua_str(f), lua_str(truth["gapStart"]), lua_str(truth["gapEnd"])))
    lines.append("  },")
    # reference histogram sanity: the 1-bit file only needs to decode
    lines.append("  onebit = %s," % lua_str("fmt_1bit.bmp"))

    # orientation samples
    lines.append("  orientation = {")
    tiny = Image.new("RGB", (8, 4), (128, 64, 32))
    for o in (1, 3, 6, 8):
        exif = Image.Exif()
        exif[0x0112] = o
        p = "orient_%d.jpg" % o
        tiny.save(os.path.join(OUT, p), "JPEG", exif=exif.tobytes())
        lines.append("    { file = %s, value = %d }," % (lua_str(p), o))
    tiny.save(os.path.join(OUT, "orient_none.jpg"), "JPEG")
    lines.append('    { file = "orient_none.jpg", value = nil },')
    tiff_with_orientation(os.path.join(OUT, "orient_le_6.tif"), 6)
    tiff_with_orientation(os.path.join(OUT, "orient_be_8.tif"), 8, big_endian=True)
    tiff_with_orientation(os.path.join(OUT, "orient_end_3.tif"), 3, ifd_at_end=True)
    lines.append('    { file = "orient_le_6.tif", value = 6 },')
    lines.append('    { file = "orient_be_8.tif", value = 8 },')
    lines.append('    { file = "orient_end_3.tif", value = 3 },')
    lines.append("  },")
    lines.append("}")
    with open(os.path.join(OUT, "manifest.lua"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("fixtures written to", OUT)


if __name__ == "__main__":
    sys.exit(main())
