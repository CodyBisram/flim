#!/usr/bin/env python3
"""Plants the demo photos (`demo/p01.jpg` to `demo/p15.jpg`) in a simulator app's disk image cache,
so the launch hosts that use them (`-feedPreviewDemo`, `-chromePreviewDemo`, `-v2DemoDarkroom`) show
real frames with no account and no network.

`DiskImageCache` files the original bytes of a storage path under "raw|<path>", named by the djb2
hash of that key in hex (Flim/Views/Darkroom/PhotoGridCell.swift). The frames are the Lapse pairs.

    python3 scripts/plant_demo_images.py <simulator id> [bundle id]

The bundle id defaults to FLIM Beta's (com.flim.app.beta); pass com.flim.app for the App Store app.
"""
import pathlib
import shutil
import subprocess
import sys

NAMES = ["parkview-flash", "restaurant-a", "wide-lit", "sign", "plush", "restaurant-b", "laptop", "steering",
         "hallway-flash", "parkview-noflash", "corner-lit", "cap", "wide-dim", "corner-dark", "hallway-noflash"]


def djb2(key: str) -> str:
    h = 5381
    for byte in key.encode():
        h = (h * 33 + byte) & 0xFFFFFFFFFFFFFFFF
    return format(h, "x")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    device, bundle = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "com.flim.app.beta"
    container = subprocess.run(["xcrun", "simctl", "get_app_container", device, bundle, "data"],
                               check=True, capture_output=True, text=True).stdout.strip()
    cache = pathlib.Path(container) / "Library/Caches/flim-images"
    cache.mkdir(parents=True, exist_ok=True)
    pairs = pathlib.Path(__file__).resolve().parent.parent / "pairs"
    for index, name in enumerate(NAMES, 1):
        shutil.copy(pairs / f"{name}_lapse.jpg", cache / djb2(f"raw|demo/p{index:02d}.jpg"))
    print(f"planted {len(NAMES)} frames in {cache}")


if __name__ == "__main__":
    main()
