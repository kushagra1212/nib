"""Builds windows/resources/nib.ico from the macOS iconset.

One source of truth for the icon: the PNGs in macos/Resources/AppIcon.iconset.
An .ico may hold PNG images directly (Windows Vista and later read them), so
the sizes Windows asks for are copied in byte for byte -- no resampling, and
no image library needed.

    python Scripts/windows/make-icon.py
"""
import os
import struct

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICONSET = os.path.join(ROOT, "macos", "Resources", "AppIcon.iconset")
OUT = os.path.join(ROOT, "windows", "resources", "nib.ico")

# Size -> the iconset file that is exactly that many pixels.
SOURCES = {
    16: "icon_16x16.png",
    32: "icon_32x32.png",
    48: None,  # no 48 in the iconset; 64 is listed instead and Windows scales
    64: "icon_64x64.png",
    128: "icon_128x128.png",
    256: "icon_256x256.png",
}


def main():
    images = []
    for size, name in SOURCES.items():
        if not name:
            continue
        with open(os.path.join(ICONSET, name), "rb") as f:
            images.append((size, f.read()))

    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    payload = b""
    for size, data in images:
        # 256 is written as 0 in the one-byte width and height fields.
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        payload += data
        offset += len(data)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(header + entries + payload)
    print(f"wrote {OUT} ({len(images)} sizes)")


if __name__ == "__main__":
    main()
