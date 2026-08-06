-- ============================================================
-- Authenticate the scheduled Edge Function calls, so Verify JWT can be turned on
--
-- READ THIS BEFORE RUNNING. Doing half of it breaks every notification in the app.
--
-- The situation
-- -------------
-- docs/LAUNCH_RUNBOOK.md says send-social-push should have Verify JWT enabled.
-- Production has it disabled, and that is currently the ONLY reason notifications
-- work at all: all three cron jobs call the functions with no Authorization header.
--
--   select jobname, command from cron.job;
--   -> SELECT net.http_post(url := 'https://<ref>.supabase.co/functions/v1/send-social-push');
--
-- No headers. Turning Verify JWT on today would silently kill develop pushes, social
-- pushes and the daily digest at once, and nothing in the app would report it: the
-- functions would start returning 401 to a cron job that ignores the response.
--
-- So the runbook is not wrong about the destination, it is just describing a state
-- the scheduler was never updated to match. This file moves the scheduler.
--
-- What this costs you
-- -------------------
-- Leaving Verify JWT off means anyone who knows the function URL can invoke it. They
-- cannot read data or inject content — the function only sends pushes derived from
-- rows that already exist — but they can burn your function invocations, and on the
-- free tier that is a quota worth protecting.
--
-- ORDER (do not reorder)
-- ----------------------
--   1. Run this file. Cron now sends the service role key.
--   2. Wait 2 minutes, then confirm pushes still fire:
--
--        select count(*) from follows where push_sent = false;   -- should stay 0
--
--      and check Edge Function logs show 200s, not 401s.
--   3. ONLY THEN, in Dashboard -> Edge Functions, enable Verify JWT on
--      send-social-push, send-develop-push and send-daily-digest.
--   4. Confirm 200s again. If anything 401s, disable Verify JWT immediately;
--      the pushes resume and you have lost nothing.
--
-- Replace <SERVICE_ROLE_KEY> below before running. Dashboard -> Project Settings ->
-- API keys -> service_role. Note this stores the key inside cron.job, readable by
-- anyone with database access — which is already service-role-level access, so it
-- grants nothing new. Supabase Vault is the tidier home for it if you would rather
-- not have it in a job definition; that is a refinement, not a blocker.
-- ============================================================

SELECT cron.unschedule('flim-social-push');
SELECT cron.unschedule('flim-develop-push');
SELECT cron.unschedule('flim-daily-digest');

SELECT cron.schedule('flim-social-push', '* * * * *', $job$
  SELECT net.http_post(
    url := 'https://wxvwamwrjlrvqmuaafjv.supabase.co/functions/v1/send-social-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
    )
  );
$job$);

SELECT cron.schedule('flim-develop-push', '* * * * *', $job$
  SELECT net.http_post(
    url := 'https://wxvwamwrjlrvqmuaafjv.supabase.co/functions/v1/send-develop-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
    )
  );
$job$);

-- Daily digest keeps its daytime-only window: hourly from 14:00 to 01:00 UTC.
SELECT cron.schedule('flim-daily-digest', '0 14-23,0-1 * * *', $job$
  SELECT net.http_post(
    url := 'https://wxvwamwrjlrvqmuaafjv.supabase.co/functions/v1/send-daily-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
    )
  );
$job$);

-- Verify the three jobs are back, with headers this time:
--
--   select jobname, schedule, command from cron.job order by jobname;
