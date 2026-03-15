#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from PIL import Image


ICON_VARIANTS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def crop_square(image: Image.Image) -> Image.Image:
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def build_icons(
    source: Path, iconset_dir: Path, appiconset_dir: Path, icns_output: Path
) -> None:
    iconset_dir.mkdir(parents=True, exist_ok=True)
    appiconset_dir.mkdir(parents=True, exist_ok=True)

    with Image.open(source) as image:
        rgba = image.convert("RGBA")
        square = crop_square(rgba)

        for name, size in ICON_VARIANTS:
            resized = square.resize((size, size), Image.Resampling.LANCZOS)
            resized.save(iconset_dir / name, format="PNG")
            resized.save(appiconset_dir / name, format="PNG")

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_output)],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate macOS app iconset and icns from a source image."
    )
    parser.add_argument(
        "--source",
        default="assets/icon image.png",
        help="Path to source image.",
    )
    parser.add_argument(
        "--iconset",
        default="Packaging/VoiceOverStudio.iconset",
        help="Output .iconset directory used to build .icns.",
    )
    parser.add_argument(
        "--appiconset",
        default="Packaging/AppIcon.appiconset",
        help="Output .appiconset directory for Xcode-style assets.",
    )
    parser.add_argument(
        "--icns",
        default="Packaging/VoiceOverStudio.icns",
        help="Output .icns file path.",
    )
    args = parser.parse_args()

    source = Path(args.source)
    iconset = Path(args.iconset)
    appiconset = Path(args.appiconset)
    icns = Path(args.icns)

    if not source.is_file():
        raise FileNotFoundError(f"Source image not found: {source}")

    build_icons(
        source=source,
        iconset_dir=iconset,
        appiconset_dir=appiconset,
        icns_output=icns,
    )
    print(f"Generated iconset at: {iconset}")
    print(f"Generated appiconset at: {appiconset}")
    print(f"Generated icns at: {icns}")


if __name__ == "__main__":
    main()