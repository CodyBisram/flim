-- ============================================================
-- darkroom_month_counts / darkroom_month_summary / darkroom_month_summary_v2:
-- stop scanning pg_timezone_names to validate p_timezone.
--
-- The 2026-09-22 production audit measured all three functions at a mean of
-- 307ms in pg_stat_statements, the slowest real query in the database, on
-- the Darkroom's Year and All-time load path (PhotoService.swift). All three
-- validate the caller-supplied zone the same way:
--
--   SELECT name INTO v_tz FROM pg_timezone_names WHERE name = p_timezone;
--   IF v_tz IS NULL THEN v_tz := 'UTC'; END IF;
--
-- pg_timezone_names is a set-returning function that materialises the whole
-- IANA catalog (close to 1200 rows, each one computing an abbreviation and a
-- UTC offset) on every call, just to test membership of one string. This
-- runs on every Darkroom summary fetch, for every month bucket the client
-- asks about, regardless of whether p_timezone is valid.
--
-- The replacement asks Postgres directly whether the zone name is usable,
-- with no catalog scan:
--
--   BEGIN
--       PERFORM now() AT TIME ZONE p_timezone;
--       v_tz := p_timezone;
--   EXCEPTION WHEN invalid_parameter_value THEN
--       v_tz := 'UTC';
--   END;
--
-- Confirmed on the schema_bootstrap.sh --keep database (Supabase's own
-- Postgres 17 image): `select now() at time zone 'Not/AZone'` raises
-- invalid_parameter_value (SQLSTATE 22023), which plpgsql's EXCEPTION WHEN
-- clause matches by name, so an unrecognised zone still falls back to UTC.
--
-- NULL is not the same case: `AT TIME ZONE` with a NULL zone name does not
-- raise, it returns NULL like any other NULL-in-NULL-out SQL expression
-- (confirmed the same way), so the block above alone leaves v_tz NULL for a
-- NULL p_timezone. The old lookup did not have that gap: `... WHERE name =
-- p_timezone` never matches a NULL, so v_tz stayed NULL after the SELECT and
-- the IF caught it, landing on 'UTC'. With a NULL p_timezone, every local_ts
-- in the query below would come out NULL, date_trunc(NULL) is NULL, and
-- every row collapses into one NULL month bucket -- a real regression, not
-- a cosmetic one. Each function below guards p_timezone IS NULL before the
-- validation block for that reason, so the NULL case still yields v_tz =
-- 'UTC', matching production today.
--
-- Signatures, grants, volatility and SECURITY are all unchanged, so nothing
-- on the Swift side needs to change; this is a body-only replace.
-- ============================================================

CREATE OR REPLACE FUNCTION public.darkroom_month_counts(p_timezone text)
 RETURNS TABLE(month_start date, photo_count integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tz TEXT;
BEGIN
    IF p_timezone IS NULL THEN
        v_tz := 'UTC';
    ELSE
        BEGIN
            PERFORM now() AT TIME ZONE p_timezone;
            v_tz := p_timezone;
        EXCEPTION WHEN invalid_parameter_value THEN
            v_tz := 'UTC';
        END;
    END IF;

    RETURN QUERY
    SELECT
        date_trunc('month', (p.taken_at - interval '4 hours') AT TIME ZONE v_tz)::date AS month_start,
        count(*)::integer AS photo_count
    FROM public.photos p
    WHERE p.user_id = auth.uid()
      AND p.is_sorted = true
    GROUP BY 1
    ORDER BY 1;
END;
$function$;
REVOKE ALL ON FUNCTION public.darkroom_month_counts(p_timezone text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.darkroom_month_counts(p_timezone text) TO authenticated;

CREATE OR REPLACE FUNCTION public.darkroom_month_summary(p_timezone text, p_covers integer DEFAULT 4)
 RETURNS TABLE(month_start date, shot_count integer, night_count integer, developing_count integer, cover_paths text[])
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tz TEXT;
    v_covers INT;
BEGIN
    IF p_timezone IS NULL THEN
        v_tz := 'UTC';
    ELSE
        BEGIN
            PERFORM now() AT TIME ZONE p_timezone;
            v_tz := p_timezone;
        EXCEPTION WHEN invalid_parameter_value THEN
            v_tz := 'UTC';
        END;
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
$function$;
REVOKE ALL ON FUNCTION public.darkroom_month_summary(p_timezone text, p_covers integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.darkroom_month_summary(p_timezone text, p_covers integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.darkroom_month_summary_v2(p_timezone text, p_covers integer DEFAULT 4)
 RETURNS TABLE(month_start date, shot_count integer, night_count integer, developing_count integer, cover_paths text[], top_cover_path text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tz TEXT;
    v_covers INT;
BEGIN
    IF p_timezone IS NULL THEN
        v_tz := 'UTC';
    ELSE
        BEGIN
            PERFORM now() AT TIME ZONE p_timezone;
            v_tz := p_timezone;
        EXCEPTION WHEN invalid_parameter_value THEN
            v_tz := 'UTC';
        END;
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
$function$;
REVOKE ALL ON FUNCTION public.darkroom_month_summary_v2(p_timezone text, p_covers integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.darkroom_month_summary_v2(p_timezone text, p_covers integer) TO authenticated;
