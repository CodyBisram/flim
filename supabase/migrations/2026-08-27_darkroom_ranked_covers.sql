-- ============================================================
-- Migration: darkroom_month_summary_v2, reaction-ranked month covers.
-- Approved Darkroom Zoom redesign follow-up: covers stop being "first N
-- nights, chronological sample" and become "the user's most-reacted photos
-- of the month", still displayed chronologically.
--
-- WHY A NEW FUNCTION, NOT REPLACE: darkroom_month_summary(TEXT, INT) (see
-- 2026-08-25_darkroom_month_summary.sql) is already live and called by
-- shipped app builds. Changing its OUT columns requires DROP FUNCTION first,
-- which breaks every installed client mid-flight the moment this is pasted
-- in, PostgREST would 404 on the old signature until every device upgrades.
-- v1 is left completely alone, byte for byte. This migration only adds
-- darkroom_month_summary_v2, a new function with two extra OUT columns.
-- Once every shipped build calls v2, a future migration can retire v1; not
-- this one.
--
-- SELECTION RULE (the actual feature):
--   For each calendar month bucket (same 4am-shifted, client-supplied-zone
--   bucketing as v1), rank the user's own photos in that month by:
--     reaction_count DESC, taken_at DESC (ties go to the newer shot)
--   reaction_count = COUNT(photo_reactions on the photo itself)
--                   + COUNT(post_reactions on the feed post that shares it,
--                     via posts.photo_id), for the user's own photos only.
--   Take the top LEAST(GREATEST(p_covers,1),12) of these "reacted" photos
--   (reaction_count > 0) as the primary selection.
--
-- BACKFILL RULE: if a month has fewer reacted photos than the requested
-- cover count, the remaining slots are filled from that month's unreacted
-- (reaction_count = 0) photos, chronologically EARLIEST first, until either
-- the cover count or the month's total photo count is reached, whichever is
-- smaller. A zero-reaction photo therefore only ever appears via backfill,
-- never via the reaction ranking itself (its reaction_count of 0 makes it
-- ineligible for the "reacted photos" pool by construction).
--
-- RETURN ORDER IS NOT SELECTION ORDER: cover_paths is the selected set
-- re-sorted to taken_at ASC before being returned, so the array reads as a
-- chronological filmstrip even though the set itself was chosen by rank.
-- This mirrors v1's own contract (oldest-first covers), just with a
-- different selection rule feeding the same chronological output shape.
--
-- top_cover_path IS THE ARRAY'S TRUE RANK 1: the single highest-ranked photo
-- by (reaction_count DESC, taken_at DESC) if the month has any reacted
-- photo, else (an all-zero-reaction month) the earliest photo in the month,
-- i.e. the first photo the backfill rule would have chosen. This column is
-- for the All-time rung's year grid, one cover image per month cell,
-- replacing the 2x2 mosaic that used to be built from cover_paths[0..3]
-- client-side. NULL is only possible for a month with zero photos, which
-- cannot occur: month_agg (and therefore every returned row) is built by
-- grouping the user's own already-filtered photos, so a bucket with no
-- photos never produces a row in the first place, exactly like v1.
--
-- REACTIONS ON HIDDEN/COVERED CONTENT: this function runs SECURITY INVOKER
-- (see below), so a photo_reactions or post_reactions row that RLS would
-- currently hide from the caller (a blocked reactor, or a post the
-- auto-moderation trigger set posts.hidden = true on while under review)
-- is also invisible to this count. That is the same security boundary the
-- rest of the app already enforces for reactions and posts, not a new rule
-- invented here, so a photo mid-moderation-review simply ranks as if those
-- reactions do not exist yet rather than bypassing RLS to count them.
--
-- SCOPE, TIMEZONE, NIGHT/DEVELOPING SEMANTICS, p_covers CLAMP (1..12), THE
-- INVOKER-NOT-DEFINER REASONING, AND THE COVER PATH RULE (thumb_path with a
-- storage_path fallback, matching the client's own displayPath rule so
-- cache keys stay consistent) ARE ALL UNCHANGED FROM v1. See
-- 2026-08-25_darkroom_month_summary.sql for the full reasoning on each; it
-- is not repeated here except where this function's behavior differs.
--
-- INTERNAL NAMING, SAME TRAP AS v1: this function's OUT columns include
-- month_start, cover_paths, and the new top_cover_path. plpgsql's default
-- variable_conflict = error makes any UNQUALIFIED reference to a name that
-- is both an OUT column and a query column a runtime error. Every internal
-- CTE column that could collide is prefixed (bucket_month, agg_*) or is a
-- name no OUT column uses (photo_id), exactly like v1's bucket_month dodge
-- of its own month_start collision. Only the final SELECT emits the OUT
-- column names.
--
-- INDEXES: none added. The join/aggregation paths this function needs are
-- already index-backed by existing objects: photo_reactions's own
-- UNIQUE (photo_id, user_id, emoji) constraint leads with photo_id, so an
-- equality lookup by photo_id is index-backed already; posts_photo_idx
-- (schema.sql, "Indexes on hot query paths") covers posts.photo_id;
-- post_reactions_post_idx covers the post_reactions.post_id join back to
-- posts. Adding another index on top of these would be speculative, so
-- none is added.
--
-- SMOKE TEST (run after pasting, in the unauthenticated SQL editor):
--   SELECT * FROM darkroom_month_summary_v2('America/New_York', 7);
-- Expected: zero rows, no error, same as v1's smoke test (auth.uid() is
-- NULL outside a real session, so the WHERE user_id = auth.uid() clause
-- matches nothing).
-- ============================================================

CREATE OR REPLACE FUNCTION public.darkroom_month_summary_v2(p_timezone TEXT, p_covers INT DEFAULT 4)
RETURNS TABLE(
    month_start DATE,
    shot_count INTEGER,
    night_count INTEGER,
    developing_count INTEGER,
    cover_paths TEXT[],
    top_cover_path TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_tz TEXT;
    v_covers INT;
BEGIN
    SELECT name INTO v_tz FROM pg_timezone_names WHERE name = p_timezone;
    IF v_tz IS NULL THEN
        v_tz := 'UTC';
    END IF;

    v_covers := LEAST(GREATEST(COALESCE(p_covers, 4), 1), 12);

    RETURN QUERY
    WITH shifted AS (
        SELECT
            p.id AS photo_id,
            p.taken_at,
            p.develops_at,
            COALESCE(p.thumb_path, p.storage_path) AS display_path,
            (p.taken_at - interval '4 hours') AT TIME ZONE v_tz AS local_ts
        FROM public.photos p
        WHERE p.user_id = auth.uid()
          AND p.is_sorted = true
    ),
    bucketed AS (
        SELECT
            photo_id,
            date_trunc('month', local_ts)::date AS bucket_month,
            date_trunc('day', local_ts)::date AS night_start,
            taken_at,
            develops_at,
            display_path
        FROM shifted
    ),
    month_agg AS (
        SELECT
            bucket_month,
            count(*)::integer AS agg_shots,
            count(DISTINCT night_start)::integer AS agg_nights,
            count(*) FILTER (WHERE develops_at > now())::integer AS agg_developing
        FROM bucketed
        GROUP BY bucket_month
    ),
    reaction_counts AS (
        SELECT
            b.photo_id,
            b.bucket_month,
            b.taken_at,
            b.display_path,
            (COALESCE(pr.cnt, 0) + COALESCE(po.cnt, 0))::integer AS agg_reactions
        FROM bucketed b
        LEFT JOIN LATERAL (
            SELECT count(*) AS cnt
            FROM public.photo_reactions r
            WHERE r.photo_id = b.photo_id
        ) pr ON true
        LEFT JOIN LATERAL (
            SELECT count(*) AS cnt
            FROM public.posts po2
            JOIN public.post_reactions r2 ON r2.post_id = po2.id
            WHERE po2.photo_id = b.photo_id
        ) po ON true
    ),
    reacted_ranked AS (
        SELECT
            photo_id,
            bucket_month,
            taken_at,
            display_path,
            agg_reactions,
            row_number() OVER (
                PARTITION BY bucket_month
                ORDER BY agg_reactions DESC, taken_at DESC
            ) AS agg_reacted_rank
        FROM reaction_counts
        WHERE agg_reactions > 0
    ),
    top_reacted AS (
        SELECT photo_id, bucket_month, taken_at, display_path, agg_reacted_rank
        FROM reacted_ranked
        WHERE agg_reacted_rank <= v_covers
    ),
    reacted_selected_counts AS (
        SELECT bucket_month, count(*)::integer AS agg_reacted_selected
        FROM top_reacted
        GROUP BY bucket_month
    ),
    backfill_quota AS (
        SELECT
            m.bucket_month,
            (v_covers - COALESCE(rsc.agg_reacted_selected, 0)) AS agg_needed
        FROM month_agg m
        LEFT JOIN reacted_selected_counts rsc ON rsc.bucket_month = m.bucket_month
    ),
    backfill_pool AS (
        SELECT rc.photo_id, rc.bucket_month, rc.taken_at, rc.display_path
        FROM reaction_counts rc
        WHERE NOT EXISTS (
            SELECT 1 FROM top_reacted tr WHERE tr.photo_id = rc.photo_id
        )
    ),
    backfill_ranked AS (
        SELECT
            photo_id,
            bucket_month,
            taken_at,
            display_path,
            row_number() OVER (
                PARTITION BY bucket_month
                ORDER BY taken_at ASC
            ) AS agg_backfill_rank
        FROM backfill_pool
    ),
    backfill_selected AS (
        SELECT br.photo_id, br.bucket_month, br.taken_at, br.display_path, br.agg_backfill_rank
        FROM backfill_ranked br
        JOIN backfill_quota bq ON bq.bucket_month = br.bucket_month
        WHERE br.agg_backfill_rank <= bq.agg_needed
    ),
    final_covers AS (
        SELECT
            bucket_month, photo_id, taken_at, display_path,
            agg_reacted_rank AS agg_selection_order
        FROM top_reacted
        UNION ALL
        SELECT
            bucket_month, photo_id, taken_at, display_path,
            (v_covers + agg_backfill_rank) AS agg_selection_order
        FROM backfill_selected
    ),
    month_covers AS (
        SELECT
            bucket_month,
            array_agg(display_path ORDER BY taken_at ASC) AS agg_covers
        FROM final_covers
        GROUP BY bucket_month
    ),
    month_top_cover AS (
        SELECT bucket_month, display_path AS agg_top_cover
        FROM (
            SELECT
                bucket_month,
                display_path,
                row_number() OVER (
                    PARTITION BY bucket_month
                    ORDER BY agg_selection_order ASC
                ) AS agg_top_rank
            FROM final_covers
        ) ranked_final
        WHERE agg_top_rank = 1
    )
    SELECT
        m.bucket_month,
        m.agg_shots,
        m.agg_nights,
        m.agg_developing,
        COALESCE(c.agg_covers, ARRAY[]::text[]),
        tc.agg_top_cover
    FROM month_agg m
    LEFT JOIN month_covers c ON c.bucket_month = m.bucket_month
    LEFT JOIN month_top_cover tc ON tc.bucket_month = m.bucket_month
    ORDER BY m.bucket_month;
END;
$$;

REVOKE ALL ON FUNCTION public.darkroom_month_summary_v2(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.darkroom_month_summary_v2(TEXT, INT) TO authenticated;
