# Pending

The consolidated list of what is queued, blocked, or waiting on the owner. Created 2026-08-27,
because the only list that existed was `docs/BACKLOG.md`, which is narrower than it looks: that
file is the `/backlog-burn` ledger for mechanical cleanup only (tests for untested pure logic,
doc drift, provably dead code). Product work, gates and owner steps had no home. This is it.

Statuses: `queued`, `blocked: <what on>`, `owner`, `decided: <what>`.

## 1.5.1, ranked

Written 2026-08-30, with 1.5.0 (build 327) submitted and in review. Review cleared 2026-09-01.

### 1. The look: flash falloff, then grain

**Grain REVERTED 2026-09-03.** The owner saw the shadow-peaked grain on device and did not want
it ("I don't like the new train, let's revert"). `FilmStock.original` ships `.midtone` again and
the composite default is back to `.sourceOver`; the rendered look is byte-identical to 1.5.0
(the 58c674f look-pin baselines pass unchanged, production renders match the 1.5.0 files by md5).
`GrainProfile.pushed`, the sweep, the probes and the `shadowRamp` fixture stay in the code,
dormant, with the measurements in their comments. Flash falloff (dec7b57) stays shipped. Do not
re-propose shadow grain without a new owner ask; if it ever comes back, the double-linearised
mask and the composite veil are the two facts to start from.


**Flash falloff SHIPPED 2026-08-31** (`dec7b57`). It was the single largest gap between FLIM and
an actual disposable, and was absent rather than mistuned: flash frames had 0.00% of pixels below
0.04 where a real disposable has 15 to 35%. Blur luminance to a coarse illumination map, apply a
downward gamma keyed off it, gated on the EXIF flash-fired bit so it does not crush ambient night
scenes.

**Grain is BUILT, 2026-09-01, sitting in the working tree, pending owner sign-off on the
previews.**

- `GrainProfile` (`FilmStock.swift`): the shipped stock uses `.pushed` (shadow-peaked anchors
  written in coverage, chroma 0.25, evPush 0.35); the old profile is kept as `.midtone`.
  `flim.cube` is untouched. `grain` amplitude stays 0.06.
- `GrainComposite`'s default flipped from `.sourceOver` to `.meanPreserving` on all five
  signatures. This was the change parked on 2026-08-17 for the seam reason that flash falloff has
  since made moot.
- The measurement that reframed the work: the tone mask was linearised twice between
  `CIToneCurve` and `CIBlendWithMask`, so the shipped curve asked for 0.30 shadow coverage and
  landed 0.0054. Half of "no grain in shadows" was a unit error. Anchors are now written in
  coverage, and a test holds the code to the rendered mask.
- Two hypotheses the measurement contradicted: chroma grain does NOT recover saturation (moves
  the gap by less than 0.0005); removing the white veil (the mean-preserving composite) is what
  did (median saturation gap -0.086 to -0.032). Shadow-peaked grain on the old source-over
  composite is impossible (saturation gap -0.212, p5 0.153 on parkview-noflash), so the composite
  flip was forced, not chosen. evPush is bounded, not fitted: the calibration set has no exposure
  spread.
- Results, median over 12 in-sample pairs: shadow texture ratio to Lapse 0.37 to 1.04; whole-frame
  localContrast ratio 0.67 to 1.01; saturation gap -0.086 to -0.032; mean gap -0.023 to -0.043
  (every frame about 0.02 darker, the veil was hiding a LUT-side tone gap, which belongs to
  colour, and colour stays closed). Hold-out hallway-flash shadow ratio 0.14 to 0.86.
- Costs: feed card bytes median +5.7%, worst +44% on dark scenes; flash night masters can nearly
  double. Four scenes now slightly overshoot Lapse saturation (worst wide-dim +0.070).
- Look pin re-recorded, new `shadowRamp` synthetic fixture. Full suite green except the two
  pre-existing EmojiCatalogTests Flags failures.
- Owner feel-test shots: a flat bright wall or sky (midtone grain is deliberately about 5x lower,
  risk of reading digitally smooth, the dial is the 0.40 anchor's coverage), a black object in a
  lit room, a flash shot in a dark room, a night street with point lights, and an old photo beside
  a new one in the feed.
- Previews: `pairs/_grain_preview/` (gitignored), `{wide-lit, restaurant-a, parkview-flash,
  hallway-flash, steering, plush}_before.jpg`, `_after.jpg`, `_crop-darkest-1to1.png`.
- Revert: `grainProfile: .pushed` to `.midtone` in `FilmStock.original`, plus
  `GrainComposite = .meanPreserving` back to `.sourceOver` on the five processor signatures, then
  re-record the pin.
- Status: `owner` (look at the previews, approve or name a dial).

Neither needed a LUT refit, which matters: a refit has already been MEASURED as a regression.

DO NOT open colour. Warmth, greens and the black floor all need the cube, and the cube was fitted
to match Lapse rather than film. Changing the target is a calibration shoot, not a task.

### 2. Ask the 26 people who were never asked about notifications

51 accounts, 26 hold no device token and were NEVER PROMPTED. Only 2 have actually declined. The
product's own design note says no notification means no reveal, so half the userbase structurally
cannot be pulled back for the thing the app is built around. This is pure absence rather than a
preference to respect, which makes it the highest-leverage and lowest-risk retention work
available. Re-read [[flim-onboarding-camera-permission]]'s checklist before touching the primer.

### 3. Screenshots

Owner deferred these from 1.5 deliberately. They show a square-grid Darkroom, a Rolls screen that
no longer exists, and a reveal with a progress bar; the invite screenshot misdescribes a mechanic
that is now finite. Reshoot AFTER the look work, or they get shot twice.

The look work they were waiting on is now built (grain, see item 1) and waiting on owner
sign-off, not on more engineering. Screenshots can follow that sign-off.

### 4. Finish the on-device caching (DONE 2026-09-01)

`RollSnapshotStore` persists `rolls` and `coverPaths` as one JSON file per account, under
Application Support at `RollSnapshots/<uid>.json`. `RollService.restore(for:)` loads
synchronously, keyed on the explicit uid, and is a no-op once memory already holds anything;
`ContentView` calls it right after `resetForAccountChange()` on account change, and
`fetchRolls(for:)` calls it before its first `await`. Every mutation (fetch, create, join,
rename, `setRollCover`, forget) rewrites the file under the epoch guard.

Tests: `RollSnapshotStoreTests` and `RollServiceSnapshotTests` (cross-account isolation,
stale-epoch write cannot overwrite the current account's state).

Known gap, mirrors `FailedUploadStore`/`FeedSeenStore`: no purge on sign-out or delete-account;
`RollSnapshotStore.delete(for:)` exists and is unwired.

Not verified: on-device first-frame timing. Needs an airplane-mode relaunch on a device.

### 5. Hygiene, cheap and worth doing together

- `invite_sent`: the deletion above is REVERSED, do not delete it. The 2026-08-29 note said "never
  wired on the client"; that was wrong. It has fired from the two roll share sheets' `onComplete`
  since 2026-08-08 (`03cfcee`), and 2026-08-31 (`f7ec75b`) deliberately added three tap-fired sites
  (reveal, profile invite sheet, feed empty state) alongside per-surface `usage_events`;
  `2026-08-31_invite_source_events.sql` documents that `invite_sent` "still fires the once-ever
  funnel milestone", and `docs/METRICS.md`'s invite funnel reads it as the sent step. Production
  still holds zero rows as of 2026-09-01, which is consistent: the tap-fired sites are post-1.5.0
  and unshipped, and the older share-sheet `onComplete` path evidently never fires (`ShareLink`
  reports no completion). Expect rows once 1.5.1 ships; if none arrive, that is the bug to chase,
  not the event. Status: `decided: keep`.
- The three owner-by-email sites: DONE as a migration, NOT YET DEPLOYED.
  `supabase/migrations/2026-09-01_pin_owner_identity_everywhere.sql` adds `public.owner_user_id()`
  (the single pinned UUID), rewrites both `is_owner` variants and `auto_follow_owner()` to read
  from it, and `send-social-push` / `send-daily-digest` now call it by RPC with a fail-closed
  fallback, cached per invocation. Verified in a throwaway Postgres container: applies twice
  cleanly, grants correct (authenticated + service_role, not anon), the auto-follow trigger behaves
  identically in all three cases, `deno check` passes on both functions. Owner step: apply the
  migration FIRST, then `supabase functions deploy send-social-push --no-verify-jwt` and the same
  for `send-daily-digest`. Deploying functions first only degrades (no owner push tokens, covered-
  post exemption fails closed) rather than errors. Applied to production and both functions deployed 2026-09-02 (verified:
  `owner_user_id()` returns the pinned id, the trigger no longer reads email). Status: `done`.
- `CachedImage.load()` staleness guard: DONE. A `loadGeneration` counter bumped at the top of
  `load()`; each of the three post-await writes checks its captured generation before touching
  state. No testable seam, so no test.
- `FilmStripGrid` row keys: DONE. `FilmStripLayout.rowKey(for:offset:)` keys rows on the first
  item's id with a non-colliding empty-row fallback; tests in `FilmStripLayoutTests` include the
  deletion scenario.
- `RollCarouselView` deletion: unchanged, still an owner call.

### 6. Now queued: 1.5 review cleared 2026-09-01

Both items below were only gated on 1.5 App Review, which cleared 2026-09-01. Both are now built.

- `public.profiles` / `security_invoker`: DONE and APPLIED to production 2026-09-02 (verified:
  `security_invoker=on`, anon has no grant on the view, the widened column grant is live).
  `supabase/migrations/2026-09-02_profiles_security_invoker.sql` grants `hidden_from_discovery`
  to `authenticated` (the view exposes it and the column grant did not; flipping without this
  breaks every profile read for everyone), sets `security_invoker = on`, and revokes `anon`
  SELECT on the view. Anon losing profiles is by design: the site only calls RPCs, no SQL
  function reads `profiles`, and every app read is in FeedService/RollService under a session.
  The API log endpoint on this plan returns too few rows to prove it from traffic; the code audit
  is the evidence. Verified in a local Supabase stack: authenticated reads another user's row
  with all eight columns, `email`/`invite_code` stay denied, anon is denied, UPDATE/DELETE
  through the view stay denied, applies twice cleanly. Independent of the 2026-09-01
  owner-identity migration. No Swift change. Status: `done`.
- `schema.sql` never folded in `2026-08-17_profile_identity.sql`: no `signup_ordinal` column,
  trigger, or grant exists in schema.sql, though production has all three. A from-scratch
  environment built from schema.sql alone lacks the column. Found 2026-09-02 while mirroring the
  profiles change (adding `signup_ordinal` to the mirrored grant broke a fresh load). Fold it in
  as its own change. Status: `queued`.
- Roll rename: the FEATURE IS REMOVED (owner decision 2026-09-02, "I don't want the feature to
  rename a roll at all"). The menu item, alert, `RollService.renameRoll`, and the Live Activity
  end-and-rerequest helper built for it the day before are gone; `setRollCover` keeps its widget
  refresh. The `rolls: creator can update` policy stays because cover selection uses it. Do not
  re-propose renaming.

### The strategic one, not a task

Rolls hold 291 of 1,627 photos. Four in five shots never touch one, and rolls are positioned as the
differentiator. Either the shared path becomes the default or the strategy follows what people
actually do. Worth deciding before more is built on top of rolls.

## Next up

### done 2026-09-02: "still-no-shot" push sent to 7

Second touch to everyone reachable who has never taken a photograph (six of them had the straight
"Take a shot." on 2026-08-19). Copy chosen by the owner from four drafts: "We checked." / "Not a
single shot. The camera is right there, and the first one can be of literally anything." Lands on
the camera. Delivered to arielkarina, branb, hoodsplice, ksultan15, liza, madison, nibs; the other
eight never-shot accounts hold no device token and cannot be reached.

Found and fixed on the way: `send-one-shot-push` derived "has shot" by fetching photo rows, and
PostgREST caps a select at 1000. With `photos` at 1808 rows the dry run named 13 people, six of
whom had shot. Both cohorts now count per person with exact HEAD counts. The August send predates
the cap and was correct. Any edge function that fetches rows from `photos` to derive a fact about
users has this bug; `send-social-push` and `send-daily-digest` were not audited for it.

### done 2026-09-03: the push functions survive table growth, and one-shot sends need a secret

`send-one-shot-push` now requires an `x-one-shot-secret` header matching the `ONE_SHOT_PUSH_SECRET`
project secret (constant-time compare, 503 if the secret is unset, 401 on mismatch). Set and
deployed 2026-09-03; the value lives in the owner's home directory, never in the repo, and
`supabase secrets set` issues a new one any time. Invocation is now
`curl -H "x-one-shot-secret: <secret>" "<fn url>?campaign=<name>[&user=<uuid>][&send=true]"`.

The 1000-row audit across `send-social-push`, `send-daily-digest`, `send-develop-push`: four
whole-table fetches with no bound at all (`covered_post_windows` twice, `device_tokens`,
`digest_state`, `blocks` twice) now page through `fetchAllPages`. Everything else is bounded by
an unsent backlog or a per-post/per-roll scope; the nearest real limits are the digest's 48h
`posts` window (breaks past 1000 posts platform-wide in 48h) and its `follows` fan-out (breaks
when the posters in a window share more than 1000 followers). All four functions redeployed.

`schema.sql` now carries `signup_ordinal` (column, backfill, unique index, both triggers, the
view column, the grant), verified by a fresh load in a local stack. Found while doing it: the
BADGE SYSTEM (`profile_badges`, `profile_film_stats`, and roughly ten follow-on badge migrations
from 2026-08-17/18) is entirely absent from `schema.sql` too. Live and called by the app, so a
fresh environment lacks it outright. FOLDED 2026-09-03: all twelve badge functions, `earned_badges`,
`users.displayed_badges`, `photos_roll_user_idx`, and `usage_events` + `log_usage_event()` (also
missing, and the `regular` badge reads it). Every function body, constraint, index and grant
verified byte-identical to production after stripping comments; fresh load twice, clean. Status:
`done`.

The one-shot campaign `islands` now routes to the Rolls tab (`{"t": "rolls"}`, a push
destination added to the app 2026-09-03; older builds open the app as before).

### resolved 2026-08-29 — there is no 20-uploads-per-day cap

A UX pass asked what a person sees when they hit it. Answer: nothing, because it does not exist.
Searched the camera, PhotoService, every storage migration and the Cloudflare worker: no counter,
no RPC, no RLS check, no client message. The only traces are two comments in already-applied
migrations (`2026-08-17_usage_events.sql:88`, `2026-08-17_profile_identity.sql:275`) that refer to
it as real. Those migrations are history and were left untouched; this note is the correction.

Owner confirmed 2026-08-29 he never approved it. Nothing to remove in code. The memory files that
asserted it, including the badge rule that cited it as a design constraint, are corrected.


### done: the privilege escalation fix is APPLIED (verified against production 2026-09-01)

`supabase/migrations/2026-08-29_close_users_privilege_escalation.sql`. Confirmed live by querying
the database: `lock_users_privileged_columns_trigger` exists, `is_owner()` no longer mentions
`email`, and `authenticated` holds UPDATE on exactly `avatar_path, bio, cover_path, display_name,
username` with no table-wide grant. The hole is closed.

Found 2026-08-29 by a security pass, then confirmed directly against the live database:
`authenticated` held TABLE-WIDE UPDATE on `public.users` (every column: `email`, `id`,
`invite_code`, `invite_uses_remaining`, `signup_ordinal`), the RLS policy is row-level so it
permits writing any column of your OWN row, and `is_owner()` resolved the entire admin surface by
matching `users.email`. So any signed-in user could PATCH their own email to the owner's and gain
`approve_invite_request()` (insert any address into `allowed_emails`, a total bypass of the
invite-only gate), every requester's raw email, and the moderation queue.

Three layers: column-scoped grants replacing the table-wide ones; `is_owner()` re-pointed at the
owner's immutable UUID; and a BEFORE UPDATE trigger pinning `id`/`email`/`invite_code`/
`invite_uses_remaining` as defence in depth against a future GRANT mistake.

Verified in a throwaway Postgres container: the exploit reproduces before and fails after, a
simulated future grant-mistake is still blocked by the trigger alone, and signup INSERT plus
profile UPDATE still work. Verified against production: the pinned UUID is cody / ordinal 1, and
`redeem_invite` / `credit_invite_earnback` / `delete_account` are all postgres-owned SECURITY
DEFINER, which is what makes the trigger's `current_user` exemption correct.

Still owed, on device rather than in SQL: signup still works, profile edit still works, invite
redemption still decrements. One TestFlight check each.

### follow-up: other places that resolve "the owner" by email

Superseded, see item 5 in "1.5.1, ranked" above: done as a migration, not yet deployed.

### follow-up: `invite_sent` analytics event is dead

Superseded, see item 5 in "1.5.1, ranked" above: the event is not dead, keep it.


### done 2026-08-29 — invites, the real mechanic (design overhaul 3c)

SHIPPED and APPLIED. All three migrations are live in production and verified against the
database, not just assumed:

- `2026-08-29_invite_quota.sql` — allowance of 3, defaults, non-negative CHECK, `redeem_invite`
  decrements. Verified: 50 accounts at 3, one NULL. **`signup_ordinal = 1` keeps NULL, meaning
  unlimited**, a deliberate seeding exception: that account had sent 26 of the app's 44 redeemed
  invites and capping it at 3 would have throttled the main distribution channel.
- `2026-08-29_invite_earnback.sql` — `invite_earnbacks` ledger + `AFTER INSERT` trigger on
  `photos`. Inviter gets one back when their invitee takes a FIRST PHOTO. Inviter only, not both
  (the design said both; every new user already starts with 3 unspent, so crediting the invitee
  mints a net new invite from nothing).
- `2026-08-29_invite_earnback_reset.sql` — the backfill ran and was then REVERSED, owner chose to
  start clean. **The ledger rows were KEPT on purpose**: deleting them would re-credit those 29
  invitees on their next photo, which is the same retroactive payout arriving later and at random.
- `2026-08-29_get_own_invites_sent.sql` — the invite screen's history, `authenticated` only,
  never returns an email.

Swift: `AuthService.ownInviteQuota()` / `ownInvitesSent()`, both FAIL SOFT, so client and server
can deploy in either order. `InviteSheet` is its own file now.

**Copy rules are enforced by `InviteCopyTests`, not remembered.** Nothing says "roll" (Rolls ship
their own Share invite meaning invite someone INTO a roll), and the earn-back line must describe
inviter-only-on-first-photo rather than the design's "you both get one back".

Measured while building: 67% of invited accounts (29 of 43) have taken at least one photo, which
is what makes earn-back worth having.

NOT DONE: the invitee half of earn-back (one UPDATE if ever wanted).

### backlogged: Chapters (design overhaul 3a shelf + 3b recap)

Month covers on the profile and the monthly recap. Owner backlogged it on 2026-08-29 to get the
header landed. It is the only part of the overhaul needing new data (month rollups).

### resolved 2026-09-02: roll renaming is removed as a feature

See item 6 above. The staleness bug it carried is moot.

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

### done 2026-09-03: the feed redesign is live and digest windowing shipped

Owner gate set 2026-08-24, on two changes before the feed redesign left TestFlight. 1.5.0
shipped to the App Store WITH the feed redesign, so the gate as originally written has been
crossed. Status of the two items:

1. **Seen-store migration, one shot: SHIPPED 2026-08-31** (`81d7c9c`, "Seed the feed backlog as
   seen", and `e95e7ad`, "The feed seed leaves two days unseen, and spares the four who want
   everything"). Seeded as seen everything posted before the device's `lastActivitySeen`, falling
   back to "everything before the most recent 04:00" when absent, skipping any device that
   already held marks.
2. **Digest windowing: SHIPPED and DEPLOYED 2026-09-03.** Each recipient's window start is now
   `max(last digest, that user's client_versions.updated_at)`, so the push counts only what
   arrived since they last launched, and a zero count suppresses without advancing digest state
   (the file's existing invariant for "nothing to send"). Users with no `client_versions` row
   (5 of 29 eligible at deploy time) keep the old window. `?dry=true` logs per-recipient window
   and outcome without sending or writing. Checked against production before deploy: three
   recipients (trina, cody, stephenxnyc) who had opened the app after the posts landed would
   have been pushed about content they had already seen; all three now suppress. Seen state
   stays device-local; that is a published privacy stance, not a preference.

### done: version decision

`MARKETING_VERSION` is `1.5.1` on both targets in `project.yml` (lines 74 and 147). 1.5.0
(build 327) was released to the App Store and its train closed (`f8d1dd8`, "1.5.1 opens").
The bump this section used to ask for has already happened. Status: `done`.

## Owner actions

- **owner** — Device-test the rolls redesign (batches 1 and 2, `06b08ea` through `51dcae5`).
  Not reachable in the simulator: the develop beat animating, the 3g summary card, and the
  completion-flag behaviour, all of which need taps. 1.5.0 shipped this work to the App Store;
  strike this entry if it has already been seen on a release build.
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
- The new left-aligned profile header (build 320): two badges, inline stats, and the badge
  explanation now swapping the STATS row rather than the handle line.
- The film-strip rows on the profile and roll grids (build 319): the perforated road between rows
  has never been seen on device on either surface.
- Three-across Darkroom sharpness (build 317): the decode now derives from the frame height, and
  whether that actually reads sharp is the part tests cannot answer.
- `skipDeadFrame`'s correction (build 319) needs a real mid-reveal image failure on a frame BEHIND
  the reader to confirm the pager no longer retargets. Tests cover the arithmetic, not the wiring.

## 1.5, wanted but unbuilt

- **Chapters: BUILT 2026-09-03 on branch `chapters`, not merged, not pushed.** Owner decisions
  that day: months are LIVE AND GROWING (the current month plays now and grows as shots arrive,
  not gated on the month ending); every month back to a person's first shot appears; everyone
  who already exists gets a shelf. Because months are computed from `photos`, the backfill is
  free: no data migration. Defaults set without an owner answer, change on his word: a month is
  everything you shot including roll shots on your own page and only what you posted on someone
  else's (the server enforces the profile grid's exact visibility); the recap picks fifteen on
  device with Vision (aesthetics, faces, feature-print diversity, first and last shot always
  kept), no manual swapping yet.
  - Data: `profile_chapters(p_profile_id)` and `chapter_photos(p_profile_id, p_month_start)` in
    `2026-09-03_chapters.sql`, folded into schema.sql, container-verified for every visibility
    case and cross-checked against production counts. NOT YET APPLIED to production (the write
    was blocked from the session; owner applies, or retry). Apply BEFORE any build with the shelf
    reaches a device; until then the shelf fails soft and simply does not render.
  - App: `ChapterService`, `ChapterShelfView` (3a, between the profile actions and the grid),
    `ChapterRecapView` (3b opening card plus native-paging playback reusing the reveal's beat),
    `ChapterCurator` (pure selection, tested) and `ChapterCuration` (the Vision actor).
    `-chaptersPreviewDemo` is an offline simulator harness; `-seedChapters` seeds a signed-in
    account. Twenty-three new tests. Full suite green on the branch bar the two known emoji
    failures; Release builds.
  - Two product calls the data side flagged: the month boundary is the Darkroom's 04:00 shift
    fixed at UTC (the app has no per-user timezone), so a shot near local midnight at a month edge
    can land in a different month than the Darkroom shows; and unsorted developed personal shots
    count toward a month immediately. Both documented in the SQL; either is a small follow-up.
  - Deferred: "Share as a contact sheet" is a wired stub with an inline "coming soon" (needs a
    month layout on top of BrandedExport); manual pick swapping; device pass for Dynamic Type,
    VoiceOver and real-photo curation quality (Vision behaves differently in the simulator).
  - This is 1.6-sized. Merging it into main means deciding the version first.
- **Look colour pass**: see `flim-look-gap-vs-lapse`. Decide the two-looks-in-the-feed question
  before the first parameter moves. Grain was tried and reverted 2026-09-03 (see item 1 at the
  top of this file). The two-looks question has been answered by events: flash falloff shipped
  in 1.5.1, so the seam exists regardless.
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
