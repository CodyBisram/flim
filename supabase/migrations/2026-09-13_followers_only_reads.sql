-- Posts are readable by the people who follow you (2026-09-13, the owner's call after two audits
-- deferred it). Before this any signed-in member could open anyone's page and see every post; the
-- feed was follow-based but the page was not. Following stays one-way and instant: tapping Follow
-- is what opens someone's photographs to you, and the person who invited you is followed for you
-- at sign-up. What stays visible to everyone on FLIM: the profile itself (name, avatar, bio,
-- badges, counts), so people can be found and followed.
--
-- The one exception is being tagged: a post you are tagged in is yours to see whether or not
-- you follow its author, because the push that told you about it opens it.
--
-- Every server read of posts goes through the same predicate: the posts SELECT policy, the
-- storage policy for post images, and the three chapter functions (a chapter is built from
-- posts). Comments, reactions and likes already require a readable parent, so they follow.

CREATE OR REPLACE FUNCTION public.can_see_posts_of(p_viewer UUID, p_author UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_viewer IS NOT NULL AND (
        p_viewer = p_author
        OR EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = p_viewer AND f.following_id = p_author)
    );
$$;
REVOKE ALL ON FUNCTION public.can_see_posts_of(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_see_posts_of(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.post_visible_to(p_viewer UUID, p_post_id UUID, p_author UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT public.can_see_posts_of(p_viewer, p_author)
        OR EXISTS (SELECT 1 FROM public.post_tags t WHERE t.post_id = p_post_id AND t.tagged_user_id = p_viewer);
$$;
REVOKE ALL ON FUNCTION public.post_visible_to(UUID, UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_visible_to(UUID, UUID, UUID) TO authenticated;

DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
DROP POLICY IF EXISTS "posts: readable by followers" ON public.posts;
CREATE POLICY "posts: readable by followers"
    ON public.posts FOR SELECT TO authenticated
    USING (
        NOT hidden
        AND NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND public.covered_post_visible(auth.uid(), user_id, created_at)
        AND public.post_visible_to(auth.uid(), id, user_id)
    );

DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.posts po
            WHERE (objects.name = po.storage_path OR objects.name = po.thumb_path OR objects.name = po.feed_path)
              AND NOT po.hidden
              AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
              AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
              AND public.post_visible_to(auth.uid(), po.id, po.user_id)
        )
    );

-- profile_chapters: the same predicate, appended to the source CTE.
CREATE OR REPLACE FUNCTION public.profile_chapters(p_profile_id uuid)
 RETURNS TABLE(month_start date, shot_count integer, roll_count integer, cover_paths text[], first_shot_at timestamp with time zone, last_shot_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH source AS (
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
            date_trunc('month', (taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS bucket_month,
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

-- chapter_photos: the same predicate, appended to the source CTE.
CREATE OR REPLACE FUNCTION public.chapter_photos(p_profile_id uuid, p_month_start date)
 RETURNS TABLE(id uuid, taken_at timestamp with time zone, thumb_path text, feed_path text, storage_path text, roll_id uuid, roll_name text, post_id uuid, quality real, phash bigint, sharpness real, is_miss boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH source AS (
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
    WHERE date_trunc('month', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ORDER BY s.taken_at ASC
    LIMIT 1000;
$function$;

-- chapter_stats: the same predicate, appended to the source CTE.
CREATE OR REPLACE FUNCTION public.chapter_stats(p_profile_id uuid, p_month_start date)
 RETURNS TABLE(stat_key text, value_int integer, value_text text, photo_id uuid, photo_thumb_path text, post_id uuid, user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    WITH source AS (
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
          AND date_trunc('month', (po.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
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
               date_trunc('day', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS shot_day
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
          AND date_trunc('month', (pr.created_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
        GROUP BY pr.emoji
    ),
    -- ---- golden_hour ----
    hour_counts AS (
        SELECT EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York'))::int AS hr, count(*) AS cnt
        FROM source s
        GROUP BY hr
    ),
    -- ---- roll_mvp: same visibility predicate as the "photos: roll members can
    -- read shared" storage policy, not the simpler unfiltered people_shot_with
    -- count -- see the header comment above for why. ----
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
         WHERE EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) >= 22
            OR EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) < 4
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
