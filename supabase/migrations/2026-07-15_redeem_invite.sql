-- ============================================================
-- Migration: server-side invite-code redemption (redeem_invite RPC)
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
-- ⚠️ run this BEFORE pushing the Swift client that calls redeem_invite.
-- Statements are in dependency order (rate-gate table, then column, then
-- function + grants).
--
-- What this adds: a friend enters their invite_code + your email in the app,
-- pre-sign-in (no session yet, same as is_email_allowed). redeem_invite()
-- looks the code up against users.invite_code and, on a match, adds your
-- email to allowed_emails so is_email_allowed() then lets you request an
-- OTP. No inviter match returns FALSE and writes nothing.
--
-- Rate gate is GLOBAL, not per-actor: 30 attempts per rolling hour across
-- every caller, full stop. Per-IP/per-email keying would defeat nothing —
-- an attacker brute-forcing the 36^6 code keyspace rotates both trivially —
-- and it would need its own indexing/cleanup for no real benefit. A flat
-- global gate is simpler, can't be bypassed by rotating identity, and
-- 30/hour is far above any real invite flow while still crushing the
-- brute-force math. `id BOOLEAN PK CHECK (id)` is a standard singleton-row
-- trick: id can only ever be TRUE, and TRUE is already the primary key, so a
-- second row is structurally impossible.
--
-- note stores the inviter's UUID, not their username: usernames are
-- nullable and can change, so a username snapshot would go stale or be
-- missing. The UUID is a stable, permanent audit trail back to users.id.
--
-- RETURN TRUE is idempotent by design: ON CONFLICT DO NOTHING on the
-- allowed_emails insert plus an unconditional RETURN TRUE means redeeming
-- the same valid code for the same email twice (double-tap, client retry)
-- is always safe, never errors, never writes a second row — and it closes
-- an email-enumeration side channel, since "already allowed" and "freshly
-- allowed" look identical to the caller.
-- ============================================================

-- 1. Singleton rate-gate table. RLS on, no policies, and every role's
--    implicit privileges are stripped — reachable only from inside
--    redeem_invite()'s SECURITY DEFINER body.
CREATE TABLE IF NOT EXISTS public.redeem_invite_rate (
    id           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
INSERT INTO public.redeem_invite_rate (id) VALUES (TRUE) ON CONFLICT DO NOTHING;
ALTER TABLE public.redeem_invite_rate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redeem_invite_rate FROM PUBLIC, anon, authenticated;

-- 2. Forward-compat hook for scarce invites ("this code works N times").
--    Nullable; NULL = unlimited, which is every existing row and everything
--    v1 enforces. redeem_invite() does not read or decrement this column
--    yet — wiring it in later is additive, no shape change needed.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS invite_uses_remaining INT;

-- 3. The RPC itself.
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code TEXT, p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_email    TEXT := LOWER(TRIM(p_email));
    v_code     TEXT := UPPER(TRIM(p_code));
    v_inviter  UUID;
    v_window   TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    -- Global rate gate. FOR UPDATE serializes concurrent callers on the
    -- single row so two requests can't both read attempts=29 and slip
    -- through together.
    SELECT window_start, attempts INTO v_window, v_attempts
    FROM public.redeem_invite_rate
    WHERE id = TRUE
    FOR UPDATE;

    IF v_window < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.redeem_invite_rate SET window_start = NOW(), attempts = 1 WHERE id = TRUE;
    ELSIF v_attempts >= 30 THEN
        RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0003';
    ELSE
        UPDATE public.redeem_invite_rate SET attempts = attempts + 1 WHERE id = TRUE;
    END IF;

    -- Case/whitespace-insensitive match against the inviting user's own code.
    SELECT id INTO v_inviter FROM public.users WHERE invite_code = v_code LIMIT 1;

    IF v_inviter IS NULL THEN
        RETURN FALSE;
    END IF;

    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invited_by:' || v_inviter::text)
    ON CONFLICT (email) DO NOTHING;

    RETURN TRUE;
END;
$$;

-- 4. Grants: explicit REVOKE-then-GRANT-to-both, not just one role. The
--    outage lesson documented at is_blocked_either_way in schema.sql is that
--    a client-callable function's EXECUTE grants must be spelled out for
--    every role that calls it — SECURITY DEFINER only changes whose
--    privileges the BODY runs with, it does not substitute for the caller
--    needing EXECUTE. redeem_invite is called pre-sign-in (anon) and is
--    harmless to also allow post-sign-in (authenticated), same shape as
--    is_email_allowed.
REVOKE ALL ON FUNCTION public.redeem_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(TEXT, TEXT) TO anon, authenticated;
