#!/usr/bin/env python3
"""Renders Resources/AppIcon/appicon.svg into Resources/AppIcon.icns (all ten sizes, PNG entries).

Needs an SVG renderer on PATH: rsvg-convert (brew install librsvg) or ImageMagick's convert/magick.
Usage: scripts/make-icns.py
"""
import os, shutil, struct, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SVG = os.path.join(ROOT, "Resources/AppIcon/appicon.svg")
OUT = os.path.join(ROOT, "Resources/AppIcon.icns")
# icns type → pixel size
TYPES = [("ic04", 16), ("ic11", 32), ("ic05", 32), ("ic12", 64), ("ic07", 128),
         ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]

def render(size, path):
    if shutil.which("rsvg-convert"):
        cmd = ["rsvg-convert", "-w", str(size), "-h", str(size), SVG, "-o", path]
    else:
        tool = shutil.which("magick") or shutil.which("convert")
        if not tool:
            sys.exit("Install librsvg (rsvg-convert) or ImageMagick to render the icon.")
        cmd = [tool, "-background", "none", "-density", str(max(72, 72 * size // 1024 * 4)), SVG,
               "-resize", f"{size}x{size}", f"PNG32:{path}"]
    subprocess.run(cmd, check=True)

with tempfile.TemporaryDirectory() as tmp:
    pngs = {}
    for size in sorted({s for _, s in TYPES}):
        path = os.path.join(tmp, f"{size}.png")
        render(size, path)
        pngs[size] = open(path, "rb").read()
    body = b"".join(t.encode() + struct.pack(">I", len(pngs[s]) + 8) + pngs[s] for t, s in TYPES)
    with open(OUT, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
    shutil.copy(os.path.join(tmp, "1024.png"), os.path.join(ROOT, "Resources/AppIcon/preview-1024.png"))
print(f"wrote {OUT}")
