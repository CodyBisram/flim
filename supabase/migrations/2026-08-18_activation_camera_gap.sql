-- ============================================================
-- Migration: two activation events that split the one gap the funnel cannot
-- currently explain.
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER 2026-08-08_activation_events.sql (long applied). Nothing
-- else depends on it, and it is additive: it widens a CHECK and touches no row.
--
-- WHY THESE TWO, AND NOT A SWEEP OF NEW EVENTS
-- ---------------------------------------------
-- The funnel is already instrumented end to end, and cohort-scoped to the 21
-- accounts that signed up on or after 2026-08-12 (the date the last of these
-- events shipped, so earlier accounts cannot answer for steps that did not yet
-- exist) it reads:
--
--     first_launch          20    95%
--     onboarding_finished   19    90%
--     camera_authorized     20    95%
--     first_shot            11    52%   <- the cliff
--     post_shared            7    33%
--     roll_joined            2    10%
--     reveal_watched         0     0%
--
-- Onboarding is not the problem and permission is not the problem: 20 of 21
-- reach a camera the app itself confirms is authorized. Then nine of them never
-- take a photograph. Every question about why is currently unanswerable,
-- because `camera_authorized` fires when AUTHORIZATION is granted, which is not
-- the same as the preview ever producing a frame, and nothing at all records an
-- attempt to shoot.
--
-- So exactly two events, both once-ever, both sitting inside that gap:
--
--   camera_ready    the preview delivered its first real frame. Separates "the
--                   camera never actually worked for them" -- a black viewfinder
--                   is a bug this app has genuinely had before -- from "the
--                   camera worked and they left".
--   shutter_tapped  they tried at least once. If this sits near 20 while
--                   first_shot sits at 11, captures are FAILING and that is a
--                   completely different bug from anything about intent.
--
-- Three outcomes, three different fixes, and today all three look identical.
-- Deliberately not added: anything that would need to know what someone was
-- looking at, or how long for. This is a funnel, not a session recorder, and
-- the day-bucket privacy stance the instrumentation was built under still holds.
--
-- These belong in activation_events rather than usage_events because the
-- question is "did this account ever get this far", which is exactly what that
-- table's unique index on (user_id, event) is for. Frequency is not interesting
-- here; reaching the step once is the whole signal.
-- ============================================================

ALTER TABLE public.activation_events DROP CONSTRAINT IF EXISTS activation_events_event_check;
ALTER TABLE public.activation_events ADD CONSTRAINT activation_events_event_check CHECK (
    event = ANY (ARRAY[
        'first_launch',
        'onboarding_finished',
        'camera_authorized',
        'camera_ready',
        'shutter_tapped',
        'first_shot',
        'roll_created',
        'roll_joined',
        'invite_sent',
        'invite_redeemed',
        'post_shared',
        'reveal_watched'
    ])
);


-- ---- Verify -----------------------------------------------------------------
--
--   -- Both new names must be present.
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname = 'activation_events_event_check';
--
--   -- The funnel, cohort-scoped. Re-run with a LATER cutoff once a build
--   -- carrying camera_ready and shutter_tapped has been out long enough to
--   -- have a cohort of its own: comparing a step against accounts that
--   -- predate it is the one way this table lies.
--   WITH cohort AS (SELECT id FROM public.users WHERE created_at >= '2026-08-12')
--   SELECT ae.event, COUNT(DISTINCT ae.user_id) AS users
--   FROM public.activation_events ae JOIN cohort c ON c.id = ae.user_id
--   GROUP BY ae.event ORDER BY users DESC;
