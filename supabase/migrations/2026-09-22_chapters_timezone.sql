-- ============================================================
-- Chapters take the phone's time zone.
--
-- profile_chapters, chapter_photos and chapter_stats bucketed months and days
-- with a fixed four-hour shift (`taken_at - interval '4 hours'`, i.e. UTC-4,
-- Eastern daylight time with no winter change), and golden_hour and
-- night_shots read the hour in America/New_York outright. That was FLIM's
-- user base when Chapters shipped on 2026-09-03; it is not any more. The
-- 2026-09-22 audit's data pass found at least one active account whose
-- shooting, posting and reacting all fall silent in a window that is a normal
-- night's sleep at UTC+8 and midday in New York, so for that person "between
-- 10pm and 4am" counted their afternoon, the busiest day was off by one, and
-- a shot at 2am on the first of the month belonged to the wrong chapter.
--
-- Each function now takes p_timezone, an IANA zone name, the same parameter
-- and the same validation the Darkroom's month functions have used since
-- 2026-08-24 (darkroom_month_counts, darkroom_month_summary), so the two
-- surfaces that describe "your month" agree on where a month begins. The
-- app sends TimeZone.current.identifier (ChapterService.swift): the zone the
-- phone is in when the chapter is opened, which for the closing card after
-- your own reveal is your own. A viewer in another zone sees the owner's month
-- bucketed by the viewer's clock; the alternative, a stored per-user zone, is
-- a column and a write path FLIM does not have, and the difference is only
-- ever a shot taken within hours of a month boundary.
--
-- DEFAULT 'America/New_York', not UTC: a client that does not send the
-- parameter (build 395 and everything before it) keeps today's answers,
-- within an hour in winter, because the fixed shift never observed standard
-- time and the named zone does. The two-argument signatures are dropped so
-- PostgREST has one function to resolve a call to whether or not p_timezone
-- is in the body.
--
-- chapter_timezone(text) is the validator: NULL and an unknown name both fall
-- back to the default. It asks Postgres directly whether the name is usable
-- (`now() AT TIME ZONE p_timezone` raises invalid_parameter_value, SQLSTATE
-- 22023, for a name it does not know) rather than scanning pg_timezone_names,
-- the 300ms catalog walk the 2026-09-22_darkroom_timezone_validation
-- migration took out of the Darkroom's path. The three functions stay
-- LANGUAGE sql and read the resolved zone once through a one-row `tz` CTE
-- (an uncorrelated scalar subquery is an InitPlan, evaluated once per call),
-- so nothing about their plans or their grants changes.
--
-- Same DROP FUNCTION IF EXISTS + CREATE OR REPLACE + re-grant dance as every
-- prior return-shape change to these functions. Safe to re-run.
-- ============================================================

CREATE OR REPLACE FUNCTION public.chapter_timezone(p_timezone text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
    IF p_timezone IS NULL THEN
        RETURN 'America/New_York';
    END IF;
    PERFORM now() AT TIME ZONE p_timezone;
    RETURN p_timezone;
EXCEPTION WHEN invalid_parameter_value THEN
    RETURN 'America/New_York';
END;
$$;

COMMENT ON FUNCTION public.chapter_timezone(text) IS
    'The IANA zone Chapters bucket a month in: the caller''s if Postgres knows it, America/New_York otherwise.';

-- ---- profile_chapters --------------------------------------------------------

DROP FUNCTION IF EXISTS public.profile_chapters(uuid);

CREATE OR REPLACE FUNCTION public.profile_chapters(p_profile_id uuid, p_timezone text DEFAULT 'America/New_York')
 RETURNS TABLE(month_start date, shot_count integer, roll_count integer, cover_paths text[], first_shot_at timestamp with time zone, last_shot_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH tz AS (
        SELECT public.chapter_timezone(p_timezone) AS z
    ),
    source AS (
        SELECT p.id, po.taken_at, p.roll_id, p.quality, p.is_miss,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
          AND public.post_visible_to(auth.uid(), po.id, po.user_id)
    ),
    bucketed AS (
        SELECT
            date_trunc('month', taken_at AT TIME ZONE (SELECT z FROM tz))::date AS bucket_month,
            taken_at, roll_id, display_path, quality, is_miss
        FROM source
    ),
    ranked_covers AS (
        SELECT bucket_month, display_path,
               row_number() OVER (
                   PARTITION BY bucket_month
                   ORDER BY quality DESC NULLS LAST, taken_at DESC
               ) AS rn
        FROM bucketed
        WHERE NOT is_miss
    )
    SELECT
        b.bucket_month,
        count(*)::integer,
        count(DISTINCT b.roll_id) FILTER (WHERE b.roll_id IS NOT NULL)::integer,
        COALESCE(
            (SELECT array_agg(rc.display_path ORDER BY rc.rn)
             FROM ranked_covers rc
             WHERE rc.bucket_month = b.bucket_month AND rc.rn <= 4),
            ARRAY[]::text[]
        ),
        min(b.taken_at),
        max(b.taken_at)
    FROM bucketed b
    GROUP BY b.bucket_month
    ORDER BY b.bucket_month DESC;
$function$;

REVOKE ALL ON FUNCTION public.profile_chapters(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_chapters(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_chapters(uuid, text) TO authenticated;

-- ---- chapter_photos ----------------------------------------------------------

DROP FUNCTION IF EXISTS public.chapter_photos(uuid, date);

CREATE OR REPLACE FUNCTION public.chapter_photos(p_profile_id uuid, p_month_start date, p_timezone text DEFAULT 'America/New_York')
 RETURNS TABLE(id uuid, taken_at timestamp with time zone, thumb_path text, feed_path text, storage_path text, roll_id uuid, roll_name text, post_id uuid, quality real, phash bigint, sharpness real, is_miss boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH tz AS (
        SELECT public.chapter_timezone(p_timezone) AS z
    ),
    source AS (
        SELECT p.id, po.taken_at, po.thumb_path, po.feed_path, po.storage_path, p.roll_id,
               po.id AS post_id, p.quality, p.phash, p.sharpness, p.is_miss
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
          AND public.post_visible_to(auth.uid(), po.id, po.user_id)
    )
    SELECT s.id, s.taken_at, s.thumb_path, s.feed_path, s.storage_path, s.roll_id, r.name, s.post_id,
           s.quality, s.phash, s.sharpness, s.is_miss
    FROM source s
    LEFT JOIN public.rolls r ON r.id = s.roll_id
    WHERE date_trunc('month', s.taken_at AT TIME ZONE (SELECT z FROM tz))::date = p_month_start
    ORDER BY s.taken_at ASC
    LIMIT 1000;
$function$;

REVOKE ALL ON FUNCTION public.chapter_photos(uuid, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_photos(uuid, date, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_photos(uuid, date, text) TO authenticated;

-- ---- chapter_stats -----------------------------------------------------------
-- Body as 2026-09-13_followers_only_reads.sql left it, with every
-- `- interval '4 hours' AT TIME ZONE 'utc'` and every 'America/New_York'
-- replaced by the resolved zone. Nothing else moves.

DROP FUNCTION IF EXISTS public.chapter_stats(uuid, date);

CREATE OR REPLACE FUNCTION public.chapter_stats(p_profile_id uuid, p_month_start date, p_timezone text DEFAULT 'America/New_York')
 RETURNS TABLE(stat_key text, value_int integer, value_text text, photo_id uuid, photo_thumb_path text, post_id uuid, user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH tz AS (
        SELECT public.chapter_timezone(p_timezone) AS z
    ),
    source AS (
        -- Byte-for-byte the same predicate as chapter_photos' own source CTE,
        -- narrowed to the one month up front so every CTE below it is already
        -- scoped correctly.
        SELECT po.id AS post_id, p.id AS photo_id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
          AND public.post_visible_to(auth.uid(), po.id, po.user_id)
          AND date_trunc('month', po.taken_at AT TIME ZONE (SELECT z FROM tz))::date = p_month_start
    ),
    reaction_counts AS (
        SELECT s.post_id, s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY s.post_id, s.photo_id, s.display_path, s.taken_at
    ),
    comment_counts AS (
        SELECT s.post_id, s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_comments pc ON pc.post_id = s.post_id
        GROUP BY s.post_id, s.photo_id, s.display_path, s.taken_at
    ),
    reaction_emoji AS (
        SELECT pr.emoji, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY pr.emoji
    ),
    day_bucketed AS (
        SELECT s.photo_id, s.post_id, s.display_path, s.taken_at,
               date_trunc('day', s.taken_at AT TIME ZONE (SELECT z FROM tz))::date AS shot_day
        FROM source s
    ),
    day_counts AS (
        SELECT shot_day, count(*) AS cnt FROM day_bucketed GROUP BY shot_day
    ),
    streaks AS (
        -- Classic gaps-and-islands: within a sequence of distinct days, a run of
        -- CONSECUTIVE days shares the same (day - row_number()) value.
        SELECT shot_day, shot_day - (row_number() OVER (ORDER BY shot_day))::int AS grp
        FROM (SELECT DISTINCT shot_day FROM day_bucketed) d
    ),
    streak_lengths AS (
        SELECT grp, count(*) AS len FROM streaks GROUP BY grp
    ),
    roll_ids AS (
        SELECT DISTINCT roll_id FROM source WHERE roll_id IS NOT NULL
    ),
    -- ---- biggest_fan ----
    fan_counts AS (
        SELECT pr.user_id AS reactor_id, count(*) AS cnt, max(pr.created_at) AS last_reacted_at
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        WHERE pr.user_id <> p_profile_id
        GROUP BY pr.user_id
    ),
    -- ---- top_given_reaction (owner's own behaviour, source CTE does not apply) ----
    given_reactions AS (
        SELECT pr.emoji, count(*) AS cnt
        FROM public.post_reactions pr
        JOIN public.posts po ON po.id = pr.post_id
        WHERE pr.user_id = p_profile_id
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND date_trunc('month', pr.created_at AT TIME ZONE (SELECT z FROM tz))::date = p_month_start
        GROUP BY pr.emoji
    ),
    -- ---- golden_hour ----
    hour_counts AS (
        SELECT EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE (SELECT z FROM tz)))::int AS hr, count(*) AS cnt
        FROM source s
        GROUP BY hr
    ),
    -- ---- roll_mvp: same visibility predicate as the "photos: roll members can
    -- read shared" storage policy, not the simpler unfiltered people_shot_with
    -- count -- see 2026-09-05_chapter_stats_more.sql for why. ----
    roll_mvp_counts AS (
        SELECT p.user_id AS shooter_id, count(*) AS cnt
        FROM public.photos p
        WHERE p.roll_id IN (SELECT roll_id FROM roll_ids)
          AND p.user_id <> p_profile_id
          AND NOT p.hidden
          AND public.is_roll_member(p.roll_id)
          AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
        GROUP BY p.user_id
    ),
    -- ---- longest_gap ----
    distinct_days AS (
        SELECT DISTINCT shot_day FROM day_bucketed
    ),
    day_gaps AS (
        SELECT shot_day, shot_day - LAG(shot_day) OVER (ORDER BY shot_day) AS gap_days
        FROM distinct_days
    ),
    gap_pick AS (
        SELECT shot_day, gap_days
        FROM day_gaps
        WHERE gap_days IS NOT NULL
        ORDER BY gap_days DESC, shot_day ASC
        LIMIT 1
    ),
    gap_ending_photo AS (
        -- The earliest shot on the day that ended the gap (first shot back
        -- after the drought), matched back to day_bucketed rather than
        -- re-deriving shot_day from taken_at a second time.
        SELECT db.photo_id, db.display_path, db.post_id, gp.gap_days
        FROM gap_pick gp
        JOIN day_bucketed db ON db.shot_day = gp.shot_day
        ORDER BY db.taken_at ASC
        LIMIT 1
    ),
    stats (stat_key, value_int, value_text, photo_id, photo_thumb_path, post_id, user_id) AS (
        (SELECT 'shots'::text, count(*)::int, NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::uuid
         FROM source
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'reactions_received', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM source s JOIN public.post_reactions pr ON pr.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'comments_received', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM source s JOIN public.post_comments pc ON pc.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'most_reacted', rc.cnt::int, NULL, rc.photo_id, rc.display_path, rc.post_id, NULL
         FROM reaction_counts rc
         ORDER BY rc.cnt DESC, rc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'most_commented', cc.cnt::int, NULL, cc.photo_id, cc.display_path, cc.post_id, NULL
         FROM comment_counts cc
         ORDER BY cc.cnt DESC, cc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_reaction', re.cnt::int, re.emoji, NULL, NULL, NULL, NULL
         FROM reaction_emoji re
         ORDER BY re.cnt DESC, re.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'busiest_day', dc.cnt::int, to_char(dc.shot_day, 'YYYY-MM-DD'), NULL, NULL, NULL, NULL
         FROM day_counts dc
         ORDER BY dc.cnt DESC, dc.shot_day DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'night_shots', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM source s
         WHERE EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE (SELECT z FROM tz))) >= 22
            OR EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE (SELECT z FROM tz))) < 4
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'streak_days', max(len)::int, NULL, NULL, NULL, NULL, NULL
         FROM streak_lengths)

        UNION ALL
        (SELECT 'rolls_count', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM roll_ids
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'people_shot_with', count(DISTINCT rm.user_id)::int, NULL, NULL, NULL, NULL, NULL
         FROM public.roll_members rm
         WHERE rm.roll_id IN (SELECT roll_id FROM roll_ids)
           AND rm.user_id <> p_profile_id
         HAVING count(DISTINCT rm.user_id) > 0)

        UNION ALL
        (SELECT 'first_shot', NULL, NULL, s.photo_id, s.display_path, s.post_id, NULL
         FROM source s
         ORDER BY s.taken_at ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'last_shot', NULL, NULL, s.photo_id, s.display_path, s.post_id, NULL
         FROM source s
         ORDER BY s.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'biggest_fan', fc.cnt::int, u.username, NULL, NULL, NULL, fc.reactor_id
         FROM fan_counts fc
         JOIN public.users u ON u.id = fc.reactor_id
         WHERE NOT public.is_blocked_either_way(auth.uid(), fc.reactor_id)
         ORDER BY fc.cnt DESC, fc.last_reacted_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_given_reaction', gr.cnt::int, gr.emoji, NULL, NULL, NULL, NULL
         FROM given_reactions gr
         ORDER BY gr.cnt DESC, gr.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'golden_hour', hc.hr::int, hc.cnt::text, NULL, NULL, NULL, NULL
         FROM hour_counts hc
         WHERE (SELECT count(*) FROM source) >= 3
         ORDER BY hc.cnt DESC, hc.hr ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'roll_mvp', rmc.cnt::int, u.username, NULL, NULL, NULL, rmc.shooter_id
         FROM roll_mvp_counts rmc
         JOIN public.users u ON u.id = rmc.shooter_id
         ORDER BY rmc.cnt DESC, u.username ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'longest_gap', gep.gap_days::int, NULL, gep.photo_id, gep.display_path, gep.post_id, NULL
         FROM gap_ending_photo gep
         WHERE gep.gap_days >= 3)
    ),
    owner_pick AS (
        SELECT chapter_public_stats FROM public.users WHERE id = p_profile_id
    )
    SELECT st.stat_key, st.value_int, st.value_text, st.photo_id, st.photo_thumb_path, st.post_id, st.user_id
    FROM stats st
    WHERE auth.uid() = p_profile_id
       OR EXISTS (
            SELECT 1 FROM owner_pick op
            WHERE COALESCE(array_length(op.chapter_public_stats, 1), 0) = 0
               OR st.stat_key = ANY(op.chapter_public_stats)
          );
$function$;

REVOKE ALL ON FUNCTION public.chapter_stats(uuid, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_stats(uuid, date, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_stats(uuid, date, text) TO authenticated;
