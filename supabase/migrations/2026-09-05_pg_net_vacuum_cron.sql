-- ============================================================
-- Migration: recurring VACUUM for net._http_response, pg_net's response
-- log table. Idempotent; safe to re-run.
--
-- WHY: pre-release audit on 2026-09-05 found net._http_response had grown
-- from 3.3 MB (2026-08-26) to 15 MB. Live row count stayed bounded (686
-- rows; pg_net's own expiry logic works), so the growth is pure bloat:
-- inserts and pg_net's own deletes leave dead tuples nothing reclaims on
-- its own. A manual VACUUM FULL just took it to 336 kB. This is the same
-- shape as the 2026-08-24 Disk IO incident, whose fix was also a one-time
-- hand vacuum with no recurring job behind it, so it silently regrew. This
-- closes that gap with a standing weekly job instead of another one-off.
--
-- CADENCE: Sunday 09:00 UTC, weekly. Clear of every other job's schedule
-- (flim-cron-cleanup 08:20 daily, flim-storage-sweep 09:17 daily,
-- flim-mark-developed and the push jobs run every 2-5 minutes but touch
-- unrelated tables) and clear of the Monday r2-tripwire.yml GitHub Actions
-- run, which is a separate, non-database system on a different day.
--
-- LOCK: VACUUM (FULL, ...) takes ACCESS EXCLUSIVE on net._http_response for
-- its duration. Nothing in this app reads that table (it is pg_net's own
-- internal response log, written asynchronously by the extension) and
-- nothing in this app writes to it either, so a few seconds of exclusivity
-- at 09:00 UTC on a Sunday has no user-visible effect.
--
-- TRANSACTION: VACUUM cannot run inside a transaction block. pg_cron does
-- not wrap a scheduled command in one; each job's command runs as its own
-- top-level statement, the same as typing it into psql with autocommit on.
-- This project already has direct proof of exactly that: the runaway
-- 'one-shot-vacuum-2' job retired in 2026-08-28_cron_hygiene.sql was
-- `VACUUM FULL cron.job_run_details` scheduled '* * * * *', and it ran
-- successfully every minute for days (that is WHY it had to be hand
-- unscheduled, not because it errored). Same mechanism, same role, same
-- project, so VACUUM (FULL, ANALYZE) here needs no fallback to plain
-- VACUUM (ANALYZE).
--
-- Idempotent: unschedule-then-schedule, matching the pattern in
-- 2026-08-28_cron_hygiene.sql and 2026-08-24_disk_io_cron_hygiene.sql.
-- ============================================================

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'flim-net-response-vacuum';

SELECT cron.schedule(
    'flim-net-response-vacuum',
    '0 9 * * 0',
    $job$VACUUM (FULL, ANALYZE) net._http_response$job$
);

-- Verify:
--   select jobname, schedule, command from cron.job where jobname = 'flim-net-response-vacuum';
--   -- after it has run at least once:
--   select * from cron.job_run_details where jobid = (select jobid from cron.job where jobname = 'flim-net-response-vacuum') order by start_time desc limit 5;
