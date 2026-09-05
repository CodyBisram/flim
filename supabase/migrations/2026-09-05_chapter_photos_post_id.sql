-- ============================================================
-- Migration: chapter_photos() and chapter_stats() return post_id, so the
-- closing card can open a post detail view (reactions/comments) instead of
-- a photo-id lookup that finds nothing.
--
-- WHY: chapter_stats already counts public.post_reactions / public.
-- post_comments (posts.id-keyed -- see 2026-09-04_chapter_stats.sql's own
-- "REACTIONS/COMMENTS SOURCE" note: a chapter is what you posted, so
-- reactions live on the post, never on the roll-photo thread). The app's
-- photo viewer, however, opens a photo by id and reads
-- public.photo_reactions / public.photo_comments -- a different table,
-- keyed on photo_id, backing the separate roll-photo-thread UI. Tapping
-- the closing card's "most reacted" photo therefore opened a viewer with
-- zero reactions: right count, wrong id, wrong table. The fix ships on the
-- Swift side by switching chapter photo taps to open the POST detail
-- screen, which needs a post_id per row from both functions below.
--
-- Both functions are posted-only as of 2026-09-04_chapters_posted_only.sql
-- (chapter_photos) and shipped that way from day one (chapter_stats):
-- every row either function can ever return already passed through
-- public.posts, so post_id is NEVER NULL on chapter_photos, and never NULL
-- on the chapter_stats rows that carry a photo at all (most_reacted,
-- most_commented, first_shot, last_shot -- the only stat_key values with a
-- non-null photo_id already). Every other chapter_stats row keeps
-- post_id NULL, same as its existing NULL photo_id.
--
-- RETURN TYPE CHANGE: Postgres will not let CREATE OR REPLACE FUNCTION
-- change a function's RETURNS TABLE column list in place ("cannot change
-- return type of existing function"). DROP FUNCTION IF EXISTS first, then
-- CREATE, then re-grant EXACTLY as before (authenticated only; anon and
-- PUBLIC revoked) -- both functions were SECURITY DEFINER with no other
-- grants, so there is nothing else to restore. This is safe to re-run: a
-- second pass drops the already-updated function and recreates the
-- identical shape.
--
-- COMPATIBILITY: PostgREST returns one JSON object per row; a client that
-- decodes only the keys it already knows (id/taken_at/thumb_path/
-- feed_path/storage_path/roll_id/roll_name, or stat_key/value_int/
-- value_text/photo_id/photo_thumb_path) ignores the new post_id key
-- entirely. Adding a column to a RETURNS TABLE is additive and backward
-- compatible; no client needs to change before this migration ships.
--
-- Nothing else changes: same visibility predicates, same posted-only
-- source, same month boundary, same ordering, same 1000-row cap on
-- chapter_photos, same omission rule and visibility pick on chapter_stats.
-- ============================================================

DROP FUNCTION IF EXISTS public.chapter_photos(UUID, DATE);

CREATE FUNCTION public.chapter_photos(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    id           UUID,
    taken_at     TIMESTAMPTZ,
    thumb_path   TEXT,
    feed_path    TEXT,
    storage_path TEXT,
    roll_id      UUID,
    roll_name    TEXT,
    post_id      UUID
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Same posted-only rule as profile_chapters. post_id comes straight
        -- off the same posts row already joined for taken_at/thumb_path/etc
        -- -- reactions and comments live on the POST (public.post_reactions /
        -- public.post_comments), never on the photo, so this is the id the
        -- app's post detail viewer needs, and it is never NULL here because
        -- every row in this CTE was reached only via a matching posts row.
        SELECT p.id, po.taken_at, po.thumb_path, po.feed_path, po.storage_path, p.roll_id,
               po.id AS post_id
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    )
    SELECT s.id, s.taken_at, s.thumb_path, s.feed_path, s.storage_path, s.roll_id, r.name, s.post_id
    FROM source s
    LEFT JOIN public.rolls r ON r.id = s.roll_id
    WHERE date_trunc('month', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ORDER BY s.taken_at ASC
    LIMIT 1000;
$$;

REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_photos(UUID, DATE) TO authenticated;

DROP FUNCTION IF EXISTS public.chapter_stats(UUID, DATE);

CREATE FUNCTION public.chapter_stats(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    stat_key         TEXT,
    value_int        INTEGER,
    value_text       TEXT,
    photo_id         UUID,
    photo_thumb_path TEXT,
    post_id          UUID
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Byte-for-byte the same predicate as chapter_photos' own source CTE,
        -- narrowed to the one month up front so every CTE below it is already
        -- scoped correctly. post_id already existed here (needed for the
        -- post_reactions/post_comments joins below -- reactions and comments
        -- live on the POST, never on the photo); it just was not carried
        -- through to the final result rows until now.
        SELECT po.id AS post_id, p.id AS photo_id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
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
        SELECT date_trunc('day', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS shot_day
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
    stats (stat_key, value_int, value_text, photo_id, photo_thumb_path, post_id) AS (
        (SELECT 'shots'::text, count(*)::int, NULL::text, NULL::uuid, NULL::text, NULL::uuid
         FROM source
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'reactions_received', count(*)::int, NULL, NULL, NULL, NULL
         FROM source s JOIN public.post_reactions pr ON pr.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'comments_received', count(*)::int, NULL, NULL, NULL, NULL
         FROM source s JOIN public.post_comments pc ON pc.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'most_reacted', rc.cnt::int, NULL, rc.photo_id, rc.display_path, rc.post_id
         FROM reaction_counts rc
         ORDER BY rc.cnt DESC, rc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'most_commented', cc.cnt::int, NULL, cc.photo_id, cc.display_path, cc.post_id
         FROM comment_counts cc
         ORDER BY cc.cnt DESC, cc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_reaction', re.cnt::int, re.emoji, NULL, NULL, NULL
         FROM reaction_emoji re
         ORDER BY re.cnt DESC, re.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'busiest_day', dc.cnt::int, to_char(dc.shot_day, 'YYYY-MM-DD'), NULL, NULL, NULL
         FROM day_counts dc
         ORDER BY dc.cnt DESC, dc.shot_day DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'night_shots', count(*)::int, NULL, NULL, NULL, NULL
         FROM source s
         WHERE EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) >= 22
            OR EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) < 4
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'streak_days', max(len)::int, NULL, NULL, NULL, NULL
         FROM streak_lengths)

        UNION ALL
        (SELECT 'rolls_count', count(*)::int, NULL, NULL, NULL, NULL
         FROM roll_ids
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'people_shot_with', count(DISTINCT rm.user_id)::int, NULL, NULL, NULL, NULL
         FROM public.roll_members rm
         WHERE rm.roll_id IN (SELECT roll_id FROM roll_ids)
           AND rm.user_id <> p_profile_id
         HAVING count(DISTINCT rm.user_id) > 0)

        UNION ALL
        (SELECT 'first_shot', NULL, NULL, s.photo_id, s.display_path, s.post_id
         FROM source s
         ORDER BY s.taken_at ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'last_shot', NULL, NULL, s.photo_id, s.display_path, s.post_id
         FROM source s
         ORDER BY s.taken_at DESC
         LIMIT 1)
    ),
    owner_pick AS (
        SELECT chapter_public_stats FROM public.users WHERE id = p_profile_id
    )
    SELECT st.stat_key, st.value_int, st.value_text, st.photo_id, st.photo_thumb_path, st.post_id
    FROM stats st
    WHERE auth.uid() = p_profile_id
       OR EXISTS (
            SELECT 1 FROM owner_pick op
            WHERE COALESCE(array_length(op.chapter_public_stats, 1), 0) = 0
               OR st.stat_key = ANY(op.chapter_public_stats)
          );
$$;

REVOKE ALL ON FUNCTION public.chapter_stats(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_stats(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_stats(UUID, DATE) TO authenticated;
