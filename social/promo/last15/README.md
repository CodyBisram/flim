# LAST15 (from the team at FLIM)

A note from the team, for Friday and Saturday only: the code LAST15 lets 15 more people into FLIM,
and the first 100 keep the Founding badge. Two versions to pick from.

- **Version A, photo post** (1080 x 1350) and its matching **story** (1080 x 1920, "Link in bio"):
  one print on a soft paper mount, the note handwritten under it, the sign-off "The team at FLIM".
- **Version B, reel** (15 s, 1080 x 1920): prints develop from dark one by one while the note is
  written on in hand, beat by beat: the note, 15 more, the Founding 100, the code, link in bio.

| Reel | Line |
| --- | --- |
| 0 to 3 s | A note from the small team that makes FLIM. (the first print develops) |
| 3 to 6 s | We're letting 15 more people in. |
| 6 to 9 s | The first 100 keep a Founding badge on their profile. For good. (second print) |
| 9 to 12 s | LAST15, printed. Friday and Saturday only. Then the code is gone. (third print) |
| 12 to 15 s | Code LAST15. Link in bio. The team at FLIM |

## Edit

`config.js` holds the copy, colours, the grade and the photo slots. In the copy, `[[15]]` and
`[[LAST15]]` mark the only amber words. Photos are always 3:4; an empty slot shows a placeholder.
To swap in a scan of real handwriting, put a transparent PNG in `scans/` and name it under
`handwritingScans`; the typed note then stays hidden.

`campaign.html` in Chrome shows all three frames side by side with the reel playing.

The hero photo (`photos/church-straightened.jpg`) is the uploaded frame with its converging
verticals corrected, cropped to 3:4 above the people at the bottom of the original.

## Layers

Every element carries a `data-layer`: background, perforations, mount, photo-hero, photo-second,
photo-third, handwriting, 15, code, printed, grain. The renderer exports each one alone on
transparency at 3x, so the frames can be rebuilt or edited in any design tool.

## Render

```
node social/promo/last15/render.mjs          # stills, layers, storyboard, overview (~2 min)
node social/promo/last15/render.mjs --reel   # plus the 15 s reel
```

Everything lands in `out/` (not committed): `post.png` and `story.png` at Instagram's exact sizes,
`post@3x.png` and `story@3x.png` masters, `layers/`, `storyboard/`, `overview.png`, `reel.mp4`.
