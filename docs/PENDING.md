# Pending

The consolidated list of what is queued, blocked, or waiting on the owner. Created 2026-08-27,
because the only list that existed was `docs/BACKLOG.md`, which is narrower than it looks: that
file is the `/backlog-burn` ledger for mechanical cleanup only (tests for untested pure logic,
doc drift, provably dead code). Product work, gates and owner steps had no home. This is it.

Statuses: `queued`, `blocked: <what on>`, `owner`, `decided: <what>`.

## Next up

### done 2026-08-27 — Share export redesign

Built from the handoff bundle (`~/Downloads/Rolls screen redesign.zip`, which despite the name
contains only `design_handoff_share_export/`). Parts 1 through 4 all landed, including the
metadata plumbing the handoff said could wait.

- Project: https://claude.ai/design/p/489eee60-b5ed-4ef9-b79a-39e722480070 (named "Rolls screen
  redesign"; the share export is a file inside it)
- **How to read a design project from here:** `DesignSync` with `method: get_file` and an
  explicit `projectId` works on a REGULAR design project. Only `list_projects` is filtered to
  design-system projects, which is what made it look unreachable. No `/design-login` was needed.

Follow-up, explicitly out of scope in the handoff and not designed yet: **the roll contact
sheet.** `Save all` on a roll dumps N loose JPEGs into the share sheet, which forgets the one
idea the app is built on. The roll's frames on one print, roll name and date across the bottom.

### queued: the share button removal (blocked on a decision)

Owner asked for the Darkroom/grid pager's share button to be removed and a "Save to camera roll"
item added to its three-dots menu, deferring real sharing (Instagram, Snapchat, Messages) until
later. Two things surfaced and it was parked:

1. The feed's existing "Save to Camera Roll" does NOT save; it opens `SharePreviewSheet`. So
   mirroring it into the pager would swap a share button for a differently-labelled share button.
   A real one-tap save is available: `CameraRollAutoSave` already writes master bytes via
   `PHPhotoLibrary` and the add-only permission shipped.
2. Removing the share button orphans `SharePreviewSheet` entirely, and that sheet is now the
   whole share export redesign. Undecided: park the print, keep it reachable from the menu, or
   change the pager only.

Read `flim-photo-export-isolation` before touching the export path: every export needs its own
directory, and a shared one could share one roll's photos as another's.

## Blocking a production ship

### done 2026-08-28 — the ephemeral feed is gone

The 04:00 clearing rule was removed. It could not survive per-author grouping: marks are made
one shot at a time as the pager lands on each, while clearing demanded a mark on EVERY shot in
a unit, so a ten-shot day needed ten separate scroll-pasts to retire. Single-shot days vanished
on schedule and multi-shot days accumulated for the full window, which is why the feed read as
empty one morning and endless the next afternoon. The two spec rules behind it contradict each
other under grouping ("nothing unseen expires" against "seen units clear at the next boundary");
a day that is one-tenth read is neither.

The feed now shows what the fetch returned, bounded only by `FeedUnit.retentionWindow` (7 days,
kept deliberately: this app posts on a delay, so a short window drops shots that have only just
become visible). Seen state drives the pill, the ledger, the caught-up seam and where a unit
opens, and nothing else. Any future seen-state bug is now a wrong pill, not a feed that empties
or never ends.

### blocked: feed redesign is TestFlight-only until two changes land

Owner gate set 2026-08-24. Neither is built. Do not push the feed to production without both.

1. **Seen-store migration**, one shot: seed as seen everything posted before the device's
   `lastActivitySeen`, falling back to "everything before the most recent 04:00" when absent.
   Skip any device that already holds marks (testers). Fresh installs keep the everything-unseen
   rule. Without it, existing users open into a week of lit pills. (Reworded 2026-08-28: the
   original said "dated so seeded days clear immediately", which no longer means anything now
   that nothing clears. The migration is still wanted, for the pills and the ledger.)
2. **Digest windowing**: clamp each recipient's window with
   `max(last_digest, client_versions.updated_at)` in `send-daily-digest`'s per-user loop, so the
   10:00 push counts what arrived since they last launched, and suppresses at zero. The digest
   is server-computed and knows nothing about device-local seen state, so today it over-promises
   against an app that opens showing only what is truly unseen. Seen state must NOT go
   server-side; that is a published privacy stance, not a preference.

Both are implement-at-production-push-time. Do not build early.

### owner: version decision

`MARKETING_VERSION` is still 1.4.3 in `project.yml` (both targets, lines ~74 and ~147). The
1.4.3 train has since absorbed the entire feed redesign, the rolls redesign and the
confirmations redesign, which is 1.5-sized content on what was opened as a polish train.
Bumping means editing both targets. Releasing a version closes its train immediately, so the
first push after any App Store release must carry the bump or it is rejected with
"Invalid Pre-Release Train".

## Owner actions

- **owner** — Device-test the rolls redesign (batches 1 and 2, `06b08ea` through `51dcae5`).
  Not reachable in the simulator: the develop beat animating, the 3g summary card, and the
  completion-flag behaviour, all of which need taps.
- **owner** — `mark_developed_photos` cron cadence is untracked in the repo. Read it off
  Dashboard → Database → Cron Jobs and record it in the next cron-touching migration.
- **owner** — Seamlessness wave device checks: darkroom scroll with many nights plus delete/undo
  and a 60s poll landing mid-session (highest blast radius, static-traced only); feed scroll;
  pinch a full-screen photo on a 3x device to confirm 1400 still reads sharp, since several
  surfaces came down from 1600.
- **owner** — Site analytics on flim-app.com is live but collects nothing until three owner
  steps are done.

## Waiting on device, from work already shipped

- First 04:00 boundary after real reads: retention's first live test.
- Two-shot leader-film strip verdict.
- Colophon in the Profile footer.
- Confirmations: undo capsule and consequence sheets on a real TestFlight pass.
- Photos-permission explainer row under the toggle needs the on-device permission-timing pass.

## 1.5, wanted but unbuilt

- **Chapters**: monthly recaps, playable like a reveal. Confirmed want.
- **Look colour pass**: see `flim-look-gap-vs-lapse`. Decide the two-looks-in-the-feed question
  before the first parameter moves.
- **decided: no** — Home merge (Feed + Activity). In the audit's plan, owner is UNSURE, do not
  build without an explicit yes.
- **Naming**: shots / frames / flims / instances. Copy says "shot" as a placeholder. The grouped
  card needing a word for "12 of these" is the natural moment to decide.

## Parked on purpose

Re-proposing one of these without new information wastes a cycle. Reasons live in
`flim-deferred-work` and `flim-15-direction`.

- R2 migration: shelved behind the weekly tripwire, which has not fired.
- Save-all bounded parallelism: needs a measurement on a real large roll.
- Swift 6 language mode: 23 strict-concurrency warnings, counted by CI so they cannot grow quietly.
- Home-screen widget.
- Contact-sheet roll rows, and a contact-sheet restyle of the Darkroom grid.
- Inline-editable roll title: shipped, then reverted at the owner's request. Do not re-propose.
- The account-delete page's "save all N photos first" offer: needs a full-library export path
  that does not exist.
