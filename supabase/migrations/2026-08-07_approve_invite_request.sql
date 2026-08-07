-- ============================================================
-- Migration: approving an invite request in one step
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-07_invite_requests.sql.
--
-- Approving used to be two statements typed by hand: insert the address into
-- allowed_emails, then mark the request handled. Two statements means one of
-- them gets forgotten, and a request marked handled but never allowlisted is
-- somebody who asked, was told they were on the list, and then silently never
-- heard back.
--
-- ⚠️ THIS FUNCTION GRANTS ACCESS TO THE APP. It is owner-only, and the REVOKEs
-- below are the only thing standing between it and self-service signup. Read
-- the note on them before changing anything here.
-- ============================================================

CREATE OR REPLACE FUNCTION public.approve_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;

    -- Allowlisting is the part that matters, so it happens first and is
    -- idempotent. Approving somebody twice is harmless.
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invite request')
    ON CONFLICT (email) DO NOTHING;

    -- Marking handled is bookkeeping. An address approved without ever having
    -- asked (someone you just decided to add) updates nothing here, which is
    -- correct rather than an error.
    UPDATE public.invite_requests SET handled = TRUE WHERE email = v_email;

    RETURN TRUE;
END;
$$;

-- ⚠️ The whole invite gate rests on these three lines.
--
-- This project carries the stock Supabase default privileges, which GRANT
-- EXECUTE on every newly created function to anon, authenticated AND
-- service_role at creation time. Without the explicit revokes below, any signed
-- out visitor could call this over the public REST endpoint with their own
-- address and allowlist themselves, and FLIM would be open to anyone who read
-- the page source. Revoking PUBLIC alone does NOT remove a grant made to a
-- named role.
--
-- Nothing is granted back. The owner calls this from the SQL editor or with the
-- service role key, both of which bypass these grants entirely.
REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM authenticated;

-- ---- How to work the queue -------------------------------------------------
--
-- See who is waiting:
--   SELECT email, note, created_at FROM public.invite_requests
--   WHERE NOT handled ORDER BY created_at;
--
-- Approve one, which allowlists them and clears them from the queue:
--   SELECT public.approve_invite_request('them@example.com');
--
-- Turn somebody down without allowlisting them, so they stop reappearing:
--   UPDATE public.invite_requests SET handled = TRUE WHERE email = 'them@example.com';
--
-- They can request an OTP as soon as they are allowlisted. Nothing is sent to
-- them automatically, so tell them yourself.
