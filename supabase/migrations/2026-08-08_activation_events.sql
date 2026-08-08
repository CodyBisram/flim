-- ============================================================
-- Migration: activation instrumentation (activation_events table,
-- log_activation_event RPC, activation_funnel RPC, plus a one-time backfill).
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-07_admin_dashboard.sql (public.is_owner()).
-- ⚠️ run this BEFORE pushing the Swift client that calls log_activation_event.
--
-- The app ships with no analytics of any kind today. This is a deliberate
-- in-house replacement for a third-party SDK (PostHog, Amplitude, etc): FLIM's
-- own App Store listing promises "no algorithm, no strangers", and shipping
-- behavioural data off-device to a third party contradicts that and adds a
-- privacy disclosure. A table in a database the owner already runs is cheaper,
-- more private, and enough at this scale.
--
-- Every row is a "first time X happened" MILESTONE per user, not an event
-- stream: (user_id, event) is unique. This is what lets the client fire e.g.
-- `first_shot` on every single capture rather than maintaining a local "have I
-- already logged this" flag, simpler and less bug-prone on the client, the
-- database is what makes it idempotent, not client state.
--
-- Cost: capped at one row per (user, event) across the 8 known events below,
-- so at 1,000 users this is at most 8,000 rows, ever. Negligible.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The table. A typo in the client (or a future event nobody wired up here)
--    is a loud constraint-violation error, not a silently-accepted junk row.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activation_events (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    event      TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT activation_events_event_check CHECK (event IN (
        'first_launch', 'first_shot', 'roll_created', 'roll_joined',
        'invite_sent', 'invite_redeemed', 'post_shared', 'reveal_watched'
    ))
);

-- The idempotence guarantee itself, and the ON CONFLICT target
-- log_activation_event() below relies on.
CREATE UNIQUE INDEX IF NOT EXISTS activation_events_user_event_idx
    ON public.activation_events (user_id, event);
CREATE INDEX IF NOT EXISTS activation_events_event_idx ON public.activation_events (event);

-- ------------------------------------------------------------
-- 2. RLS. A user may insert only their own row, and in practice only ever
--    does so through log_activation_event() below. NOBODY may SELECT
--    directly, not even the row's own user, only the owner, gated the same
--    way list_feedback / list_invite_requests / list_photo_reports already
--    are. No UPDATE or DELETE policy exists at all, so both are refused
--    outright under RLS: this table is append-only.
-- ------------------------------------------------------------
ALTER TABLE public.activation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "activation_events: insert own" ON public.activation_events;
CREATE POLICY "activation_events: insert own"
    ON public.activation_events FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "activation_events: owner reads" ON public.activation_events;
CREATE POLICY "activation_events: owner reads"
    ON public.activation_events FOR SELECT TO authenticated
    USING (public.is_owner());

-- ------------------------------------------------------------
-- 3. log_activation_event. No-op (not an error) when auth.uid() is null, so a
--    client bug (a stray call before sign-in, a race during sign-out) can
--    never crash a capture call. An unknown p_event still raises loudly via
--    the CHECK constraint above, that failure mode is intentional.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_activation_event(p_event TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO public.activation_events (user_id, event)
    VALUES (auth.uid(), p_event)
    ON CONFLICT (user_id, event) DO NOTHING;
END;
$$;

-- ------------------------------------------------------------
-- 4. activation_funnel, owner-gated exactly like list_feedback: a non-owner
--    caller gets an empty result set, never an error and never real rows. One
--    row per KNOWN event, even ones with zero occurrences so far (LEFT JOIN,
--    not a plain GROUP BY over the table), so "0 of N have done this yet" is
--    a visible row rather than a missing one, plus the current total user
--    count on every row.
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
        'first_launch', 'first_shot', 'roll_created', 'roll_joined',
        'invite_sent', 'invite_redeemed', 'post_shared', 'reveal_watched'
    ]) WITH ORDINALITY AS ev(event, ord)
    LEFT JOIN public.activation_events ae ON ae.event = ev.event
    GROUP BY ev.event, ev.ord
    ORDER BY ev.ord;
END;
$$;

-- ------------------------------------------------------------
-- 5. Grants. This project carries the stock Supabase default privileges,
--    which GRANT EXECUTE on new FUNCTIONS to anon and authenticated at
--    creation time, and REVOKE FROM PUBLIC alone does not remove anon's own
--    named grant. Both RPCs are authenticated-only, never anon.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.log_activation_event(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_activation_event(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_activation_event(TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.activation_funnel() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.activation_funnel() FROM anon;
GRANT EXECUTE ON FUNCTION public.activation_funnel() TO authenticated;

-- ------------------------------------------------------------
-- 6. One-time backfill: derive what the existing data already proves
--    happened, so the funnel isn't empty on day one. Every INSERT uses that
--    event's REAL historical timestamp (never now()), and ON CONFLICT DO
--    NOTHING makes each one idempotent and safe to re-run, and safe to run
--    alongside the live RPC (whichever writes a given (user, event) row first
--    wins; nothing is ever overwritten).
--
--    Derived, because the existing data unambiguously proves the event
--    happened at a specific, recoverable time:
--      first_shot      <- earliest public.photos row per user (taken_at)
--      roll_created     <- earliest public.rolls row per creator (created_at)
--      roll_joined      <- earliest public.roll_members row per user (joined_at)
--      reveal_watched   <- earliest public.roll_reveal_views row per user (viewed_at)
--      post_shared      <- earliest public.posts row per user (created_at); a
--                           posts row IS the "shared a photo to the feed"
--                           action, there is no other write path that creates one
--      invite_redeemed  <- redeem_invite() stamps allowed_emails.note with
--                           'invited_by:<uuid>' the moment a code is redeemed;
--                           joined back to the user who went on to sign up
--                           with that email, timestamped by
--                           allowed_emails.added_at (when the redemption
--                           itself happened, not when they later signed up)
--
--    NOT derived. No evidence exists anywhere in this schema for either, so
--    nothing is invented:
--      first_launch  <- nothing has ever recorded a launch or session; this
--                        table did not exist before this change, and there is
--                        no proxy for it (sign-in only proves an account
--                        exists, not that any particular later launch happened).
--      invite_sent   <- redeem_invite() records that a code WAS redeemed by
--                        someone, never that the owner's code was shared/sent
--                        out; a code that was sent but never used leaves no
--                        row anywhere. Only the client, going forward, can
--                        know this.
-- ------------------------------------------------------------
INSERT INTO public.activation_events (user_id, event, created_at)
SELECT user_id, 'first_shot', MIN(taken_at)
FROM public.photos
GROUP BY user_id
ON CONFLICT (user_id, event) DO NOTHING;

INSERT INTO public.activation_events (user_id, event, created_at)
SELECT created_by, 'roll_created', MIN(created_at)
FROM public.rolls
GROUP BY created_by
ON CONFLICT (user_id, event) DO NOTHING;

INSERT INTO public.activation_events (user_id, event, created_at)
SELECT user_id, 'roll_joined', MIN(joined_at)
FROM public.roll_members
GROUP BY user_id
ON CONFLICT (user_id, event) DO NOTHING;

INSERT INTO public.activation_events (user_id, event, created_at)
SELECT user_id, 'reveal_watched', MIN(viewed_at)
FROM public.roll_reveal_views
GROUP BY user_id
ON CONFLICT (user_id, event) DO NOTHING;

INSERT INTO public.activation_events (user_id, event, created_at)
SELECT user_id, 'post_shared', MIN(created_at)
FROM public.posts
GROUP BY user_id
ON CONFLICT (user_id, event) DO NOTHING;

INSERT INTO public.activation_events (user_id, event, created_at)
SELECT u.id, 'invite_redeemed', MIN(ae.added_at)
FROM public.allowed_emails ae
JOIN public.users u ON lower(u.email) = ae.email
WHERE ae.note LIKE 'invited_by:%'
GROUP BY u.id
ON CONFLICT (user_id, event) DO NOTHING;

-- ---- How the app and the dashboard use this --------------------------------
--
-- App (signed-in user, fire-and-forget, safe to call every time):
--   SELECT log_activation_event('first_shot');
--
-- Dashboard / SQL editor (owner's own session):
--   SELECT * FROM activation_funnel();
--
-- The funnel call no-ops (empty result set) for any caller whose auth.uid()
-- does not resolve to codyysb@gmail.com in public.users, regardless of what
-- key or session called it with.
