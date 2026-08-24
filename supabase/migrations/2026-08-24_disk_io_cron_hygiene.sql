-- ============================================================
-- Migration: cron cadence + plumbing hygiene, after the Disk IO
-- Budget warning of 2026-08-24. ALREADY APPLIED to production by
-- hand that day; this file records the state so it is re-runnable
-- on a fresh project. Safe to re-run.
--
-- WHY: pg_stat_statements showed the IO budget was being spent by
-- the push PLUMBING, not the app. Two crons ran every minute
-- (flim-social-push, flim-develop-push), 2,880 runs/day, each run
-- writing four bookkeeping rows to cron.job_run_details (~600K
-- administrative writes on record) and posting via pg_net. On top:
-- net._http_response had bloated to 110 MB while holding 720 rows,
-- and job_run_details grew unbounded. FLIM's own queries did not
-- appear in the top disk readers OR writers.
--
-- THE TRADE, accepted by the owner 2026-08-24: develop pushes may
-- arrive up to 5 minutes after a reveal (the develop is scheduled
-- 12h ahead; nobody can tell), social pushes up to 2 minutes after
-- the act. Each halving of cadence halves that slice of the bill.
-- ============================================================

-- 1. Cadence: develop-push every 5 minutes, social-push every 2.
--    (Job ids differ per project; match on jobname when re-running.)
DO $$
DECLARE
    develop_id BIGINT;
    social_id  BIGINT;
BEGIN
    SELECT jobid INTO develop_id FROM cron.job WHERE jobname = 'flim-develop-push';
    SELECT jobid INTO social_id  FROM cron.job WHERE jobname = 'flim-social-push';
    IF develop_id IS NOT NULL THEN
        PERFORM cron.alter_job(develop_id, schedule := '*/5 * * * *');
    END IF;
    IF social_id IS NOT NULL THEN
        PERFORM cron.alter_job(social_id, schedule := '*/2 * * * *');
    END IF;
END $$;

-- 2. Bound the bookkeeping: keep three days of cron run history.
--    Scheduled at 08:20 UTC, off the hour so it never contends with
--    the digest's top-of-hour runs.
DELETE FROM cron.job_run_details WHERE end_time < now() - interval '3 days';
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flim-cron-cleanup') THEN
        PERFORM cron.schedule('flim-cron-cleanup', '20 8 * * *',
            $job$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '3 days'$job$);
    END IF;
END $$;

-- 3. One-time space reclamation, done by hand 2026-08-24 because
--    VACUUM cannot run inside the SQL editor's transaction wrapper.
--    The workaround that worked: schedule it as a one-shot cron job
--    (cron runs outside a transaction), wait a minute, unschedule.
--    Results that day: net._http_response 110 MB -> 864 KB,
--    cron.job_run_details -> ~5 MB. Not needed routinely; the
--    cleanup job above prevents the regrowth.
--
--    SELECT cron.schedule('one-shot-vacuum', '* * * * *',
--        $job$VACUUM FULL net._http_response$job$);
--    -- wait one minute --
--    SELECT cron.unschedule('one-shot-vacuum');
