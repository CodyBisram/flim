---
name: tripwire
description: Weekly production health check — egress vs the 5GB launch gate, Disk IO and pg_net bloat, cron cadences, push backlog. Read-only; reports PASS/ALERT per check and logs one line to docs/TRIPWIRE.md.
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

1. **Egress vs the launch gate.** Current calendar month's egress total, and a straight-
   line projection to month end. ALERT if the projection exceeds 4GB (80% of the 5GB free
   tier). This is also the R2 tripwire: an ALERT here is the signal that re-opens the R2
   conversation, per the 1.5 direction. Do not re-propose R2 on a PASS.
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
- 2026-08-31: egress 1.2GB (proj 2.9GB) PASS · pg_net 4MB PASS · crons PASS · backlog 0 PASS · db 412MB (+2%)
```

The log line is the trend memory for check 5 and for spotting slow drift; never skip it.
