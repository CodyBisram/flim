-- The version census tells "not yet reported" apart from "active on a build too old to report"
-- (2026-09-16). An account with no client_versions row but a reaction, comment, post or photo in
-- the last 30 days is running something older than 1.4.3 (the census shipped 2026-08-21) with
-- automatic updates off; one such account had left 35 reactions while every panel called it
-- dark. Named, because the fix is a text message from the owner, not a push.
CREATE OR REPLACE FUNCTION public.admin_versions()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH gate AS (SELECT public.is_owner() AS ok),
  unreported AS (
    SELECT u.id, u.username,
           GREATEST(
             (SELECT max(created_at) FROM public.post_reactions r WHERE r.user_id = u.id),
             (SELECT max(created_at) FROM public.post_comments c WHERE c.user_id = u.id),
             (SELECT max(created_at) FROM public.posts p WHERE p.user_id = u.id),
             (SELECT max(taken_at) FROM public.photos ph WHERE ph.user_id = u.id)
           ) AS last_activity
    FROM public.users u
    WHERE NOT EXISTS (SELECT 1 FROM public.client_versions c WHERE c.user_id = u.id)
  )
  SELECT CASE WHEN (SELECT ok FROM gate) THEN jsonb_build_object(
    'accounts', (SELECT count(*) FROM public.users),
    'reported', (SELECT count(*) FROM public.client_versions),
    'unreported', (SELECT count(*) FROM unreported),
    'unreported_active', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('username', username, 'last_activity', last_activity)
                                ORDER BY last_activity DESC), '[]'::jsonb)
      FROM unreported WHERE last_activity > now() - interval '30 days'),
    'versions', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'version', v.version,
               'users', v.users,
               'builds', v.builds,
               'last_seen', v.last_seen
             ) ORDER BY v.users DESC, v.version DESC), '[]'::jsonb)
      FROM (
        SELECT version,
               count(*) AS users,
               string_agg(DISTINCT COALESCE(build, '?'), ', ' ORDER BY COALESCE(build, '?')) AS builds,
               max(updated_at) AS last_seen
        FROM public.client_versions
        GROUP BY version
      ) v
    )
  ) ELSE NULL END;
$function$;
