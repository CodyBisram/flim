-- ============================================================
-- Migration: in-app feedback capture (submit_feedback RPC + owner queue)
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-07_admin_dashboard.sql (public.is_owner()).
-- ⚠️ run this BEFORE pushing the Swift client that calls submit_feedback.
--
-- The app's only feedback path used to be a mailto: draft: it depends on the
-- person switching to Mail and pressing send, and it cannot carry diagnostics.
-- This lands the report directly in the database and captures the build and
-- device context that would otherwise take a round trip to ask for.
--
-- Shape mirrors invite_requests / redeem_invite: a table with RLS on and no
-- policies, reachable only through SECURITY DEFINER functions, plus a
-- singleton rate-gate table so a compromised or buggy client can't flood it.
-- Unlike those two, the caller here is a signed-in app user (not a stranger
-- pre-auth), so submit_feedback is granted to authenticated only, never anon,
-- and records auth.uid() itself rather than trusting a caller-supplied id.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The reports themselves. RLS on, zero policies: the only way in is
--    submit_feedback() below, and the only way out is list_feedback() /
--    dismiss_feedback(), both owner-gated.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feedback (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID REFERENCES public.users(id) ON DELETE CASCADE,
    message      TEXT NOT NULL,
    app_version  TEXT,
    app_build    TEXT,
    os_version   TEXT,
    device_model TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    handled      BOOLEAN NOT NULL DEFAULT FALSE
);

ALTER TABLE public.feedback ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feedback FROM PUBLIC, anon, authenticated;

-- Owner's queue reads unhandled rows oldest-first; index keeps that cheap as
-- the table grows instead of scanning every historical report.
CREATE INDEX IF NOT EXISTS feedback_unhandled_idx ON public.feedback (created_at) WHERE NOT handled;
CREATE INDEX IF NOT EXISTS feedback_user_id_idx ON public.feedback (user_id);

-- ------------------------------------------------------------
-- 2. Global rate gate, same singleton trick as redeem_invite_rate and
--    invite_request_rate: id can only ever be TRUE, and TRUE is already the
--    primary key, so a second row is structurally impossible. A flat global
--    cap (not per-user) is deliberate here too, a compromised or scripted
--    client rotating identities defeats per-user keying for free and it
--    would need its own indexing and cleanup for no real benefit. 50 an hour
--    across every caller is far above anything a real person filing a bug
--    report would ever hit.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.feedback_rate (
    id           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
INSERT INTO public.feedback_rate (id) VALUES (TRUE) ON CONFLICT DO NOTHING;
ALTER TABLE public.feedback_rate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feedback_rate FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 3. submit_feedback. auth.uid() is the only source of the author, a caller
--    cannot claim to be someone else. An empty or whitespace-only message
--    returns FALSE rather than erroring, since that's a client-side validation
--    miss, not abuse; an over-length message is silently trimmed to 2000
--    characters rather than rejected, since a report that's too long is still
--    a report worth keeping.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_feedback(
    p_message      TEXT,
    p_app_version  TEXT,
    p_app_build    TEXT,
    p_os_version   TEXT,
    p_device_model TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_message  TEXT;
    v_window   TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    -- Belt-and-suspenders: the EXECUTE grant already keeps this off anon, but
    -- a NULL auth.uid() would otherwise insert an author-less row.
    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    v_message := LEFT(TRIM(COALESCE(p_message, '')), 2000);
    IF v_message = '' THEN
        RETURN FALSE;
    END IF;

    -- Global rate gate. FOR UPDATE serializes concurrent callers on the
    -- single row so two requests can't both read attempts=49 and slip
    -- through together.
    SELECT window_start, attempts INTO v_window, v_attempts
    FROM public.feedback_rate
    WHERE id = TRUE
    FOR UPDATE;

    IF v_window < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.feedback_rate SET window_start = NOW(), attempts = 1 WHERE id = TRUE;
    ELSIF v_attempts >= 50 THEN
        RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0003';
    ELSE
        UPDATE public.feedback_rate SET attempts = attempts + 1 WHERE id = TRUE;
    END IF;

    INSERT INTO public.feedback (user_id, message, app_version, app_build, os_version, device_model)
    VALUES (
        auth.uid(),
        v_message,
        NULLIF(TRIM(COALESCE(p_app_version, '')), ''),
        NULLIF(TRIM(COALESCE(p_app_build, '')), ''),
        NULLIF(TRIM(COALESCE(p_os_version, '')), ''),
        NULLIF(TRIM(COALESCE(p_device_model, '')), '')
    );

    RETURN TRUE;
END;
$$;

-- ------------------------------------------------------------
-- 4. Owner-side queue, same shape as list_invite_requests / dismiss_*_report
--    in 2026-08-07_admin_dashboard.sql: the dashboard calls these with the
--    owner's own signed-in session, no service role in that picture, so the
--    gate lives inside the body via is_owner() and the grant opens to
--    authenticated. Non-owner callers get an empty result set from
--    list_feedback and a raised exception from dismiss_feedback, same as the
--    rest of that dashboard.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_feedback()
RETURNS TABLE (
    id           UUID,
    message      TEXT,
    app_version  TEXT,
    app_build    TEXT,
    os_version   TEXT,
    device_model TEXT,
    username     TEXT,
    created_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        f.id,
        f.message,
        f.app_version,
        f.app_build,
        f.os_version,
        f.device_model,
        u.username,
        f.created_at
    FROM public.feedback f
    LEFT JOIN public.users u ON u.id = f.user_id
    WHERE NOT f.handled
    ORDER BY f.created_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.dismiss_feedback(p_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.feedback SET handled = TRUE WHERE id = p_id;

    RETURN TRUE;
END;
$$;

-- ------------------------------------------------------------
-- 5. Grants. This project carries the stock Supabase default privileges,
--    which GRANT ALL on new TABLES and EXECUTE on new FUNCTIONS to anon and
--    authenticated at creation time. The table grants are already stripped in
--    steps 1 and 2. Every function below gets the same explicit
--    REVOKE-then-GRANT treatment: submit_feedback is authenticated-only (the
--    caller is a signed-in app user, never anon), and list_feedback /
--    dismiss_feedback are granted to authenticated with the real gate inside
--    the body, same reasoning as every other owner-dashboard function.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.submit_feedback(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_feedback(TEXT, TEXT, TEXT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_feedback(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.list_feedback() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_feedback() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_feedback() TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_feedback(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dismiss_feedback(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.dismiss_feedback(UUID) TO authenticated;

-- ---- How the app and the dashboard use this --------------------------------
--
-- App (signed-in user):
--   SELECT submit_feedback('the camera crashed on the third photo', '1.3', '151', '18.5', 'iPhone15,3');
--
-- Dashboard (owner's own session):
--   SELECT * FROM list_feedback();
--   SELECT dismiss_feedback('<feedback-uuid>');
--
-- Both dashboard calls no-op (empty list, or a raised exception on the write
-- call) for any caller whose auth.uid() does not resolve to codyysb@gmail.com
-- in public.users, regardless of what key or session called them with.
