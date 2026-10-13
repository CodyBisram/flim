-- The daily digest at noon on each person's own clock (owner's call, 2026-10-12). NOT YET
-- APPLIED. The owner applies it AFTER deploying send-daily-digest: this runs the job every hour,
-- and only the new function sends each person their digest at their local noon (by the zone
-- their phone reports on launch, client_versions.timezone). The old one would send everyone
-- theirs at the first hourly run past 20 hours since their last. Idempotent: safe to re-run.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flim-daily-digest') THEN
        PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'flim-daily-digest'),
                               schedule := '0 * * * *');
    END IF;
END;
$$;
