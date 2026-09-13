-- The nightly numbers (2026-09-13): one JSON of the counts that matter, read by the
-- .github/workflows/nightly-numbers.yml job with the service key, appended as one line a day to
-- docs/NUMBERS.md. Service role only, like r2_watch_numbers. Every number here is a day-bucket
-- count or a row count; nothing personal leaves the database.
CREATE OR REPLACE FUNCTION public.nightly_numbers()
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH ny AS (SELECT (NOW() AT TIME ZONE 'America/New_York')::date AS today)
SELECT jsonb_build_object(
    'day', (SELECT (today - 1)::text FROM ny),
    'accounts', (SELECT COUNT(*) FROM public.users WHERE username <> 'applereview'),
    'new_accounts', (SELECT COUNT(*) FROM public.users u, ny WHERE (u.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'openers', (SELECT COUNT(DISTINCT user_id) FROM public.usage_events e, ny WHERE e.event = 'app_open' AND e.day = ny.today - 1),
    'openers_7d_avg', (SELECT ROUND(AVG(n)) FROM (SELECT day, COUNT(DISTINCT user_id) n FROM public.usage_events e, ny WHERE e.event = 'app_open' AND e.day >= ny.today - 7 AND e.day < ny.today GROUP BY day) d),
    'shooters', (SELECT COUNT(DISTINCT user_id) FROM public.photos p, ny WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'photos', (SELECT COUNT(*) FROM public.photos p, ny WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'posts', (SELECT COUNT(*) FROM public.posts p, ny WHERE (p.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'reactions', (SELECT COUNT(*) FROM public.post_reactions r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'comments', (SELECT COUNT(*) FROM public.post_comments c, ny WHERE (c.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'follows', (SELECT COUNT(*) FROM public.follows f, ny WHERE (f.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'rolls_created', (SELECT COUNT(*) FROM public.rolls r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'reveals_watched', (SELECT COUNT(*) FROM public.roll_reveal_views v, ny WHERE (v.viewed_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'invites_redeemed', (SELECT COUNT(*) FROM public.allowed_emails a, ny WHERE (a.added_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'founding_left', (SELECT 100 - COUNT(*) FROM public.users WHERE signup_ordinal IS NOT NULL AND username <> 'applereview'),
    'photos_missing_renditions_24h', (SELECT COUNT(*) FROM public.photos p WHERE p.taken_at > NOW() - INTERVAL '1 day' AND p.taken_at < NOW() - INTERVAL '1 hour' AND (p.thumb_path IS NULL OR p.feed_path IS NULL)),
    'photos_24h', (SELECT COUNT(*) FROM public.photos p WHERE p.taken_at > NOW() - INTERVAL '1 day' AND p.taken_at < NOW() - INTERVAL '1 hour'),
    'develop_pushes_unsent_over_1h', (SELECT COUNT(DISTINCT roll_id) FROM public.photos WHERE roll_id IS NOT NULL AND push_sent = FALSE AND develops_at < NOW() - INTERVAL '1 hour'),
    'push_deliveries_failed_terminal_24h', (SELECT COUNT(*) FROM public.push_deliveries WHERE NOT delivered AND attempts >= 3 AND updated_at > NOW() - INTERVAL '1 day'),
    'push_deliveries_24h', (SELECT COUNT(*) FROM public.push_deliveries WHERE updated_at > NOW() - INTERVAL '1 day'),
    'cron_failures_24h', (SELECT COUNT(*) FROM cron.job_run_details WHERE status <> 'succeeded' AND start_time > NOW() - INTERVAL '1 day'),
    'edge_non_200_24h', (SELECT COUNT(*) FROM net._http_response WHERE created > NOW() - INTERVAL '1 day' AND status_code <> 200),
    'ops_alerts_unsent', (SELECT COUNT(*) FROM public.ops_alerts WHERE NOT push_sent),
    'crash_rows_24h', (SELECT COUNT(*) FROM public.crash_diagnostics WHERE kind IN ('crash','hang') AND created_at > NOW() - INTERVAL '1 day'),
    'reports_open', (SELECT (SELECT COUNT(*) FROM public.photo_reports WHERE NOT push_sent) + (SELECT COUNT(*) FROM public.user_reports WHERE NOT push_sent)),
    'db_mb', (SELECT ROUND(pg_database_size(current_database()) / 1048576.0)),
    'storage_gb', (SELECT ROUND(COALESCE(SUM((metadata->>'size')::bigint), 0) / 1073741824.0, 2) FROM storage.objects WHERE bucket_id = 'photos')
);
$$;
REVOKE ALL ON FUNCTION public.nightly_numbers() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nightly_numbers() TO service_role;

-- The job's way to wake the owner: one ops_alerts row, which the social push turns into a push.
CREATE OR REPLACE FUNCTION public.raise_ops_alert(p_source TEXT, p_detail TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO public.ops_alerts (source, detail) VALUES (p_source, LEFT(p_detail, 500));
$$;
REVOKE ALL ON FUNCTION public.raise_ops_alert(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.raise_ops_alert(TEXT, TEXT) TO service_role;
