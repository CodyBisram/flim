-- The app's waitlist joins the website's invite requests (2026-10-06). NOT YET APPLIED. The owner
-- applies it. Idempotent: safe to re-run. Additive: two columns, one stamp, one new function, and
-- three existing functions replaced. No existing row is deleted; existing rows gain source 'web'
-- (true of all of them) and, where an approval can be read back, approved_at (see 2 below).
--
-- Signing up is invite only. Someone who downloads FLIM without a code meets the "you need an
-- invite" wall on the sign-in screen and leaves. The app gains a "Join the waitlist" form (name and
-- email). The website already has the same ask (request_invite into public.invite_requests, read
-- on the dashboard's Invites panel and in the daily invite digest), so the app writes into that
-- same table: one list, one place the owner lets people in.
--
--   1. invite_requests gains name (the app sends one, the website does not) and source ('web' or
--      'app', default 'web', so request_invite is untouched and still writes 'web').
--   2. invite_requests gains approved_at. handled meant "approved or declined", which cannot say
--      who still needs an email from the owner. approve_invite_request now stamps it (once).
--      Backfill: a handled request whose email holds the 'invite request' allowlist note, the note
--      only approve_invite_request writes, was approved; it gets that row's added_at.
--   3. join_waitlist(p_name, p_email) -> 'joined' | 'invalid' | 'rate_limited'. Anon-callable
--      (the caller has no session), SECURITY DEFINER. The answer never says whether an address
--      already asked, is already allowlisted or already has an account: all are 'joined', and
--      only a new address writes a row (source 'app'). An existing request is kept as it is,
--      name and note included. Rate limited per client on the invite rate table
--      ('waitlist:ip:<address>', 5 an hour, the client key invite_preview uses) under a shared
--      ceiling ('waitlist:global', 300 an hour) that only bounds how fast the table can grow.
--      Checked after the input, so a typo does not spend an attempt; a refused call spends
--      nothing (the bumps roll back with it).
--   4. list_invite_requests() also returns name, source, approved_at and has_account (an auth
--      account with that address exists now), and lists approved requests as well as waiting
--      ones, so the dashboard can show who was let in but has not signed up. Declined requests
--      (handled, never approved) stay out, as before. The return type changes, so it is dropped
--      first. Old dashboard copies keep working: email, note and created_at are still there.
--   5. The owner gate in list, approve and decline_invite_request. `IF NOT is_owner()` let a
--      caller with no JWT subject through (NOT NULL is NULL, and IF NULL skips the RAISE). list
--      and decline now refuse unless `auth.uid() IS NOT NULL AND is_owner()`.
--      approve_invite_request refuses the same way for every call that comes through the API
--      (PostgREST connects as `authenticator`), but still accepts a direct database session:
--      the daily invite digest (send-invite-digest) tells the owner to paste
--      `SELECT public.approve_invite_request('...')` into the SQL editor, which has no JWT at
--      all, and such a session already has full access to every table this touches.
--
-- request_invite is not changed. The digest reads invite_requests directly (handled = false), so
-- app requests appear in it too, with no redeploy.
--
-- Verify after applying (expect: every row 'web' before the app ships; then a count of approved):
--   SELECT source, count(*) FROM public.invite_requests GROUP BY 1;
--   SELECT count(*) FILTER (WHERE approved_at IS NOT NULL) AS approved,
--          count(*) FILTER (WHERE handled AND approved_at IS NULL) AS declined,
--          count(*) FILTER (WHERE NOT handled) AS waiting
--   FROM public.invite_requests;

-- ---------------------------------------------------------------------------------------------
-- 1 and 2. Columns
-- ---------------------------------------------------------------------------------------------
ALTER TABLE public.invite_requests
    ADD COLUMN IF NOT EXISTS name TEXT CHECK (name IS NULL OR char_length(name) BETWEEN 1 AND 60);
ALTER TABLE public.invite_requests
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'web' CHECK (source IN ('web', 'app'));
ALTER TABLE public.invite_requests
    ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ NULL;

-- Still no client access to the table at all; the functions below are the only way in.
ALTER TABLE public.invite_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invite_requests FROM PUBLIC, anon, authenticated;

-- Approvals made before the stamp existed. Only rows still unstamped, so a rerun changes nothing.
UPDATE public.invite_requests ir
SET approved_at = ae.added_at
FROM public.allowed_emails ae
WHERE ae.email = ir.email
  AND ae.note = 'invite request'
  AND ir.handled
  AND ir.approved_at IS NULL;

-- ---------------------------------------------------------------------------------------------
-- 3. Joining from the app
-- ---------------------------------------------------------------------------------------------
-- Name: runs of whitespace or control characters become one space, then trimmed; 1 to 60
-- characters. Email: trimmed and lower-cased, at most 254 characters, local@domain.tld with a
-- top-level part of two or more letters, digits or hyphens, and none of , ; < > ( ) " or a
-- control character (so the dashboard's "Copy emails" list can only ever paste as one address
-- per entry).
CREATE OR REPLACE FUNCTION public.join_waitlist(p_name TEXT, p_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_name   TEXT := btrim(regexp_replace(COALESCE(p_name, ''), '[[:space:][:cntrl:]]+', ' ', 'g'));
    v_email  TEXT := lower(btrim(COALESCE(p_email, '')));
    v_client TEXT;
BEGIN
    IF char_length(v_name) NOT BETWEEN 1 AND 60
       OR char_length(v_email) > 254
       OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z0-9-]{2,}$'
       OR v_email ~ '[[:cntrl:],;<>()"]' THEN
        RETURN 'invalid';
    END IF;

    -- Per client first, then the shared ceiling. A refusal from either is caught here, which
    -- rolls back every counter this block bumped, so a refused call spends nothing.
    v_client := public.invite_rate_client();
    BEGIN
        IF v_client IS NOT NULL THEN
            PERFORM public.bump_invite_rate('waitlist:ip:' || v_client, 5);
        END IF;
        PERFORM public.bump_invite_rate('waitlist:global', 300);
    EXCEPTION WHEN SQLSTATE 'P0003' THEN
        RETURN 'rate_limited';
    END;

    -- Already allowed in, or already an account: nothing to wait for, and nothing written.
    IF EXISTS (SELECT 1 FROM public.allowed_emails WHERE email = v_email)
       OR EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email) THEN
        RETURN 'joined';
    END IF;

    -- Already asked, from the app or the website: the first request stands as it is, so a
    -- stranger who knows the address cannot rename someone else's place in line.
    INSERT INTO public.invite_requests (email, name, source)
    VALUES (v_email, v_name, 'app')
    ON CONFLICT (email) DO NOTHING;

    RETURN 'joined';
END;
$$;
REVOKE ALL ON FUNCTION public.join_waitlist(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_waitlist(TEXT, TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4 and 5. The owner's list, approve and decline
-- ---------------------------------------------------------------------------------------------
-- Waiting requests and approved ones; declined ones stay out. Oldest first, as before.
DROP FUNCTION IF EXISTS public.list_invite_requests();
CREATE OR REPLACE FUNCTION public.list_invite_requests()
RETURNS TABLE (
    email       TEXT,
    note        TEXT,
    created_at  TIMESTAMPTZ,
    name        TEXT,
    source      TEXT,
    approved_at TIMESTAMPTZ,
    has_account BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL OR public.is_owner() IS NOT TRUE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT ir.email,
           ir.note,
           ir.created_at,
           ir.name,
           ir.source,
           ir.approved_at,
           EXISTS (SELECT 1 FROM auth.users a WHERE lower(a.email) = ir.email)
    FROM public.invite_requests ir
    WHERE NOT ir.handled OR ir.approved_at IS NOT NULL
    ORDER BY ir.created_at ASC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_invite_requests() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_invite_requests() TO authenticated;

-- Same signature and return as before. Lets the email in (allowlist note 'invite request', kept
-- if the email was already allowlisted), marks the request handled, stamps approved_at once.
-- Returns FALSE for an empty email, as before. A request that does not exist still allowlists
-- the email, as before: the digest's SQL and the dashboard both pass an address it listed.
CREATE OR REPLACE FUNCTION public.approve_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    -- Through the API, only the signed-in owner. A direct database session (the SQL editor,
    -- where the invite digest's SQL is pasted) carries no JWT and already has table access.
    IF session_user = 'authenticator'
       AND (auth.uid() IS NULL OR public.is_owner() IS NOT TRUE) THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;

    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invite request')
    ON CONFLICT (email) DO NOTHING;

    UPDATE public.invite_requests
    SET handled = TRUE,
        approved_at = COALESCE(approved_at, NOW())
    WHERE email = v_email;

    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_invite_request(TEXT) TO authenticated;

-- Same signature, return and effect as before; only the gate changes.
CREATE OR REPLACE FUNCTION public.decline_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    IF auth.uid() IS NULL OR public.is_owner() IS NOT TRUE THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;

    UPDATE public.invite_requests SET handled = TRUE WHERE email = v_email;

    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.decline_invite_request(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decline_invite_request(TEXT) TO authenticated;
