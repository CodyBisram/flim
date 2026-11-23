# Seals, 1.7.1

Design: design project 95291707-e8eb-42e7-9636-26d165ffbb85, boards "Blend 5 - Seals" and
"Blend 5b - Seals on pages- text- every seal"; the seal drawing is `seals/flim-seal.jsx` there
(lifted unchanged from the 1.7 reel). Where this document and the boards disagree, this document
wins: the boards' copy was written without the server rules and seven lines were wrong.

## Goals

1. Seals look like the reel: the reel's drawing, exactly.
2. Every seal explains itself when tapped: what it was for and when (earned), or what to do and
   how close you are (not earned).
3. One seal goes on your page, not two.

Not in scope: new seals, re-tiering, changing any award rule except Good Company.

## 1. The seal drawing (`DeskSeal`, Flim/Views/DeskComponents.swift)

Port `sealBody` / `FlimSeal` from `seals/flim-seal.jsx` to SwiftUI, in a 100 x 100 unit space
scaled to the requested size (a real size, never `scaleEffect`, so strokes stay fine).

- Outer shape: stroke 1.6 units, fill = ink at 7% (none when blind). Inner copy of the shape at
  86% scale about the centre, stroke 0.9, no fill. Round line joins.
- Shapes by tier: founding = circle r46 with inner circle r31 (not 86%); gold = circle r37 plus 14
  laurel leaves (ellipses rx 5.2 ry 2.3; for side in -1, 1 and i in 0..<7: a = 40 + 17i degrees,
  centre (50 + side*44*sin a, 50 - 44*cos a), rotated side*(a - 25) degrees; filled ink at 85%, or
  stroked 0.8 when blind); silver = shield path `M50 4 L91 15 V48 C91 72 73 88 50 97 C27 88 9 72 9 48 V15 Z`;
  bronze = diamond `M50 3 L97 50 L50 97 L3 50 Z`; accent = square `M8 8 H92 V92 H8 Z`.
- Text, Plex Mono 500 for ring and date, Caslon 400 for the name, all fixed size (never Dynamic
  Type): ring 6.5 units (Good Company 6), tracking 0.14em; date 6 units, tracking 0.14em; name
  12.5 units unless the seal sets its own size (table below). Founding seals set the ring on an arc
  (`M 11.5 50 A 38.5 38.5 0 0 1 88.5 50`, 7 units, tracking 0.16em, centred). Vertical positions
  per shape (ring / name / date, and the blind shift dy applied when there is no date line):
  round -/55/66 dy 0; laurel 33.5/55/67 dy 4; shield 30/55/68 dy 4; diamond 40.5/55/66.5 dy 1;
  square 31.5/55.5/69 dy 5. Good Company's name sits 2 units higher.
- Inks (Paper / Slate): founding A88C38 / D4B65A, gold D46A7E / F5738C, silver 8C74D6 / A88CFA,
  bronze 3FA898 / 59D1BF, accent 5E534A / B9AEA3. Blind ink C9B6A2 / 4A423B with a pressed
  highlight: the same seal drawn first in white (Paper, 80%) or black (Slate, 25%), offset
  (0.7, 0.9) units.
- Upright. The 1.7 tilt, the 0.92 opacity and the round "selected" ring are removed; the sheet
  marks the page seal with the ON YOUR PAGE tag instead.
- Middle text: the seal's name, except Founding 100 ("No 23", year as the date) and Founding Crew
  ("Crew"; its ring reads FOUNDING CREW). Date line: "SEP 2026" (Founding 100: the year).
  Spotlight's ring carries its ISO week ("WK 44").

## 2. Copy (new `SealCopy`, one entry per `ProfileBadgeKind`)

1.7 only. The 1.6 strings (`explanation`, `howToEarn`, `DeskSeal.ringLine`'s callers in v1) stay
as they are; `DeskSeal` reads its ring from `SealCopy`.

| Seal | Ring | Name size | Earned (card) | How to get it (card) | Progress |
|---|---|---|---|---|---|
| Founder | BUILT FLIM | | Built FLIM. | never blind | none |
| Founding Crew | FOUNDING CREW | | Part of the crew that got FLIM off the ground. | never blind | none |
| Founding 100 | FOUNDING 100 | | One of the first hundred people on FLIM. | never blind; on someone else's card: Only the first hundred got this one. | none |
| Front Row | 5 FIRSTS | | First to open the reveal, on five different rolls. | Be first to open the reveal on five different rolls with other people in them. | count, 5 rolls |
| Packed House | ROLL OF 10 | 9 | Shot into a roll that reached ten photographers. | Shoot into a roll that grows to ten photographers. | closest roll, 10 |
| Cover to Cover | 10 ROLLS | 8.5 | Shot into ten rolls before they developed. | Shoot into ten different rolls. Each one counts when it develops. | count, 10 rolls |
| Open Door | 10 JOINED | 11.5 | Invited ten people who joined FLIM. | Invite ten people who join FLIM. | count, 10 joined |
| Still Shooting | A YEAR ON | 9.5 | Still shooting a year after joining. | Shoot a frame a year or more after you joined. | date |
| Full Set | 20 SEALS | | Held twenty other seals at once. | Earn twenty other seals. Spotlight, Feedback and Bug Catcher don't count. | count, 20 seals (bar) |
| Spotlight | WK n | | A frame chosen for Spotlight. | never blind; on someone else's card: The team chooses Spotlight each week. | none |
| Patron | 5 JOINED | | Invited five people who joined FLIM. | Invite five people who join FLIM. | count, 5 joined |
| Darkroom | ALL REVEALS | | Opened the reveal on every roll joined. | Open the reveal on every roll you're in once it develops. | all of them |
| First In | FIRST OPEN | | First to open the reveal on a roll. | Be first to open the reveal on a roll with other people in it. | one step |
| Kept One | 10 KEPT | | Let ten frames develop and kept them to yourself. | Let ten frames develop without posting them. | count, 10 kept |
| Regular | 7 DAYS | | Opened FLIM on seven different days. | Open FLIM on seven different days. | count, 7 days |
| Recruiter | 3 STAYED | | Invited three people still shooting a month later. | Invite three people who are still shooting a month after they join. | count, 3 |
| Feedback | CHANGED FLIM | | Sent feedback that changed FLIM. | Send feedback in Settings. When it changes FLIM, the team gives you this. | given by the team |
| Bug Catcher | FOUND A BUG | 10.5 | Found a bug the team fixed. | Report a bug with Send feedback in Settings. When the team fixes it, they give you this. | given by the team |
| Full Roll | CAME BACK | | Shot into a roll early, then came back to it. | Shoot into a roll in its first 6 hours, then again 6 hours or more after it started. It counts when the roll develops. | two steps: "Shoot into a roll in its first 6 hours" / "Come back to it 6 hours or more after it started" |
| Roll Maker | STARTED | 10.5 | Started a roll that got its first frame. | Start a roll and get a frame into it. Anyone's frame counts, yours too. | two steps: "Start a roll" / "Get a frame into it" |
| Plus One | INVITED | | Invited someone who joined FLIM. | Invite someone who joins FLIM. | one step |
| Well Met | REACTION | | Someone reacted to one of your frames in a roll. | Get a reaction on one of your frames in a roll. | one step |
| Full House | ROLL OF 5 | 10.5 | Shot into a roll that reached five photographers. | Shoot into a roll that grows to five photographers. | closest roll, 5 |
| Spotter | A TAG | | Tagged someone in one of your frames. | Tag someone in one of your frames. | one step |
| In Frame | TAGGED | | Tagged in someone's frame. | Get tagged in someone's frame. | one step |
| Good Company | 10 FRIENDS | 8 | Made ten friends on FLIM. | Have ten friends on FLIM. | count, 10 friends |
| First Light | FIRST FRAME | | Shot a first frame. | Shoot your first frame. | one step |
| Shared | POSTED | | Posted a frame to the feed. | Post a frame to the feed. | one step |
| Joined In | JOINED ONE | | Joined a roll someone else started. | Join a roll someone else started. | one step |
| Chipped In | SHOT IN ONE | 12 | Shot into a roll someone else started. | Shoot into a roll someone else started. | one step |
| Chimed In | REACTED | | Reacted to someone's frame in a roll. | React to someone else's frame in a roll. | one step |
| Said It | A CAPTION | | Wrote a caption on a frame. | Write a caption when you post a frame. | one step |
| Ten Frames | 10 FRAMES | 11.5 | Shot ten frames. | Shoot ten frames. | count, 10 frames |

Every "how to get it" line must describe the ratchet's real predicate (`_ratchet_badges`). The
backend pass verifies each row against it and corrects the copy, not the rule, wherever they
differ. No em dashes. Never name a person or a roll.

Progress line formats: count "6 of 10 kept" (unit word per seal: frames, days, rolls, kept,
joined, still shooting, friends, seals); closest roll "Your closest roll has 3 of 5
photographers."; all of them "7 of 9 reveals opened." (shown from the first developed roll, "0 of 3
reveals opened." included); date "You'll hit a year on March 20, 2027. Shoot a frame any time after
that." and, once the anniversary has passed, "It's been a year. Shoot a frame to earn it."; under a
blind seal in the sheet, once started: "6 OF 10", "1 OF 2", "MAR 2027" (after the anniversary:
"READY").

## 3. Screens (1.7 only; `AppInfo.is17`)

**Seals sheet** (`BadgePickerSheet`'s 1.7 path): title Seals, Done. Line: "Tap a seal to see what
it's for. One goes on your page, and only you can see the ones you haven't earned." EARNED grid, then NOT YET EARNED (blind), each in tier
order then catalogue order; positions never move with progress. Three across on phone, four on Duo
closed. The page seal carries ON YOUR PAGE (Plex Mono 9.5, accent text ink). A new seal keeps its
red dot until its card is opened. Blind seals that have started show progress under them. The
Automatic / Custom switch and the Save button are gone. Tapping a seal opens its card. Never shown
blind: Founder, Founding Crew, Founding 100, Spotlight. Empty: "None yet. Your first one goes on
your page by itself." A failed load is never shown as empty: "Couldn't load your seals. Check your
connection and try again." with Try again, in place of both sections.

**Seal card**: floats over the desk, inset 10 from the edges, rounded, with a close button (44 pt
target). Seal at 120 (132 on someone else's page card), name in Caslon, then:
- earned, yours: earned line; "Earned Sep 2026" in Plex Mono; button "Put on my page", or the
  quiet "On your page" state (check mark, accent text ink). Tapping the button saves immediately
  (`setDisplayedBadges([id])`), turns it into the quiet state, and the card stays open. A failed
  save shows "Couldn't put it on your page. Check your connection and try again." and restores the
  button.
- not earned, yours: how-to line, then its progress form (ticks for counts up to 10, a bar for
  Full Set, dots for closest roll, a bar of ticks for all of them, a checklist for two steps, 12
  month ticks for the date). One step: the line only. Given by the team: GIVEN BY THE TEAM label
  and the line.
- someone else's: their seal and date, their earned line, never their name. Then either "You have
  this one too" (no date) or the how-to line and your progress, headed YOUR PROGRESS when there is
  progress to show and HOW TO GET IT otherwise. If your seals or progress can't be read, the card
  says nothing about you. Founding 100 and Spotlight use the lines in the table.
- Dynamic Type: name, lines, date and button scale; the card grows and scrolls; the seal and its
  text never scale.

**Duo open**: follow the existing docked pattern (`DeskLayout.open`, as `docksMonths` and
`docksComments` do): the seals list holds the left of the fold and the card sits on the right over
the desk; tapping another seal swaps the card, and the tapped seal is marked in the list.

**Your page header** (`UserPageView`): one seal beside the name. Yours opens the Seals sheet; no
seal, no placeholder glyph (the Seals pill stays). Someone else's opens the seal card (replacing the
1.6 swap-in on 1.7). VoiceOver: the card is reachable and announces the same lines.

**One seal**: on 1.7 the chosen list is one id. Until you choose, the page shows your rarest seal
(server default: tier first, then fewest holders, then newest). A stored second choice is ignored.

## 4. Backend (one migration, `supabase/migrations/2026-11-22_171_seals.sql`, folded into schema.sql)

- `own_seal_progress()` returns `(badge_id text, current int, target int, due_at timestamptz)` for
  `auth.uid()`, one row per earnable seal not yet earned that has a progress form. `current` and
  `target` must come from the same predicates as `_ratchet_badges`, so a seal is earned exactly
  when `current` reaches `target`: counts as above; Full House / Packed House = the most
  photographers on any roll you shot into; Darkroom = reveals opened / rolls that count; Full Roll
  and Roll Maker = steps done of 2; Full Set = other seals held of 20; Still Shooting = `due_at`
  (the first anniversary), current/target 0/0. Security definer, `search_path = public`,
  authenticated only. Must stay fast for every account (it runs each time the sheet opens).
- `mark_own_badge_seen(p_badge_id text)`: marks one of your seals seen. `mark_own_badges_seen()`
  stays for 1.7.0 clients.
- Good Company: ten friends (both directions of `follows`), `earned_at` = the moment the tenth
  friendship formed (the later of the two follow rows), ranked so an eleventh never moves it. The
  ratchet never removes a seal, so everyone who holds it keeps it.
- Confirm `_resolve_effective_displayed_badges`' default is rarest first as described in 3; when a
  person has chosen one or more seals, the first is the one shown.
- Verify every "how to get it" line in 2 against `_ratchet_badges` and report the Roll Maker steps.
- Apply to FLIM Dev and production only with the owner's go.

## 5. Tests

- `SealCopy` covers every `ProfileBadgeKind`; no em dashes; ring lines fit their shape at the seal's
  type size (measure in a unit test, as `BadgeSwapLineTests` does).
- Progress decoding and the line formatter for each form, including started vs not started.
- One-seal rule: choosing replaces, never appends.
- UI test (FlimUITests, `-badgePickerDemo` extended with progress): open the sheet, tap an earned
  seal, Put on my page, tap a blind seal, see its progress, close.
- Schema bootstrap passes; `own_seal_progress()` checked against `_ratchet_badges` on the staging DB
  for accounts on both sides of each threshold.
- Screenshots: iPhone and Duo (closed and open), Paper and Slate, largest text once.

## 6. Release

1.7.1: `MARKETING_VERSION` to 1.7.1 in both targets, with `FlimUITests/Desk17UITests.swift`. The
backend migration is applied before the build reaches testers (the app falls back to no progress
if the RPC is missing).
