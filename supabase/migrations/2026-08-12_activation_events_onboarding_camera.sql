-- ============================================================
-- Migration: widen public.activation_events' event allowlist by exactly two
-- values, so the funnel can explain its biggest leak instead of only
-- measuring it: 9 of 25 accounts never took a photo, and today there is
-- nothing recorded between `first_launch` and `first_shot`, so the data can
-- only ever say "they launched and never shot", conflating abandoning
-- onboarding, denying camera permission, and reaching a working camera and
-- leaving. Those need three different responses.
--
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-08_activation_events.sql (already applied).
-- ⚠️ run this BEFORE pushing the Swift client that calls
--    log_activation_event('onboarding_finished') /
--    log_activation_event('camera_authorized').
--
-- New events, inserted into the funnel's narrative order right after
-- first_launch and before first_shot:
--   onboarding_finished  <- reached the end of onboarding
--   camera_authorized    <- camera permission was granted
--
-- No table, index, RLS policy, or RPC signature changes. Only the CHECK
-- constraint's allowed set and activation_funnel()'s known-event list widen.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Widen the CHECK constraint. DROP and ADD are two clauses of the SAME
--    ALTER TABLE statement, not two separate statements, so this is one
--    atomic DDL command: if the new constraint's validation scan (against
--    every existing row) fails for any reason, Postgres rolls the whole
--    statement back and the table is left with its original constraint
--    intact, never unconstrained. Existing rows only ever contain the
--    original 8 event values, all of which remain in this list, so the
--    validation scan is guaranteed to pass.
-- ------------------------------------------------------------
ALTER TABLE public.activation_events
    DROP CONSTRAINT IF EXISTS activation_events_event_check,
    ADD CONSTRAINT activation_events_event_check CHECK (event IN (
        'first_launch', 'onboarding_finished', 'camera_authorized', 'first_shot',
        'roll_created', 'roll_joined', 'invite_sent', 'invite_redeemed',
        'post_shared', 'reveal_watched'
    ));

-- ------------------------------------------------------------
-- 2. activation_funnel()'s known-event list is hardcoded (not derived from
--    the CHECK constraint or any other source), so it must be widened here
--    too, in the same order, or the two new events would silently never
--    appear in the very report they exist to feed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activation_funnel()
RETURNS TABLE (
    event          TEXT,
    distinct_users BIGINT,
    total_users    BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total BIGINT;
BEGIN
    IF NOT public.is_owner() THEN
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_total FROM public.users;

    RETURN QUERY
    SELECT
        ev.event,
        COALESCE(COUNT(DISTINCT ae.user_id), 0)::BIGINT AS distinct_users,
        v_total AS total_users
    FROM unnest(ARRAY[
        'first_launch', 'onboarding_finished', 'camera_authorized', 'first_shot',
        'roll_created', 'roll_joined', 'invite_sent', 'invite_redeemed',
        'post_shared', 'reveal_watched'
    ]) WITH ORDINALITY AS ev(event, ord)
    LEFT JOIN public.activation_events ae ON ae.event = ev.event
    GROUP BY ev.event, ev.ord
    ORDER BY ev.ord;
END;
$$;

-- ------------------------------------------------------------
-- 3. Grants unchanged, re-stated for safety since CREATE OR REPLACE
--    FUNCTION does not touch existing grants, but Supabase's stock default
--    privileges grant EXECUTE to anon at CREATE time on brand new function
--    objects; this is a REPLACE of an existing one, so grants are untouched,
--    but re-asserting costs nothing and keeps this migration self-contained.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.activation_funnel() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.activation_funnel() FROM anon;
GRANT EXECUTE ON FUNCTION public.activation_funnel() TO authenticated;

-- log_activation_event(TEXT) itself is untouched: same signature, same body,
-- same grants. No new events need backfilling either: nothing in the
-- existing schema is evidence that onboarding finished or camera permission
-- was granted (unlike first_shot, which photos.taken_at proves happened),
-- so, same policy as first_launch and invite_sent above, these start empty
-- and are populated only by the client going forward.
