#!/usr/bin/env python3
"""Full-resolution JPEG/TIFF pair scans for the plugin flow test.

Usage: gen_flow_images.py <output dir>
Writes the images plus flow_manifest.lua with the true gap position in the
*stored* pixel frame (the frame Lightroom's crop values use).
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_fixtures import make_pair  # noqa: E402


def main(out):
    os.makedirs(out, exist_ok=True)
    entries = []

    def add(name, case, seed, save):
        rng = np.random.default_rng(seed)
        pil, truth = make_pair(rng, case)
        entries.append((name, save(pil, os.path.join(out, name), truth)))

    def save_jpeg(pil, path, truth):
        pil.save(path, "JPEG", quality=92)
        return truth

    def save_lzw_tiff(pil, path, truth):
        pil.save(path, "TIFF", compression="tiff_lzw")
        return truth

    def save_exif6(pil, path, truth):
        # Stored pixels are the displayed image turned 90 degrees counter-
        # clockwise; orientation 6 tells viewers to turn it back clockwise.
        stored = pil.transpose(Image.ROTATE_90)
        exif = Image.Exif()
        exif[0x0112] = 6
        stored.save(path, "JPEG", quality=92, exif=exif.tobytes())
        # displayed (u, v) -> stored (x, y) = (v, 1 - u): a vertical gap
        # u in [g0, g1] becomes rows y in [1 - g1, 1 - g0].
        return {"axis": "y", "gapStart": 1 - truth["gapEnd"], "gapEnd": 1 - truth["gapStart"]}

    add("pair.jpg", {"W": 3000, "H": 2000}, 11, save_jpeg)
    add("pair_lzw.tif", {"W": 3000, "H": 2000, "pos": 0.46}, 12, save_lzw_tiff)
    add("pair_exif6.jpg", {"W": 3000, "H": 2000, "pos": 0.45}, 13, save_exif6)
    add("pair_user_rotated.jpg", {"W": 3000, "H": 2000, "pos": 0.44}, 14, save_jpeg)
    add("night.jpg", {"W": 3000, "H": 2000, "kinds": ("night", "night")}, 15, save_jpeg)
    add("onenight.jpg", {"W": 3000, "H": 2000, "kinds": ("night", "highkey")}, 16, save_jpeg)
    add("hidden.jpg", {"W": 3000, "H": 2000}, 17, save_jpeg)
    with open(os.path.join(out, "not_an_image.jpg"), "wb") as f:
        f.write(b"this is not a JPEG")
    entries.append(("not_an_image.jpg", None))

    lines = ["return {"]
    for name, t in entries:
        if t is None:
            lines.append('  ["%s"] = false,' % name)
        else:
            lines.append('  ["%s"] = { axis = "%s", gapStart = %r, gapEnd = %r },'
                         % (name, t["axis"], float(t["gapStart"]), float(t["gapEnd"])))
    lines.append("}")
    with open(os.path.join(out, "flow_manifest.lua"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
