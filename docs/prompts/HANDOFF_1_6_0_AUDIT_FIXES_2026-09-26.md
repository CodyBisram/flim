# Handoff: 1.6.0 pre-release audit fixes (2026-09-26)

Paste this whole file into the local Claude Code session. It has Xcode and database access;
the cloud session that wrote this had neither, so **none of the Swift below has been compiled**.
Your job is to verify, fix anything that doesn't build, apply the server pieces in order, and
report back in the agent completion format.

## 0. Get the code

```bash
git fetch origin claude/edit-flim-app-b7p5b6
git checkout claude/edit-flim-app-b7p5b6   # 3 commits on top of origin/main 55e3f83
git log --oneline origin/main..HEAD
#   853bb98 feed count: never "0 shots from 0 friends", no jumping
#   38e84bf server: Spotlight report rule, pending_entries, push fixes
#   de30755 app: capture queue, decode timing, account-switch leaks, Spotlight menu
```

Do not merge to main until section 2 passes. Merging to main triggers a TestFlight upload.

## 1. What changed and why

The audit compared `origin/train/1.5.3` (live) with `origin/main` (1.6.0 candidate).

### Blockers fixed
| # | Problem | Fix | Files |
|---|---|---|---|
| B1 | Every queued shot decoded a ~48 MB full-res bitmap at enqueue; a crash replay enqueued all saved shots at once → likely OOM, possible crash loop | Decode starts inside the pipeline task after `await previous?.value` | `PhotoService.swift` ~207-265 |
| B2 | Shots left in a 1.5.3 queue (`<id>.jpg` + `<id>.json`) were deleted by `prune` on first 1.6.0 launch | `adoptLegacySidecars` converts them to `.saved` manifest entries before prune/remove; tolerant legacy decoder | `CaptureQueueStore.swift` ~106-258, test `legacySidecarShotsSurvivePruneAndReplay` |
| S-1 | Two accounts could follow a photographer, then report a published Spotlight frame and hide it for everyone | `auto_hide_reported`: once a week is published, only follows/tags/roll joins/posts from before the earliest publish count | `2026-09-25_spotlight_hardening.sql` §3 (+ schema.sql fold) |

### Feed "N shots from N friends"
The rule now: photos from people you follow, from the last 7 days, that you haven't reached,
plus how many people posted them. Your own posts never count. The server's count is the truth,
and the phone subtracts what you read until the next server count. The line disappears at zero
and never says "0 shots".
- "0 from 0" came from the phone's loaded feed keeping posts that had since aged past the
  server's 7-day window (`NOW()` at each recount). Marks on those were subtracted, and the line
  showed whenever any loaded unit was unseen. Now: `FeedUnit.wasCounted`, `remainingLedger`
  returns nil instead of zero, and the header gates on `shots > 0`.
- Jumping every ~4 s: when an upload landed, "pending" cleared before the recount answered.
  Now `pendingAtCount` is snapshotted when each count is asked, and out-of-order answers are
  dropped (`acceptServerCount`).
- The fallback used the old "what arrived" whole-day count; that code is removed and
  `loadedRemaining` replaces it.
- Backlog-seeded marks are now queued for upload (`FeedSeenStore.seedBacklog`).
- Files: `FeedUnit.swift`, `FeedView.swift`, `FeedSeenStore.swift`, `FeedUnitTests`, `FeedSeenStoreTests`.

### Should-fix items, done
- Widget can't repaint the signed-out account after `clear()` (generation + epoch gate, `WidgetSync.swift`; `WidgetSyncCommitGateTests`).
- A push tapped while signed out, or held across an account change, no longer opens for the next account (`PendingPushDestination.dropAccountScoped`, `ContentView`; `PushDestinationTests`). Tab dots reset on account change (`TabSignals.resetForAccountChange`).
- Pager delete now hides the photo in the Darkroom grid for the undo window (`PhotoPagerView.onDeletePhase` → `DarkroomView.handlePagerDelete`, epoch-guarded revert).
- Large Darkroom delete: a failed later chunk no longer resurrects the photos earlier chunks deleted (`deletePhotosConfirmed`).
- Spotlight menu offers "Take it down" for every waiting week. `own_spotlight_entry()` appends `pending_entries JSONB`; the client decodes both production's current shape and the new one (`Spotlight.swift`, `FeedService+Spotlight.swift`, `SpotlightTests`).
- Paged reads (`follows`, followers, user posts, comments) order on a unique key. Visible side effect: follower/following lists are now oldest-follow-first.
- `send-social-push`: no Spotlight push for a hidden photo; skipped/stale-week rows are marked instead of re-read each run; a transient read or RPC error retries instead of dropping the push.
- `send-one-shot-push`: email match escapes LIKE wildcards and confirms an exact case-insensitive match.
- `2026-09-21_reveal_completion.sql` backfill is guarded to pre-feature rows (safe to re-run).
- `schema.sql`: transitional `posts: readable by authenticated` policies are author-only, so a partial psql run can't expose every post. Final policies are unchanged.
- Nits: `deletePost` has its doc and `@discardableResult` back, the `ShareToFeedSheet` force unwrap is gone, `RollsView` uses `FlimTheme.error`.

Server work WAS verified in the cloud session: `scripts/schema_bootstrap.sh` on
supabase/postgres 17 (fresh and re-run), hardening applied twice, auto-hide and
`own_spotlight_entry` behaviour tests, and `deno check` on both functions.

## 2. Verify (do this first)

```bash
# Build: both configurations. Release catches DEBUG-only symbols.
xcodebuild -project Flim.xcodeproj -scheme Flim -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project Flim.xcodeproj -scheme Flim -configuration Release -destination 'generic/platform=iOS Simulator' build

# Focused tests
xcodebuild test -project Flim.xcodeproj -scheme Flim -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:FlimTests/FeedUnitTests -only-testing:FlimTests/FeedSeenStoreTests \
  -only-testing:FlimTests/FeedSeenStoreSeedTests -only-testing:FlimTests/CaptureQueueStoreTests \
  -only-testing:FlimTests/SpotlightTests -only-testing:FlimTests/PushDestinationTests \
  -only-testing:FlimTests/WidgetSnapshotTests -only-testing:FlimTests/QueryBatchingTests \
  -only-testing:FlimTests/AccountEpochTests
# Then the full FlimTests suite.
```

The project and scheme match CI (`.github/workflows/ios-testflight.yml`); pick any installed simulator for the destination. If you'd rather not build locally, a draft PR to main
runs the same build, tests and schema bootstrap in CI without uploading.

Compile-risk spots to look at first if the build fails:
- `WidgetSync.run`: `await MainActor.run { ... }` captures `WidgetSnapshot` (non-Sendable; fine under Swift 5.9 minimal checking).
- `PhotoService` ~216: `let prepare: @Sendable () async -> PreparedCapture` (`PreparedCapture` is `@unchecked Sendable`).
- `Spotlight.swift`: a hand-written `init(from:)` for `OwnSpotlightEntry` sits in an extension so the memberwise init survives (`SpotlightPreviewDemoHost.swift:176` uses it).
- `DarkroomView` passes `onDeletePhase: { handlePagerDelete($0, $1) }`.

On-device checks:
1. **1.5.3 upgrade:** with 1.5.3 installed, go offline, shoot several frames, force-kill. Install this build and launch online. Every frame uploads.
2. **Memory:** shoot 20 frames fast on a throttled connection, kill, relaunch. Watch memory in Instruments; nothing gets killed.
3. **Feed count:** swipe through a day. The number only goes down, with no jump up every few seconds. Leave the feed open for hours, or across the oldest post's 7-day mark: never "0 shots from 0 friends". The line disappears when everything is read.
4. **Widget:** stage a Darkroom delete, sign out immediately. The widget ends up empty.
5. **Push:** tap a join-roll push while signed out, then sign in as another account. No join sheet.
6. **Pager delete:** delete from the photo pager. The photo leaves the grid; Undo brings it back.

## 3. Production state (the cloud session could not reach the database)

Run read-only before shipping:

```sql
-- Are the two 09-24 migrations applied? 1.6.0 depends on both.
-- account_purge_complete defines _dead_owner_photos_objects and list_dead_owner_photos_objects;
-- detach_device_token defines detach_device_token(text), executable by anon.
select proname, pg_get_function_identity_arguments(oid) from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('_dead_owner_photos_objects','list_dead_owner_photos_objects','detach_device_token',
                   'refuse_caption_in_spotlight','own_spotlight_entry','invite_landing');
select has_function_privilege('anon','public.detach_device_token(text)','execute');

-- Hardening not applied yet? This should NOT list pending_entries until you apply it.
select pg_get_function_result('public.own_spotlight_entry()'::regprocedure);

-- Has any Spotlight week been published? (decides the 1.5.3 grid note below)
select count(*) filter (where published_at is not null) as published, count(*) from public.spotlight_weeks;
```

## 4. Deploy order (owner action, after section 2 passes)

1. Apply `2026-09-24_account_purge_complete.sql` and `2026-09-24_detach_device_token.sql` if section 3 shows them missing, then redeploy `sweep-orphaned-storage`.
2. Apply `supabase/migrations/2026-09-25_spotlight_hardening.sql`. It must come **before** step 3: the new `send-social-push` reads `spotlight_weeks.skipped_at`, and until hardening is applied Spotlight pushes stall (fail safe, nothing sent).
3. Deploy `send-social-push` and `send-one-shot-push`.
4. Apply `2026-09-25_invite_loop.sql` (and `2026-09-26_outreach_codes.sql` when you want it). Then redeploy `send-social-push` if you haven't since.
5. Do not re-apply `2026-09-21_reveal_completion.sql`; it's already live. The edit only makes future re-runs safe.
6. Update the App Store Connect privacy label: `PrivacyInfo.xcprivacy` now declares Crash Data and Product Interaction (linked).
7. Update `docs/PENDING.md`: hardening now also covers the pre-publish report rule and `pending_entries`.
8. Merge the branch to main. That runs the TestFlight build.

## 5. Decisions made on the owner's behalf

- **1.5.3 profile grid shows published Spotlight frames to strangers** (and their comments fail). Only 1.6 filters this. Decision: accept it; it fades as people update. Revisit if a week is published while many users are still on 1.5.3.
- **Burst latency:** each shot now decodes at its turn with no look-ahead, so shots in a fast burst appear slightly later. Chosen for crash-replay memory safety.
- **Follower lists** now have a defined order (oldest follow first).

## 6. Known remaining risks

- The push payload has no recipient id, so a held push destination can only be dropped on the signed-out screen or on an account change, not matched to a specific user.
- Feed count: a push that lands in the same instant the server runs its count can dip the number by that batch for one round trip. The device clock versus the server clock can misjudge a post exactly at the 7-day edge until the next recount.
- In a schema.sql run that stops partway, the storage policy `photos: readable when shared to a post` is still broad (psql without `--single-transaction` only).
- Not exercised by tests: the roll-member and tag branches of the new auto-hide rule.
- Stale "ledger snapshot" wording remains in comments in `FeedUnitCard.swift` and `FeedService.swift`. Cosmetic.

## 7. Report back in this format

```text
STATUS: COMPLETE | BLOCKED | NEEDS OWNER ACTION
CHANGED:
- path: reason (any build fixes you made)
VERIFIED:
- Debug build / Release build / focused tests / full suite / device checks 1-6 / production queries: PASS | FAIL | NOT RUN
NOT VERIFIED:
- item: reason
RISKS:
- concrete, or NONE
HANDOFF:
- next step, or NONE
```
