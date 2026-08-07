-- ============================================================
-- Migration: invite requests from the website (request_invite RPC)
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Run this BEFORE deploying the site that calls request_invite.
--
-- The landing page asks a stranger for their email and a line about who they
-- would put on a roll. They have no session, so this follows the same shape as
-- redeem_invite: an anon-callable SECURITY DEFINER function in front of tables
-- that no client role can touch directly.
--
-- This does NOT allowlist anyone. It only records the ask. Granting access is
-- still a deliberate act by the owner, inserting into allowed_emails, because
-- the whole product promise is that nobody arrives unvetted.
-- ============================================================

-- 1. The requests themselves. email is the key so a double-tap, a retry, or
--    somebody asking twice in a week collapses into one row rather than filling
--    the table with duplicates of the same person.
CREATE TABLE IF NOT EXISTS public.invite_requests (
    email      TEXT PRIMARY KEY,
    note       TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    handled    BOOLEAN NOT NULL DEFAULT FALSE
);

-- 2. Global rate gate, same singleton trick and same reasoning as
--    redeem_invite_rate: keying per IP or per email defeats nothing, since
--    anyone flooding this rotates both for free, and it would need its own
--    indexing and cleanup for no benefit. 60 an hour across all callers is far
--    above any real signup rate and still makes a flood pointless.
CREATE TABLE IF NOT EXISTS public.invite_request_rate (
    id           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
INSERT INTO public.invite_request_rate (id) VALUES (TRUE) ON CONFLICT DO NOTHING;

-- 3. Both tables are reachable only from inside the function below.
--
--    RLS with no policies already denies everything, but the REVOKEs are not
--    redundant: this project carries the stock Supabase default privileges,
--    which GRANT ALL ON TABLES to anon and authenticated at creation time. RLS
--    is the thing actually stopping them today, and a policy added later for
--    some unrelated reason would silently hand over a grant that was never
--    meant to exist. Strip it now.
ALTER TABLE public.invite_requests     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_request_rate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invite_requests     FROM anon, authenticated;
REVOKE ALL ON public.invite_request_rate FROM anon, authenticated;

-- 4. The function.
--
--    Always returns TRUE for a well-formed address, whether the row was new,
--    already there, or dropped by the rate gate. A caller therefore cannot use
--    this to test whether an address has already asked, and cannot tell that a
--    gate exists at all. The only FALSE is a malformed address, which is a
--    validation message rather than information about anyone.
CREATE OR REPLACE FUNCTION public.request_invite(
    p_email TEXT,
    p_note  TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email    TEXT;
    v_note     TEXT;
    v_start    TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    v_email := lower(trim(COALESCE(p_email, '')));

    -- Deliberately loose. Address syntax is not worth policing here; anything
    -- that survives this is still only a row in a table the owner reads by eye.
    IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RETURN FALSE;
    END IF;

    v_note := NULLIF(left(trim(COALESCE(p_note, '')), 500), '');

    SELECT window_start, attempts INTO v_start, v_attempts
    FROM public.invite_request_rate WHERE id FOR UPDATE;

    IF v_start < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.invite_request_rate SET window_start = NOW(), attempts = 1 WHERE id;
    ELSIF v_attempts >= 60 THEN
        RETURN TRUE;
    ELSE
        UPDATE public.invite_request_rate SET attempts = attempts + 1 WHERE id;
    END IF;

    -- A second ask keeps the original timestamp, so the queue stays in the order
    -- people actually first asked, but takes a newer note if one was written:
    -- somebody who comes back with more to say is worth reading.
    INSERT INTO public.invite_requests (email, note)
    VALUES (v_email, v_note)
    ON CONFLICT (email) DO UPDATE
        SET note = COALESCE(EXCLUDED.note, public.invite_requests.note);

    RETURN TRUE;
END;
$$;

-- anon is the point here: the caller is a stranger on the website with no
-- session. authenticated is included so an existing user passing the link on
-- does not hit a permission error.
REVOKE ALL ON FUNCTION public.request_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_invite(TEXT, TEXT) TO anon, authenticated;

-- Read the queue as the owner:
--   SELECT email, note, created_at FROM public.invite_requests
--   WHERE NOT handled ORDER BY created_at;
-- Then allowlist someone the usual way, and mark them off:
--   INSERT INTO public.allowed_emails (email) VALUES ('them@example.com')
--     ON CONFLICT DO NOTHING;
--   UPDATE public.invite_requests SET handled = TRUE WHERE email = 'them@example.com';
