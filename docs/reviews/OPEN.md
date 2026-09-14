# Open findings from the nightly review

One row per finding the nightly review has raised. The review re-verifies every row marked
`open` or `unverified` against HEAD each night and moves it to `fixed` (with the commit) or
`not a bug` (with one line why), so this file is the truth about what is still wrong, and
`docs/reviews/<date>.md` is the evidence. Seeded 2026-09-13 from thirteen review files that had
sat unread in pull requests; everything starts `unverified` and the first night triages it.

| Raised | Severity | Finding | Status | Note |
|---|---|---|---|---|
| 2026-08-27 | high | Flim/ContentView.swift:117 (account-change flush ran after the cache resets, dropping a pending undoable action) | fixed | 92c1fb9 |
| 2026-08-27 | high | Flim/Views/Rolls/RollsView.swift:397-398 ("Shoot into this roll" posts a bare NotificationCenter notification instead of CameraRollSelection.select, camera can point at the wrong roll) | open | |
| 2026-08-27 | high | Flim/Views/Feed/FeedView.swift:484,799-801 (onAuthorBlocked re-snapshots the ledger non-growOnly, can shrink the header's counts for unrelated already-read units) | open | |
| 2026-08-27 | high | Flim/Views/Profile/BadgePickerSheet.swift:651-684 (commit() bypasses UndoCenter, a stale staged clear-badges action can overwrite a fresh save) | open | |
| 2026-08-27 | medium | Flim/Views/Rolls/RollsView.swift frame-counts race (mine defaulted to 0 between two sequential writes) | fixed | 92c1fb9 |
| 2026-08-27 | medium | Flim/Views/Feed/UserPageView.swift:327-347 (blockAccount defers dismiss into the staged commit closure, can pop whatever the user navigated to since) | open | |
| 2026-08-27 | low | Flim/Views/Profile/ProfileView.swift:512-518 (photoError auto-dismiss timer is never cancelled, a second error can be cut short by the first one's timer) | open | |
| 2026-08-28 | high | Flim/Views/Rolls/RollDetailView.swift:607-618 (reveal re-presents on every reappearance; presenting never marks it seen, only genuine completion does) | open | |
| 2026-08-28 | medium | RollRevealView.swift selection/index desync after skipDeadFrame | fixed | 92c1fb9 |
| 2026-08-28 | low | Flim/Views/Rolls/RollRevealView.swift:480-484 (stages a reportPhoto undo but has no undoCapsuleHost of its own, capsule unreachable during the reveal) | open | |
| 2026-08-28 | low | SharePreviewSheet.swift Share button not gated on render completion | fixed | 92c1fb9 |
| 2026-08-30 | low-medium | Flim/Views/Feed/FeedView.swift:260,723-736 (inviteQuota fetched once in .task, never refreshed by reload(), can hand out an already-dead invite code) | open | |
| 2026-08-31 | medium | Flim/Services/InstantFilmProcessor.swift:668-669 (flashFalloff floors peak at 0.02 instead of treating it as 1, darkening an already near-black flash frame instead of leaving it untouched) | open | |
| 2026-09-01 | medium | `admin_overview()`'s never_asked_notifications (2026-08-31_admin_overview_v2.sql:88-93) adds a device_tokens condition admin_reach()'s never_asked lacks, so the two panels disagree | open | |
| 2026-09-01 | medium | `admin_overview()`'s reveals week-over-week (2026-08-31_admin_overview_v2.sql:31-32,45-48) compares an 8-day "now" window to a 7-day "prev" window | open | |
| 2026-09-03 | high | PhotoGridCell.swift disk-cache-miss path had no loadGeneration guard | fixed | 92c1fb9 |
| 2026-09-03 | low | Flim/Services/RollSnapshotStore.swift:55-61 (save() spawns an unordered detached Task per call; two persistSnapshot() calls for one account can finish out of order) | open | |
| 2026-09-05 | high | Flim/Views/Profile/ChapterRecapView.swift:387-395 (recap pager still resolves reactions/comments by photo id against photo_reactions/photo_comments, not the post_reactions/post_comments chapter_stats() counts from) | open | |
| 2026-09-05 | medium-high | Flim/Services/PhotoService.swift:568-634 (generic upload-failure catch never calls patchEarlierBurstGroup; the retry path at :393-396 also returns patchEarlier: nil, so the obligation is permanently dropped) | open | |
| 2026-09-05 | medium | Flim/Views/Rolls/RollDetailView.swift:861-877 (openAwaitingPhotoIfReady reads awaitingPhotoComments after polling instead of capturing it with photoId; a second push for the same roll can attach the wrong comment intent) | open | |
| 2026-09-05 | ? | Burst grouping's 3-second window is measured against a timestamp taken after the previous shot's full pipeline | unverified | |
| 2026-09-05 | ? | "Play again" on a chapter's closing card replays from a stale index | unverified | |
| 2026-09-05 | ? | A reveal shown mid-poll can conflict with a pending push-photo presentation | unverified | |
| 2026-09-05 | ? | Burst cover selection ties a measured zero sharpness score with an unmeasured one | unverified | |
| 2026-09-06 | high | `Flim/Views/Main/MainTabView.swift:116` and `Flim/Views/Rolls/RollsView.swift:341,360,484,617` (high) | unverified | |
| 2026-09-06 | medium | `Flim/Services/RemotePush.swift:111` (medium) | unverified | |
| 2026-09-09 | ? | Flim/Services/FailedUploadStore.swift:104 | unverified | |
| 2026-09-09 | ? | Flim/Services/ChapterCuration.swift:154 | unverified | |
| 2026-09-10 | high | FeedService.swift:974, high | unverified | |
| 2026-09-10 | high | Flim/Views/Rolls/RollRevealViewModel.swift:170-182, high | unverified | |
| 2026-09-10 | high | supabase/functions/send-daily-digest/index.ts, high | unverified | |
| 2026-09-10 | medium | Flim/Services/AuthService.swift:474-499, medium | unverified | |
| 2026-09-10 | medium | supabase/functions/send-develop-push/index.ts:249, medium | unverified | |
| 2026-09-10 | medium | Flim/Views/Feed/FeedView.swift:462 and Flim/Views/Rolls/RollsView.swift:230, medium | unverified | |
| 2026-09-10 | medium | Flim/Services/Activation.swift:82-109, medium | unverified | |
| 2026-09-10 | low | Flim/Views/Rolls/RollDevelopAskSheet.swift:24-25, low | unverified | |
| 2026-09-10 | low | Flim/Views/Profile/ChapterRecapViewModel.swift:227-237, low | unverified | |
| 2026-09-11 | medium | Flim/Services/ShareBreadcrumbs.swift:36 (medium) | unverified | |
| 2026-09-12 | ? | Flim/Services/RollService.swift:27, :111 | unverified | |
| 2026-09-12 | ? | supabase/functions/send-social-push/index.ts:272, 300-322, 729-772, 1048-1076 | unverified | |
| 2026-09-12 | ? | Flim/Services/PhotoService.swift:1262, 1285, 1398 | unverified | |
