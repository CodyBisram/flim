#!/usr/bin/env python3
"""
Fit a 3D LUT (.cube) that maps FLIM's NEUTRAL captures onto Lapse's look.

Input: a folder of same-scene pairs (shot seconds apart, same framing-ish):
    pairs/
      kitchen_neutral.jpg   kitchen_lapse.jpg
      dark-room_neutral.jpg dark-room_lapse.jpg
      ...
Pairs don't need pixel alignment — the fit uses color statistics, not pixels:
  1. MKL (Monge-Kantorovitch linear) transform matching mean+covariance of the
     combined pixel clouds (captures the overall color/saturation/warmth shift).
  2. Per-channel 1D histogram refinement (captures the tone curve — the shadow
     behavior that matters for dark shots).
Both are baked into a 33^3 .cube for CIColorCubeWithColorSpace.

Usage:
    python3 -m venv .venv && .venv/bin/pip install numpy pillow
    .venv/bin/python scripts/fit_lut.py pairs/ --out Flim/Resources/flim.cube

Then set `lut: "flim"` on FilmParams (grain/bloom/vignette still layer on top).
"""
import argparse, sys
from pathlib import Path

import numpy as np
from PIL import Image

EDGE = 512          # analysis size — plenty for color stats
CUBE = 33           # standard .cube lattice


def load_pixels(path: Path) -> np.ndarray:
    img = Image.open(path).convert("RGB")
    img.thumbnail((EDGE, EDGE))
    return np.asarray(img, dtype=np.float64).reshape(-1, 3) / 255.0


def normalize_exposure(px: np.ndarray) -> np.ndarray:
    """Scene-adaptive exposure lift for dark scenes — MUST mirror the app
    (InstantFilmProcessor): EV = clamp(0.6 * log2(0.18 / meanLum), 0, 0.5),
    applied as a linear-space gain. Deliberately GENTLE: night scenes stay night
    (a city skyline must not get daylighted); only truly underexposed scenes get
    a nudge. Bright scenes pass through untouched."""
    lum = 0.299 * px[:, 0] + 0.587 * px[:, 1] + 0.114 * px[:, 2]
    mean = max(lum.mean(), 1e-4)
    ev = float(np.clip(0.6 * np.log2(0.18 / mean), 0, 0.5))
    if ev < 0.01:
        return px
    lin = np.power(px, 2.2) * (2 ** ev)
    return np.clip(np.power(np.clip(lin, 0, 1), 1 / 2.2), 0, 1)


# Pairs that must never train the fit, with the measurement that condemned each. They stay on
# disk because they are still evidence; they are excluded because a pair only teaches something
# if Lapse's frame is a RENDERING of the scene rather than of something else.
#
#   corner-dark      Lapse rendered it 0.9 stop DARKER than the neutral at near-identical
#                    framing. Nothing in the look does that, so the pair teaches a shift that
#                    is not in the look.
#   hallway-noflash  A completely dark scene with nothing to focus on. Lapse's frame is ~95%
#                    sensor noise: its contrast falls to 38% at 4x downsample and 5% at 64x,
#                    where a real photograph keeps 99% and 93% (measured on hallway-flash, same
#                    room, same minute). Structure correlation with the neutral is 0.38 against
#                    0.71 for the flash frame. Training on it maps near-black onto lifted, tinted
#                    grey, which is the exact opposite of the black-point deficit being chased.
DEFAULT_EXCLUDE = ("corner-dark", "hallway-noflash")


def gather(pairs_dir: Path, exclude=()):
    neutrals, graded = [], []
    for n in sorted(pairs_dir.glob("*_neutral.*")):
        stem = n.name.rsplit("_neutral", 1)[0]
        if stem in exclude:
            print(f"   skipping {stem} (excluded)")
            continue
        g = next((p for p in pairs_dir.glob(f"{stem}_lapse.*")), None)
        if g is None:
            print(f"!! no lapse partner for {n.name}, skipping", file=sys.stderr)
            continue
        neutrals.append(normalize_exposure(load_pixels(n)))
        graded.append(load_pixels(g))
        print(f"   pair: {n.name} <-> {g.name}")
    if not neutrals:
        sys.exit("no pairs found (expected *_neutral.jpg + *_lapse.jpg)")
    return np.vstack(neutrals), np.vstack(graded)


def mkl_transform(src: np.ndarray, dst: np.ndarray):
    """Linear transform T, b such that src @ T + b matches dst's mean+covariance."""
    ms, md = src.mean(0), dst.mean(0)
    cs = np.cov(src, rowvar=False) + np.eye(3) * 1e-8
    cd = np.cov(dst, rowvar=False) + np.eye(3) * 1e-8
    # MKL: T = cs^-1/2 (cs^1/2 cd cs^1/2)^1/2 cs^-1/2
    def sqrtm(m):
        w, v = np.linalg.eigh(m)
        return v @ np.diag(np.sqrt(np.maximum(w, 0))) @ v.T
    cs_h = sqrtm(cs)
    cs_ih = np.linalg.inv(cs_h)
    T = cs_ih @ sqrtm(cs_h @ cd @ cs_h) @ cs_ih
    b = md - ms @ T
    return T, b


def channel_luts(src: np.ndarray, dst: np.ndarray, points=256):
    """Per-channel monotone histogram match src→dst (after MKL), as 1D LUTs."""
    luts = []
    qs = np.linspace(0, 100, points)
    for c in range(3):
        s = np.percentile(src[:, c], qs)
        d = np.percentile(dst[:, c], qs)
        luts.append((s, d))
    return luts


def apply_1d(x: np.ndarray, luts):
    out = np.empty_like(x)
    for c in range(3):
        s, d = luts[c]
        out[:, c] = np.interp(x[:, c], s, d)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pairs", type=Path)
    ap.add_argument("--out", type=Path, default=Path("flim.cube"))
    ap.add_argument("--strength", type=float, default=1.0,
                    help="blend toward the fitted look (0..1), 1 = full Lapse match")
    ap.add_argument("--exclude", nargs="*", default=list(DEFAULT_EXCLUDE),
                    help="pair stems to leave out of the fit; see DEFAULT_EXCLUDE for why "
                         "each default is there. Pass --exclude with no names to fit on "
                         "everything, which is only ever a diagnostic.")
    args = ap.parse_args()

    print("== loading pairs")
    src, dst = gather(args.pairs, exclude=set(args.exclude))
    print(f"== fitting on {len(src):,} / {len(dst):,} pixels")

    T, b = mkl_transform(src, dst)
    src_mkl = np.clip(src @ T + b, 0, 1)
    luts = channel_luts(src_mkl, dst)

    # Bake lattice: identity grid → MKL → 1D refinement → optional strength blend.
    g = np.linspace(0, 1, CUBE)
    B, G, R = np.meshgrid(g, g, g, indexing="ij")          # .cube order: R fastest
    grid = np.stack([R, G, B], axis=-1).reshape(-1, 3)
    out = np.clip(grid @ T + b, 0, 1)
    out = np.clip(apply_1d(out, luts), 0, 1)
    out = grid + (out - grid) * args.strength

    with open(args.out, "w") as f:
        f.write(f"TITLE \"FLIM fitted from Lapse pairs\"\nLUT_3D_SIZE {CUBE}\n")
        for r, gg, bb in out:
            f.write(f"{r:.6f} {gg:.6f} {bb:.6f}\n")
    print(f"== wrote {args.out} (size {CUBE}, strength {args.strength})")


if __name__ == "__main__":
    main()
