# What runs on a schedule

Everything that fires without a person, what it produces, and where to look. Reworked
2026-09-13: the nightly review and the weekly social drafts used to open a pull request each
(fifteen sat unread for two weeks); they now commit straight to main into CI-ignored folders,
and the review keeps a ledger it re-verifies every night. A nightly numbers job was added.

Moved 2026-09-14: the review, the social drafts (retired 2026-09-21) and a new weekly product memo run on the
owner's Raspberry Pi (a clone at `~/work/flim`, a fine-grained token scoped to this repo,
committing as `Cody Bisram (pi)` so git log tells the Pi from the owner and from the old cloud
runs). The two claude.ai routines (`trig_016sRvtGxYpPVyN3mXtEHi2v` review,
`trig_016yUs6HtUepKBwDDNYvLeft` social) were disabled the same day at 15:49 ET and stay off:
there is exactly one reviewer. The five "check on PR #N" reminders are disabled too.

| When (ET) | What | Where it runs | Output |
|---|---|---|---|
| 02:07 daily | Nightly review (the prompt below); on a night with no commits it deep-audits one module in rotation instead | Raspberry Pi | `docs/reviews/<date>.md` for new findings, `docs/reviews/OPEN.md` re-verified, committed to main |
| 00:20 daily | Nightly numbers + rendition repair | GitHub Actions `nightly-numbers.yml` (GitHub's cron is best-effort; it has run up to five hours late) | one line appended to `docs/NUMBERS.md`; an `ops_alerts` row (so a push to the owner) when something is broken; then `scripts/repair_renditions.py` rebuilds any thumb or feed card a capture lost |
| Mon 07:30 | Product memo | Raspberry Pi | `docs/memos/<date>.md`, committed to main. A "What the database says" section reads `public.memo_snapshot()` through the read-only role (below) |
| Sun 06:00 | Ledger burn (the prompt below): up to five small open ledger rows a person can hit, fixed one commit each on `burn/<date>`, one pull request | Raspberry Pi | PR "Ledger burn, week of <Mon DD>"; CI verifies, the owner merges; `OPEN.md` is left for the nightly review to update once the merge lands. Never main. Added 2026-09-21 |
| every 30 min | TestFlight build checklist: a green `ios-testflight` run on main plus ninety minutes is a processed build (the App Store Connect key on the Pi is Sales and Reports only, so `/v1/builds` is closed to it); the build number is read from the run's log | Raspberry Pi | one push per build, never repeated, with the "On device:" list from the newest done block in `docs/PENDING.md` that names the build's train, or "nothing owed on device for this build". Added 2026-09-21 |
| Mon 09:07 | R2 tripwire | GitHub Actions `r2-tripwire.yml` | silent while quiet, fails (email) when a migration trigger fires |
| every 2 min | Social push | pg_cron `flim-social-push` | pushes, `push_deliveries`, drains `ops_alerts` to the owner |
| every 5 min | Develop push, mark developed | pg_cron `flim-develop-push`, `flim-mark-developed` | roll-developed pushes |
| hourly 10:00 to 21:00 | Daily digest | pg_cron `flim-daily-digest` | one digest push per person per day |
| 04:20 daily | pg_net cleanup | pg_cron `flim-cron-cleanup` | keeps `net._http_response` small (runs BEFORE a late numbers job can read the day; see the numbers row) |
| 05:17 daily | Storage sweep | pg_cron `flim-storage-sweep` | orphaned objects removed, `ops_alerts` on surprises |
| Sun 05:00 / 05:30 | pg_net vacuum, invite rate sweep | pg_cron | housekeeping |
| always | Uptime Kuma on flim-app.com, the AASA file, Supabase; App Store review watcher; webhook receiver at hooks.flim-app.com fed by `pi_hook_*` database triggers on crash_diagnostics, ops_alerts, user_reports, users, activation_events (applied in the SQL editor, not a migration); since 2026-09-21 the receiver answers three of them (below) | Raspberry Pi | pushes to the owner, independent of the social-push path |

## The receiver's answers

The receiver at hooks.flim-app.com answers the webhook with 204 first and does its work on a
thread afterwards, so a slow lookup never holds the database trigger. Every `table:id` it has
handled is remembered on disk, so a redelivered webhook writes nothing twice. Each payload is
appended to a log on the Pi with the email dropped before it touches disk, so any event can be
replayed for a test. Three inserts get an answer, not just an announcement (added 2026-09-21):

- **A new `users` row.** One line: who invited them and how many people they will already know on
  day one (the same set the Find friends screen ranks: the inviter, the inviter's other invitees,
  the inviter's follows, and roll mates), and the client version once it reports, all from a
  single call to `public.receiver_lookup(user_id)` (the `allowed_emails` note that `redeem_invite`
  writes, resolved to a username; a cohort code is named alongside it when the inviter had one
  live at signup, otherwise it was the personal code). The email in the payload is never pushed,
  logged or queried by value, and `receiver_lookup` never returns it either.
- **A new `user_reports` row** (and `photo_reports`, once its trigger exists: the SQL is in
  `docs/sql/pi_hook_photo_reports.sql`, to be run in the SQL editor and mirrored by the owner).
  Reporter and reported as usernames, the reason, the photo's roll or the page, and a drafted
  call in one sentence that starts "hide and warn" or "no action, here is why". Nothing is
  actioned; the owner decides.
- **A new `crash_diagnostics` row of kind crash, hang or cpuException** (breadcrumb rows are UI
  traces and are skipped). The build, device and OS, when it occurred versus when it was uploaded,
  the signal read the way `docs/CRASH_TRIAGE.md` reads it, and the deepest frame as binary plus
  offset. The Pi cannot symbolicate (the dSYM is a workflow artifact and `atos` is a macOS tool),
  which the note says once per build; until a frame is symbolicated on the Mac no ledger row is
  claimed as a match.

The inviter, day-one and username lookups need a database credential the Pi does not have
today. `public.receiver_lookup(uuid)` (migration `2026-09-22_pi_reader.sql`) answers the whole
line in one call; `docs/sql/flim_reader_role.sql` creates the read-only role that can call it.
Until the owner applies the migration, runs that script and hands the Pi the pooler URI, those
parts of the line say so and the rest still arrives.

## The memo on live data

`public.memo_snapshot()` (migration `2026-09-22_pi_reader.sql`) answers the eleven questions the
2026-09-21 audit's data pass raised in one JSON document, reshaped from the tested SQL in
`docs/METRICS.md` and the `admin_*` functions rather than a hand-rolled count: seven-day uniques
against the seven before, first-open cohort retention, adoption by build, rolls created and
follow-up rolls, push coverage and the never-answered notification ask, renditions missing,
photos per day and storage, invite campaign redemptions and signups by day, reciprocal pairs and
how many run through the owner, reports/blocks/crashes/edge errors, and cron health. The Monday
memo keeps its "The number" section and gains "What the database says" under it, one line of
reading per key. Waiting on the same read-only role as the receiver: the Pi holds no service key
and no management token, so nothing of this runs until the owner applies the migration, runs
`docs/sql/flim_reader_role.sql` and hands the Pi the pooler URI.

## The ledger

`docs/reviews/OPEN.md` is the truth about what the reviewer still believes is wrong. Rows move
to `fixed` (with the commit) or `not a bug` (with why) as the nightly run re-checks them against
HEAD; nothing is deleted. Read it before a release. The commit message each night carries the
counts ("Review notes for Sep 14: 2 new, 5 fixed, 30 open") so `git log docs/reviews` is the
trend.

## The numbers

`docs/NUMBERS.md` gets one row a day: accounts, new accounts, openers (and the trailing week
average), shooters, photos, posts, reactions, comments, follows, rolls created, reveals watched,
invites redeemed, Founding 100 left, database MB, storage GB. The alert conditions (a capture
still missing renditions an hour later, a developed roll nobody was told about, a push that gave
up, a cron failure, a non-200 edge response, a crash row, an open report) are in
`scripts/nightly_numbers.sh`; they land as an `ops_alerts` row, and the social push turns that
into a push to the owner within two minutes. A quiet day raises nothing. To run it by hand:

```
FLIM_SERVICE_KEY=... bash scripts/nightly_numbers.sh
```

## Routine prompts

These are the prompts the Pi runs (the review and the burn verbatim; the memo's prompt lives on the Pi and
is not recorded here yet). Keep them in sync with what is live; a change here is a change
there, by the owner's hand.

### Nightly review (`trig_016sRvtGxYpPVyN3mXtEHi2v`)

```
You are the nightly code reviewer for FLIM, the iOS app in this repository (Swift/SwiftUI app in Flim/, tests in FlimTests/, Supabase backend in supabase/, edge functions in supabase/functions/). You have two jobs every night, and you commit the result straight to main under docs/reviews/ (that folder is ignored by CI, so your commits cost nothing and nobody has to merge them).

JOB 1, review what changed. Run git log --since='24 hours ago' on the checked-out main. If there are commits, take their combined diff and review it adversarially for CORRECTNESS ONLY: logic errors, state staleness, index-vs-id keying mistakes, races around await boundaries, off-by-one and boundary errors (this app has a 04:00 day boundary in FeedUnit.dayKey, not midnight), RLS or grant changes that widen what a user can read or write, and edge function paths that can double-send or never send a push. Read enough surrounding code to verify each candidate finding is real; discard anything you cannot support with a concrete failure scenario (specific inputs or state leading to specific wrong behavior). No style notes, no generic cautions, no praise. Before writing a finding, check docs/reviews/OPEN.md: if the same defect is already a row there, do not add it again. If findings survive, write docs/reviews/<today YYYY-MM-DD>.md with, for each finding: file:line, a one-sentence defect statement, the failure scenario, and severity (high/medium/low), most severe first; then add one row per finding to the table in docs/reviews/OPEN.md with Raised = today, the severity, a Finding cell that names the file:line AND states the defect in one clause (never a bare file path), Status = open, and an empty Note. If there are no commits, or no findings survive, write no dated file.

JOB 2, re-verify the ledger. docs/reviews/OPEN.md is the list of findings still believed to be wrong. Read every row whose Status is open or unverified. For each, find the evidence in docs/reviews/<Raised date>.md, then check the CURRENT code on main and decide: fixed (the defect no longer exists; put the short hash of the commit that fixed it in Note, found with git log -S or git log -L or git log -- <file>), not a bug (the failure scenario does not hold; put one sentence why in Note), or open (still real; if Status was unverified, change it to open, fill in the Severity if it is '?', and rewrite the Finding cell so it states the defect, not just a path). If a row's file:line moved, update the Finding cell to the current location. Do at most 20 unverified rows per night, oldest first, so the run stays bounded; open rows are cheap and you re-check all of them every night. Never delete a row; the ledger is the history. Keep the table sorted by Raised date. Keep the header paragraph as it is.

COMMIT. If anything changed under docs/reviews/, commit it on main with the one-line message 'Review notes for <Mon DD>: N new, M fixed, K open.' where N is new findings tonight, M is rows you moved to fixed or not a bug, and K is rows still open after tonight; if there are no new findings, the message is 'Review ledger for <Mon DD>: M fixed, K open.' Use NO tool or assistant attribution of any kind (no Co-Authored-By, no generated-with lines, nothing naming an AI anywhere). Then run git pull --rebase origin main and git push origin main; if the push is rejected, pull --rebase and push again, up to three times. Never open a branch or a PR. Touch nothing outside docs/reviews/. Never modify app code, never merge anything, never comment on PRs or issues. Use no em dashes anywhere in anything you write.
```

### Ledger burn (Sunday 06:00, `flim-burn.timer`)

The Pi's job runner replaces `__DATE__` with today's date and `__WEEK__` with the coming Monday
("Sep 28") before the run. A dry run by hand (`DRY=1 flim-job.sh burn`) removes the push URL and
the GitHub token first, so it cannot push whatever the run decides; the branch is inspected and
deleted afterwards. The first dry run, 2026-09-21, produced five commits on `burn/2026-09-21`
(each named the way the ledger names the row, no trailers), and showed that the fine-grained
token cannot open a pull request yet; the branch was deleted.

```
You are the weekly ledger burn for FLIM, the iOS app in this repository (Swift/SwiftUI app in Flim/, tests in FlimTests/, Supabase backend in supabase/). You run on a machine that cannot build Swift. The ios-testflight workflow's build-and-test job is the verifier and the owner merges; your deliverable is one pull request, or nothing.

PICK. Read docs/reviews/OPEN.md and take every row whose Status is open. Keep the ones a person can hit in normal use AND that are small: one file, one rule, one test, under about thirty minutes of work. Skip, without exception, any row that touches auth (AuthService, sign-in, AccountEpoch), RLS or grants or anything under supabase/, the capture pipeline (PhotoService upload and retry paths, CaptureQueueStore, FailedUploadStore, BurstGrouping), InstantFilmProcessor or LUTs or FilmStock or anything about the look, money (invite quotas, Founding 100, earnbacks, campaigns), or deletion of anything. Those are the owner's. Skip any row whose finding contradicts an owner decision recorded in docs/PENDING.md; name the decision in the pull request body instead. Skip any row that an open pull request on the repository already fixes (gh pr list). Stop at five rows.

If nothing qualifies, print "ledger burn: nothing small and safe this week" and stop. Create no branch, open no pull request.

BRANCH. Start from the freshly reset main and run git checkout -b burn/__DATE__. Fix one row at a time. For each row: read its evidence in docs/reviews/<Raised date>.md and the current code, make the smallest change that removes the defect, and add a unit test when the rule is pure (a function with no UI and no network; the FeedUnit, RollImminence and BurstGrouping tests in FlimTests/ show the shape). Put a new test in an EXISTING FlimTests file that already covers that type or its nearest neighbour. This machine cannot run xcodegen, so a brand-new test file would never be added to Flim.xcodeproj and would never run; if a row needs a new file, leave the row and say why. Commit each row on its own. The message is one plain line naming the row the way the ledger does: "Ledger <Raised date>, <file>: <what changed>." Use no attribution trailer of any kind. Do not touch docs/reviews/OPEN.md; the nightly review moves the row once the merge lands. Change nothing outside the files the row names and the one test file that covers them.

CHECK. Before handing off, for each commit: git show --stat shows only the files the row names plus at most one test file; the Swift is plausible by inspection (balanced braces, every symbol you reference exists in the repository, confirmed with grep, no force unwraps you added); there is no em dash anywhere in what you wrote. A row you cannot finish inside these rules is undone with git reset --hard to the previous commit and listed as left, with one line why. If no commit survives, delete the branch (git checkout main; git branch -D burn/__DATE__) and stop; open no pull request.

HAND OFF. Run git push -u origin burn/__DATE__ and open exactly one pull request against main with gh pr create, titled "Ledger burn, week of __WEEK__". The body has two lists. "Fixed": one line per row with its Raised date, the file, what changed, and whether a test was added. "Looked at and left": one line per open row you considered and did not take, and why. End the body with the sentence "CI is the verifier; nothing here was built locally." Never merge, never push to main, never comment on other pull requests or issues, never send anything anywhere else. Use no em dashes anywhere in anything you write.
```

### Social drafts: retired 2026-09-21

The weekly draft batch ran on the Pi from 2026-09-14 (`social/drafts/<date>.md`, Buffer as the
send gate). Retired on the owner's word: nothing drafted was ever sent, so the job produced files
and nothing else. The past drafts stay in `social/drafts/`; the `/social-drafts` skill stays
callable by hand for a launch week. The Pi ran it from a systemd user timer, not a crontab line;
`flim-social.timer` and its service were disabled and deleted on 2026-09-21, the `social` case was
removed from the Pi's job runner, and the prompt copy on the Pi was deleted.
