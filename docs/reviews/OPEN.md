# Open findings from the nightly review

One row per finding the nightly review has raised. The review re-verifies every row marked
`open` or `unverified` against HEAD each night and moves it to `fixed` (with the commit) or
`not a bug` (with one line why), so this file is the truth about what is still wrong, and
`docs/reviews/<date>.md` is the evidence. Seeded 2026-09-13 from thirteen review files that had
sat unread in pull requests; everything starts `unverified` and the first night triages it.

| Raised | Severity | Finding | Status | Note |
|---|---|---|---|---|
| 2026-08-27 | ? | Flim/ContentView.swift:109 | unverified | |
| 2026-08-27 | ? | Flim/Views/Rolls/RollsView.swift:357-362 | unverified | |
| 2026-08-27 | ? | Flim/Views/Feed/FeedView.swift:406 (via FeedUnitCard.swift onAuthorBlocked) | unverified | |
| 2026-08-27 | ? | Flim/Views/Profile/BadgePickerSheet.swift:643-660 | unverified | |
| 2026-08-27 | ? | Flim/Views/Rolls/RollsView.swift:398-406 and 733-739 | unverified | |
| 2026-08-27 | ? | Flim/Views/Feed/UserPageView.swift:246-266 | unverified | |
| 2026-08-27 | ? | Flim/Views/Profile/ProfileView.swift:501-507 | unverified | |
| 2026-08-28 | high | RollDetailView.swift:366 (high) | unverified | |
| 2026-08-28 | medium | RollRevealView.swift:134-137 (medium) | unverified | |
| 2026-08-28 | low | RollRevealView.swift:387 (low) | unverified | |
| 2026-08-28 | low | SharePreviewSheet.swift:310-313 (low) | unverified | |
| 2026-08-30 | ? | Flim/Views/Feed/FeedView.swift:218 | unverified | |
| 2026-08-31 | medium | Flim/Services/InstantFilmProcessor.swift:631-632 (severity: medium) | unverified | |
| 2026-09-01 | ? | `admin_overview()`'s never_asked_notifications does not match the definition its own comment claims | unverified | |
| 2026-09-01 | ? | Reveals week-over-week comparison in `admin_overview()` compares an 8-day window to a 7-day window | unverified | |
| 2026-09-03 | high | Flim/Views/Darkroom/PhotoGridCell.swift:371 (severity: high) | unverified | |
| 2026-09-03 | low | Flim/Services/RollSnapshotStore.swift:232 (severity: low) | unverified | |
| 2026-09-05 | ? | Chapter recap pager reads and writes the wrong reactions/comments table | unverified | |
| 2026-09-05 | ? | A burst pairing patch is silently and permanently dropped on a generic upload failure | unverified | |
| 2026-09-05 | ? | A second push tap for the same roll can overwrite the wrong photo's comment intent | unverified | |
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
