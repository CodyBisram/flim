# Rolls redesign handoff (Claude Design, revision 3)

> Batch 1 (screens 3a-3d, 3h: header with ledger, picker, active-roll block, ready bands, archive grid)
> shipped 2026-08-26, revision-3 header + 3c amendments applied.
> Batch 2 (3e-3g: the reveal rework) is NOT yet built; its spec is below and is authoritative,
> including the Amendments section, which wins over anything after it.


**Revision 3.** Read the *Amendments* section before anything else — it supersedes the body where they disagree.

| Rev | What changed |
| --- | --- |
| 1 | Initial spec: eight screens (3a–3h), workflow, copy inventory, token mapping. |
| 2 | Developer review. The develop beat kept (timer-only deletion); `rollRevealSeen` moved to completion; Share invite dropped from archive tiles; adaptive clock tick; 3f reclassified as a third `PhotoPagerView` composition, not a flag flip. Camera pre-selection confirmed to exist already. |
| 3 | Header corrected to Feed/Darkroom's compact one-row bar with a ledger slot (`FlimNavTitle` is used in only two places in the app, both of them Rolls). 3c's blank film strip cut. |

## Overview

The Rolls tab is rebuilt around a single idea: **the screen should do the thing its clocks are asking for.**

Today it is a `List` of roll rows. Every row carries a 54pt cover with a develop ring, a member count, an invite code, and one of three status chips, all at the same visual weight, all animating on a 60-second `TimelineView`. It is the most-visited screen in the app (per the comment on `RollsView.refreshLiveActivities`) and it has no primary action — "Reveals in 3h 12m" is a deadline with no verb attached, and the Camera is a separate tab that does not know which roll you meant.

The redesign:

1. The roll closing soonest becomes a **header with a primary action** — *Shoot into this roll* — that opens Camera with that roll pre-selected.
2. The other open rolls become a **picker**, not a list. You only ever shoot into one roll; switching is a tap.
3. **Ready to reveal** stays a loud, transient band. It is an inbox that empties.
4. **Developed rolls become an album grid** (180pt covers, two-up), because at that point a roll is something you browse by picture, not an agenda item.
5. The **reveal drops its timer, not its ceremony.** The shared clock, the story bar and Skip all go; you page at your own speed on the shared photo viewer and can comment on a frame for the first time. Each frame still arrives as a well and **develops in place** the first time you reach it — once per frame, never again.
6. The visual anatomy is lifted directly from the recently-redesigned **Darkroom**: band → meta line → film rack between dashed perforations, units divided by a hairline that fades out at both ends. The header is Feed's and Darkroom's compact one-row bar, not the 34pt title Rolls uses today.

## About the design files

The files in `design/` are **design references created in HTML** — prototypes of intended look and behaviour, not production code to copy.

The target codebase is **SwiftUI (iOS)**, at `Flim/`. The task is to recreate these screens in SwiftUI using the app's existing patterns and atoms — `FlimTheme`, `flimFont(_:weight:relativeTo:)`, `FlimNavTitle`, `DarkroomDayUnitView`, `DarkroomPerforationLine`, `DarkroomFrameView`, `DarkroomDevelopArc`, `DarkroomUnitSeparator`, `ReactionBar`, `PhotoPagerView`, `CachedImage` — **not** by porting HTML. Almost every atom this design needs already exists in the repo; the work is mostly composition plus one new view model shape.

Two colour notes before anything else:

- The prototypes are drawn on the **Nocturne** design system's palette (ground `#161826`, accent `#9184d9`). The **app** uses `FlimTheme.bg` (`#0A0A0A`) and a *user-chosen* accent read from `@Environment(\.flimAccent)`. **Ship the app's tokens, not Nocturne's.** The mapping table under *Design tokens* gives the exact substitution for every value.
- Every icon in the prototypes is a Phosphor glyph standing in for an SF Symbol, because SF Symbols cannot be loaded in a browser. Ship SF Symbols; the mapping table names each one.

## Fidelity

**High-fidelity.** Every measurement, weight and colour below is exact and was derived from source files in this repo, not invented. Where a value comes from a named constant (`DarkroomDayUnit.framePitch`, `Roll.developDelayPhrase`, `RollImminence.closingWindow`), **read the constant — do not hard-code the number.** Several comments in the repo record bugs caused by exactly that.

The one genuinely new geometry is the archive grid (two columns, 10pt gutter). Everything else reuses an existing spec.

## Amendments (review round 2)

Seven corrections after implementation review — five from the developer, two from a design pass. Where this section disagrees with anything below, **this section wins.**

1. **The develop beat stays.** Only the *timer* is deleted. Each frame arrives as a well and develops in place the first time you page to it — one ~0.8s blur-to-sharp, once per frame, never again. See 3f.
2. **`rollRevealSeen` moves from presentation to completion.** Today it is written when the reveal is presented (`RollDetailView` line ~360, before a frame plays). Under self-pacing that is wrong. See *State*.
3. **Archive tiles do not offer Share invite.** Invites end when a roll develops (owner decision, 2026-08-26; `RollDetailView` ~line 232, `RollMembersView` ~line 70). See *Interactions*.
4. **The clock tick is adaptive, not fixed at 60s.** See *Interactions*.
5. **3f is a third composition of `PhotoPagerView`, not `showsNightRack: true`.** See 3f.
6. **The header is the compact one-row bar, not `FlimNavTitle`.** My original spec said "`FlimNavTitle("Rolls")` unchanged" — faithful to today's `RollsView`, and wrong about the app. See *Shared chrome*.
7. **3c loses its blank film strip.** Cut on review: it carried no state, read as a loading skeleton, and misused `DarkroomFrameSlot.empty` — whose own doc says a single-strip day gets no padding "because a three-shot day is a short piece of film, not a strip nine-tenths empty." See 3c.

---

## Screens

Eight screens, ids `3a`–`3h`, in `design/Rolls - redesign.dc.html` (turn 3, the top section of the file). The baseline recreation of today's screen is `design/Rolls - current.dc.html`.

### Shared chrome (all Rolls screens)

**Header row** — the compact one-row bar the redesigned Feed and Darkroom both use. **Not `FlimNavTitle`.**

Audit: `FlimNavTitle` (34pt `.light`) appears in exactly two places in the whole app — `RollsView` and `RollDetailView`. `flimInlineTitle` is for sheets. Feed (`FeedView.header`) and Darkroom (`DarkroomView.normalHeaderRow`) use neither: both render a plain `HStack` with `Text(...).flimFont(17, weight: .light).tracking(0.5).foregroundStyle(FlimTheme.textPrimary)`, then a `·` and a 12pt ledger, then `Spacer`, then trailing controls. Rolls was the odd one out, and my first spec canonised the odd one out. Correcting it.

Anatomy, matching `FeedView.header` / `DarkroomView.normalHeaderRow`:

- `HStack` baseline-aligned, spacing 6, horizontal padding 16, bottom padding 10.
- `"Rolls"` — 17pt `.light`, tracking 0.5, `FlimTheme.textPrimary`, `relativeTo: .body`.
- **The ledger** — take the pattern whole rather than only shrinking the type; the slot is genuinely wanted here. `·` then a 12pt value, `relativeTo: .caption`:
  - Something ready to reveal → `"1 ready"` in **accent** with Feed's glow (`.shadow(color: accent.opacity(0.55), radius: 6)`). Feed reserves that treatment for the urgent, right-now fact, which is exactly what a sealed roll is.
  - Otherwise → `"3 open"` in `FlimTheme.textTertiary`, matching Darkroom's shot count.
  - **Never a zero.** Omitted entirely when nothing is open and nothing is ready (3c, 3d), the same rule Feed's ledger doc states.
  - Count open rolls **server-side**, never from a loaded page — same trap as `frameCounts`.
- `Spacer`, then the trailing `plus`: 17pt accent, `.expandTapTarget(by: 9)` to reach 44. Presents a menu with **New roll** and **Join with a code** (today these are two separate toolbar glyphs; collapse them).

Consequence worth noting: with the tab title at 17pt, the **active roll's name at 26pt `.light` is the largest type on the screen.** That is correct — the roll is the subject, the tab is a label — but it inverts today's hierarchy, so expect it to look wrong for a day.

**Do not revert this.** A later pass reading `RollsView.swift` in isolation will see `FlimNavTitle` and "fix" the header back. It is a deliberate deviation from the current code toward the app's actual convention.

**Tab bar** — unchanged (`MainTabView`), Rolls selected.

### 3a — Shooting (the default state)

**Purpose:** see which roll is closing next and shoot into it.

Vertical order inside a `ScrollView`:

**1. Open-roll picker.** Horizontal scroll, `showsIndicators: false`, leading/trailing padding 16, item spacing 18, mask-faded over the last 26pt of the trailing edge.
Each item is a `VStack(spacing: 5)`:
- Row: roll name 13pt `.medium` + remaining time 11pt, baseline-aligned, spacing 6, `lineLimit(1)`.
- Selection mark: 2pt tall, 1pt corner radius, full item width — **accent when selected, clear otherwise.**

Selected item: name `textPrimary`, time `--color-accent-300` equivalent (see token table). Unselected: name and time both `FlimTheme.textSecondary`. **Selection is carried by the accent mark, never by contrast** — unselected items must stay ≥ 4.5:1 (this is the third time this exact regression was caught in review; `FlimTheme.textTertiary`'s own doc records the original).

Contains **only rolls where `!roll.isDeveloped`**, ordered by `revealAt` ascending. A developed roll is not shootable, so it is not a choice.

**2. Active roll block.** Top padding 16.
- Name: 26pt `.light`, tracking 0.3, `textPrimary`, bottom margin 5, horizontal padding 16.
- Clock line: 12.5pt. `"Closes 6:12 AM · "` in `textSecondary`, `"3h 12m left to shoot"` in accent-300. One `TimelineView(.periodic(from: .now, by: 60))` for the whole screen — not one per row.
- Meta line: 12.5pt `textSecondary`, top margin 2.
- **Rack**, horizontal padding 16: `DarkroomPerforationLine` (3pt tall, dash `[4, 6]`, `FlimTheme.stroke`), then an `HStack(spacing: DarkroomDayUnit.frameGap)` of frames with 2pt vertical padding, then a second perforation line. Frames are `DarkroomDayUnit.framePitch - frameGap` × 59 (44×59 today). Capacity from `DarkroomDayUnit.stripCapacity(availableWidth: width - 32)` — **one strip only**, never wrapped; the last slot becomes an overflow well when the roll has more frames than fit.
- Frames in an undeveloped roll are **wells**, exactly `DarkroomFrameView.developingWell`: fill `Color(white: 0.063)`, 2pt radius, 1pt `FlimTheme.stroke` border, containing a 16×16 `DarkroomDevelopArc` at the roll's shared fraction. The fraction is `RollImminence.progress(roll:now:)` — one value for the whole roll, computed once per tick.
- Overflow well: same well, containing `"+12"` at 11pt `.medium` in accent-300 instead of an arc.
- **Primary action**, top padding 14, horizontal 16: 46pt tall capsule, 1pt accent border, transparent fill, centred `HStack(spacing: 8)` of a 18pt `camera.aperture` and a 15pt `.medium` label. Outlined, never filled.

**3. Unit separator** — `DarkroomUnitSeparator`, top padding 20 here (it defaults to 11).

**4. Ready band** (zero or more).
- Band: padding top 10, leading 16, trailing 12, bottom 5. Name 17pt `.light` tracking 0.4 `textPrimary`; trailing pill `"Reveal · 47"` 11pt `.medium`, padding 4/9, capsule, accent-tinted fill (`accent.opacity(0.16)`) + 1pt accent border, accent-200 text.
- Meta 11.5pt `textTertiary`, horizontal 16, bottom 5.
- Rack of **sealed** wells: same well but accent-tinted (`accent.opacity(0.16)` fill, `accent.opacity(0.35)` border) with a **complete** arc. Sealed frames are never real photographs — the reveal is the first time anyone sees them.

**5. Developed section.**
- Header: `"Developed · 11"` 10.5pt `.semibold`, tracking 0.13em, uppercase, `textSecondary`; then a 1pt rule fading to transparent rightward; padding 18/16/12.
- Grid: 2 columns, 10pt gutter, horizontal padding 16. Each tile: square cover, 2pt radius, `.scaledToFill()`, 1pt `FlimTheme.stroke` inset border; name 13pt `textSecondary` `lineLimit(1)` truncating tail; meta 11.5pt `textTertiary`, tightened 5pt.
- Ordered by `revealAt` descending (`RollImminence.sorted`'s third band).

### 3b — The last hour

Identical to 3a with three changes, gated on `RollImminence.closingLabel(roll:now:) != nil` (i.e. inside `RollImminence.closingWindow`, one hour):

1. The **whole** clock line goes accent-300, not just the second clause.
2. Button label changes: `"Last frames — shoot now"`.
3. Picker time for the active roll shows the short form (`24m`, then `40s` under a minute) — `closingLabel` already produces exactly these.

### 3c — Nothing open

Every roll has developed, so there is no active roll and no picker.

- Title 26pt `.light` `textPrimary`: `"No roll is open"`.
- Body 12.5pt `textSecondary`, line spacing ~1.55: `"A roll closes 12 hours after it starts. Nobody sees a frame until then."` — **the "12 hours" must come from `Roll.developDelayPhrase`.** A literal here is false in every DEBUG build; `Roll`'s own doc records this.
- Two 46pt capsules side by side, 8pt gap, top padding 6: **Start a roll** (accent border, accent-200 label, `plus` glyph) and **Join with a code** (`FlimTheme.stroke` border, `textSecondary` label, `person.badge.plus`).
- Then the Developed grid.

**No rack on this screen.** An earlier revision put a strip of unexposed pad slots here as a "blank piece of film". It was cut: it carried no state (there is no roll, so there are no slots), it read as a loading skeleton next to the app's real `ShimmerPlaceholder`, and it used `DarkroomFrameSlot.empty` against the reasoning in that type's own doc. The whitespace is correct — the photographs begin one section down, and the screen was never bare, only bare at the top.

If this state later needs a nudge rather than an absence, the honest version is a fact, not an ornament: the roll that closed most recently, named, with its own developed strip — *"Ilana's birthday closed 4 hours ago · 47 frames"*. Note that it duplicates the newest archive tile directly beneath it, so it needs a reason beyond filling space.

### 3d — No rolls at all

First run, and after leaving the last roll. Copy is kept verbatim from today's `RollsView.emptyState` — it is already the product's voice.

- `film.stack` 44pt `.ultraLight`, accent at 0.8.
- `"Better with friends."` 17pt `.light` `textSecondary`.
- `"Start a roll and share the code, or join one with a friend's code."` 13pt `textTertiary`, centred, horizontal padding 40.
- **Create** / **Join** as two capsules, 12/24 padding, 10pt gap. Today these use `OutlineButtonStyle` (`glassCapsule`); either keep that or use the plain accent outline for consistency with 3a/3c. Pick one and use it everywhere.

### 3e — Reveal, the cover

Keep today's `RollRevealView.coverCard` as-is. It is the one beat that earns its keep, and its own doc explains why (it answers *why am I looking at this* before *what is it*).

Centred stack on the reveal ground: eyebrow `"DEVELOPED"` 11pt `.semibold` tracking 3.5 accent → roll name 34pt `.ultraLight` tracking 2, `lineLimit(3)`, `minimumScaleFactor(0.6)`, horizontal padding 32, top 14 → 44×1 rule at `white.opacity(0.18)`, top 20 → `viewModel.cover.metaLine` 15pt `.medium` at `Color(white: 0.82)`, top 20 → `dateLine()` 13pt at `Color(white: 0.45)`, top 5. Bottom: a 120×2 capsule filling over `RevealCover.holdDuration`, bottom padding 92. Tap begins.

### 3f — Reveal, the roll at your pace  ← the substantive change

**This is a third composition of `PhotoPagerView`, not a flag flip.** `showsNightRack: true` is Darkroom chrome for own photos — Darkroom header, share-to-feed actions, no report branch. The reveal deck is mixed-author and needs attribution, reactions, comments **and** report. Budget it as a new mode alongside the existing two (`showsReveal`, or equivalent), reusing the pager's engine: paging, zoom, `resolvePhotoUpgrade`, `resolvedCacheKey`, the rack's single `SpatialTapGesture`, the share/delete/report branch.

**Delete from the reveal:**
- The auto-advance timer and `RevealPacing.slideDuration` / `viewingDuration`.
- The story progress bar and its 30Hz `TimelineView`.
- The `Skip` button (nothing left to skip).
- `playbackGesture`'s tap-zone / hold / pause machinery.

**Keep — this is the amendment.** The develop moment survives, moved off the clock and onto the finger. Each frame arrives as a **well** and develops in place the first time it is reached: one blur-to-sharp of ~0.8s (`RevealPacing.developDuration` retuned from 1.4s, since it no longer has to share a slide with a 5s hold), once per frame, never replayed on a backward swipe. Same modifiers as today — `blur(26 → 0)`, `saturation(1.7 → 1)`, `opacity(0.65 → 1)` — and still short-circuited by `accessibilityReduceMotion`.

Track it as `@State var developedFrameIds: Set<UUID>`, keyed by photo id and never by index (the deck mutates: `skipDeadFrame` removes entries mid-playback — `FeedUnitCard`'s own doc records the wrong-photograph cache poisoning that index-keying caused there).

The reason to keep it: the reveal is one-shot per roll and one of the app's two engines. Strip the ceremony and the once-ever reveal is visually identical to browsing the same roll's grid five minutes later. Self-pacing and comments were the gains worth having; the beat was not the cost of them.

Also keep from `RevealPacing`: `prefetchWindow` / `prefetchRange`, `moveSlop`, and `dismissThreshold` if swipe-down-to-dismiss stays.

Layout:
- Header, top padding 62, horizontal 16, `HStack(spacing: 12)`: `xmark` 15pt `textPrimary` → roll name 14pt `.semibold` → `Spacer` → `"Done"` 13pt `.medium` `textSecondary`. Done goes to 3g and **counts as completion**.
- Photograph: `.scaledToFit()`, full width, vertical padding 14. Develop beat as above; pinch-to-zoom is the pager's own.
- **Rack scrubber**, horizontal padding 16: perforation line, `HStack(spacing: 2)` of 30×40 compact frames, perforation line. Three states, and this is the whole idea made visible:
  - **Reached and developed** → the photograph, `opacity(0.45)`.
  - **Current** → the photograph at full opacity with a 1.5pt accent ring (`DarkroomFrameView.isCurrent == true`).
  - **Not yet reached** → a compact `developingWell`: `Color(white: 0.063)` fill, 2pt radius, 1pt `FlimTheme.stroke` border, a 9×9 circle at `accent.opacity(0.7)`, 1.5pt stroke. Verbatim the `compact` branch that already exists.

  The rack scrolls, centred on the current frame, faded to transparent over 22pt at **both** edges — 47 frames do not fit and 11 must not read as all of them. One `SpatialTapGesture` on the row resolves the hit; no per-frame recognizer.
- Credit block, centred, spacing 2: `"@mira"` 15pt `.semibold` (tappable → profile) and `"18 of 47 · 1:42 AM"` 12pt `textSecondary`.
- `ReactionBar` unchanged: horizontal scroll, chip spacing 8, horizontal padding 16. Chip = `HStack(spacing: 4)` of a 16pt emoji + 13pt `.semibold` count, padding 11/7, capsule `white.opacity(0.12)`; mine = `accent.opacity(0.28)` fill + 1pt accent border. Trailing `plus` 36×32 capsule `white.opacity(0.12)`. Defaults `PostEmoji.all`.
- Comment row: `bubble.left` 14pt + `"3 comments"` 12.5pt `textSecondary`, horizontal 16 → `PhotoCommentsSheet`. **A real gain from reusing the pager** — a timed slideshow could never allow it.
- Footer bottom padding 44 (clear of the home indicator).

Swiping past the last frame lands on 3g.

### 3g — Reveal, the end

Today's `RollRevealView.summary`, with one change: **View the roll becomes an outlined accent capsule** (46pt tall, 36pt horizontal padding, 15pt `.medium` accent-200 label) instead of a filled accent capsule with black text, matching 3a's primary.

`film.stack` 44pt `.ultraLight` accent → roll name 24pt `.light` → `"47 shots · developed together"` 14pt `Color(white: 0.6)` → presence pill (`sparkles` or `person.2.fill`, 13pt `.medium`, padding 8/14, accent-tinted capsule) → View the roll → `"Save all to Camera Roll"` 14pt `.medium` with `square.and.arrow.down` 13pt, `Color(white: 0.7)`. Save-all failure copy lands directly under the button with a Retry, unchanged.

The presence line is the only thing carrying the communal feeling once the shared clock is gone — consider giving it more weight than it has today.

### 3h — After the reveal

The answer to "is that portion gone?" — **yes.**

`isReadyToReveal(roll)` is `roll.isDeveloped && !UserDefaults.standard.bool(forKey: "rollRevealSeen.\(roll.id.uuidString)")`. Once that flag is written the Ready band drops out, the roll enters the Developed grid as the newest tile, and the header count increments (11 → 12).

**When the flag is written changes.** Today `RollDetailView` sets it at *presentation* — inside the `.task` that decides to show the reveal, before a single frame plays (around line 360). That was safe while auto-advance guaranteed the deck finished. Under self-pacing it is not: someone can swipe away at frame 2 of 47, and write-on-open means they have burned their only ceremony and the camera-roll auto-save gate (`CameraRollAutoSave`'s `isRollRevealed`) has fired for a reveal they did not watch.

**The rule: write it on completion.** Completion is reaching 3g — by swiping past the last frame or by tapping Done. Any earlier dismissal (swipe-down, `xmark`, backgrounding) leaves the flag unset, so the Ready band stays up and the reveal replays from the cover. That is strictly better than today's behaviour and it is a decision, not an inference — three other places read this flag (`CameraRollAutoSave`, `WidgetSync`, `RollsView.isReadyToReveal`) and all three want "watched", not "opened".

3h is otherwise identical to 3a: same active roll, same picker (all three open rolls still there — revealing a roll that was never in the picker cannot remove one from it), Ready band absent.

---

## Interactions & behaviour

| Trigger | Result |
| --- | --- |
| Tap a picker item | That roll becomes the active roll. Header re-renders in place; no navigation. Haptic `Haptics.tap()`. |
| Tap the active roll's name or rack | Push `RollDetailView(roll:)`. |
| Tap **Shoot into this roll** | Switch to the Camera tab with this roll pre-selected. The camera's own capsule already shows `RollImminence.closingLabel`. |
| Tap a Ready band | Push `RollDetailView`, which plays the reveal (3e → 3f → 3g) on first open only. |
| Tap an archive tile | Push `RollDetailView` (grid, play-through, save all). |
| Tap `+` in the toolbar | Menu: New roll (`CreateRollView`) / Join with a code (`JoinRollView`). |
| Long-press a picker item | Existing `rollMenu`: Share invite, Mute/Unmute, Leave (members only). |
| Long-press an archive tile | Mute/Unmute, Leave (members only). **No Share invite** — invites end when a roll develops (owner decision, 2026-08-26; the share affordance and the code banner are already gone from developed rolls in `RollDetailView` and `RollMembersView`). Offering it on an archive tile would resurrect a dead action. |
| Swipe an archive tile trailing | Leave (members only), through `ConsequenceSheet(consequence: .leave(...))`. |
| Re-tap the Rolls tab | Scroll to top (existing `scrollToTop` signal). |
| Pull to refresh | Existing `load()`. |
| Swipe horizontally in 3f | Page one frame. Rack recentres. |
| Tap a rack frame in 3f | Jump to that frame. |
| Swipe past the last frame in 3f | 3g. |
| Swipe down > `RevealPacing.dismissThreshold` in 3f | Dismiss the reveal. |

**Animation:** the only periodic redraw on the Rolls screen is **one** `TimelineView` driving the active roll's clock line and develop arc — not one per row. The archive is static. The Ready band is static (its arc is complete). Nothing pulses, nothing escalates by colour cycling. The 30Hz story bar is deleted.

**The tick is adaptive.** A fixed 60-second cadence contradicts the copy: `RollImminence.closingLabel` returns a seconds form under a minute (`"40s left to shoot"`), and a 60s tick would leave "40s" on screen for a full minute — stale the moment it draws, on the one screen whose whole job is telling the truth about a deadline. Drive the cadence off the label's own form:

```swift
// 1s only while the label is counting seconds; 60s the rest of the time.
let remaining = RollImminence.secondsRemaining(roll: roll, now: .now)
let cadence: TimeInterval = remaining < 60 ? 1 : 60
TimelineView(.periodic(from: .now, by: cadence)) { … }
```

The 1s cadence is reachable only in the final minute of a roll's life, so it costs nothing in practice. If you would rather not carry the conditional, drop the seconds form from the copy instead and let the last minute read `"under a minute left to shoot"` — but do not ship a seconds label on a minute tick.

**Accessibility:** keep `FlimTypeScale.maximum` (`.accessibility2`). The picker row, the 46pt primary, and rack frames all need `.accessibilityElement()` + labels; rack frames keep the button trait so VoiceOver can focus them individually and a double-tap resolves through the row's `SpatialTapGesture`. Every touch target reaches 44pt via `expandTapTarget`; the toolbar `plus` takes 9.

**Loading / error / empty:** unchanged from `RollsView` — `ProgressView().tint(.white)` on a cold load with nothing cached, `ErrorState(message:retry:)` on failure with nothing cached, 3d when the list is genuinely empty. Covers resolve through the existing batched `resolveCovers()` keyed by **storage path, not roll id** (that doc comment records a real bug). Archive tiles use `CachedImage(url:maxPixel:cacheKey:)` with `maxPixel` sized to 180pt at `displayScale`, `cacheKey` the path.

---

## State

New or changed on the Rolls screen:

| State | Type | Notes |
| --- | --- | --- |
| `activeRollId` | `UUID?` | The roll in the header. Defaults to the first of `openRolls`. Persist per session (`@SceneStorage`) so returning from Camera does not reset the choice. Must fall back gracefully when that roll develops, is left, or is deleted. |
| `openRolls` | `[Roll]` | `rolls.rolls.filter { !$0.isDeveloped }` sorted by `revealAt` ascending. |
| `readyRolls` | `[Roll]` | `filter(isReadyToReveal)`. |
| `developedRolls` | `[Roll]` | Developed and seen, sorted by `revealAt` descending. |
| `frameCounts` | `[UUID: Int]` | Per-roll frame count for the rack and meta line. **Server-side count, never a page length** — `PhotoService`'s pagination doc and `RollDetailView.rollFullyPaged` both record undercounting bugs from exactly this. `photos.rollTotalShotCount(rollId:)` already exists and `RollsView` already calls it. |
| `myFrameCounts` | `[UUID: Int]` | For "you shot 4". Same rule. |
| `memberCounts` | existing | `rolls.memberCounts`. |
| `coverURLs` | existing | Keyed by storage path. |

New in the reveal:

| State | Type | Notes |
| --- | --- | --- |
| `developedFrameIds` | `Set<UUID>` | Which frames have played their develop beat. Keyed by photo id, never index — the deck mutates under playback (`skipDeadFrame`). |
| `revealCompleted` | `Bool` | Set on reaching 3g. **This**, not presentation, writes `rollRevealSeen.<id>`. |

Existing state to keep: `mutedRolls`, `loadError`, `rollToLeave`, `inviteShareRoll`, `toastMessage` + `toastDismiss`.

Retire: nothing in `RollImminence` (the three-band sort still drives the three sections). The invite-code chip and the per-row status chips are removed from the view only.

---

## Design tokens

**Ship the app's tokens.** The middle column is what the prototypes drew; the right column is what to write in SwiftUI.

| Role | Prototype (Nocturne) | Ship (FLIM) |
| --- | --- | --- |
| Ground | `#161826` | `FlimTheme.bg` (`#0A0A0A`) |
| Elevated surface | `#232532` | `FlimTheme.bgElevated` (`Color(white: 0.08)`) |
| Hairline / frame border / perforation | `#3f424d` | `FlimTheme.stroke` (`Color(white: 0.14)`) |
| Primary text | `#e9e9ed` | `FlimTheme.textPrimary` |
| Secondary text (12–13pt meta, picker labels) | `#9397ab` | `FlimTheme.textSecondary` (`Color(white: 0.62)`) |
| Tertiary text (11.5pt band meta) | `#9397ab` | `FlimTheme.textTertiary` (`Color(white: 0.48)`) |
| Accent (marks, borders, arcs, glyphs) | `#9184d9` | `@Environment(\.flimAccent)` |
| Accent text on dark (clock, pill labels) | `#d2cefd` / `#e7e5fe` | `accent` — it clears 3:1 for chrome; for paragraph-size accent text use a lighter step |
| Accent tint fill (pills, sealed wells) | `#2b2741` | `accent.opacity(0.16)` |
| Accent tint, mine (reaction chip) | — | `accent.opacity(0.28)` |
| Well fill | `#292b31` | `Color(white: 0.063)` |
| Chip fill (reveal) | `rgba(233,233,237,0.12)` | `Color.white.opacity(0.12)` |

Do **not** read the accent statically. `FlimTheme.accent` reads `UserDefaults` directly and SwiftUI cannot see that change — `Theme.swift` records a half-recoloured app from exactly this. Use `@Environment(\.flimAccent)`.

**Type** — SF Pro throughout, via `flimFont(_:weight:design:relativeTo:)`, never `.system(size:)`:

| Use | Size | Weight | Tracking | relativeTo |
| --- | --- | --- | --- | --- |
| Header title (compact bar) | 17 | `.light` | 0.5 | `.body` |
| Header ledger | 12 | `.regular` | — | `.caption` |
| ~~Page title (`FlimNavTitle`)~~ | ~~34~~ | — | — | Not used — see *Shared chrome* |
| Active roll name | 26 | `.light` | 0.3 | `.title3` |
| Reveal cover roll name | 34 | `.ultraLight` | 2 | — |
| Reveal end roll name | 24 | `.light` | — | — |
| Band name (Ready, archive) | 17 | `.light` | 0.4 | `.body` |
| Primary button label | 15 | `.medium` | — | `.body` |
| Reveal credit `@handle` | 15 | `.semibold` | — | `.body` |
| Clock line, meta line, archive tile name | 12.5–13 | `.regular` | — | `.footnote` |
| Picker name | 13 | `.medium` | — | `.footnote` |
| Band meta, archive tile meta | 11.5 | `.regular` | — | `.caption` |
| Pills, overflow well, picker time | 11 | `.medium` | — | `.caption` |
| Section header (`DEVELOPED · 11`) | 10.5 | `.semibold` | 0.13em, uppercase | `.caption` |

**Spacing** — 16 is the screen's horizontal gutter (band trailing is 12, matching `DarkroomDayUnitView.band`). Rack vertical padding 2. Picker item spacing 18. Archive gutter 10. Primary button height 46. Separator top 11 (20 where noted).

**Radii** — film frames and archive tiles 2pt (they are frames). Pills and buttons fully rounded. No 12–16pt cards anywhere; this design has no card chrome.

**Shadows** — none on the Rolls screen. On a dark ground elevation is an edge plus ambient darkness.

**Constants to read, not retype:** `DarkroomDayUnit.framePitch` (46), `.frameGap` (2), `.stripCapacity(availableWidth:)`, `.perforationWidth(slotCount:)`, `Roll.developDelay`, `Roll.developDelayPhrase`, `RollImminence.closingWindow`, `RollImminence.progress(roll:now:)`, `RollImminence.closingLabel(roll:now:)`, `RollImminence.sorted(_:now:isReadyToReveal:)`, `RevealPacing.prefetchWindow`, `PostEmoji.all`, `Roll.memberCap`.

---

## Copy

### Rolls — header

| State | String |
| --- | --- |
| Title | `Rolls` |
| Ledger, something ready | `· 1 ready` (accent + glow) |
| Ledger, otherwise | `· 3 open` (textTertiary) |
| Ledger, nothing open or ready | omitted entirely |

### Rolls — active roll

| State | String |
| --- | --- |
| Clock, normal | `Closes 6:12 AM · 3h 12m left to shoot` |
| Clock, last hour | `Closes 6:12 AM · 24m left to shoot` |
| Clock, last minute | `Closes 6:12 AM · 40s left to shoot` |
| Meta | `5 people · 19 frames · you shot 4` |
| Meta, none of yours | `5 people · 19 frames · none of them yours` |
| Meta, nothing at all | `3 people · no frames yet` |
| Action | `Shoot into this roll` |
| Action, last hour | `Last frames — shoot now` |
| Overflow well | `+12` |

The framing is deliberate and comes from `RollImminence`'s own doc: at reveal the roll **closes to new shots**, so this is a window shutting, not a delivery arriving. Never "Reveals in".

### Rolls — ready to reveal

| State | String |
| --- | --- |
| Pill | `Reveal · 47` |
| Meta | `8 people · sealed until you open it` |
| Meta, yours only | `Just you · sealed until you open it` |

### Rolls — nothing open / none at all

| State | String |
| --- | --- |
| Title | `No roll is open` |
| Body | `A roll closes 12 hours after it starts. Nobody sees a frame until then.` (12 hours from `Roll.developDelayPhrase`) |
| Actions | `Start a roll` · `Join with a code` |
| Empty, title | `Better with friends.` |
| Empty, body | `Start a roll and share the code, or join one with a friend's code.` |
| Empty, actions | `Create` · `Join` |
| Archive header | `Developed · 12` |

### Reveal

| State | String |
| --- | --- |
| Cover eyebrow | `DEVELOPED` |
| Cover meta | `47 shots from 8 people` |
| Cover meta, solo | `47 shots, all yours` |
| Viewer credit | `@mira` |
| Viewer position | `18 of 47 · 1:42 AM` |
| Viewer dismiss | `Done` |
| Viewer thread | `3 comments` |
| End, meta | `47 shots · developed together` |
| End, presence first | `You're first to open this roll` |
| End, presence after | `4 of 8 have opened this roll` |
| End, primary | `View the roll` |
| End, save | `Save all to Camera Roll` |
| End, saving | `Getting them ready` |
| All frames deleted | `The shots in this roll were deleted.` |

Leave confirmations keep using `RollConsequence.leave(name:myShots:)` — one copy for all three screens that ask.

### Removed copy

| Was | Why |
| --- | --- |
| Invite-code chip on every row | A six-character string needed once, at share time, printed permanently on the busiest screen. It lives inside the roll and in the share sheet. |
| `Reveals in 3h 12m` | A reveal closes your window; it does not deliver anything. |
| `Developed` chip | The Developed section says it. |
| `Ready to reveal` pill | Replaced by `Reveal · 47`, which also says how much. |
| `Skip` (reveal) | Nothing to skip once the slideshow has no clock. |
| ~~The develop animation~~ | **Kept** — moved from the timer onto your thumb, once per frame. See the amendments. |
| Story progress bar | The rack is the position indicator. |

---

## What is lost, honestly

The **shared clock**. Everyone used to experience the roll in the same rhythm, and that is part of why a reveal feels like an event; self-pacing trades it for agency and comments. Keeping the per-frame develop beat (see the amendments) is what stops the reveal collapsing into the roll grid, but it does not restore the shared rhythm — nothing does.

The presence line on 3g now carries the communal half on its own, and it is thinner than what it replaces. If the reveal loses weight in testing, that line is where to put it back.

## Open questions for the team

1. Where does `activeRollId` live? `@SceneStorage` survives relaunch but not an account switch; `AccountEpoch` guards exist for this elsewhere.
2. ~~Camera pre-selection~~ — **answered in review: the Camera already accepts a pre-selected roll via a notification.** Reuse that path rather than adding a route.
3. Two or more rolls ready at once: the design stacks Ready bands. Is there a cap before it should collapse to a count?
4. `frameCounts` for every open roll is N count queries on screen load. `RollsView.refreshLiveActivities` already bounds a similar cost with `maxConcurrent` — reuse that bound, or fold the counts into one RPC.
5. The archive grid at two columns of 180pt: confirm against a Pro Max and a mini before committing (the rack derives its capacity from measured width for exactly this reason).
6. `RevealPacing.developDuration` at ~0.8s rather than 1.4s: the shorter beat is a guess, freed up because it no longer shares a slide with a 5s hold. Tune it on device.
7. Does a backward swipe onto an already-developed frame ever re-develop? Specced as no. If the ceremony tests as too thin, re-developing on a *second full pass* is a possible middle ground — but it would make "once, never again" a lie, so decide deliberately.

---

## Assets

- `design/img/*.jpg` — eight frames copied from `pairs/` in this repo (the `_lapse` graded variants), standing in for real roll covers. Not new assets; do not ship them.
- Icons in the prototypes are **Phosphor** glyphs standing in for SF Symbols. Ship SF Symbols:

| Prototype | SF Symbol |
| --- | --- |
| `ph-aperture` | `camera.aperture` |
| `ph-images` | `photo.stack` |
| `ph-film-strip` | `film.stack` |
| `ph-house` | `house` |
| `ph-plus` | `plus` |
| `ph-user-plus` | `person.badge.plus` |
| `ph-bell-slash` | `bell.slash.fill` |
| `ph-sparkle` | `sparkles` |
| `ph-x` | `xmark` |
| `ph-chat-circle` | `bubble.left` |
| `ph-download-simple` | `square.and.arrow.down` |
| `ph-caret-right` | `chevron.right` |

- Fonts: the prototypes use Inter (Nocturne's face). **Ship SF Pro** — the app's own type, via `flimFont`.

## Files

| File | What it is |
| --- | --- |
| `design/Rolls - redesign.dc.html` | The board. Turn 3 (top) is the design to build: screens `3a`–`3h`, the workflow, and the copy inventory. 3f's rack shows the three frame states of the amended reveal (developed behind you, current, wells ahead). Turn 2 (`2a`) is the same direction before refinement, with the reasoning notes. Turn 1 (`1a`, `1b`) are two earlier explorations, kept for context. |
| `design/Rolls - current.dc.html` | Pixel recreation of the Rolls screen as it ships today, built from `RollsView.swift`, `Theme.swift`, `MetaChip.swift`, `RollImminence.swift`, `MainTabView.swift`. Use it as the before-picture. |
| `design/ios-frame.jsx`, `design/support.js` | Prototype scaffolding (device bezel, HTML runtime). Not part of the design. |
| `design/_ds/nocturne-…/styles.css` | The Nocturne token sheet the prototypes were drawn against. Reference only — see the token mapping table. |

### Source files to read before starting

`Flim/Views/Rolls/RollsView.swift` · `Flim/Models/RollImminence.swift` · `Flim/Models/Roll.swift` · `Flim/Views/Theme.swift` · `Flim/Views/Components/FlimFont.swift` · `Flim/Views/Darkroom/DarkroomRackView.swift` · `Flim/Views/Darkroom/DarkroomDayUnit.swift` · `Flim/Views/Rolls/RollDetailView.swift` · `Flim/Views/Rolls/RollRevealView.swift` · `Flim/Views/Rolls/RollRevealViewModel.swift` · `Flim/Models/RevealPacing.swift` · `Flim/Views/Components/PhotoPagerView.swift` · `Flim/Views/Components/ReactionBar.swift` · `Flim/Views/Main/MainTabView.swift` · `Flim/Views/Feed/FeedView.swift` (the `header` property — the convention this design follows) · `Flim/Views/Darkroom/DarkroomView.swift` (`normalHeaderRow`)

The doc comments in these files are unusually load-bearing — several record specific production bugs (cover URLs keyed by id instead of path, counts read from a page length instead of the server, a statically-read accent that never invalidates, `rollFullyPaged` set on a starved drain). Read them before changing the code they sit on.
