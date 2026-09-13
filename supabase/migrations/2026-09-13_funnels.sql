-- The two funnels the UI audit asked for (docs/UI_SOCIAL_AUDIT_2026-09-12.md), as one function,
-- counts not percentages, scoped to accounts created since a date. Owner-only: no client grant.
--
--   select * from public.weekly_funnels('2026-09-01');
--
-- Everyday: created -> connected (follows someone; the inviter auto-follow counts, so the second
-- column says how many follow someone BEYOND the inviter) -> saw a friend's photo (opened the feed
-- on any day) -> reacted or commented on someone else's post -> posted -> got a response (a
-- reaction or comment on one of their posts by someone else) -> came back (opened the app on a
-- day after the day they joined).
-- Roll: joined a roll they did not create -> contributed a frame to a roll -> in a roll with two
-- or more contributors -> watched a reveal -> in a second roll with two or more contributors.
CREATE OR REPLACE FUNCTION public.weekly_funnels(p_since DATE)
RETURNS TABLE (funnel TEXT, ord INT, step TEXT, people BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH cohort AS (
    SELECT u.id, u.created_at, LOWER(u.email) AS email FROM public.users u
    WHERE u.created_at >= p_since AND u.username <> 'applereview'
),
inviter AS (
    SELECT c.id AS user_id, NULLIF(SUBSTRING(a.note FROM 'invited_by:(.*)'), '')::uuid AS inviter_id
    FROM cohort c LEFT JOIN public.allowed_emails a ON a.email = c.email
),
everyday AS (
    SELECT 1 AS ord, 'created' AS step, COUNT(*) AS people FROM cohort
    UNION ALL SELECT 2, 'follows someone', COUNT(DISTINCT f.follower_id) FROM public.follows f JOIN cohort c ON c.id = f.follower_id
    UNION ALL SELECT 3, 'follows someone beyond the inviter', COUNT(DISTINCT f.follower_id)
        FROM public.follows f JOIN inviter i ON i.user_id = f.follower_id WHERE f.following_id IS DISTINCT FROM i.inviter_id
    UNION ALL SELECT 4, 'opened the feed', COUNT(DISTINCT e.user_id) FROM public.usage_events e JOIN cohort c ON c.id = e.user_id WHERE e.event = 'feed_viewed'
    UNION ALL SELECT 5, 'reacted or commented on a friend', COUNT(DISTINCT x.user_id) FROM (
        SELECT r.user_id FROM public.post_reactions r JOIN public.posts p ON p.id = r.post_id WHERE p.user_id <> r.user_id
        UNION SELECT k.user_id FROM public.post_comments k JOIN public.posts p ON p.id = k.post_id WHERE p.user_id <> k.user_id
    ) x JOIN cohort c ON c.id = x.user_id
    UNION ALL SELECT 6, 'posted', COUNT(DISTINCT p.user_id) FROM public.posts p JOIN cohort c ON c.id = p.user_id
    UNION ALL SELECT 7, 'got a response', COUNT(DISTINCT p.user_id) FROM public.posts p JOIN cohort c ON c.id = p.user_id
        WHERE EXISTS (SELECT 1 FROM public.post_reactions r WHERE r.post_id = p.id AND r.user_id <> p.user_id)
           OR EXISTS (SELECT 1 FROM public.post_comments k WHERE k.post_id = p.id AND k.user_id <> p.user_id)
    UNION ALL SELECT 8, 'came back another day', COUNT(DISTINCT e.user_id) FROM public.usage_events e JOIN cohort c ON c.id = e.user_id
        WHERE e.event = 'app_open' AND e.day > (c.created_at AT TIME ZONE 'America/New_York')::date
),
contributors AS (
    SELECT roll_id, COUNT(DISTINCT user_id) AS n FROM public.photos WHERE roll_id IS NOT NULL GROUP BY roll_id
),
roll AS (
    SELECT 1 AS ord, 'created' AS step, COUNT(*) AS people FROM cohort
    UNION ALL SELECT 2, 'joined a roll they did not create', COUNT(DISTINCT m.user_id)
        FROM public.roll_members m JOIN public.rolls r ON r.id = m.roll_id JOIN cohort c ON c.id = m.user_id WHERE r.created_by <> m.user_id
    UNION ALL SELECT 3, 'contributed a frame to a roll', COUNT(DISTINCT p.user_id) FROM public.photos p JOIN cohort c ON c.id = p.user_id WHERE p.roll_id IS NOT NULL
    UNION ALL SELECT 4, 'in a roll with two or more contributors', COUNT(DISTINCT m.user_id)
        FROM public.roll_members m JOIN contributors k ON k.roll_id = m.roll_id JOIN cohort c ON c.id = m.user_id WHERE k.n >= 2
    UNION ALL SELECT 5, 'watched a reveal', COUNT(DISTINCT v.user_id) FROM public.roll_reveal_views v JOIN cohort c ON c.id = v.user_id
    UNION ALL SELECT 6, 'in a second roll with two or more contributors', COUNT(*) FROM (
        SELECT m.user_id FROM public.roll_members m JOIN contributors k ON k.roll_id = m.roll_id JOIN cohort c ON c.id = m.user_id
        WHERE k.n >= 2 GROUP BY m.user_id HAVING COUNT(*) >= 2
    ) s
)
SELECT 'everyday', ord, step, people FROM everyday
UNION ALL SELECT 'roll', ord, step, people FROM roll
ORDER BY 1, 2;
$$;
REVOKE ALL ON FUNCTION public.weekly_funnels(DATE) FROM PUBLIC, anon, authenticated;

-- Time to first response after a post, and who never gets one. A response is a reaction or a
-- comment by someone other than the author. Posts younger than a day are not counted as
-- unanswered; they have not had their day.
--
--   select * from public.first_response_stats('2026-09-01');
CREATE OR REPLACE FUNCTION public.first_response_stats(p_since DATE)
RETURNS TABLE (measure TEXT, value TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH posts AS (
    SELECT p.id, p.user_id, p.created_at FROM public.posts po JOIN public.posts p ON p.id = po.id
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
aged AS (SELECT * FROM first_resp WHERE created_at < NOW() - INTERVAL '1 day')
SELECT 'posts since', COUNT(*)::text FROM posts
UNION ALL SELECT 'posts answered', COUNT(*)::text FROM answered
UNION ALL SELECT 'median minutes to first response', ROUND(EXTRACT(EPOCH FROM PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY responded_at - created_at)) / 60)::text FROM answered
UNION ALL SELECT 'answered within an hour', COUNT(*)::text FROM answered WHERE responded_at - created_at <= INTERVAL '1 hour'
UNION ALL SELECT 'answered within a day', COUNT(*)::text FROM answered WHERE responded_at - created_at <= INTERVAL '1 day'
UNION ALL SELECT 'posts older than a day with no response', COUNT(*)::text FROM aged WHERE responded_at IS NULL
UNION ALL SELECT 'people who posted', COUNT(DISTINCT user_id)::text FROM posts
UNION ALL SELECT 'people who posted and never got a response', COUNT(*)::text FROM (
    SELECT user_id FROM aged GROUP BY user_id HAVING COUNT(responded_at) = 0
) n
UNION ALL SELECT 'never answered, by username', COALESCE(STRING_AGG(u.username, ', ' ORDER BY u.username), '-') FROM (
    SELECT user_id FROM aged GROUP BY user_id HAVING COUNT(responded_at) = 0
) n JOIN public.users u ON u.id = n.user_id;
$$;
REVOKE ALL ON FUNCTION public.first_response_stats(DATE) FROM PUBLIC, anon, authenticated;
