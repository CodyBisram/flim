# FLIM iOS application audit — September 24, 2026

## Context and scope

A full, read-only audit of the FLIM iOS application, conducted as a senior iOS review of the whole
app target rather than a diff review. Six reviewers each took one domain and read every file in it
in full: (1) app lifecycle, auth, account switching, push registration and deep links; (2) capture,
image processing, upload, retry, persistence and deletion; (3) feed, social graph, comments,
reactions, activity, seen-marks and undo; (4) rolls, reveal, Live Activities, the home-screen widget
and local notifications; (5) Darkroom, photo pager, profile, identity, invites and chapters;
(6) project configuration, build and release, privacy manifest, cross-cutting code health, testing
strategy and design system. The primary reviewer cross-checked every P1 and P2 below against the
source before it was included, and read the auth, lifecycle, capture-entry and delete paths directly.

Reviewed HEAD: `c433c19e53a7d7f27476381f0c5d9f56fa9064b1` (Sep 24, 2026). App target: 175 Swift
files, about 52,300 lines, plus a WidgetKit extension. Deployment target iOS 18.0, Swift 5.9
language mode, `supabase-swift` 2.x. Test target: 133 unit test files, 2 UI test files.

**Not in scope:** Supabase SQL, RLS, Edge Functions and the web target were read only where an iOS
finding depended on them. Nothing was built, no test was run, no device was used, and no production
request was made. Findings are from source analysis; each is marked CONFIRMED (the whole path was
traced) or PLAUSIBLE (a runtime detail could differ).

**Already-known items were excluded.** `docs/reviews/OPEN.md` carries 19 open findings from the
nightly review; each was re-verified as not worse than described and is not repeated here. The
`docs/BACKLOG.md` item about `navigationDestination` inside lazy containers is still present at four
sites (`FeedUnitCard.swift:258`, `PostDetailView.swift:201`, `ActivityFeedView.swift:208,214`) and
is likewise not re-filed.

## Overall assessment

This is a disciplined codebase for its size, and considerably stronger than at the September 11
audit. All seven P1/P2 items from that audit that touch the iOS client are now closed in code (see
"Status of previously flagged items"). The things that most often go wrong in a photo-social app of
this shape are handled deliberately: captures are durable on disk before any network call, uploads
are idempotent and retried across foreground, reconnect and relaunch, deletion is row-first with a
sweeper as backstop, and account switching is guarded by a generation counter (`AccountEpoch`) that
is checked per write rather than per function. There are no unsafe force unwraps, no `try!`, no
`fatalError`, no GCD mixed into Swift concurrency, and no deprecated UIKit or SwiftUI APIs in the app
target. Image loading downsamples through `CGImageSource`, caches by storage path, and caps
concurrency. Off-app surfaces (Live Activity, widget, local reminders) are torn down together on
delete and leave. CI counts strict-concurrency warnings on every pull request so the Swift 6
migration cost is tracked.

The remaining problems are almost all of one shape: a well-established rule that is applied at
nearly every site and missed at one or two. The `AccountEpoch` guard is missing on a handful of
writes; the app-wide `UndoCenter` is bypassed by the Darkroom's own older undo timer; one reaction
path writes to a view-local array instead of the shared cache; one per-account key skips the
userId namespace every other key uses; the 4am day boundary is missed in one more formatter. None of
these is architectural. They are the cost of a large surface with one author, and the fix for most
is to reuse the existing helper.

Two findings are P1. Account deletion removes every photo row and every stored object before
calling the `delete_account` RPC, and if that final call fails the screen tells the person nothing
was deleted. A server-initiated sign-out (expired or revoked refresh token) takes a different path
from a user-initiated one and skips the widget clear and the push-token detach, so a signed-out
phone keeps showing and receiving the departed account's data.

Priority meanings: **P1** = data loss, privacy, or a core flow that lies to the user; **P2** = real
reliability or correctness bug reachable in ordinary use; **P3** = edge case, inconsistency with an
established rule, or maintainability. These are priorities, not claims that harm has occurred.

## Findings requiring action

### 1. P1 — Account deletion destroys photos before the account, then reports "Nothing was deleted"

**Evidence:** `Flim/Services/AuthService.swift:787-805`; `Flim/Views/Profile/AccountDeleteView.swift:235-243`. CONFIRMED.

`deleteAccount()` runs three steps in order: delete all `photos` rows for the user, remove every
object under the user's Storage prefix (best-effort, bounded to 20 pages), then call the
`delete_account` RPC. If the RPC throws after the first two steps succeeded (a timeout, a dropped
connection, a transient 5xx), `AccountDeleteView` catches it and shows the unconditional copy
"Couldn't finish deleting. Nothing was deleted." At that moment the account exists, every photo row
and every rendition byte is gone, and the person has been told the opposite. A retry completes
cleanly, but the copy invites them not to.

**Recommendation:** Either move the row and object deletion inside the server-side `delete_account`
function so the client makes one call, or keep the client ordering and make the failure copy
truthful about which stage failed ("Your photos were deleted but the account could not be closed.
Try again."). Track a local "deletion started" flag so a relaunch can resume rather than restart.

**Acceptance:** Fail the RPC after the photo delete succeeds. The screen must not claim nothing
happened, and a relaunch must offer to finish.

### 2. P1 — A server-forced sign-out skips the widget clear and the push-token detach

**Evidence:** `Flim/Services/AuthService.swift:875-880` (the `.signedOut` case of
`listenForAuthChanges`) versus `AuthService.swift:721-743` (`signOut()`);
`Flim/ContentView.swift:171-188`; `Flim/Services/RemotePush.swift:124`. CONFIRMED.

User-initiated `signOut()` detaches the device token before the session goes, then posts
`.flimAccountDidChange`, which is the only thing that calls `WidgetSync.clear()`. The SDK's
`.signedOut` event, which fires for an expired or revoked refresh token, only bumps the epoch and
clears `currentUser`. `ContentView`'s `onChange(of: currentUser?.id)` still resets the in-memory
caches and cancels local reminders, but the home-screen widget keeps rendering the departed
account's snapshot, and the `device_tokens` row stays attached, so this phone keeps receiving that
account's pushes while visibly showing the sign-in screen. The token cannot be detached from this
path because `unregisterCurrentDevice()` requires a live session that is already gone.

**Recommendation:** Post `.flimAccountDidChange` (or call `WidgetSync.clear()` directly) from the
`.signedOut` case. For the token, the client has no credential left to act with; either the server
prunes `device_tokens` on refresh-token revocation, or tokens carry a last-seen timestamp and are
aged out. This half needs an owner decision on the push backend.

**Acceptance:** Revoke a session server-side while the app is installed. The widget must go blank on
the next foreground, and no push for that account may be delivered to the device afterward.

### 3. P2 — The Darkroom's delete undo runs outside `UndoCenter`, so it is never flushed

**Evidence:** `Flim/Views/Darkroom/DarkroomView.swift:1081-1136` (own 4-second `undoTask`),
`:544` (`onDisappear` is the only flush); `Flim/Services/UndoCenter.swift:10-15`;
`Flim/ContentView.swift:123,228`; `Flim/Services/PhotoService.swift:1672-1698`. CONFIRMED.

`UndoCenter`'s own header names the failure mode: "an app killed mid-window would silently lose an
action the person watched happen", and `ContentView` flushes it on leaving the foreground and on
account change. The Darkroom predates the center and keeps its own timer, which is flushed only when
the view disappears. Swipe-delete a photo, lock the phone or switch apps within four seconds, and
the delete never reaches the server; the photo is back on relaunch with no explanation. On an
account switch inside the window the stale task still fires: the row delete is filtered to zero rows
by RLS, `deletePhotos` returns `true` because the request did not throw, and the caller treats it
as done.

**Recommendation:** Stage Darkroom deletes through `UndoCenter.shared.stage` like every other
reversible action, which brings the background and account-change flushes for free. Separately,
`deletePhotos` should capture the epoch and should not treat a non-throwing DELETE as proof that
rows were removed.

**Acceptance:** Delete in the Darkroom, background the app within the window, relaunch: the photo
must be gone. Delete, switch accounts within the window: the original account must still be able
to see and re-delete the photo, with no false success.

### 4. P2 — The post-detail reaction bar bypasses the shared reaction cache

**Evidence:** `Flim/Views/Feed/PostDetailView.swift:558-572`; compare `FeedUnitCard.swift:139`
and `FeedService.swift:1298` (`reactToPost`). CONFIRMED.

`toggle(_:)` mutates a view-local `reactions` array, calls the raw `addReaction`/`removeReaction`
and discards their result, then overwrites the array from `fetchReactions`. It never writes
`feed.reactionsByPost[post.id]`, which every feed card reads. Every other reaction and comment-like
path in the app writes through the shared cache. Open a post from a profile or the Activity tab,
tap a reaction, go back: the feed card is stale until the next refresh, and a failed write is
silently absorbed.

**Recommendation:** Route through `feed.reactToPost` as `doubleTapLike` in the same file already
does, and derive `reactions` from `feed.reactionsByPost[post.id]` filtered for blocks.

### 5. P2 — `commentOnPost` writes the comment cache with no epoch guard

**Evidence:** `Flim/Services/FeedService.swift:1375-1379`, callers at `CommentsSheet.swift` and
`PostDetailView.swift:586`. CONFIRMED.

After `addComment` the function assigns `commentsByPost[postId] = await fetchComments(...)`
unconditionally. Every comparable write in this file captures `AccountEpoch.current` first and
re-checks it. A comment sent just before an account switch lands a comment list computed for the
old user (including `likedByMe`) in the new account's cache, for a post the new account may also be
able to see.

**Recommendation:** Capture the epoch before the first await and guard the assignment, matching
the rest of the file.

### 6. P2 — The camera session has no interruption or runtime-error recovery

**Evidence:** `Flim/Views/Camera/CameraViewModel.swift` (whole file), `CameraView.swift:275,396`.
CONFIRMED absence; PLAUSIBLE as a user-visible freeze.

There is no observer for `AVCaptureSession.wasInterruptedNotification`,
`interruptionEndedNotification` or `runtimeErrorNotification` anywhere in the app. The session is
started and stopped only by the Camera tab's appear and disappear. If media services reset, or an
accessory or a phone call takes the camera while the tab is frontmost, the viewfinder freezes and
`capturePhoto()` silently returns on `guard session.isRunning`. Recovery requires switching tabs
and back, and nothing tells the person why the shutter is dead.

**Recommendation:** Observe the three notifications in `configure()`, restart the session on
`.runtimeError` and on interruption end, and show a one-line state ("Camera unavailable") while
interrupted, per Apple's AVCam sample.

### 7. P2 — Deleting a roll cancels its reminder before the server confirms, and swallows failure

**Evidence:** `Flim/Views/Rolls/RollDetailView.swift:847-857` versus the Leave flow at
`:862-879`. CONFIRMED.

Delete cancels the local develop reminder synchronously, then `try?`s `deleteRoll` and dismisses
regardless. Leave, two call sites down, cancels only after success and shows a toast on failure.
An offline delete leaves the roll alive on the server with its owner's only "your roll developed"
channel permanently cancelled, and the sheet closes as if it worked.

**Recommendation:** Mirror the Leave flow: cancel after success, toast on failure.

### 8. P2 — `lastActivitySeen` is not namespaced by account

**Evidence:** `Flim/Views/Main/MainTabView.swift:111`, `Flim/Views/Feed/FeedView.swift:47`,
`Flim/ContentView.swift:240`; compare `Flim/Services/NewAccountIntro.swift:46-90`, which suffixes
every per-account key with the userId. CONFIRMED.

The Activity "New" cutoff and the tab dot are keyed by a plain `@AppStorage("lastActivitySeen")`.
A second account on the same device inherits the first account's cutoff, so its Activity tab
shows the wrong "new" section and dot until the value churns. The `rollRevealSeen.<rollId>` family
is per roll rather than per account, but is seeded from the server's `completed_at`
(`RollService.swift:377-406`) so its exposure is limited to a shared roll viewed by two accounts on
one device.

**Recommendation:** Key `lastActivitySeen` by userId the way `NewAccountIntro` does.

### 9. P3 — Non-isolated mutable statics touched from unstructured tasks

**Evidence:** `Flim/Services/RemotePush.swift:51` (`registeredAccountId`),
`Flim/Services/Activation.swift:79` (`activeUserId`);
`Flim/Views/Camera/CameraViewModel.swift:660,692` (`shutterTappedAt`, `nonisolated(unsafe)`,
written on main, read on the AVFoundation delegate queue). CONFIRMED shape, low impact today.

The first two are effectively serialized by their few call sites; the third feeds only a
diagnostic log line. All three are the sites that will need a lock or `@MainActor` before Swift 6
strict concurrency can be enabled.

### 10. P3 — Remaining `AccountEpoch` gaps

**Evidence:** `Flim/Services/RollService.swift:557-572` (`setRollCover`, the one mutator in that
file without a guard; `persistSnapshot()` runs after the await);
`Flim/Services/FeedService.swift:723` (`unfollow` inside the otherwise-guarded `block`);
`Flim/Views/Darkroom/DarkroomView.swift:1410-1421` (`openRequestedPhoto` assigns
`selectedPhoto` after an unguarded fetch). CONFIRMED.

Each is bounded (update-by-id, random UUID, or RLS-limited read), but each breaks a rule the
surrounding file treats as load-bearing.

### 11. P3 — One more midnight boundary

**Evidence:** `Flim/Models/RevealCover.swift:46-49`. CONFIRMED.

`dateLine()` uses `calendar.startOfDay`, not `FeedUnit.dayKey`. The same class of bug was fixed in
`RollDevelopAskSheet` (Sep 10) and `Roll.defaultName` (Sep 20). A roll started at 11:50pm and
viewed at 1:15am says "Shot yesterday" while every other surface calls it tonight.
`RevealCoverTests` has no boundary case.

### 12. P3 — Live Activity updates are unthrottled and skip deletes

**Evidence:** `Flim/Services/PhotoService.swift:656` (one `syncRollActivity` per capture; the
comment's "one update per burst" claim only holds for identical states, and `shotCount` changes
every shot); `PhotoService.swift:1688-1690` (`deletePhotos` refreshes the widget but never the
activity). PLAUSIBLE for the throttle, CONFIRMED for the delete.

`WidgetSync.refresh()` a few files away already has a 700ms coalescing debounce; reuse it.

### 13. P3 — Silent failure and duplicated mechanisms in social views

**Evidence:** `Flim/Views/Profile/BlockedUsersSheet.swift:76-81` (row removed optimistically,
`FeedService.unblock` reverts its own set on failure but the sheet never learns);
`Flim/Views/Components/PhotoPagerView.swift:2019-2043` (`doubleTapLike`'s non-post branch
overwrites the whole per-photo reaction array from a fetch, racing `toggleReaction`'s keyed
`OptimisticToggle`); `Flim/Services/FeedService.swift:1508-1518` (`deletePost` leaves entries in
three per-post dictionaries that `dropPosts(forDeletedPhotoIds:)` clears);
`Flim/Views/Feed/FeedUnitCard.swift:207-243` (a programmatic reposition after straddle completion
skips `resolveURLs`, so newly inserted neighbours can render blank for a beat). CONFIRMED except
the pager race, PLAUSIBLE.

### 14. P3 — Hygiene

- `Flim/FlimApp.swift:109-124` and `Flim/Services/PushDestination.swift:114`: host and scheme
  matching is case-sensitive with no normalization. `routePersonalInviteCode` has no test at all.
  PLAUSIBLE.
- `Flim/Services/CubeLUT.swift:16-23`: a plain `static var` cache mutated from `nonisolated`
  code reachable off detached tasks; safe only because `PhotoService.pipeline` serializes
  captures. PLAUSIBLE.
- `Flim/Services/RemotePush.swift:236`: the only production `print(`; route through `os.Logger`.
  CONFIRMED.
- Design-token drift: `Color(red: 1, green: 0.4, blue: 0.4)` for validation errors at
  `OTPView.swift:76`, `ProfileView.swift:625`, `UsernameView.swift:124`, `PhoneAuthView.swift:81`,
  and a slightly different `0.42` at `FeedbackSheet.swift:41`; `Color(white: 0.3)` placeholder
  gray four times; `OTPView.swift:30` re-literals `FlimTheme.bg`. Add error and placeholder
  tokens to `FlimTheme`. CONFIRMED.
- No localization infrastructure at all (zero `String(localized:)`, no `.xcstrings`). Plausibly
  intentional for an invite-only English product; noted so it is a decision, not an omission.

## Status of previously flagged items (September 11 audit)

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Write-boundary migration rejects rendition-path writes | Fixed | `supabase/migrations/2026-09-11_photo_grants_hotfix.sql:15` |
| 2 | Photo INSERT does not validate path ownership | Fixed | same migration, `lock_photo_paths_to_owner` trigger, lines 17-46 |
| 3 | `deletePhoto` removes bytes before the row | Fixed | `PhotoService.swift:1649-1698`, single delegates to batch, row first |
| 4 | Account deletion `try?`s the prerequisite and can loop | Fixed, but see finding 1 | `AuthService.swift:793` (`try await`), `:796` (bounded to 20) |
| 5 | Queued captures resume under the next account's generation | Fixed | `PhotoService.swift:228` captures the epoch before the shot enters the pipeline; every later write re-checks it |
| 6 | Raw and processed stores are not one recovery state machine | Fixed | `CaptureQueueStore.swift` `PendingCapture.Stage` + `CaptureRecovery.plan`, consumed in order at `ContentView.swift:153-154` |
| 18 | Image retry reuses the rejected signed URL | Fixed | `PhotoGridCell.swift:419-432` re-signs by storage path |

Finding 4's fix moved the failure from "loops forever" to "lies about what was deleted"; that is
finding 1 above.

## Architecture and code health

**Shape.** Nine `@Observable` services are created once in `FlimApp` and injected through the
environment; views read them with `@Environment`. 45 `@Observable` types, 41 files carrying
`@MainActor`, 13 `.shared` singletons (image caches, undo, seen-marks, burst detection, crash
reporting). Network access is confined to 12 files; `FeedService` (83 call sites) and
`PhotoService` (38) own most of it. Off-main work uses `Task.detached` (about 40 sites, all image
or network) with no GCD anywhere. The `AccountEpoch` generation counter is the app's single most
important invariant and is applied at essentially every write site (this audit found the four that
miss it).

**What is done well.** Durable capture before upload with idempotent `upsert` retries and a
`23505` recovery path; row-first deletion with a sweeper backstop; `CGImageSource` downsampling and a
storage-path-keyed disk cache; keyset pagination with tie-breaking and straddle completion; blocks
enforced by RLS and re-filtered client-side on every surface; Live Activity ranges clamped after a
real production crash; `AccountEpoch` and `AccountEpochTests` modelling the exact "guard before the
await" defect; the widget writes images before the snapshot JSON so the extension never sees a
dangling reference; Liquid Glass gated behind `#available(iOS 26, *)` in one place.

| Signal | Count | Note |
|---|---|---|
| Unsafe force unwraps | 0 | 7 raw `!` sites, all provably safe (literals, guarded, same-dictionary re-lookup) |
| `try!` / `fatalError(` / `precondition(` | 0 / 0 / 0 | |
| `assertionFailure(` | 1 | `AuthService.swift:856`, identity mismatch, justified |
| `as!` | 1 | `CameraPreview.swift:92`, standard `layer` override |
| `DispatchQueue.main.async` / `.global` | 0 / 0 | |
| `Task.detached` | ~40 | image and network work only |
| `Timer.scheduledTimer` | 0 | |
| `NotificationCenter.addObserver` | 2 | both in `KeyboardDismissController`, idempotent |
| `nonisolated(unsafe)` | 3 | 2 immutable after init, 1 racy but diagnostic-only (finding 9) |
| `@unchecked Sendable` | 2 | both lock- or single-writer-guarded, both commented |
| Distinct `UserDefaults` key families | ~14 | 1 per-account key un-namespaced (finding 8) |
| `Calendar.current` / `TimeZone.current` sites | 20 | consistently through `FeedUnit.dayBoundaryHour`, one miss (finding 11), one known open row |
| `.accessibilityLabel(` vs `Button {` vs `Image(systemName:` | 104 / 200 / 149 | ratio suggests some icon-only buttons lack labels; not triaged per site |
| `.dynamicTypeSize(` ceiling | 1 | app-wide `.accessibility3` at `FlimFont.swift:195` |
| `print(` outside DEBUG and tests | 1 | `RemotePush.swift:236` |
| Deprecated UIKit / SwiftUI API | 0 | |
| `Color(` outside theme files | 122 in 38 files | at least 5 literal duplicates of existing tokens |
| Localization | 0 | English literals throughout |

## Testing assessment

The unit suite is large (133 files, roughly 71 XCTest and 61 Swift Testing) and entirely offline:
no test references the Supabase client. That is by design. The global `supabase` singleton
(`Flim/Config/SupabaseClient.swift:4`) has no injection seam, so `FeedService` and `PhotoService`
bodies are not unit-testable; instead the app pulls pure logic into static helpers (decoding,
cursors, day-key math, grouping, `OptimisticToggle`, `UserFacingError`, `CaptureRecovery.plan`) and
tests those thoroughly. The trade is fast, deterministic CI against no coverage of query
construction or the actual network bodies. Async tests poll through a `waitUntil` helper rather
than fixed sleeps, and the UserDefaults-touching tests use a per-test suite.

Gaps this audit would have caught with a test: `deleteAccount` partial failure ordering (finding
1); the `.signedOut` cleanup contract (finding 2, needs the auth stream to be fakeable); the
Darkroom delete under a scene or epoch change (finding 3); `commentOnPost` epoch respect (finding
5); `setRollCover` under an account switch (finding 10); `RevealCover.dateLine` at the 4am boundary
(finding 11); `routePersonalInviteCode` at all (finding 14). `RemotePush`'s claim/detach state
machine is exercised only through its pure predicates.

UI tests cover two flows (feed comments return, share sheet) and are deliberately outside the CI
scheme. Sign-in, capture and reveal, the three flows a stranger meets first, have no automated UI
coverage and depend on manual TestFlight passes. `EmojiCatalogTests` still fails on the iOS 26.3.1
simulator per the backlog; not re-run here.

## Swift 6 and iOS 26 readiness

Language mode is 5.9 with no strict-concurrency flag (`project.yml:65,142`). The CI advisory job
(`.github/workflows/ios-testflight.yml:110-174`) reports 23 unique warnings under
`-strict-concurrency=complete`, mostly `static let` caches on non-Sendable types and four
sending-closure sites in `CameraViewModel`. This audit's reading agrees with the job's claim that
none is a defect today; the three sites in finding 9 plus `CubeLUT.cache` are the ones that need a
real fix rather than an annotation. The iOS 18 floor and the iOS 26 Liquid Glass styling coexist
through one gated block in `Theme.swift:270-294`. No deprecated API was found.

## Verification and handoff plan

No build, test or device run was performed for this audit. Suggested order, each batch small enough
to ship on its own:

### Batch 1: the two P1s and the delete path

1. Make account deletion truthful and resumable (finding 1). Prefer moving row and object deletion
   server-side into `delete_account`; otherwise fix the copy and add a resume flag.
2. Clear the widget from the `.signedOut` path, and decide with the push backend owner how
   orphaned device tokens are pruned (finding 2).
3. Move Darkroom deletes onto `UndoCenter` and make `deletePhotos` check the epoch and the affected
   row count (finding 3).

### Batch 2: consistency with existing rules

4. Route `PostDetailView.toggle` through `reactToPost` (finding 4).
5. Add the epoch guard to `commentOnPost`, `setRollCover`, `block`'s `unfollow`, and
   `openRequestedPhoto` (findings 5, 10).
6. Reorder roll delete to cancel after success and toast on failure (finding 7).
7. Namespace `lastActivitySeen` by userId (finding 8).
8. Shift `RevealCover.dateLine` through `FeedUnit.dayKey` and add the boundary test (finding 11).

### Batch 3: camera resilience and off-app surfaces

9. Add capture-session interruption and runtime-error observers with a visible unavailable state
   (finding 6); verify on device with a phone call and a media-services reset.
10. Debounce `syncRollActivity` and call it from `deletePhotos` (finding 12).

### Batch 4: hygiene, when touching those files anyway

11. Findings 9, 13 and 14: statics under a lock or `@MainActor`, the blocked-users revert, the
    pager double-tap path, `deletePost` cache cleanup, case-insensitive link matching, the one
    `print`, and the error and placeholder colour tokens.

Before the next release, run a two-account pass on one device covering: delete a photo and
background the app inside the undo window; react from a post opened through Activity and return to
the feed; delete a roll offline; sign into the second account and check the Activity tab's "new"
cutoff. Do not mark any finding closed from a happy-path test alone; the specific failure scenario
above should be exercised.
