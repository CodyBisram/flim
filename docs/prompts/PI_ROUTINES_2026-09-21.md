# Prompt for the Pi session, 2026-09-21

Paste the block below into a Claude Code session on the Raspberry Pi, in `~/work/flim`.

```
You are working on the Raspberry Pi that runs FLIM's scheduled jobs. The repo is cloned at
~/work/flim on main; you commit as "Cody Bisram (pi)" with a fine-grained token scoped to this
repo. Read docs/ROUTINES.md first: it is the source of truth for everything that runs here, and
you will update it as you go. Today is 2026-09-21.

Rules that never bend:
- No mention of Claude, AI, assistants or tools anywhere in repo content: not in commits, not in
  Co-Authored-By trailers, not in code comments, SQL, docs or prompts you store. The Pi's commits
  carry no trailer at all.
- No em dashes in anything you write, anywhere.
- This machine cannot build Swift. Any change to app code goes on a branch and opens a pull
  request; the ios-testflight workflow's build-and-test job is the verifier and the owner merges.
  Never push app code to main from here.
- Docs and ledger commits go straight to main, as the review and the memo already do.
- Never send a push, an email, or a social post. Never run a migration against production.
  If a task needs one, write the SQL to a file, say so, and stop that task.
- Secrets stay where they are. Do not print a token, a key or a connection string; do not copy
  one into the repo or into a prompt file.

Do these in order. Verify each before starting the next, and finish with the report format at
the end.

1. RETIRE THE SOCIAL DRAFTS JOB. Open the crontab (crontab -l) and remove the Monday 08:00 line
   that runs the social drafts. docs/ROUTINES.md already records the job as retired 2026-09-21;
   confirm the table no longer lists it and that nothing else on this machine references that
   job (a systemd timer, a wrapper script under ~/work or ~/bin). Leave social/drafts/ and the
   /social-drafts skill in place.

2. THE LEDGER BURN, SUNDAYS 06:00. docs/reviews/OPEN.md is the nightly review's ledger. Add a
   weekly job that:
   - reads every row marked open, and picks the ones a person can hit in normal use that are
     small (under about thirty minutes each: one file, one rule, one test). Skip anything
     touching auth, RLS, the capture pipeline, InstantFilmProcessor, the look, money, or
     deletion; those are the owner's.
   - fixes them on a branch named burn/<date>, one commit per row, each commit message naming
     the row's date and file the way the ledger does, with a unit test where the rule is pure
     (the existing FlimTests show the shape; a new test file needs `xcodegen generate` and the
     regenerated Flim.xcodeproj/project.pbxproj committed with it, or it never runs).
   - opens one pull request titled "Ledger burn, week of <Mon DD>" whose body lists each row
     fixed and each row looked at and left, with one line why. The PR is the deliverable; CI
     verifies; the owner merges. Do not mark rows fixed in OPEN.md; the nightly review does
     that itself once the merge lands.
   - stops at five rows a week. A branch that cannot be finished is deleted, not left open.
   The /backlog-burn skill in .claude/skills is most of this already; read it and reuse its
   discipline (verified before handed off, never pushed to main). Add the job to the ROUTINES.md
   table and put its prompt under the prompts section there, verbatim, the way the review's is.

3. THE WEBHOOK RECEIVER RESPONDS. The receiver at hooks.flim-app.com already gets a POST for
   every row the pi_hook_* triggers fire on (read supabase/migrations/2026-09-15_pi_hooks.sql
   for the exact tables and the header secret it checks). Right now it only receives. Add three
   handlers, each writing one short note to wherever the receiver already delivers to the owner
   (find it; do not invent a new channel):
   a. A new public.users row: who invited them (invite_campaigns or the personal code), how many
      people they will already know on day one (the invite tree the Find friends screen uses:
      roll mates, the inviter, the inviter's follows), and their client version once it reports.
      One line. Never include their email; the payload carries it, drop it at the door.
   b. A new photo_reports or user_reports row: the reported item's owner and reporter as
      usernames, the reason, the photo's roll or page, and a drafted call in one sentence
      ("hide and warn", "no action, here is why"). Nothing is actioned; the owner decides.
   c. A new crash_diagnostics row whose kind is a crash or hang (not breadcrumb): triage it
      against docs/CRASH_TRIAGE.md, name the top frame and the build, and say whether it
      matches an open ledger row. If the receiver cannot symbolicate, say so once and stop.
   The handlers must be idempotent (a redelivered webhook writes nothing twice) and must never
   block the receiver's 200 response; do the work after acknowledging. Test each with a replayed
   payload from the receiver's own log before calling it done. Record the three in ROUTINES.md.

4. THE MEMO READS THE LIVE DATABASE. The Monday 07:30 memo is written from docs/NUMBERS.md.
   Give it the eleven questions the 2026-09-21 audit's data pass answered (docs/PENDING.md, the
   "done 2026-09-21" blocks, and docs/METRICS.md for the tested SQL): seven-day uniques against
   the seven before, first-open cohort retention, adoption by build, rolls created and follow-up
   rolls, push coverage and the never-answered notification ask, renditions missing, photos per
   day and storage, invite campaign redemptions and signups by source, reciprocal pairs and how
   many run through the owner, reports/blocks/crashes/edge errors, and cron health.
   Credentials: look for a database credential this machine already holds for the receiver or
   the numbers. If it holds the service key, use it through PostgREST or psql read-only. If it
   holds only the management token, note that it rotates daily and stop this task with the SQL
   for the owner to create a read-only role:
     create role flim_reader login password '<owner sets this>' ;
     grant usage on schema public to flim_reader;
     grant select on all tables in schema public to flim_reader;
     alter default privileges in schema public grant select on tables to flim_reader;
   Never hand-roll a count that docs/METRICS.md already has; the traps there (PostgREST's 1000
   row cap, the funnel's cohort scoping, shots versus posts) have all bitten before. The memo's
   "The number" section stays; add a "What the database says" section under it, tables only,
   one line of reading each.

5. SCRIPT THE DEVICE TEST. When a TestFlight build finishes processing, send the owner the
   checklist for it. The App Store review watcher on this machine already polls App Store
   Connect; reuse its credential and cadence to notice a new build for the app (id6786079629)
   reaching a processed state. The checklist is the "owed on device" or "On device:" list in the
   newest "done" block of docs/PENDING.md that names that build's train; if the newest block has
   none, say "nothing owed on device for this build" and stop. One message per build, never
   repeated. If the watcher has no App Store Connect API key (only a public-page poll), fall
   back to the GitHub Actions run: a green ios-testflight run on main, plus ninety minutes.
   Record it in ROUTINES.md.

Then run the whole schedule once by hand where that is safe (the burn on a dry branch you then
delete; the handlers on replayed payloads; the memo query set without writing a memo; the
checklist against build 394, which is owed exactly the eight checks in the newest PENDING block)
and confirm crontab -l shows the review, the memo, the burn, and nothing for social.

Report in this format and nothing else:

STATUS: COMPLETE | BLOCKED | NEEDS OWNER ACTION
CHANGED: path: reason, one per line (crontab and files outside the repo included)
VERIFIED: exact command or check: PASS | FAIL | NOT RUN
NOT VERIFIED: item: reason
RISKS: concrete only, or NONE
HANDOFF: what the owner must do (the read-only role, a credential, a merge), or NONE
```
