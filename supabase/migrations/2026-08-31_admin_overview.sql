-- ============================================================
-- Migration: admin_overview() — the dashboard's one-glance home panel.
-- Paste into Supabase Dashboard -> SQL Editor and run once. Idempotent.
--
-- Every other admin_* RPC answers ONE question in depth (the funnel, retention,
-- reach). None of them answers "how is FLIM doing this week" at a glance, which
-- is the first thing the owner opens the dashboard to know. This is that panel:
-- the six numbers that matter, each against the SAME window a week earlier so the
-- direction is visible, a little standing context, and three things worth acting
-- on. It computes, it does not editorialise; the web panel turns a delta into an
-- arrow and a red card.
--
-- Same shape as the rest of 2026-08-19_admin_analytics.sql: SECURITY DEFINER,
-- one is_owner() gate returning NULL to everyone else, granted to authenticated
-- (the gate, not the grant, is what restricts it), revoked from public/anon.
--
-- Sourcing note: everything is read from the source-of-truth tables (users,
-- photos, posts, rolls, allowed_emails) over a rolling 7-day timestamp window,
-- EXCEPT reveals, which is a VOLUME number and so comes from usage_events'
-- day-bucketed counter (activation_events would only count each person's FIRST
-- reveal). Reveals therefore window on whole days, not a rolling instant; at a
-- weekly glance that difference does not show.
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
    SELECT now()                     AS t_now,
           now() - interval '7 days' AS t0,     -- start of THIS week's window
           now() - interval '14 days' AS t1,    -- start of LAST week's window
           (current_date - 7)  AS d0,           -- same, as day buckets for usage_events
           (current_date - 14) AS d1
  )
  SELECT CASE WHEN (SELECT ok FROM gate) THEN jsonb_build_object(
    'generated_at', (SELECT t_now FROM w),

    -- Standing context: the denominators the week's motion happens against.
    'totals', jsonb_build_object(
      'users',     (SELECT count(*) FROM public.users),
      'ever_shot', (SELECT count(DISTINCT user_id) FROM public.photos),
      'photos',    (SELECT count(*) FROM public.photos),
      'rolls',     (SELECT count(*) FROM public.rolls)
    ),

    -- The six headline metrics, each { now, prev } so the panel can draw a delta.
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
      -- Redemptions, the ground truth of growth, from the allowlist note redeem_invite writes.
      -- This is the honest "people who actually got in", separate from invite_sent, which only
      -- began firing on the personal-invite shares this week.
      'invites_redeemed', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.allowed_emails, w
                  WHERE note LIKE 'invited_by:%' AND added_at >= t0),
        'prev', (SELECT count(*) FROM public.allowed_emails, w
                  WHERE note LIKE 'invited_by:%' AND added_at >= t1 AND added_at < t0))
    ),

    -- Three standing facts worth acting on, each a number the panel can flag.
    'attention', jsonb_build_object(
      -- Everyone the notification prompt never reached: not a recorded state, the ABSENCE of
      -- both decisions. The same definition admin_reach uses.
      'never_asked_notifications', (
        SELECT count(*) FROM public.users u
        WHERE NOT EXISTS (SELECT 1 FROM public.device_tokens d WHERE d.user_id = u.id)
          AND NOT EXISTS (SELECT 1 FROM public.activation_events a
                          WHERE a.user_id = u.id
                            AND a.event IN ('notifications_authorized', 'notifications_denied'))),
      -- How concentrated invite-sending is: distinct accounts that have ever brought anyone in.
      -- A small number against a large user base is the whole growth problem in one figure.
      'invite_senders_ever', (
        SELECT count(DISTINCT substring(note FROM 12))
        FROM public.allowed_emails WHERE note LIKE 'invited_by:%'),
      -- Rolls are the stated differentiator; how long since anyone made one is the honest read
      -- on whether that path is alive. NULL if none exist yet.
      'days_since_last_roll', (
        SELECT floor(extract(epoch FROM now() - max(created_at)) / 86400)::int
        FROM public.rolls)
    )
  ) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.admin_overview() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_overview() TO authenticated;

-- ---- Verify (as the owner, via the app's client, or in the SQL editor which
--      runs as a superuser and will see the gate return NULL — expected) -------
--
--   select public.admin_overview();   -- returns the object as the owner, null otherwise
