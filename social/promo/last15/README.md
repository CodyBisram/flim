# LAST15 (from the team at FLIM)

A note from the team, for Friday and Saturday only: the code LAST15 lets 15 more people into FLIM,
and they are first in line for what comes next.

- **Photo post** (1080 x 1350): one print on a soft paper mount, the note printed under it in
  Archivo, signed by hand "The team at FLIM".
- **Story** (1080 x 1920): the same note, with "Link in bio".

> We're letting 15 more people into FLIM.
> Get in now and you're first in line for everything we make next.
> Code LAST15, two days only.
> *The team at FLIM*

## Edit

`config.js` holds the copy, colours, the grade and the photo. In the copy, `[[15]]` and
`[[LAST15]]` mark the only amber words. Photos are always 3:4; an empty slot shows a placeholder.
The sign-off is the only handwriting; to use a scan of a real one, put a transparent PNG in
`scans/` and name it under `signoffScans`.

`campaign.html` in Chrome shows the post and the story side by side.

The photo (`photos/church-straightened.jpg`) is the uploaded frame with its converging verticals
corrected, cropped to 3:4 above the people at the bottom of the original.

## Layers

Every element carries a `data-layer`: background, perforations, mount, photo-hero, copy, 15, code,
handwriting (the sign-off and the story's underline), printed, grain. The renderer exports each
one alone on transparency at 3x, so the frames can be rebuilt or edited in any design tool.

## Render

```
node social/promo/last15/render.mjs
```

Everything lands in `out/` (not committed): `post.png` and `story.png` at Instagram's exact sizes,
`post@3x.png` and `story@3x.png` masters (3240 x 4050, 3240 x 5760), `layers/`, `overview.png`.
