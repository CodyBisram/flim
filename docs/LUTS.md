# Using a 3D LUT for the FLIM look

FLIM can grade photos with an Adobe/Resolve **`.cube` 3D LUT** instead of (or as a starting point
for) the parametric slider chain. This gets you a "baked film" result that's hard to hit with
sliders alone — ideal for matching a specific reference look.

## How the pipeline uses it

When a film stock's `params.lut` is set to a bundled `.cube` file, the processor applies the LUT
as the **color grade**, then still layers on **grain, bloom, and vignette** (structural film
effects the LUT usually doesn't include). If `lut` is `nil` or the file fails to load, it falls
back to the parametric chain — so this is always safe.

Order: `LUT (color) → bloom → vignette → grain`.

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
