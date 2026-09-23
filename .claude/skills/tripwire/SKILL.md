---
name: tripwire
description: Weekly production health check, egress run-rate against the R2 trigger, Disk IO and pg_net bloat, cron cadences, push backlog. Read-only; reports PASS/ALERT per check and logs one line to docs/TRIPWIRE.md.
---

# FLIM tripwire

The standing weekly production check. Every threshold here guards a decision the owner
already made: the invite list stays closed until egress is monetized, R2 stays shelved
unless egress says otherwise, and the Disk IO incident's fixes must stay in place.
Read-only: SELECT and RPC reads only, no DDL, no DML, no deploys.

## Access

Queries go through the Supabase Management API with the token in
`~/.flim-supabase-token` (see `.claude/agents/production-analyst.md` for the exact curl
shape). A 401 means it expired: report that and stop. Prefer the `admin_*` RPCs and the tested queries in
`docs/METRICS.md` over hand-rolled SQL. Run the checks via the production-analyst agent.

## The checks

1. **Egress run-rate vs the R2 trigger.** The first line of `scripts/tripwire_check.sh`
   below is `scripts/r2_trigger_check.sh`'s own verdict. The thresholds, the 9MB session
   constant and the run-rate arithmetic live in that script and nowhere else; the Monday
   workflow `r2-tripwire.yml` runs the same file, so this is its cross-check, not a
   second implementation. Also confirm that workflow's latest run succeeded with
   `gh run list --workflow r2-tripwire.yml --limit 1`. The project is on Supabase Pro
   (250GB egress a month); the old free-tier 5GB gate is dead, do not resurrect it.
2. **The other four numbers.** Run `bash scripts/tripwire_check.sh --log` (it reads the
   service key from `~/.claude/flim-r2-watch.env`, runs the R2 check itself, and appends
   the week's line to `docs/TRIPWIRE.md`). It prints one
   PASS or ALERT line per check with the number that decided it: pg_net bloat (over
   20MB means the cleanup cron stopped; the 2026-08 incident was 110MB from per-minute
   crons), cron cadences (push crons at `*/5` and `*/2`, cleanup and the Sunday vacuum
   present and active; a reverted cadence is how the Disk IO incident starts again),
   push backlog (unsent rows older than an hour; the poll should never leave one), and
   database size against the last logged line (over 25% in a week). The thresholds live
   in the script; change them there, with the owner, never here.
3. **The one judgment.** Only the database-size check needs you: when it alerts, say
   whether the growth has a known cause (a rolls weekend, a backfill, pg_net bloat
   again) by reading `docs/NUMBERS.md` and the week's commits, and say so in the report.

## Output

A short report: the script's five lines as they came, then one sentence per ALERT saying
what it means and which decision it feeds (see above), not a proposed fix. No prose around
passing checks.

The script has already appended the week's line to `docs/TRIPWIRE.md` (creating the file
if missing), for example:

```
- 2026-08-31: egress run-rate 2.9GB/mo of 250GB PASS · pg_net 4MB PASS · crons PASS · backlog 0 PASS · db 412MB (+2%)
```

That line is the trend memory for the size check and for spotting slow drift. When you
named a cause for the size, add it in parentheses after the size figure on that line.
