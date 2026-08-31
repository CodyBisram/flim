-- ============================================================
-- Migration: admin_overview() v2 — invite-by-surface + a signups trend.
-- Paste into Supabase Dashboard -> SQL Editor and run once. Idempotent
-- (CREATE OR REPLACE), and safe to run over the first admin_overview.
--
-- Adds two fields to the same object the Overview panel already reads:
--   invite_sources : shares from each surface (profile / feed / reveal), so the
--                    reveal-invite experiment is answerable on the dashboard
--                    rather than only in a SQL query. Zero until 1.5.1 ships the
--                    source-tagged events; the structure is here so it fills in.
--   signups_daily  : new users per day for the last 14 days, a small trend strip
--                    to read the growth line at a glance the way the reference
--                    dashboard leans on charts, not just standing numbers.
--
-- Everything else is unchanged from v1. Same is_owner gate, SECURITY DEFINER,
-- authenticated-only grant.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_overview()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH gate AS (SELECT public.is_owner() AS ok),
  w AS (
    SELECT now() AS t_now,
           now() - interval '7 days'  AS t0,
           now() - interval '14 days' AS t1,
           (current_date - 7)  AS d0,
           (current_date - 14) AS d1
  )
  SELECT CASE WHEN (SELECT ok FROM gate) THEN jsonb_build_object(
    'generated_at', (SELECT t_now FROM w),

    'totals', jsonb_build_object(
      'users',     (SELECT count(*) FROM public.users),
      'ever_shot', (SELECT count(DISTINCT user_id) FROM public.photos),
      'photos',    (SELECT count(*) FROM public.photos),
      'rolls',     (SELECT count(*) FROM public.rolls)
    ),

    'week', jsonb_build_object(
      'new_users', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.users, w WHERE created_at >= t0),
        'prev', (SELECT count(*) FROM public.users, w WHERE created_at >= t1 AND created_at < t0)),
      'active_shooters', jsonb_build_object(
        'now',  (SELECT count(DISTINCT user_id) FROM public.photos, w WHERE taken_at >= t0),
        'prev', (SELECT count(DISTINCT user_id) FROM public.photos, w WHERE taken_at >= t1 AND taken_at < t0)),
      'shots', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.photos, w WHERE taken_at >= t0),
        'prev', (SELECT count(*) FROM public.photos, w WHERE taken_at >= t1 AND taken_at < t0)),
      'posts', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.posts, w WHERE created_at >= t0),
        'prev', (SELECT count(*) FROM public.posts, w WHERE created_at >= t1 AND created_at < t0)),
      'reveals', jsonb_build_object(
        'now',  (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events, w
                  WHERE event = 'reveal_watched' AND day >= d0),
        'prev', (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events, w
                  WHERE event = 'reveal_watched' AND day >= d1 AND day < d0)),
      'invites_redeemed', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.allowed_emails, w
                  WHERE note LIKE 'invited_by:%' AND added_at >= t0),
        'prev', (SELECT count(*) FROM public.allowed_emails, w
                  WHERE note LIKE 'invited_by:%' AND added_at >= t1 AND added_at < t0))
    ),

    -- NEW: which surface an invite share came from. All-time volume, since the
    -- question is "does the reveal placement get used at all", not this week only.
    'invite_sources', jsonb_build_object(
      'profile', (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events WHERE event = 'invite_shared_profile'),
      'feed',    (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events WHERE event = 'invite_shared_feed'),
      'reveal',  (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events WHERE event = 'invite_shared_reveal')
    ),

    -- NEW: new users per day, oldest first, last 14 days. A trend strip for the panel.
    'signups_daily', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'day', to_char(dd, 'MM-DD'),
               'n',   (SELECT count(*) FROM public.users u
                        WHERE u.created_at >= dd AND u.created_at < dd + interval '1 day'))
             ORDER BY dd), '[]'::jsonb)
      FROM generate_series((current_date - 13)::timestamptz, current_date::timestamptz, interval '1 day') dd
    ),

    'attention', jsonb_build_object(
      'never_asked_notifications', (
        SELECT count(*) FROM public.users u
        WHERE NOT EXISTS (SELECT 1 FROM public.device_tokens d WHERE d.user_id = u.id)
          AND NOT EXISTS (SELECT 1 FROM public.activation_events a
                          WHERE a.user_id = u.id
                            AND a.event IN ('notifications_authorized', 'notifications_denied'))),
      'invite_senders_ever', (
        SELECT count(DISTINCT substring(note FROM 12))
        FROM public.allowed_emails WHERE note LIKE 'invited_by:%'),
      'days_since_last_roll', (
        SELECT floor(extract(epoch FROM now() - max(created_at)) / 86400)::int
        FROM public.rolls)
    )
  ) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.admin_overview() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_overview() TO authenticated;
