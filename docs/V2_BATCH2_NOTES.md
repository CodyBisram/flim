# v2 batch 2, design notes (2026-09-14, written before the gate opens)

Two client behaviours, each independently revertable, both approved in principle by the owner
on 2026-09-14 (docs/V2_RECONCILIATION.md, #5 approved, #12 later). Nothing here is built.
Batch 2 starts only after the batch 1 device checks pass on the v2 build.

## A. Camera permission, asked when Camera opens

### Today

`OnboardingView.openCamera()` requests camera access as the last thing onboarding does, because
onboarding's one CTA is "open the camera" and the camera is the landing tab: the system dialog
follows directly from that tap. `CameraView.onAppear` calls `startCameraFlow()` only when
`hasOnboarded` is true; `CameraViewModel.start()` then sees the decided status and, for
`.notDetermined`, asks again itself (so a person who somehow skipped the ask still gets one).
A refusal shows `cameraDeniedOverlay` ("Camera access needed", Open Settings) in place of the
viewfinder. 26 accounts have never been prompted (they never reached the camera after
onboarding, or refused and moved on); that is the number the permission-grant rate is measured
against.

The owner's standing checklist for this flow (memory: onboarding camera permission) says the
ask must be gated on WHEN, never on whether it ever happens, and that `hasOnboarded`'s meaning
and timing must not change. Both hold below.

### The change

Onboarding stops asking. The ask moves to the first time a camera surface actually opens:

1. `OnboardingView.openCamera()` drops the `requestAccess` call and just sets `hasOnboarded`.
   `Activation.log(.onboardingFinished)` stays where it is.
2. `CameraView`'s existing `startCameraFlow()` already asks on `.notDetermined`, so the Camera
   tab asks the moment it appears after onboarding. Nothing new there; the first-run coachmark
   and the shutter sit behind the same `permission == .authorized` gate they do now.
3. A roll's "Shoot into <roll>" / "Add a photo" posts `.openCamera` with the roll as the
   destination (`pendingRollPhoto` / the roll picker's `destinations`). The ask happens on the
   camera surface it opens; the destination survives the ask because it is state on
   `MainTabView`, not on the dialog. Verify on device that the destination chip still reads the
   roll's name after the dialog closes, on both Allow and Don't Allow.
4. Refusal: keep `cameraDeniedOverlay`, but it grows a second button, "Back to Feed", so the
   refusal is not a dead tab (the package's "FLIM can't use the camera" screen). The tab stays;
   hiding it would make the refusal look like a broken app. The overlay's copy is owner copy:
   "FLIM can't use the camera. Camera access is off for FLIM in iOS Settings. You can still see
   your friends' photos and reply to them." with Open Settings and Back to Feed.
5. Do NOT ask on `.notDetermined` from anywhere that is not a camera surface (the widget's
   shutter intent lands on Camera, so it is covered; the sort deck and the Darkroom never ask).

### Why this is safe to ship alone

The only observable difference for a new account is that the system dialog appears on the
Camera tab instead of one tap earlier on the onboarding screen; since Camera is the landing
tab, that is the same moment in practice today. It becomes a real difference only if #1
(Feed-first launch) lands later, which is exactly why it ships first: the grant rate is
measured with launch unchanged, then again after.

### Measure

`Activation.log(.cameraAuthorized)` already fires once per account. Compare the share of new
accounts reaching it within a day of `onboardingFinished`, before and after, in
`weekly_funnels` or a one-off query. Captures per active day must not fall.

### Checklist (from the standing memory, re-run after this change)

Fresh install: dialog timing is on first Camera appearance, once. Tab-cycle after Allow: the
camera restarts. Refuse, then Settings, then Allow: the viewfinder comes back without a
relaunch. Do not touch `NotificationPrimerSheet`.

## B. Comments remember where they were opened from

### Today

`CommentsSheet` is a `.sheet` presented by whoever opened it: `FeedUnitCard` (`commentsTarget`),
`PostDetailView`, the roll pager. From Activity, a row navigates to `PostDetailView` via
`postRoute`, and comments open as a sheet over that. Dismissing the sheet lands wherever the
presenter was, which is already "where you came from" for the feed and the pager. The gap is
Activity: reply to a comment from Activity and the thread is a sheet over a pushed post detail;
closing both takes two gestures and the second one lands on Activity only because the
navigation stack happens to be that shape. Nothing records the origin.

### The change

Small. No new navigation form (the project has already paid for three failed ones on this
screen; see `ActivityFeedView`'s comment above `navigationDestination`).

1. `CommentsSheet` gains `origin: CommentsOrigin` (`.feed(unitId, frameIndex)`, `.activity`,
   `.pager`, `.postDetail`). It changes nothing inside the sheet; it is carried so the presenter
   can act on it.
2. Activity presents `CommentsSheet` DIRECTLY for a comment, mention or reaction row, over the
   Activity list, with `origin: .activity`, instead of pushing `PostDetailView` first. The sheet's
   header already shows the thumbnail and "Photo N of M" style context (the package's rule: you
   never lose which frame you are replying to). Dismiss lands on Activity in one gesture, by
   construction.
3. The feed keeps its sheet; on dismiss, `FeedUnitCard` already holds `selection`, so the frame
   and scroll position are where they were. Nothing to add; write the UI test that proves it.
4. Rows that open a whole post (a "posted" digest row, a tag) keep pushing `PostDetailView`.

### Not in batch 2

The package's "readable unavailable state where a notification's target is gone" (group B):
Activity's row for a deleted post. Worth doing, separate change, needs the row to know the post
is gone before it navigates.

## Exit checks for batch 2

- Grant rate versus the 26 never-prompted accounts, two weeks after.
- Captures per active day unchanged (docs/NUMBERS.md `shooters` and `photos`).
- On device: onboarding ends with no dialog; first Camera open asks; a roll's Shoot into asks
  on the camera and keeps the roll; refuse then Back to Feed; reply from Activity and close in
  one gesture; reply from the feed and come back to the same frame.
