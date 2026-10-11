#!/usr/bin/env python3
"""Stand-in for macOS `sips` used by the plugin flow test on Linux.

Supports exactly what the plugin calls:
    sips -s format bmp [-Z <max>] <input> --out <output>

FAKE_SIPS_ORIENT=1 makes it rotate pixels according to the EXIF/TIFF
orientation tag (so both possible real-world behaviours can be tested).
"""
import os
import sys

from PIL import Image, ImageOps


def main(argv):
    fmt, maxdim, out, inputs = None, None, None, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "-s":
            key, val = argv[i + 1], argv[i + 2]
            if key == "format":
                fmt = val
            i += 3
        elif a == "-Z":
            maxdim = int(argv[i + 1])
            i += 2
        elif a == "--out":
            out = argv[i + 1]
            i += 2
        else:
            inputs.append(a)
            i += 1
    if fmt != "bmp" or not out or len(inputs) != 1:
        print("fake sips: unsupported arguments %r" % argv)
        return 2
    try:
        img = Image.open(inputs[0])
        img.load()
    except Exception as e:  # noqa: BLE001
        print("Error: Unable to render source image %s (%s)" % (inputs[0], e))
        return 1
    if os.environ.get("FAKE_SIPS_ORIENT") == "1":
        img = ImageOps.exif_transpose(img)
    if maxdim:
        w, h = img.size
        s = maxdim / max(w, h)
        img = img.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    img.save(out, "BMP")
    print("%s\n  %s" % (inputs[0], out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
