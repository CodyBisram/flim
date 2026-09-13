-- Measurement fixes from the everyday-sharing audit (docs/EVERYDAY_SOCIAL_AUDIT_AND_PLAN_2026-09-13.md,
-- A3's metadata gap and A9), 2026-09-14.
--
-- 1. get_suggested_emoji's posted-photo branch asks the follower rule, the same as every other
--    post read since 2026-09-13. Without it a caller holding a photo id could read the suggested
--    emoji for a post it cannot open. Metadata, not bytes, but the boundary should be one rule.
CREATE OR REPLACE FUNCTION public.get_suggested_emoji(p_photo_ids UUID[])
RETURNS TABLE (photo_id UUID, suggested_emoji TEXT[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT s.photo_id, s.suggested_emoji
    FROM public.photo_suggested_emoji s
    JOIN public.photos p ON p.id = s.photo_id
    WHERE s.photo_id = ANY(p_photo_ids)
      AND NOT p.hidden
      AND (
            p.user_id = auth.uid()
            OR (
                p.roll_id IS NOT NULL
                AND public.is_roll_member(p.roll_id)
                AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
                AND p.develops_at <= now()
              )
            OR EXISTS (
                SELECT 1 FROM public.posts po
                WHERE po.photo_id = p.id
                  AND NOT po.hidden
                  AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
                  AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
                  AND public.post_visible_to(auth.uid(), po.id, po.user_id)
              )
          );
$$;

-- 2. "People who posted and never got a response" only looked at posts older than a day, so
--    someone with one stale unanswered post and a fresh answered one was counted as never
--    answered. Now: has at least one aged post, and none of their posts (any age) was answered.
CREATE OR REPLACE FUNCTION public.first_response_stats(p_since DATE)
RETURNS TABLE (measure TEXT, value TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH posts AS (
    SELECT p.id, p.user_id, p.created_at FROM public.posts p
    WHERE p.created_at >= p_since AND NOT p.hidden
),
first_resp AS (
    SELECT p.id, p.user_id, p.created_at,
           (SELECT MIN(t) FROM (
               SELECT r.created_at AS t FROM public.post_reactions r WHERE r.post_id = p.id AND r.user_id <> p.user_id
               UNION ALL SELECT k.created_at FROM public.post_comments k WHERE k.post_id = p.id AND k.user_id <> p.user_id
           ) x) AS responded_at
    FROM posts p
),
answered AS (SELECT * FROM first_resp WHERE responded_at IS NOT NULL),
aged AS (SELECT * FROM first_resp WHERE created_at < NOW() - INTERVAL '1 day'),
never AS (
    SELECT user_id FROM first_resp GROUP BY user_id
    HAVING COUNT(responded_at) = 0 AND COUNT(*) FILTER (WHERE created_at < NOW() - INTERVAL '1 day') > 0
)
SELECT 'posts since', COUNT(*)::text FROM posts
UNION ALL SELECT 'posts answered', COUNT(*)::text FROM answered
UNION ALL SELECT 'median minutes to first response', ROUND(EXTRACT(EPOCH FROM PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY responded_at - created_at)) / 60)::text FROM answered
UNION ALL SELECT 'answered within an hour', COUNT(*)::text FROM answered WHERE responded_at - created_at <= INTERVAL '1 hour'
UNION ALL SELECT 'answered within a day', COUNT(*)::text FROM answered WHERE responded_at - created_at <= INTERVAL '1 day'
UNION ALL SELECT 'posts older than a day with no response', COUNT(*)::text FROM aged WHERE responded_at IS NULL
UNION ALL SELECT 'people who posted', COUNT(DISTINCT user_id)::text FROM posts
UNION ALL SELECT 'people who posted and never got a response', COUNT(*)::text FROM never
UNION ALL SELECT 'never answered, by username', COALESCE(STRING_AGG(u.username, ', ' ORDER BY u.username), '-') FROM never n JOIN public.users u ON u.id = n.user_id;
$$;

-- 3. The primary product outcome the audit proposed: pairs of people who each reacted to or
--    commented on the other's photos inside a rolling window. Personal posts and roll photos
--    are counted separately (a roll makes reciprocity cheap; a page does not) and the combined
--    number is a distinct-pair union, not a sum. Never a visible score: it is how the owner
--    knows whether people are connecting, not something the app shows anyone.
--
--   select * from public.reciprocal_pairs_detail(7);   -- posts / rolls / either
--   select public.reciprocal_pairs(7);                  -- the 'either' count alone
CREATE OR REPLACE FUNCTION public.reciprocal_pairs_detail(p_days INT)
RETURNS TABLE (context TEXT, pairs BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH post_edges AS (
    SELECT DISTINCT r.user_id AS a, po.user_id AS b FROM public.post_reactions r JOIN public.posts po ON po.id = r.post_id
    WHERE r.created_at > NOW() - (p_days || ' days')::interval AND r.user_id <> po.user_id
    UNION
    SELECT DISTINCT k.user_id, po.user_id FROM public.post_comments k JOIN public.posts po ON po.id = k.post_id
    WHERE k.created_at > NOW() - (p_days || ' days')::interval AND k.user_id <> po.user_id
),
roll_edges AS (
    SELECT DISTINCT r.user_id AS a, ph.user_id AS b FROM public.photo_reactions r JOIN public.photos ph ON ph.id = r.photo_id
    WHERE r.created_at > NOW() - (p_days || ' days')::interval AND r.user_id <> ph.user_id
    UNION
    SELECT DISTINCT k.user_id, ph.user_id FROM public.photo_comments k JOIN public.photos ph ON ph.id = k.photo_id
    WHERE k.created_at > NOW() - (p_days || ' days')::interval AND k.user_id <> ph.user_id
),
post_pairs AS (SELECT LEAST(e.a, e.b) x, GREATEST(e.a, e.b) y FROM post_edges e JOIN post_edges o ON o.a = e.b AND o.b = e.a WHERE e.a < e.b),
roll_pairs AS (SELECT LEAST(e.a, e.b) x, GREATEST(e.a, e.b) y FROM roll_edges e JOIN roll_edges o ON o.a = e.b AND o.b = e.a WHERE e.a < e.b)
SELECT 'posts', COUNT(*) FROM post_pairs
UNION ALL SELECT 'rolls', COUNT(*) FROM roll_pairs
UNION ALL SELECT 'either', COUNT(*) FROM (SELECT x, y FROM post_pairs UNION SELECT x, y FROM roll_pairs) u;
$$;
REVOKE ALL ON FUNCTION public.reciprocal_pairs_detail(INT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reciprocal_pairs(p_days INT)
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT pairs FROM public.reciprocal_pairs_detail(p_days) WHERE context = 'either';
$$;
REVOKE ALL ON FUNCTION public.reciprocal_pairs(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reciprocal_pairs(INT) TO service_role;

-- 5. The trailing-week opener average counted only days that had an opener; a day with none
--    was skipped instead of counted as zero. generate_series pins it to seven days.
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
    'edge_non_200_24h', (SELECT COUNT(*) FROM net._http_response WHERE created > NOW() - INTERVAL '1 day' AND status_code <> 200),
    'ops_alerts_unsent', (SELECT COUNT(*) FROM public.ops_alerts WHERE NOT push_sent),
    'crash_rows_24h', (SELECT COUNT(*) FROM public.crash_diagnostics WHERE kind IN ('crash','hang') AND created_at > NOW() - INTERVAL '1 day'),
    'reports_unnotified', (SELECT (SELECT COUNT(*) FROM public.photo_reports WHERE NOT push_sent) + (SELECT COUNT(*) FROM public.user_reports WHERE NOT push_sent)),
    'db_mb', (SELECT ROUND(pg_database_size(current_database()) / 1048576.0)),
    'storage_gb', (SELECT ROUND(COALESCE(SUM((metadata->>'size')::bigint), 0) / 1073741824.0, 2) FROM storage.objects WHERE bucket_id = 'photos')
);
$$;
