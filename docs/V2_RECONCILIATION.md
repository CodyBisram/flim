# FLIM v2: the design package against the app, 2026-09-14

The "Stage 1 design directions" package (Handoff, System, Core Loop, Journeys, State Board,
Stage 3 Application; Stage 1 Directions is historical) read against main at `f13f95b` (the 1.5.3
release candidate, build 378), the September audits, and the owner's standing decisions. This is
the conflict list and the phased plan. Batch 1 is what gets built first; nothing else changes
without the owner's word.

## What the package gets right about the app

Its tokens are mostly the app's own, measured: bg #0A0A0A, surface, sheet #1C1C20 @96%, row
white 6%, divider #242424, text #FFFFFF / #9E9E9E / #8C8C8C, the six accents to the hex, 3:4
everywhere, 44pt targets, `expandTapTarget`, the seen ledger, optimistic reactions with rollback,
the one-shot reveal, the export-follows-ownership rule, `PostEmoji` defaults, the six-slot tray.
It adds five named roles the app states inline today (success, warning, destructive, disabled,
loading), a type-role table with per-style Dynamic Type growth, and a component set. Those are
the foundations, and they conflict with nothing.

## Conflict list

| # | Package says | App today / owner decision | Verdict |
|---|---|---|---|
| 1 | Feed-first launch, "Model A" | Camera-first is the owner's decision; the everyday audit said test it in the study first | **Flag. Not built.** Design batch 3; needs the study and the owner's word |
| 2 | Tab order Feed · Camera · Darkroom · Rolls, tab named "Friends" | Camera · Darkroom · Rolls · Feed, named "Feed" | **Flag. Not built.** Same decision as #1 |
| 3 | Activity unread clears per row, only for rows actually opened | Unread is a watermark: every row older than the last successful open is read (fixed twice this week to stamp the query instant) | **Keep the app** (owner, 2026-09-14). The watermark stays |
| 4 | Onboarding: an explicit Follow step; "See Rae's photos" appears only after Follow | The inviter is followed for you at sign-up (shipped 2026-09-08); the audit said never ask to follow someone already followed | **Keep the app.** Design batch 4 anyway; the package's own no-known-person path is compatible |
| 5 | Camera permission asked on first camera open, returning to the surface that asked | Asked at the end of onboarding, because the camera is the landing tab; there is a re-test checklist for it | **Approved for batch 2** (owner, 2026-09-14): contextual to opening Camera |
| 6 | Sorting vocabulary "Keep private / Post to page / Delete" | "Keep / Post / Delete" with one-line sublabels | **Take, batch 1**, copy below for veto |
| 7 | Labelled React and Comment controls; existing reaction chips capped at two, the rest in the tray | Emoji chips (reacted first, then defaults) in a scrolling row, a + for the picker, and a text line "Add a comment" / "View all N comments" | **Taken in batch 1, UNDER REVIEW.** Cost: a default emoji (❤️ 🔥 😂) becomes React then tap instead of one tap; an existing chip stays one tap. Reversible |
| 8 | Photograph inset 33pt each side (309 / 336 / 364 wide at 375 / 402 / 430), radius 6 | Photograph is width minus 32, radius 12 | **Taken in batch 1, UNDER REVIEW.** The most visible change in the batch; decode budget unaffected |
| 9 | Two frames: "1 of 2" plus dots; the strip from three | Strip from two | **Take, batch 1** |
| 10 | Audience sentence with the follower count: "That's 12 people right now, and anyone who follows you later"; a tagged variant | "People who follow you can see it." (added 2026-09-13) | **Take, batch 1.** Count read on sheet open; the plain line until it lands |
| 11 | Five capture states with honest copy: Not saved yet / Saved on this phone / Uploading / Queued on this phone / Uploaded | "Uploading" or "Saving N" pill, a warning line under it, "N to sort" | **Take, batch 1**, presentation over the state the service already holds |
| 12 | Comments remember their origin, Back pops to it | Comments are a sheet over whatever opened them | Design batch 2; **later** |
| 13 | Compact identity header, "Share profile link", chapters row, chosen chapter cover, empty month card | Cover photo, paper plane, derived cover | **Later** (batch 5); chosen cover needs a column |
| 14 | Durable offline post queue, partial-export retry, settings search, unavailable-target row | Capture retry exists; none of the rest | **Later** (client work, design group B) |
| 15 | Per-person shot counts on a waiting roll | Member names and the time are shown since 2026-09-13; counts before the reveal would leak authorship | **Not without a decision**; the package flags it too |
| 16 | Monetization appendix | Owner: subscription over ads, free/pro tiers are a v2 plan, not now | **Not built**, per the brief |
| 17 | Tab labels drop at AX3+ into a 2x2 grid | Ceiling is AX3, labels kept | **Later**, only when the ceiling rises |
| 18 | Deployment floor iOS 18, Liquid Glass as a finish | Matches | None |

Preserved untouched in every batch, per the brief: authentication, the audience rules (followers
plus tags), photo durability (capture queue, sidecar, renditions), image rendering and quality
(look pipeline, 1400 decode budget, cache contract), notification routing, and the first-sort
Darkroom destination. Demo content, reviewer panels, simulated backends and the Stage 1
explorations stay out of the app.

## Owner decisions, 2026-09-14

- Batch 1 stays out of 1.5.3. 1.5.3 ships from build 378 (`0e7991f`); this branch (`v2`) is the
  next release candidate, version number provisional.
- Activity's unread behaviour is preserved as it is (#3 closed: keep the watermark).
- Feed-first launch and tab order (#1, #2) are evaluated through the usability study.
- Camera permission becomes contextual to opening Camera (#5 approved for batch 2).
- Under explicit review, not settled: the extra tap for a default reaction (#7) and the
  reduced photograph width (#8). Either reverts on the owner's word.
- Before batch 2: the copy table below, old/new feed screenshots, and device checks for
  sorting, capture status, audience wording, the two-frame cue, VoiceOver and the largest
  supported text size.

## Getting batch 1 onto a phone (owner, 2026-09-14)

Main stays at the 1.5.3 candidate; `v2` never moves onto main for testing. Once 1.5.3 is out:

1. On `v2`, set `MARKETING_VERSION` to the provisional next version (1.5.4) on both targets, so
   the archive cannot be mistaken for a 1.5.3 build in App Store Connect. Commit on `v2`.
2. Archive from that pinned commit with the same lane CI uses. Since 2026-09-15 the workflow
   builds pushes to `v2` as well as `main`, in one concurrency group, so a push to `v2` IS the
   archive and two branches can never upload at once. (A hand archive, `git checkout v2 &&
   bundle exec fastlane beta` with the ASC key and match variables, still works.)
3. Record the pair here: `v2 <sha>` = build `<n>`. The device checks run against that pair.

The device checks that gate batch 2, on that build: sorting (the three words, the drag labels,
the posted notice), the capture chip through all five states (shoot; shoot then airplane mode;
shoot then lock the phone), the audience wording with and without a tag, the two-frame cue on a
two-shot day, VoiceOver through the feed card and the sort deck, and the largest supported text
size (AX3) on the feed and the sort deck. Plus the before/after feed image and the copy table
below, reviewed first.

Archive-day rules (the lane's build number is a read, then a build, then an upload minutes
later, so two lanes inside that window read the same number; CI runs the same lane on every push
to main). Verified against fastlane 2.235.0: the lookup passes no version, so it takes the most
recent upload across every marketing version, and the 1.5.4 bump does not narrow it.

- No push to main from the moment the archive starts until App Store Connect shows the build
  uploaded.
- Before starting: `gh run list --workflow ios-testflight.yml --limit 1` shows `completed`.
- From a clean checkout of the exact version-bump commit: `git status` clean, `git rev-parse
  HEAD` equal to the pinned sha, then `bundle exec fastlane beta`.
- The lane prints "Building FLIM build #N" before it archives; N and the sha go in the table
  when the upload finishes, and the App Store Connect build list confirms N appeared once.

| v2 commit | Build | Recorded |
|---|---|---|
| `fce65c0` (1.5.4) | 379 | 2026-09-15, archived by CI from the v2 branch (the workflow builds v2 too now, one concurrency group with main); batch 1; the owner cleared the sort deck, the camera chip and the two-frame cue on it |
| `988f4f4` (1.5.4) | 380 | 2026-09-16, batch 2 (camera permission on first Camera open; thread rows open comments over Activity) |
| `73783a2` (1.5.4) | 381 | 2026-09-16, batch 4a (a cohort-code arrival lands on Find friends); uploading as this was written |

## Phased plan

**Batch 1, foundations and the everyday journey (this batch).** Presentation only. Tokens:
the five named roles, the type roles as `FlimType`, the spacing and radius scales. Components:
`ResponseRow` (React / Comment with their states, two chips), `PositionCue`, `CaptureStatusChip`,
`AudienceLine`, `FlimButton` variants. Applied to one journey: feed frame → react / comment →
camera capture states → sort (new vocabulary) → compose (audience sentence) → posted result.
Validation: 375 and 430 simulators, Dynamic Type through AX3, VoiceOver labels read on the feed
card and the sort deck, look-pin baselines unchanged, full suite green.

**Batch 2, two behaviours (after owner approval of #5 and #12).** Camera permission on first
camera open; comments that pop back to where they were opened from.

**Batch 3, launch (after the study, owner's word on #1 and #2).** Feed-first launch with the
resume rule, the re-ranked tab bar, Activity in the header, one dismissible line on first open.

**Batch 4, getting in.** Destination-preserving invite flow, the no-known-person path, numeric
OTP with autofill. Keeps the inviter auto-follow (#4).

**Batch 5, the rest.** Chapter playback and chosen covers (column + write path), roll polish,
settings and trust screens, the group B client work (#14).

## Batch 1 copy, for veto

| Where | Now | Proposed |
|---|---|---|
| Sort deck, the three actions | Keep · Post · Delete | Keep private · Post to page · Delete |
| Sort deck, the line under the actions | (sublabels per action) | Keeping a photo puts it in your Darkroom, where only you can see it. Posting shows it to the people who follow you. |
| Feed card, response controls | (emoji chips) + "Add a comment" / "View all N comments" | React · Comment (or "Comment · N") |
| Feed card, failed reaction | (silent rollback) | That reaction didn't save. Retry |
| Feed card, two frames | (strip) | 1 of 2 |
| Share sheet, audience | People who follow you can see it. | Your followers can see this. That's N people right now, and anyone who follows you later. |
| Share sheet, audience with a tag | (same) | Your followers, and Rae. You tagged Rae, so she can see this photo whether or not she follows you. |
| Camera, capture chip | Uploading / Saving N | Not saved yet · Saved on this phone · Uploading · Queued on this phone · Uploaded |
| Posted notice | Posted to your page · View | Posted to your page. Your followers can see it. · View |
