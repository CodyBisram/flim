-- ============================================================
-- Migration: darkroom_month_summary, the richer sibling of
-- darkroom_month_counts (see 2026-08-24_darkroom_month_counts.sql).
-- Approved Darkroom Zoom redesign, revision 2.
--
-- THIS SUPPLEMENTS, IT DOES NOT REPLACE: darkroom_month_counts stays for
-- any caller that only needs the shot-count histogram (the year jump
-- sheet). This function is for the zoomed-out month view, which also
-- needs a night count, a "still developing" count, and a handful of cover
-- thumbnails per month. Same scope, same grouping rule, one extra pass.
--
-- SCOPE: identical to darkroom_month_counts, the caller's own rows only,
-- user_id = auth.uid() AND is_sorted = true. Nothing about any other
-- user's photos.
--
-- MONTH GROUPING: identical to darkroom_month_counts, taken_at shifted
-- back 4 hours (FeedUnit.dayBoundaryHour, the app's 04:00 local day
-- boundary), then truncated to month IN THE ZONE THE CLIENT PASSES. The
-- zone is a parameter, never a server default, for the same reconciling
-- reason as the predecessor: this aggregate and the client's own local
-- grouping must agree on one zone.
--
-- NIGHT DEFINITION: the same 4-hour-shifted timestamp, truncated to DAY
-- instead of month, is "one night" for this function's purposes.
-- night_count is COUNT(DISTINCT night) within the month. cover_paths picks
-- the earliest shot (by taken_at) of each of the first p_covers distinct
-- nights in the month, oldest night first, so the covers read as a
-- chronological filmstrip rather than a random sample.
--
-- DEVELOPING COUNT IS TIME-DERIVED, NOT FLAG-DERIVED: developing_count
-- counts photos in the month with develops_at > now(). It deliberately
-- does not read is_developed. That column is a cached/lagging flag
-- (flip_developed_photos runs on a cron, see schema.sql), and the app's
-- own rule for "is this ready" is always Date.now >= develops_at, never
-- the flag. Reading the flag here would let the summary disagree with
-- what the client itself decides to render as developed.
--
-- COVER PATH: mirrors the client's displayPath rule, thumb_path when
-- present, storage_path as the fallback. See schema.sql's note by
-- photos.thumb_path for why the fallback exists (older rows predate the
-- column).
--
-- p_covers IS CLAMPED, NOT TRUSTED: 1...12. A caller passing an oversized
-- value (or trying to use this as a scraping primitive for a huge
-- array_agg per month) gets clamped rather than served whatever it asked
-- for.
--
-- INVOKER, NOT DEFINER: same reasoning as darkroom_month_counts, every
-- row is already filtered by auth.uid() in the WHERE clause, so this
-- needs no elevated privilege, and running as invoker keeps RLS on
-- public.photos as a second, independent gate rather than punching
-- through it.
--
-- AUTHORIZATION: auth.uid() only, never a user-id parameter, for the same
-- reason as the predecessor, a parameter would let any authenticated
-- caller read another user's monthly activity and cover photos.
--
-- TIMEZONE INPUT: validated against pg_timezone_names, same as the
-- predecessor. An unrecognized or garbage string falls back to UTC rather
-- than raising.
--
-- Rows are only returned for months with at least one qualifying photo,
-- which is automatic here since every column is aggregated from the
-- caller's own filtered rows, a month_start with zero matching photos
-- never enters the grouped set.
--
-- INTERNAL NAMING: the CTEs call the month bucket bucket_month, never
-- month_start. month_start is one of this function's OUT columns, and
-- plpgsql's default variable_conflict = error makes any UNQUALIFIED
-- reference to a name that is both an OUT column and a query column a
-- runtime error (the predecessor dodged the same trap with GROUP BY 1).
-- Only the final SELECT aliases bucket_month back to month_start.
-- ============================================================

CREATE OR REPLACE FUNCTION public.darkroom_month_summary(p_timezone TEXT, p_covers INT DEFAULT 4)
RETURNS TABLE(
    month_start DATE,
    shot_count INTEGER,
    night_count INTEGER,
    developing_count INTEGER,
    cover_paths TEXT[]
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
    night_first_shot AS (
        SELECT
            bucket_month,
            night_start,
            display_path,
            row_number() OVER (
                PARTITION BY bucket_month, night_start
                ORDER BY taken_at ASC
            ) AS rn_in_night
        FROM bucketed
    ),
    night_ranked AS (
        SELECT
            bucket_month,
            night_start,
            display_path,
            row_number() OVER (
                PARTITION BY bucket_month
                ORDER BY night_start ASC
            ) AS night_rank
        FROM night_first_shot
        WHERE rn_in_night = 1
    ),
    month_covers AS (
        SELECT
            bucket_month,
            array_agg(display_path ORDER BY night_start ASC) AS agg_covers
        FROM night_ranked
        WHERE night_rank <= v_covers
        GROUP BY bucket_month
    )
    SELECT
        m.bucket_month,
        m.agg_shots,
        m.agg_nights,
        m.agg_developing,
        COALESCE(c.agg_covers, ARRAY[]::text[])
    FROM month_agg m
    LEFT JOIN month_covers c ON c.bucket_month = m.bucket_month
    ORDER BY m.bucket_month;
END;
$$;

REVOKE ALL ON FUNCTION public.darkroom_month_summary(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.darkroom_month_summary(TEXT, INT) TO authenticated;
