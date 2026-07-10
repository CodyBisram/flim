# Using a 3D LUT for the FLIM look

FLIM can grade photos with an Adobe/Resolve **`.cube` 3D LUT** instead of (or as a starting point
for) the parametric slider chain. This gets you a "baked film" result that's hard to hit with
sliders alone — ideal for matching a specific reference look.

## How the pipeline uses it

When a film stock's `params.lut` is set to a bundled `.cube` file, the processor applies the LUT
as the **color grade**, then still layers on **grain, bloom, and vignette** (structural film
effects the LUT usually doesn't include). If `lut` is `nil` or the file fails to load, it falls
back to the parametric chain — so this is always safe.

Order: `scene-adaptive exposure → LUT (color) → bloom → vignette → grain`.

The exposure step runs **before** the LUT because the LUT was fitted on
exposure-normalized inputs: `EV = clamp(0.6 * log2(0.18 / meanLum), 0, 0.5)` from
CIAreaAverage mean luminance. This formula must stay identical to
`normalize_exposure` in `scripts/fit_lut.py` — change one, change both, refit.
Dark scenes (`meanLum < 0.22`) also scale bloom down (floor 35%) so halation
doesn't milk night shots.

## Adding a LUT (3 steps)

1. **Get a `.cube` file.** Options:
   - A film-emulation LUT (many free/paid packs exist — Kodak/Fuji emulations, "faded" looks, etc.)
   - Grade a reference photo in Photoshop/Lightroom/Resolve and export a 3D LUT as `.cube`.
   - Keep it a reasonable size — `LUT_3D_SIZE 33` is standard and plenty.

2. **Add it to the app bundle.** Drop the file under the `Flim/` folder, e.g.:
   ```
   Flim/Resources/LUTs/FlimFilm.cube
   ```
   Then regenerate + build:
   ```
   xcodegen generate
   ```
   (Sources include `Flim/`, so any `.cube` under it is bundled automatically.)

3. **Point the film stock at it.** In `Flim/Models/FilmStock.swift`, set the LUT name (no extension)
   on `original`'s params:
   ```swift
   params: FilmParams(
       …,
       grain: 0.085, bloom: 0.48, monochrome: false,
       lut: "FlimFilm"        // ← the .cube's filename without extension
   )
   ```

That's it — capture now grades through the LUT. Tweak `grain` / `bloom` / `vignetteIntensity` to
taste on top of it.

## Notes

- Parsing is cached, so there's no per-photo cost after the first load.
- `.cube` files order red fastest, which matches Core Image's `CIColorCube` layout — if a LUT ever
  looks channel-swapped, that ordering is the thing to revisit (see `CubeLUT.swift`).
- Applied via `CIColorCubeWithColorSpace` in sRGB, so it's color-managed.

---

## Fitting the FLIM look from Lapse (the calibration shoot)

**Status: SHIPPED.** The fitted look is live — `Flim/Resources/flim.cube` (33³) was fitted
from 6 real same-scene (FLIM-neutral, Lapse) pairs (4 coherent pairs used; 2 moody-crush
scenes excluded as Lapse outliers) and is enabled on FLIM Original, with the parametric
grade as fallback. Scene-adaptive exposure ships alongside it (see pipeline order above).
Keep the steps below for **refits** when new calibration pairs come in.

**How it works:** photograph the same scenes in Lapse and in FLIM (neutral mode), then fit a
`.cube` that maps neutral → Lapse's grade. Fixes the dark-photo problem with data
instead of guesswork.

### On your phone
1. Settings → **Film Lab → Neutral capture ON** (TestFlight builds only).
2. For each scene: shoot in **Lapse**, then immediately in **FLIM** from the same spot.
3. Scenes to cover (the more brightness variety, the better the fit — dark ones matter most):
   - your **dark apartment** (the problem case), lights off / dim
   - indoor warm lamp light
   - indoor daylight from a window
   - outdoors daylight (shade + sun if possible)
   - a colorful subject (books, food, clothes)
   - a skin-tone shot (selfie or a person)
   - a flash shot in the dark
4. Export: save the Lapse versions to camera roll; FLIM neutrals via share/save.
   AirDrop everything to the Mac.
5. Turn **Neutral capture OFF** when done.

### On the Mac
```
pairs/               # name pairs with matching stems
  dark_neutral.jpg     dark_lapse.jpg
  window_neutral.jpg   window_lapse.jpg
  ...
python3 -m venv .venv && .venv/bin/pip install numpy pillow
.venv/bin/python scripts/fit_lut.py pairs/ --out flim.cube
```
Pairs need the same scene, not pixel alignment (the fit is statistical: MKL color
transform + per-channel tone matching). `--strength 0.85` blends the look back toward
neutral if the full match feels too strong.

Then: bundle `flim.cube`, set `FilmParams.lut = "flim"` — grain/bloom/vignette still
layer on top. One TestFlight build to feel-test; revert = set `lut` back to `nil`.
