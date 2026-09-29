# Spotlight reel (FLIM 1.6)

A 26.8 second Instagram Reel, 1080 x 1920, 30 fps, H.264 High with the Spotlight_Reel_1.wav
soundtrack in AAC 320k. The cuts sit on the track's beats, and the reading moments hold longer (`timeline` in config.js).

| Time | Beat |
| --- | --- |
| 0.0 to 2.9 | A light switches on over the Anunoby jersey on the Amalfi coast. "Your best frame this week could be in Spotlight." |
| 2.9 to 11.0 | The photo drops into the phone as your post in the feed. Menu, "Put it up for Spotlight", the first-time sheet, "Up for Spotlight." |
| 11.0 to 13.7 | The contact sheet for the week of September 21. The team at FLIM chooses five; the chosen fly into the phone. |
| 13.7 to 18.5 | The Spotlight strip in the feed, scrolled. "Your frame is in Spotlight" push, the avatar dot. |
| 18.5 to 21.9 | Your page: Founding 100 and Spotlight badges, the Spotlight badge tapped, the SPOTLIGHT shelf. |
| 21.9 to 26.8 | End card: FLIM in thin white type, "Spotlight is here.", Update to 1.6, link in bio and SPOT26, invite only with 20 Founding 100 spots left and a week on the code, the date back (09 29 '26) burned in the way the app stamps exports. |

Words stay below Instagram's top bar, and nothing important sits under its right-hand buttons.

The phone screens are rebuilt from the SwiftUI on main (`SpotlightViews.swift`, `FeedView`,
`FeedUnitCard`, `UserPageView`, `UndoCapsule`, `Theme.swift`): the same sizes, colours, strings and
order, on an iPhone 17 Pro Max (440 x 956 pt) with iOS 26 Liquid Glass bars. Inter stands in for SF
Pro and the SF Symbols are hand-drawn SVGs, since neither can ship outside Apple platforms.

## Edit

Everything changeable is in `config.js`: your name and handle, the chosen handles, the accent (any of
the app's six or a hex), the warm film grade and grain, every photo slot, the week, the clock and every
line of copy.

Or open `reel.html` in Chrome, use the Edit panel on the right, and press **Download config.js**,
then put that file over this one. Space plays and pauses; the scrubber seeks.

Photos are in `photos/`: the Dubai and Italy rolls (1500 x 2000) and the Bali roll from the
September promo cards. The sharper Dubai and Italy frames hold the big slots; ricky's and aly's
frames are Italy, arman's is Dubai. Any 3:4 portrait JPEG works.

## Render

```
node social/promo/spotlight-reel/render.mjs            # writes spotlight-reel.mp4 here (~15 min)
node social/promo/spotlight-reel/render.mjs --stills 1.2,13.3   # PNG stills instead
```

Frames are drawn at 2x (2160 x 3840) and scaled to 1080 x 1920 with Lanczos; `--scale 1` is a
quick draft, `--crf` sets quality (16 by default, lower is better).

Needs Playwright's Chromium (`npm i -D playwright` or a global install) and ffmpeg (on PATH, in
`FFMPEG`, or `pip install imageio-ffmpeg`). The one committed video is `masters/FLIM-Spotlight-Reel.mp4`,
the final render; a fresh render writes `spotlight-reel.mp4` here, which git ignores.
