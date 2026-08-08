-- ============================================================
-- Schedule the orphaned-storage sweep (pg_cron), matching the pattern in
-- 2026-08-06_authenticate_cron_invocations.sql: cron calls the Edge
-- Function over net.http_post with a real Authorization header, because
-- sweep-orphaned-storage is deployed WITH Verify JWT on (unlike the push
-- functions) -- a request with no JWT at all is rejected before it ever
-- reaches the function's own dry-run/confirm-token logic.
--
-- Replace <ANON_KEY> and <SWEEP_CONFIRM_TOKEN> below before running.
--   <ANON_KEY> unblocks Verify JWT, same key already used by the other
--     three scheduled jobs (select command from cron.job).
--   <SWEEP_CONFIRM_TOKEN> is the app-level secret set via
--     `supabase secrets set SWEEP_CONFIRM_TOKEN=<value>`, required by the
--     function itself before it will delete anything, regardless of what
--     dryRun says. Passing it here is what turns this scheduled run from a
--     report into an actual sweep.
--
-- Note (same as the other three jobs): the header/body here store both
-- values inside cron.job, readable by anyone with database access -- which
-- is already service-role-level access, so this grants nothing new.
--
-- Once daily. 09:17 UTC, not a round hour, so it doesn't stack with the
-- hourly digest/push jobs or the 13:00 invite digest.
-- ============================================================

SELECT cron.unschedule('flim-storage-sweep')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flim-storage-sweep');

SELECT cron.schedule('flim-storage-sweep', '17 9 * * *', $job$
  SELECT net.http_post(
    url := 'https://wxvwamwrjlrvqmuaafjv.supabase.co/functions/v1/sweep-orphaned-storage',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <ANON_KEY>'
    ),
    body := jsonb_build_object(
      'dryRun', false,
      'confirm', '<SWEEP_CONFIRM_TOKEN>'
    )
  );
$job$);

-- Verify:
--   select jobname, schedule, command from cron.job where jobname = 'flim-storage-sweep';
--
-- To go back to reporting only, without touching the schedule:
--   SELECT cron.alter_job(
--     (SELECT jobid FROM cron.job WHERE jobname = 'flim-storage-sweep'),
--     command := $job$ SELECT net.http_post(
--       url := 'https://wxvwamwrjlrvqmuaafjv.supabase.co/functions/v1/sweep-orphaned-storage',
--       headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer <ANON_KEY>'),
--       body := jsonb_build_object('dryRun', true)
--     ); $job$
--   );
