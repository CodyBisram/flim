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
| 02:07 daily | Nightly review (the prompt below); on a night with no commits it deep-audits one module in rotation instead | Raspberry Pi, Claude Code | `docs/reviews/<date>.md` for new findings, `docs/reviews/OPEN.md` re-verified, committed to main |
| 00:20 daily | Nightly numbers + rendition repair | GitHub Actions `nightly-numbers.yml` (GitHub's cron is best-effort; it has run up to five hours late) | one line appended to `docs/NUMBERS.md`; an `ops_alerts` row (so a push to the owner) when something is broken; then `scripts/repair_renditions.py` rebuilds any thumb or feed card a capture lost |
| Mon 07:30 | Product memo | Raspberry Pi, Claude Code | `docs/memos/<date>.md`, committed to main |
| Mon 09:07 | R2 tripwire | GitHub Actions `r2-tripwire.yml` | silent while quiet, fails (email) when a migration trigger fires |
| every 2 min | Social push | pg_cron `flim-social-push` | pushes, `push_deliveries`, drains `ops_alerts` to the owner |
| every 5 min | Develop push, mark developed | pg_cron `flim-develop-push`, `flim-mark-developed` | roll-developed pushes |
| hourly 10:00 to 21:00 | Daily digest | pg_cron `flim-daily-digest` | one digest push per person per day |
| 04:20 daily | pg_net cleanup | pg_cron `flim-cron-cleanup` | keeps `net._http_response` small (runs BEFORE a late numbers job can read the day; see the numbers row) |
| 05:17 daily | Storage sweep | pg_cron `flim-storage-sweep` | orphaned objects removed, `ops_alerts` on surprises |
| Sun 05:00 / 05:30 | pg_net vacuum, invite rate sweep | pg_cron | housekeeping |
| always | Uptime Kuma on flim-app.com, the AASA file, Supabase; App Store review watcher; webhook receiver at hooks.flim-app.com fed by `pi_hook_*` database triggers on crash_diagnostics, ops_alerts, user_reports, users, activation_events (applied in the SQL editor, not a migration) | Raspberry Pi | pushes to the owner, independent of the social-push path |

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

These are the prompts the Pi runs (the review verbatim; the memo's prompt lives on the Pi and
is not recorded here yet). Keep them in sync with what is live; a change here is a change
there, by the owner's hand.

### Nightly review (`trig_016sRvtGxYpPVyN3mXtEHi2v`)

```
You are the nightly code reviewer for FLIM, the iOS app in this repository (Swift/SwiftUI app in Flim/, tests in FlimTests/, Supabase backend in supabase/, edge functions in supabase/functions/). You have two jobs every night, and you commit the result straight to main under docs/reviews/ (that folder is ignored by CI, so your commits cost nothing and nobody has to merge them).

JOB 1, review what changed. Run git log --since='24 hours ago' on the checked-out main. If there are commits, take their combined diff and review it adversarially for CORRECTNESS ONLY: logic errors, state staleness, index-vs-id keying mistakes, races around await boundaries, off-by-one and boundary errors (this app has a 04:00 day boundary in FeedUnit.dayKey, not midnight), RLS or grant changes that widen what a user can read or write, and edge function paths that can double-send or never send a push. Read enough surrounding code to verify each candidate finding is real; discard anything you cannot support with a concrete failure scenario (specific inputs or state leading to specific wrong behavior). No style notes, no generic cautions, no praise. Before writing a finding, check docs/reviews/OPEN.md: if the same defect is already a row there, do not add it again. If findings survive, write docs/reviews/<today YYYY-MM-DD>.md with, for each finding: file:line, a one-sentence defect statement, the failure scenario, and severity (high/medium/low), most severe first; then add one row per finding to the table in docs/reviews/OPEN.md with Raised = today, the severity, a Finding cell that names the file:line AND states the defect in one clause (never a bare file path), Status = open, and an empty Note. If there are no commits, or no findings survive, write no dated file.

JOB 2, re-verify the ledger. docs/reviews/OPEN.md is the list of findings still believed to be wrong. Read every row whose Status is open or unverified. For each, find the evidence in docs/reviews/<Raised date>.md, then check the CURRENT code on main and decide: fixed (the defect no longer exists; put the short hash of the commit that fixed it in Note, found with git log -S or git log -L or git log -- <file>), not a bug (the failure scenario does not hold; put one sentence why in Note), or open (still real; if Status was unverified, change it to open, fill in the Severity if it is '?', and rewrite the Finding cell so it states the defect, not just a path). If a row's file:line moved, update the Finding cell to the current location. Do at most 20 unverified rows per night, oldest first, so the run stays bounded; open rows are cheap and you re-check all of them every night. Never delete a row; the ledger is the history. Keep the table sorted by Raised date. Keep the header paragraph as it is.

COMMIT. If anything changed under docs/reviews/, commit it on main with the one-line message 'Review notes for <Mon DD>: N new, M fixed, K open.' where N is new findings tonight, M is rows you moved to fixed or not a bug, and K is rows still open after tonight; if there are no new findings, the message is 'Review ledger for <Mon DD>: M fixed, K open.' Use NO tool or assistant attribution of any kind (no Co-Authored-By, no generated-with lines, nothing naming an AI anywhere). Then run git pull --rebase origin main and git push origin main; if the push is rejected, pull --rebase and push again, up to three times. Never open a branch or a PR. Touch nothing outside docs/reviews/. Never modify app code, never merge anything, never comment on PRs or issues. Use no em dashes anywhere in anything you write.
```

### Social drafts: retired 2026-09-21

The weekly draft batch ran on the Pi from 2026-09-14 (`social/drafts/<date>.md`, Buffer as the
send gate). Retired on the owner's word: nothing drafted was ever sent, so the job produced files
and nothing else. The past drafts stay in `social/drafts/`; the `/social-drafts` skill stays
callable by hand for a launch week. The Pi's crontab line for it is removed by the owner.
