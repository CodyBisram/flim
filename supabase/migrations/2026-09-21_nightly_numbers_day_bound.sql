-- ============================================================
-- nightly_numbers: two column fixes, day-bounded (audit item 10, 2026-09-21).
--
-- 1. accounts counted every row in public.users at the moment the function ran,
--    a running total as of "now", while new_accounts names a specific day
--    (today - 1 in New York). A run any time after midnight already includes
--    accounts created since that boundary, so Sep 18 could show +2 accounts
--    with 0 new_accounts: both numbers were true, they just did not name the
--    same day. accounts now counts everyone created before that same boundary,
--    so it agrees with new_accounts.
-- 2. reveals_watched counted viewed_at (the open), which the reveal-completion
--    change (2026-09-21_reveal_completion.sql) retires as the "watched" signal
--    everywhere else. Counts completed_at on the named day instead.
--
-- Every other column is byte-identical to the definition this replaces.
-- docs/NUMBERS.md's header describes the shape of the payload, not these two
-- columns' exact source column, so it does not change.
-- ============================================================

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
    'accounts', (SELECT COUNT(*) FROM public.users u, ny WHERE (u.created_at AT TIME ZONE 'America/New_York')::date < ny.today AND u.username <> 'applereview'),
    'new_accounts', (SELECT COUNT(*) FROM public.users u, ny WHERE (u.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'openers', (SELECT COUNT(DISTINCT user_id) FROM public.usage_events e, ny WHERE e.event = 'app_open' AND e.day = ny.today - 1),
    'openers_7d_avg', (SELECT ROUND(AVG(n)) FROM (
        SELECT d, (SELECT COUNT(DISTINCT user_id) FROM public.usage_events e WHERE e.event = 'app_open' AND e.day = d) n
        FROM ny, generate_series(ny.today - 7, ny.today - 1, INTERVAL '1 day') d) x),
    'shooters', (SELECT COUNT(DISTINCT user_id) FROM public.photos p, ny WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'photos', (SELECT COUNT(*) FROM public.photos p, ny WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'posts', (SELECT COUNT(*) FROM public.posts p, ny WHERE (p.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'reactions', (SELECT COUNT(*) FROM public.post_reactions r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'comments', (SELECT COUNT(*) FROM public.post_comments c, ny WHERE (c.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'follows', (SELECT COUNT(*) FROM public.follows f, ny WHERE (f.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'rolls_created', (SELECT COUNT(*) FROM public.rolls r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'reveals_watched', (SELECT COUNT(*) FROM public.roll_reveal_views v, ny WHERE (v.completed_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'invites_redeemed', (SELECT COUNT(*) FROM public.allowed_emails a, ny WHERE (a.added_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
    'reciprocal_pairs_7d', (SELECT public.reciprocal_pairs(7)),
    'founding_left', (SELECT 100 - COUNT(*) FROM public.users WHERE signup_ordinal IS NOT NULL AND username <> 'applereview'),
    'photos_missing_renditions_24h', (SELECT COUNT(*) FROM public.photos p WHERE p.taken_at > NOW() - INTERVAL '1 day' AND p.taken_at < NOW() - INTERVAL '1 hour' AND (p.thumb_path IS NULL OR p.feed_path IS NULL)),
    'photos_24h', (SELECT COUNT(*) FROM public.photos p WHERE p.taken_at > NOW() - INTERVAL '1 day' AND p.taken_at < NOW() - INTERVAL '1 hour'),
    'develop_pushes_unsent_over_1h', (SELECT COUNT(DISTINCT roll_id) FROM public.photos WHERE roll_id IS NOT NULL AND push_sent = FALSE AND develops_at < NOW() - INTERVAL '1 hour'),
    'push_deliveries_failed_terminal_24h', (SELECT COUNT(*) FROM public.push_deliveries WHERE NOT delivered AND attempts >= 3 AND updated_at > NOW() - INTERVAL '1 day'),
    'push_deliveries_24h', (SELECT COUNT(*) FROM public.push_deliveries WHERE updated_at > NOW() - INTERVAL '1 day'),
    'cron_failures_24h', (SELECT COUNT(*) FROM cron.job_run_details WHERE status <> 'succeeded' AND start_time > NOW() - INTERVAL '1 day'),
    'edge_non_200_24h', (SELECT COUNT(*) FROM public.edge_response_log WHERE created > NOW() - INTERVAL '1 day' AND status_code IS NOT NULL),
    'edge_timeouts_24h', (SELECT COUNT(*) FROM public.edge_response_log WHERE created > NOW() - INTERVAL '1 day' AND status_code IS NULL),
    'ops_alerts_unsent', (SELECT COUNT(*) FROM public.ops_alerts WHERE NOT push_sent),
    'crash_rows_24h', (SELECT COUNT(*) FROM public.crash_diagnostics WHERE kind IN ('crash','hang') AND created_at > NOW() - INTERVAL '1 day'),
    'reports_unnotified', (SELECT (SELECT COUNT(*) FROM public.photo_reports WHERE NOT push_sent) + (SELECT COUNT(*) FROM public.user_reports WHERE NOT push_sent)),
    'db_mb', (SELECT ROUND(pg_database_size(current_database()) / 1048576.0)),
    'storage_gb', (SELECT ROUND(COALESCE(SUM((metadata->>'size')::bigint), 0) / 1073741824.0, 2) FROM storage.objects WHERE bucket_id = 'photos')
);
$$;
