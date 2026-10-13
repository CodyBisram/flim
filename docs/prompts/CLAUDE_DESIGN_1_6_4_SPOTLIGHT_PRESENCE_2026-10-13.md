# FLIM 1.6.4: Spotlight that stays in view. Prompt for Claude Design (2026-10-13)

Three additions to Spotlight, chosen by the owner from a longer list: the week's strip stays at the
top of the feed until it has really been looked at, a quiet row reminds people who have not put a
frame up that the week is closing, and the people whose frames were chosen get a card they can
share. Paste everything below the line into a new Claude Design project.

Attach, in this order:

1. Screenshots from build 434 at 402pt:
   - the feed with a Spotlight strip at the top, "new" pill showing
   - the same feed after the strip was scrolled past once and the feed reloaded (the strip down
     in the timeline, no pill)
   - the week's sheet (the strip's band opened), and a chosen frame opened from the strip
   - a profile with the Spotlight shelf, and the gold Spotlight badge
   - the long-press menu on your own frame showing "Put it up for Spotlight"
   - the Spotlight sheet at the end of a sort, and the first-time Spotlight sheet
   - the notification a chosen person gets, and where it lands
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift` (tokens and type roles).

---

## 0. What you are designing, and why

FLIM is an invite-only iOS camera app: a disposable camera for a few close friends. Spotlight
(since 1.6.0) is its weekly moment: during a week, each person can put up one frame they shot that
week. Only the team at FLIM sees what is put up. After the week closes, the team chooses a few and
publishes them, usually on the Monday after. Everyone then sees one short strip of those frames in
their feed. The chosen get a notification, a Spotlight badge, and the frame on their page's shelf.

What the first three published weeks showed:

| Week of | Frames put up | Chosen | Reactions on chosen frames after publish |
|---|---|---|---|
| September 21 | 2 | 2 | 0 |
| September 28 | 7 | 3 | 0 |
| October 5 | 9 | 6 | 0 |

- Putting frames up is growing, and nearly all of it happens the day of and the day after the Friday
  push ("put one up this week"). About 9 of roughly 30 weekly openers now take part.
- Looking is not. The three strips were opened 16 times by 11 people in total, and the chosen frames
  got no reactions at all once published (they had 55 between them earlier, all from followers).
- The strip loses its place fast. It counts as seen the moment half of it scrolls into view, and the
  next reload puts it back at its own place in the timeline (the instant it was published). By
  midweek it is several screens down, and after seven days it leaves the feed.

The owner's read: people use Spotlight, but it is not clear they enjoy it. The payoff stays private
to the chosen, and for everyone else the week happens off screen. This round makes the week visible
from start to finish without making Spotlight a place of its own.

The codebase is public: https://github.com/CodyBisram/flim (branch `main`, build 434 is commit
58475c4). Read these before designing. They are the ground truth, and your design must be buildable
against them:

- `Flim/Views/Feed/FeedView.swift`: the strip in the feed. `spotlightStrip(_:)` (the strip and the
  `.onScrollVisibilityChange(threshold: 0.5)` that marks it seen), `spotlightStrips(in:seamBefore:)`,
  `allSpotlightStrips` (first run, nobody has posted), `seenSpotlight`, and the first-visit lines and
  1.6.0 announcement that can also sit at the top.
- `Flim/Models/Spotlight.swift`:
  - `SpotlightPlacement` / `SpotlightSlot`: where a strip sits. An unseen strip is already lifted to
    the top over a caught-up feed. Slots are snapshotted at reloads, so marking a strip seen never
    moves it while someone is reading.
  - `SpotlightSeenMark`: per account, local.
  - `OwnSpotlightEntry`: this week's server bounds `weekStartsAt` / `weekClosesAt`, `canPutUp`, and
    `postId` (what is up, if anything).
  - `SpotlightWeekLabel` (how a week is named), `SpotlightMenuItem.resolve` (who can put what up,
    and the reason strings), `SpotlightPutUpNotice` (the confirmation strings).
- `Flim/Views/Feed/SpotlightViews.swift`: `SpotlightStrip`, `SpotlightFramesRow`, `SpotlightFrameCell`,
  `SpotlightGlyphBadge`, `SpotlightWeeksSheet`, `SpotlightShelfView`, `SpotlightFirstTimeSheet`,
  `SpotlightSessionSheet` (the end-of-sort picker: frames side by side, pick one, put it up or swap
  it in), `SpotlightMenuSection`, `.spotlightPutUpFlow`.
- `Flim/Services/FeedService+Spotlight.swift`:
  - `loadSpotlightStrip`: up to 6 weeks, published inside the feed's 7-day window.
  - `refreshOwnSpotlightEntry`.
  - `putUpForSpotlight(post)`: a second put-up in a week swaps out the first.
- `Flim/Services/BrandedExport.swift` and `Flim/Services/PhotoExport.swift`: how FLIM already turns
  a frame into a shareable image (the borderless master with the date back burned in). The share
  card should come out of this pipeline, not a new one.
- `docs/SPOTLIGHT_1_6_PLAN.md`: the whole feature and every decision behind it.

## 1. Settled. Do not change or re-propose

- Spotlight is a moment, not a place. There is no Spotlight tab, page, or view beside the feed, and
  no Feed/Spotlight switch in the header. All three were designed and rejected.
- The strip is one row, roughly a third of a post's height. It never grows into a grid in the feed.
- A chosen frame reads as lit. Never draw a ring, circle, star, check, badge or border on a
  photograph.
- What a person puts up stays private to the team at FLIM. Nothing public shows that a frame is up,
  or how many people put frames up. Nothing looks like a contest or a score.
- The people choosing are "the team at FLIM", never the owner or an editor.
- A Spotlight is named by its week ("the week of October 5"), never by a weekday.
- Banned words: featured, winner, top, picked, best of, circled.
- No em or en dashes in any copy.
- Strangers can react to a chosen frame but not comment.
- One frame per person per week. The week runs Monday 04:00 to Monday 04:00, New York time, and its
  bounds come from the server (`OwnSpotlightEntry`). Only frames shot that week, by the person, with
  nobody tagged, can go up.

## 2. The three additions

### A. The strip stays at the top until it has really been looked at

Today "seen" means half of the strip scrolled into view once. Redefine it so a week's strip holds the
top of the feed until the person has actually engaged with it, then settles back to its place in the
timeline as it does today. Decide and justify:

- What counts as looked at: opening the band (the week's sheet), opening any frame, or something
  lighter (for example the strip fully on screen for some seconds, or scrolled past on several
  separate days). Opening is the honest signal, but some people will never tap. Recommend a rule
  that does not hold the top forever for someone who simply is not interested.
- Exactly where "the top" is, alongside the other things that already compete for it: the
  first-visit lines for new accounts, the 1.6.0 Spotlight announcement, the "N new" pill, and the
  caught-up block.
- Two published weeks inside the feed window at once. Only the newest should hold the top.
- The "new" pill and the pinned position together. Do they still mean the same thing?
- The moment it lets go. It must never jump while someone is reading (slots move only at reloads
  today; keep that), and it should not vanish so quickly that it seems broken.
- Someone who follows nobody, and the first-run feed with no posts.

### B. A quiet "the week is closing" row for people who have not put a frame up

For someone who can put a frame up this week (`canPutUp`) and has not (`postId` is nil), a row in
the feed in the last days of the week. Today the only nudge is the Friday push. Decide:

- When it appears and when it goes away: which day it starts, whether it changes on the final day,
  whether it leaves once the week closes, and whether it leaves once dismissed for that week.
- Where it sits relative to the strip from A. One Spotlight element at the top at a time is the
  instinct. Show how they share or take turns.
- What tapping it does. The best answer probably offers that week's eligible frames right there,
  side by side, the way `SpotlightSessionSheet` does at the end of a sort, so a frame goes up in two
  taps. Say so if you reuse it.
- Someone with no eligible frame this week (nothing shot, or everything tagged): show nothing, or a
  line that sends them to the camera. Recommend one. The owner does not want a nag.
- Someone who has a frame up: nothing in the feed. Their frame is private, so no "your frame is up"
  row either, unless you can argue for one that only they see.
- The first put-up on an account still goes through the first-time explainer before anything is
  sent.
- Copy. The deadline is `weekClosesAt` (04:00 Monday New York, which is Sunday night for most
  people today, but not for every zone). The weekday rule above is about naming a Spotlight.
  A deadline may say "tonight", "tomorrow night", or "Sunday night" if it is right in the reader's
  own zone. Propose the strings, and flag any that bend the rule.

### C. A share card for the people whose frame was chosen

The chosen get a push and a badge, then silence. Give them something to show people outside FLIM:
an image of their own chosen frame that marks it as in the Spotlight for its week, plus a way to
send it. Decide:

- Where it is offered: where the chosen push lands (the week's sheet focused on their week), their
  own shelf, the frame's own menu. Offer it only to the person whose frame it is, and never for
  anyone else's frame.
- The card itself, at 3:4, from the existing export pipeline (`BrandedExport`): the frame, the week
  ("the week of October 5"), the FLIM wordmark, flim-app.com. No handle unless the person adds it.
  Draw it for Instagram Stories (9:16 canvas around the 3:4 frame) and for a plain share.
- The text that goes with it in the share sheet. Optionally the person's own invite link
  (flim-app.com/i/CODE) when they have invites left. Draw it both with and without.
- How it reads on the shelf for a frame chosen weeks ago. Still shareable, named by its own week.

## 3. Draw these states (402pt artboards, dark, the app's own tokens)

For A, propose two directions (for example: the strip as it is but pinned, versus a compact pinned
form that grows into the full strip on tap), recommend one, and draw everything below in the
recommended one.

1. Monday, just published, unseen: the feed opens on the strip at the top. Draw it with the
   first-visit line also present.
2. The same feed after scrolling the strip past once, then reloading: still at the top per your
   rule (or not, if your rule says so).
3. After it has been looked at: settled in the timeline, and what if anything stays at the top.
4. Two weeks in the window: the newer unseen, the older seen.
5. Thursday, nothing put up, eligible frames this week: the closing row, and the row tapped,
   showing the frames and putting one up (with the first-time explainer on a first put-up).
6. The final day: the closing row's last-day form.
7. The closing row dismissed for this week, and the next week starting.
8. No eligible frames this week: your recommendation drawn.
9. A frame already up: the feed shows nothing about it.
10. The chosen person: the push landing, the share offer, the card (Stories and plain), and the
    share sheet with the text.
11. The shelf weeks later, with the share action on an old chosen frame.
12. The largest accessibility Dynamic Type size for 1, 5 and 10.

## 4. Constraints

- Client only. Everything needed already exists: `weekClosesAt`, `canPutUp`, `postId`, the strip
  weeks, the shelf, the put-up and swap RPCs.
- Existing tokens, type roles and components only (`SpotlightGlyphBadge`, `SpotlightFrameCell`,
  `SpotlightStrip`, `PrimaryButton` and friends). No new colours.
- Frames at the app's 3:4 aspect (`FlimTheme.frameAspect`), never cropped square.
- 44pt minimum targets, Dynamic Type to the largest accessibility sizes, VoiceOver labels, and Reduce
  Motion respected.
- Every new string marked as new in the copy table. Existing strings are reused where they fit.

## 5. Deliver

1. Two directions for A, one board each, with a paragraph on the trade-off and your recommendation.
2. Every state in section 3 in the recommended direction.
3. A copy table with every user-facing string, new or reused, and where it appears.
4. A decisions list: what counts as looked at, where the top is, when the closing row shows and
   goes, what tapping it does, the no-eligible-frame case, and where the share card is offered. One
   line each, with the reason.
5. An implementation note per state naming the file and type it changes, from the list above,
   including how `SpotlightSlot` / `SpotlightSeenMark` change for A, and what new local state, if
   any, the closing row needs (for example a per-account, per-week dismissal mark like
   `SpotlightSeenMark`).
