-- Post-1.5.3 ops fixes (2026-09-15).
--
-- 1. pg_net keeps responses for 6 hours (pg_net.ttl is a sighup parameter Supabase does not
--    let us change), so every "24h" counter the nightly numbers read from net._http_response was
--    really a 6-hour window, and a run GitHub delayed past the morning saw a different day than
--    the one it named. An hourly cron copies the rows worth keeping (anything not 200/204,
--    timeouts included) into a small ledger the counters read instead. Two weeks kept.
CREATE TABLE IF NOT EXISTS public.edge_response_log (
    id          BIGINT PRIMARY KEY,
    created     TIMESTAMPTZ NOT NULL,
    status_code INT,
    error_msg   TEXT,
    content     TEXT
);
ALTER TABLE public.edge_response_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.edge_response_log FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS edge_response_log_created_idx ON public.edge_response_log (created);

CREATE OR REPLACE FUNCTION public.copy_edge_failures()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n INT;
BEGIN
    INSERT INTO public.edge_response_log (id, created, status_code, error_msg, content)
    SELECT r.id, r.created, r.status_code, r.error_msg, LEFT(r.content::text, 300)
    FROM net._http_response r
    WHERE (r.status_code IS NULL OR r.status_code NOT IN (200, 204))
      AND r.id > COALESCE((SELECT MAX(id) FROM public.edge_response_log), 0)
    ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM public.edge_response_log WHERE created < NOW() - INTERVAL '14 days';
    RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.copy_edge_failures() FROM PUBLIC, anon, authenticated;
SELECT cron.schedule('flim-edge-ledger', '40 * * * *', $$SELECT public.copy_edge_failures()$$);

-- 2. Timeouts are a null status_code, which "status_code <> 200" never counted. Counted on
--    their own, from the ledger: a timeout is pg_net giving up on the reply (the function keeps running; the
--    social push can take 200s when it has work), so it is a number to watch, not an alert.
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
    'reveals_watched', (SELECT COUNT(*) FROM public.roll_reveal_views v, ny WHERE (v.viewed_at AT TIME ZONE 'America/New_York')::date = ny.today - 1),
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
