-- Reported people get the same detail as reported photos (2026-10-01, owner ask). NOT YET
-- APPLIED. The owner applies it.
--
-- `list_user_reports` returned the latest reason and a count, so the dashboard could not say who
-- reported someone. It now returns, per reported account: every open report with its reporter,
-- reason and time, and whether that reporter follows or has blocked the account; and a few facts
-- about the account itself (display name, member number, join date, posts, how many people have
-- blocked it, whether it is hidden from discovery). The shape changes, so the old function is
-- dropped first. Owner-only as before, and `is_owner() IS NOT TRUE` so a NULL answer refuses,
-- the same guard `list_photo_reports` uses. The dashboard falls back to the old fields until
-- this is applied.

DROP FUNCTION IF EXISTS public.list_user_reports();

CREATE FUNCTION public.list_user_reports()
 RETURNS TABLE(report_id uuid, reported_id uuid, reported_username text, reason text,
               report_count bigint, created_at timestamp with time zone,
               reported_display_name text, reported_number integer,
               reported_joined_at timestamp with time zone, reported_posts bigint,
               reported_blocked_by bigint, reported_hidden boolean, reporters jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF public.is_owner() IS NOT TRUE THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH counts AS (
        SELECT ur.reported_id,
               COUNT(DISTINCT ur.reporter_id) AS report_count,
               MIN(ur.created_at)             AS first_reported_at
        FROM public.user_reports ur
        WHERE NOT ur.handled
        GROUP BY ur.reported_id
    ),
    latest AS (
        SELECT DISTINCT ON (ur.reported_id) ur.id, ur.reported_id, ur.reason
        FROM public.user_reports ur
        WHERE NOT ur.handled
        ORDER BY ur.reported_id, ur.created_at DESC
    ),
    who AS (
        SELECT ur.reported_id,
               jsonb_agg(jsonb_build_object(
                   'username',     ru.username,
                   'display_name', ru.display_name,
                   'reason',       ur.reason,
                   'created_at',   ur.created_at,
                   'follows',      EXISTS (SELECT 1 FROM public.follows f
                                           WHERE f.follower_id = ur.reporter_id
                                             AND f.following_id = ur.reported_id),
                   'blocked',      EXISTS (SELECT 1 FROM public.blocks b
                                           WHERE b.blocker_id = ur.reporter_id
                                             AND b.blocked_id = ur.reported_id)
               ) ORDER BY ur.created_at ASC) AS reporters
        FROM public.user_reports ur
        LEFT JOIN public.users ru ON ru.id = ur.reporter_id
        WHERE NOT ur.handled
        GROUP BY ur.reported_id
    )
    SELECT latest.id,
           latest.reported_id,
           u.username,
           latest.reason,
           counts.report_count,
           counts.first_reported_at,
           u.display_name,
           u.signup_ordinal,
           u.created_at,
           (SELECT COUNT(*) FROM public.posts po WHERE po.user_id = u.id),
           (SELECT COUNT(*) FROM public.blocks b WHERE b.blocked_id = u.id),
           u.hidden_from_discovery,
           who.reporters
    FROM latest
    JOIN counts         ON counts.reported_id = latest.reported_id
    JOIN who            ON who.reported_id = latest.reported_id
    JOIN public.users u ON u.id = latest.reported_id
    ORDER BY counts.first_reported_at ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_user_reports() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_user_reports() TO authenticated;

-- Check: as the owner in the dashboard, or here (returns rows only for the owner's session):
--   select reported_username, report_count, reporters from public.list_user_reports();
