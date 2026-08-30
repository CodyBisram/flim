# Pending

The consolidated list of what is queued, blocked, or waiting on the owner. Created 2026-08-27,
because the only list that existed was `docs/BACKLOG.md`, which is narrower than it looks: that
file is the `/backlog-burn` ledger for mechanical cleanup only (tests for untested pure logic,
doc drift, provably dead code). Product work, gates and owner steps had no home. This is it.

Statuses: `queued`, `blocked: <what on>`, `owner`, `decided: <what>`.

## 1.5.1, ranked

Written 2026-08-30, with 1.5.0 (build 327) submitted and in review.

### 1. The look: flash falloff, then grain

**The argument for doing this FIRST inverted when 1.5 shipped.** It used to be "land it before
1.5 or the feed carries two looks permanently". That gate is closed, so the seam is now certain
wherever the change lands, and every day 1.5 is live adds photographs to the old side of it.
Do it early in 1.5.1 to keep the seam as small as it can still be.

- **Flash falloff** is the single largest gap between FLIM and an actual disposable, and it is
  absent rather than mistuned: flash frames have 0.00% of pixels below 0.04 where a real disposable
  has 15 to 35%. Simulable from a single capture because the falloff physically happened and the
  ISP tone-mapped it away; blur luminance to a coarse illumination map, apply a downward gamma
  keyed off it, GATE ON THE EXIF FLASH-FIRED BIT or it crushes ambient night scenes. ~1 day.
- **Grain** is the inverse of pushed 400/800 on all three axes: monochrome where it should be
  chroma, midtone-peaked where it should be shadow-peaked, fixed where it should scale with
  exposure. ~1 day. Where it sits in the pipeline is right and hard-won; only the mask, saturation
  and amount are wrong.

Neither needs a LUT refit, which matters: a refit has already been MEASURED as a regression.
Both trip the look-regression pin, so it needs re-recording, and flash needs a NEW synthetic
fixture or it is pinned by exactly one photograph.

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

### 4. Finish the on-device caching

The tile and avatar gating is fixed. What remains: persist `RollService.coverPaths` per account so
the first frame can attempt a disk-cache hit before any network call returns. MUST be scoped to the
signed-in user and dropped in `resetForAccountChange()`, or one account's cover leaks into
another's tile.

### 5. Hygiene, cheap and worth doing together

- Delete the `invite_sent` analytics event. Zero rows ever against 44 real invites; ground truth is
  `allowed_emails.note`. Deleting removes a trap, wiring it creates a second source that can
  disagree.
- The three owner-by-email sites (two edge functions, the auto-follow trigger). Nothing exploitable,
  but three copies of an assumption already disproven is how it comes back.
- `CachedImage.load()` needs a staleness guard on its three terminal writes; its decode runs in a
  detached task outside the cancelled tree, so a stale result can overwrite a fresh one. Cosmetic.
- `FilmStripGrid` keys rows by array position; deleting a photo mid-roll rebuilds later cells.
  Key on `row.first?.id`. Cosmetic.
- `RollCarouselView` is 331 lines with no entry point. Delete pending an owner call.

### 6. After review clears, not before

- `public.profiles` / `security_invoker`. The precondition changed without anyone noticing:
  `authenticated` now HAS column-scoped SELECT on `users` (schema.sql:1406), so the only remaining
  blocker is `anon`, which reads profiles but has no SELECT on users. No app caller appears to read
  profiles without a session, but confirm against API logs before revoking, then flip. See
  [[flim-profiles-view-security]], which is stale on exactly this point.
- Roll rename leaves the widget and Live Activity stale. `renameRoll`/`setRollCover` never call
  `WidgetSync.refresh()`, and `rollName` is baked into immutable Live Activity attributes so the
  only fix is ending and re-requesting the activity.

### The strategic one, not a task

Rolls hold 291 of 1,627 photos. Four in five shots never touch one, and rolls are positioned as the
differentiator. Either the shared path becomes the default or the strategy follows what people
actually do. Worth deciding before more is built on top of rolls.

## Next up

### resolved 2026-08-29 — there is no 20-uploads-per-day cap

A UX pass asked what a person sees when they hit it. Answer: nothing, because it does not exist.
Searched the camera, PhotoService, every storage migration and the Cloudflare worker: no counter,
no RPC, no RLS check, no client message. The only traces are two comments in already-applied
migrations (`2026-08-17_usage_events.sql:88`, `2026-08-17_profile_identity.sql:275`) that refer to
it as real. Those migrations are history and were left untouched; this note is the correction.

Owner confirmed 2026-08-29 he never approved it. Nothing to remove in code. The memory files that
asserted it, including the badge rule that cited it as a design constraint, are corrected.


### owner: APPLY THE PRIVILEGE ESCALATION FIX

`supabase/migrations/2026-08-29_close_users_privilege_escalation.sql`. Live and exploitable
against production until it is run. Does not depend on any app release.

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

AFTER APPLYING, re-verify: signup still works, profile edit still works, invite redemption still
decrements.

### follow-up: other places that resolve "the owner" by email

Same false assumption the fix above disproved, but none of these grant privilege, so they were
left out of the urgent fix: `supabase/functions/send-social-push/index.ts`,
`send-daily-digest/index.ts`, and the auto-follow-owner trigger in `schema.sql` all compare
`lower(email)`. Worst case is a wrong push recipient or a wrong auto-follow, not escalation.

### follow-up: `invite_sent` analytics event is dead

Zero rows ever, despite 6 people sending 44 real invites. Never wired on the client. Wire it or
delete it before any dashboard comes to depend on it reading zero.


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

### queued: renaming a roll leaves the widget and Live Activity stale

Found by the 2026-08-28 race/concurrency audit, NOT fixed, and unrelated to anything shipped
that day. Two halves:

- `RollService.renameRoll` and `setRollCover` never call `WidgetSync.refresh()`, unlike
  `createRoll` / `joinRoll` / `forget`, which all do. The widget's subtitle is sourced live from
  roll names, so a rename shows the old name until some unrelated refresh happens to fire.
- Worse structurally: `RollLiveActivity.sync` bakes `rollName` into `RollRevealAttributes`, and
  ActivityKit treats attributes as immutable after `Activity.request`. The update path only
  touches `content.state`, so even calling `sync` again cannot change the displayed name. The
  only fix is to `end()` the activity and request a fresh one, which nothing does on rename.
  Net: rename a still-developing roll and its lock-screen countdown keeps the old name for the
  rest of the countdown.

Cosmetic staleness, not data loss and not cross-account, but it is a direct gap against the
project rule that any mutation changing what a widget or Live Activity shows must refresh the
snapshot or end the activity.

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
- The new left-aligned profile header (build 320): two badges, inline stats, and the badge
  explanation now swapping the STATS row rather than the handle line.
- The film-strip rows on the profile and roll grids (build 319): the perforated road between rows
  has never been seen on device on either surface.
- Three-across Darkroom sharpness (build 317): the decode now derives from the frame height, and
  whether that actually reads sharp is the part tests cannot answer.
- `skipDeadFrame`'s correction (build 319) needs a real mid-reveal image failure on a frame BEHIND
  the reader to confirm the pager no longer retargets. Tests cover the arithmetic, not the wiring.

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
