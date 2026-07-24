#!/usr/bin/env python3
"""Generate the checked-in iMessage icon family from Tono's canonical app icon."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
OUTPUT = ROOT / "TonoMessagesExtension/Assets.xcassets/iMessage App Icon.stickersiconset"

SQUARE = {
    "iphone-settings-29@2x.png": (58, 58),
    "iphone-settings-29@3x.png": (87, 87),
    "ipad-settings-29@2x.png": (58, 58),
}
RECTANGLE = {
    "iphone-messages-60x45@2x.png": (120, 90),
    "iphone-messages-60x45@3x.png": (180, 135),
    "ipad-messages-67x50@2x.png": (134, 100),
    "ipad-pro-messages-74x55@2x.png": (148, 110),
    "universal-breadcrumb-27x20@2x.png": (54, 40),
    "universal-breadcrumb-27x20@3x.png": (81, 60),
    "universal-message-32x24@2x.png": (64, 48),
    "universal-message-32x24@3x.png": (96, 72),
    "messages-store-1024x768.png": (1024, 768),
}


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    if source.size != (1024, 1024):
        raise SystemExit(f"canonical icon must be 1024x1024, got {source.size}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    rectangular = source.crop((0, 128, 1024, 896))
    for name, size in SQUARE.items():
        source.resize(size, Image.Resampling.LANCZOS).save(OUTPUT / name, optimize=True)
    for name, size in RECTANGLE.items():
        rectangular.resize(size, Image.Resampling.LANCZOS).save(OUTPUT / name, optimize=True)
    print(f"generated {len(SQUARE) + len(RECTANGLE)} iMessage icons in {OUTPUT}")


if __name__ == "__main__":
    main()
