# FLIM 1.6.x: Spotlight at the end of a sort. Prompt for Claude Design (2026-09-27)

Second round on putting frames up for Spotlight from the sort deck. The first round (the per-swipe
capsule and the last-card sheet, prompt `CLAUDE_DESIGN_1_6_SPOTLIGHT_DECK_2026-09-27.md`) was
built, shipped to TestFlight as build 412, and pulled the same night: sorting fast made the offer
invisible. Build 413 (the one in App Store review as 1.6.0) has no Spotlight in the deck at all;
a frame goes up by long press wherever a posted frame appears. This brief is for ONE sheet, shown
when a sort session ends, that offers the frames just posted. Paste everything below the line into
a new Claude Design project (or the same one, saying the capsule direction is rejected).

Attach, in this order:

1. Screenshots from build 413 at 402pt:
   - the sort deck: a card, the three circles, the "Add a caption or tag people" pill, a card
     mid-swipe to Post, the "Posted to your page" notice, the Undo button in the header
   - the compose sheet ("New Post") with a person tagged
   - the long-press menu on your own profile grid showing "Put it up for Spotlight", one showing
     "Swap it into Spotlight", and one with the item greyed out ("Frames with people tagged
     can't go up")
   - the first-time Spotlight sheet
   - the Spotlight strip in the feed, and the week's sheet
   - the Darkroom right after a deck closes, and the camera right after a deck closes
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift` (tokens and type roles).

---

## 0. What you are designing

FLIM is an invite-only iOS camera app: a disposable camera for a few close friends. Shots develop
into a private Darkroom; the sort deck is where a person goes through them and swipes each one:
right to Post it to their page (their followers' feed), left to Keep it private, down to Delete.
People usually sort right after a batch develops, often 5 to 20 frames, often a burst, fast.

Spotlight (new in 1.6): each week a person can put up ONE frame they shot that week. Only the team
at FLIM sees what is put up. When the week closes, the team chooses a few and shows them to
everyone as a short strip in the feed; the chosen get a notification, a Spotlight badge and the
frame on their page.

The owner's goal is unchanged: the moment someone has just posted their best frames is the moment
to offer Spotlight. The owner's constraint is new and absolute: **keep the sorting fast.** Nothing
may appear between swipes. So the offer waits until the session ends, and then asks once:
"Put one up for Spotlight?" with every frame from that session that can go up, side by side.
Pick one, put it up (or swap it in), or say not now.

The codebase is public: https://github.com/CodyBisram/flim (branch `main`, build 413 is commit
c4f8638). Read these before designing; they are the ground truth, and your design must be
buildable against them:

- `Flim/Views/Darkroom/SortDeckView.swift`: the deck. Read `performSwipe`, `undo`, `closeDeck`,
  `commit` and the `cards.isEmpty && loaded` branch in `body`. Facts that constrain you:
  - Each swipe is HELD, not sent: it is committed when the next swipe happens or the deck closes,
    so Undo can take back even a delete. The last swipe of a session is therefore still undoable,
    and still has no post on the server, at the moment the deck runs out of cards.
  - When the last card leaves, the deck closes itself at once (`closeDeck()`: commit the held
    swipe, then dismiss). There is deliberately no "all sorted" screen.
  - The deck is a full-screen cover presented from two places: the camera and the Darkroom.
    A new account's first sort lands in the Darkroom once (`NewAccountIntro`).
  - The X in the header closes the deck early; whatever was held is committed.
  - A post can fail after the swipe (`publishError`: "Couldn't post that one...").
  - The app's usual confirmation banner is hidden behind the full-screen cover, so the deck
    has always had to show its own confirmations.
- `Flim/Views/Darkroom/SortDeckComposeSheet.swift`: caption and tags. A tagged frame can never go
  up (a tagged friend never agreed to be shown to everyone).
- `Flim/Models/Spotlight.swift`: `OwnSpotlightEntry` (this week's server bounds `weekStartsAt` /
  `weekClosesAt`, `canPutUp`, and which post is up, `postId`, with `postCreatedAt`),
  `SpotlightMenuItem.resolve` (the eligibility rules as the long-press menu applies them, and the
  reason strings), `SpotlightMenuItem.dayWord` (how a day is named), `SpotlightPutUpNotice`
  (the confirmation strings), `SpotlightRefusal` (the server's refusal strings).
- `Flim/Views/Feed/SpotlightViews.swift`: `SpotlightFirstTimeSheet` (the explainer every first
  put-up goes through), `SpotlightFlow`, `SpotlightMenuSection`, `.spotlightPutUpFlow`,
  `SpotlightFrameCell`, `SpotlightGlyphBadge`.
- `Flim/Services/FeedService+Spotlight.swift`: `putUpForSpotlight(post)` (optimistic; returns nil
  on success or the refusal message; a put-up while another frame is up SWAPS it on the server and
  the answer names the frame taken down), `takeDownFromSpotlight`, `refreshOwnSpotlightEntry`.
- `Flim/Services/FeedService.swift`: `createPost` returns `CreatedPost(post:tagsSaved:)`. A put-up
  needs that post; a frame is only offerable once its post exists.
- `Flim/Models/Photo.swift`: `takenAt` (capture time; the week rule reads this, not post time).
- `docs/SPOTLIGHT_1_6_PLAN.md`: the whole feature and every decision behind it.

## 1. Rules you design within (settled, do not change)

- One frame per person per week. The week runs Monday 04:00 to Monday 04:00, New York time; the
  bounds come from the server (`OwnSpotlightEntry`), never from the phone's clock alone.
- Only a frame SHOT this week can go up (capture time), by the person who shot it, with nobody
  tagged, from an account not in a covered window (`canPutUp` false means offer nothing, say
  nothing). The server refuses anything else.
- Putting up a second frame the same week swaps it for the first. A frame can be taken down until
  the week closes.
- The first put-up on an account shows the first-time explainer before anything is sent. You may
  redesign how the explainer meets this sheet (fold it in, precede it, follow the pick), but its
  content must be said, and said before the first put-up is sent.
- Nothing public shows that a frame is up. Only the person themselves may see it.
- The long-press item (shipped in 413) stays everywhere it is. This sheet is an addition, not a
  replacement.
- No server changes. Everything above already exists as RPCs.

## 2. What happened last round, and why this brief exists

Round one put a capsule beside the compose pill for eight seconds after each qualifying Post swipe,
and a short sheet on the last card. On device the owner found:
- The capsule for frame 1 showed under frame 2, and swiping frame 2 counted as "no". Sorting a
  burst, each offer lived for well under a second. It was effectively invisible.
- Only the last card reliably offered anything, so which frame got offered was an accident of
  order, not the person's choice.
- Before that, the last-card ask sat alone on a large blank screen whose only exit was the X,
  which does not read as "no".
- There was no sense of which frame was already up, so swapping was impossible to reason about.

The owner's call: Spotlight leaves the deck's swiping entirely. What is proposed now: sorting
stays exactly as it is, and when the session ends, one sheet shows every frame posted in that
session that can go up, side by side. With one qualifying frame it is a simple yes or not now;
with several, the person chooses. If a frame is already up this week, it is shown too, and the
pick swaps it out, named in words. Spotlight takes one frame a week, so choosing from the session
fits it.

## 3. Design these states (402pt artboards, dark, the app's own tokens)

Propose two directions for the sheet (for example: a bottom sheet over the emptied deck, versus
a sheet over wherever the deck returns the person, or a picker that reads like a contact sheet
versus a horizontal strip), then recommend one, and draw every state below in the recommended one:

A. One qualifying frame posted this session, nothing up this week. The simplest offer.
B. Several qualifying frames (draw 3, and draw 12 from a burst). Nothing up. Choosing one: how
   selection reads, what the default is (none selected, the first, the last?), and how the
   primary action changes once something is picked. Justify the default.
C. A frame is already up this week (put up from an earlier session or by long press). Show it,
   with the day it was posted ("your frame from Tuesday"), so the person knows what a pick would
   take down. The action says swap, in words.
D. The frame already up was posted THIS session (the person long-pressed it elsewhere, then
   sorted more; or it is in this session's set). Decide how it appears in the set.
E. Nothing in the session qualifies (everything kept, deleted, tagged, shot before this week, or
   the account cannot put up). No sheet; the deck closes exactly as today. Confirm or argue.
F. The session ends by the X, early, after qualifying frames were posted. Does the sheet appear?
   Justify either way.
G. Undo. The last swipe is still held when the cards run out. Decide what happens to Undo when
   the sheet appears: is the last swipe committed first (Undo gone, the frame offerable), kept
   undoable behind the sheet (and then how is it offered with no post yet), or offered inside
   the sheet? This decides the whole implementation; be explicit.
H. A post in the session failed to land ("Couldn't post that one..."). The sheet only offers
   posts that exist. How, if at all, the sheet reflects the one missing.
I. First-time: the explainer and the sheet together. Draw the first put-up end to end.
J. Putting it up: in flight, success (the confirmation, and where it shows given the banner
   limitation above), and a refusal from the server (for example the week closed while the
   sheet was open, or the frame turned out tagged). The person must never be left on a dead
   screen.
K. Not now. How the person declines, and where they land afterwards (camera or Darkroom, the
   same as a deck that closed without the sheet, including the new-account first-sort Darkroom).
L. Cadence. The person sorts three times this week and declines each time: does the sheet ask
   every session, once a day, until something is up, or stop after a decline? Recommend one;
   the owner does not want a nag and does not want the offer forgotten.
M. The Sunday-night edge: frames shot this week can develop after the week closes, so a session
   early Monday may hold frames that no longer qualify, and the sheet may be open across 04:00.
N. Largest accessibility Dynamic Type size, for A, B (12 frames) and C.

## 4. Constraints

- The deck's swiping is untouched: no new element on the card, the pill, the circles or the
  header during the session. The sheet exists only after the session ends.
- One sheet per session at most. It never blocks leaving: an obvious "Not now" and a swipe-down
  both decline.
- Frames are photographs at the app's 3:4 frame aspect (`FlimTheme.frameAspect`), never cropped
  square. A selected frame reads as chosen by light and emphasis, never by a ring, star, check
  badge or border drawn on the photograph itself.
- Existing tokens, type roles and components only (`PrimaryButton`, `SpotlightGlyphBadge`,
  `SpotlightFrameCell` and friends). No new colours. 44pt minimum targets, Dynamic Type up to
  the largest accessibility sizes, VoiceOver labels for each frame (what it is and when it was
  shot), Reduce Motion respected.
- Copy: no em or en dashes anywhere. The people choosing are "the team at FLIM", never the owner
  or an editor. A Spotlight is named by its week ("the week of September 28"), never by a
  weekday; a frame may be named by the day it was posted ("your frame from Tuesday"). Banned:
  featured, winner, top, picked, best of, circled. Reuse existing strings where they fit ("Put it
  up", "Not now", the `SpotlightPutUpNotice` confirmations, the first-time sheet's text) and mark
  every new one.
- Nothing about Spotlight may look like a contest or a score. No counts of how many people put
  frames up, no "your best frame" language.
- Client only. No new server fields or RPCs.

## 5. Deliver

1. The two directions, one board each, with a paragraph on the trade-off. Then your
   recommendation.
2. Every state in section 3 in the recommended direction, at 402pt, including N.
3. A copy table: every user-facing string, new or reused, with where it appears.
4. A decisions list answering F, G, K and L in one line each, with the reason.
5. An implementation note per state naming the file and type it changes (from the list above),
   what new state the deck needs (for example the session's posted frames and their tags), how
   the sheet is hosted given the deck's self-close and its two presenters, and anything the
   current code does that your design depends on changing. Keep it to what a 1.6.x update can
   ship: client only.
