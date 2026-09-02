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

Queries go through the Supabase Management API with a token the owner supplies in the
current conversation (see `.claude/agents/production-analyst.md` for the exact curl
shape). Tokens rotate roughly daily; if none was provided, ask for today's token before
doing anything else. Prefer the `admin_*` RPCs and the tested queries in
`docs/METRICS.md` over hand-rolled SQL. Run the checks via the production-analyst agent.

## The checks

1. **Egress run-rate vs the R2 trigger.** The project is on Supabase Pro: 250GB egress
   per month included (decided 2026-08-21; the free-tier 5GB gate is dead, do not
   resurrect it). Compute the modeled monthly RUN-RATE exactly as the dashboard's
   Ceilings gauge does: (app opens last 7 days / 7) x 30 x 9MB. Report it as a run-rate,
   never as a month projection; the month-to-date figure is a floor and says so. ALERT
   if the run-rate exceeds 100GB/month, which is the owner-ratified R2 trigger. The
   Monday GitHub workflow `r2-tripwire.yml` (scripts/r2_trigger_check.sh) automates this
   same threshold; this check is the cross-check, so also confirm that workflow's most
   recent run succeeded. The 9MB constant is a measured cold-cache session; if the owner
   supplies the dashboard's real egress figure, recalibrate it rather than trusting it.
2. **pg_net bloat.** Size of `net._http_response`. The 2026-08 incident was 110MB of
   response rows from per-minute crons. ALERT above 20MB, which means the cleanup cron
   has stopped doing its job.
3. **Cron cadences.** Read `cron.job`. The push crons must be at `*/5` and `*/2`, and the
   pg_net cleanup job must exist and be scheduled. ALERT on any drift; a reverted cadence
   is how the Disk IO incident starts again.
4. **Push backlog.** Rows eligible for a push (`push_sent` poll pattern) older than one
   hour and still unsent. ALERT above zero; the poll should never leave a backlog.
5. **Database size trend.** Total DB size now; note the delta against the last line in
   `docs/TRIPWIRE.md`. ALERT on more than 25% week-over-week growth with no known cause.

## Output

A short report: one line per check, `PASS` or `ALERT` with the number that decided it.
No prose around passing checks. Every ALERT gets one sentence of what it means and which
decision it feeds (see above), not a proposed fix.

Then append exactly one line to `docs/TRIPWIRE.md` (create the file with a one-line
header if missing):

```
- 2026-08-31: egress mtd 1.2GB, run-rate 2.9GB/mo PASS · pg_net 4MB PASS · crons PASS · backlog 0 PASS · db 412MB (+2%)
```

The log line is the trend memory for check 5 and for spotting slow drift; never skip it.
