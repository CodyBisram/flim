-- The open door: let people in without an invite code, up to a daily number (2026-10-15). NOT YET
-- APPLIED. The owner applies it. Idempotent: safe to re-run. Changes no existing row, and with the
-- door shut (as it is created) nothing behaves differently from before.
--
-- Why. Signing up needed a code, and almost nobody arrives with one any more: 0 new accounts from
-- 2026-10-08 to 2026-10-15, while App Store search brought a third of first-time downloads. The
-- waitlist was the way in for everyone else, and it was not used: 3 requests in two months, all
-- from the website, none approved. Asking and waiting is the step people skip.
--
-- What. One switch, public.signup_door, shut by default. While it is open and fewer than
-- daily_cap people came in through it in the last 24 hours:
--
--   1. is_email_allowed answers TRUE for any address, so the app (every shipped version) sends
--      the sign-in code instead of showing the invite field.
--   2. gate_new_auth_user (the server's own gate on auth.users) admits the new account and
--      writes its allowed_emails row with note 'open door', which is how the dashboard and the
--      queries below tell this cohort apart. Nobody is credited with inviting them: the note
--      is not invited_by:<uuid>, so no earnback, no invite push, no Recruiter credit.
--
-- join_waitlist is deliberately NOT changed. It takes any address without proving anyone owns
-- it, so letting it admit would let a few calls fill the day's places with made-up addresses.
-- While the door has room nobody is sent to the waitlist anyway: is_email_allowed says yes.
--
-- The new account auto-follows the owner (auto_follow_owner, unchanged), so the first feed is not
-- empty. Personal, campaign and roll codes keep working exactly as before and take precedence:
-- an address already allowlisted never touches the door.
--
-- The cap counts accounts Auth creates, which happens when the code is SENT, so someone who asks
-- for a code and never types it still uses a place. That is the intended bound: the cap limits
-- how many strangers a bad day can let in, not how many finish.
--
-- Shutting the door again stops new admissions only. Everyone who came in keeps their account
-- and can sign in again, since their allowed_emails row stays.
--
-- Owner controls (SQL editor):
--   Open:   UPDATE public.signup_door SET open = TRUE,  updated_at = NOW();
--   Shut:   UPDATE public.signup_door SET open = FALSE, updated_at = NOW();
--   Cap:    UPDATE public.signup_door SET daily_cap = 50, updated_at = NOW();
--   Status: SELECT open, daily_cap,
--                  (SELECT count(*) FROM public.allowed_emails
--                   WHERE note = 'open door' AND added_at > NOW() - INTERVAL '24 hours') AS last_24h,
--                  (SELECT count(*) FROM public.allowed_emails WHERE note = 'open door') AS ever
--           FROM public.signup_door;
--
-- Verify after applying (expect f, 25, then t, t once opened):
--   SELECT open, daily_cap FROM public.signup_door;
--   SELECT public.signup_door_has_room();
--   SELECT has_function_privilege('anon', 'public.signup_door_has_room()', 'EXECUTE');  -- false

-- ---------------------------------------------------------------------------------------------
-- The switch
-- ---------------------------------------------------------------------------------------------
-- One row only (id can only be TRUE). No client access: the owner flips it in the SQL editor,
-- and only the SECURITY DEFINER functions below read it.
CREATE TABLE IF NOT EXISTS public.signup_door (
    id         BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    open       BOOLEAN NOT NULL DEFAULT FALSE,
    daily_cap  INT NOT NULL DEFAULT 25 CHECK (daily_cap BETWEEN 0 AND 1000),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.signup_door (id) VALUES (TRUE) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.signup_door ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.signup_door FROM PUBLIC, anon, authenticated;

-- The open-door admissions in the last 24 hours are found by note and added_at.
CREATE INDEX IF NOT EXISTS allowed_emails_open_door_idx
    ON public.allowed_emails (added_at) WHERE note = 'open door';

-- TRUE while the door is open and has room today. Read-only; the admitting functions take a lock
-- before asking, so two signups at once cannot both take the last place.
CREATE OR REPLACE FUNCTION public.signup_door_has_room()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE((
        SELECT d.open
               AND (SELECT count(*) FROM public.allowed_emails ae
                    WHERE ae.note = 'open door'
                      AND ae.added_at > NOW() - INTERVAL '24 hours') < d.daily_cap
        FROM public.signup_door d
        WHERE d.id
    ), FALSE);
$$;
REVOKE ALL ON FUNCTION public.signup_door_has_room() FROM PUBLIC, anon, authenticated;

-- Lets one address in through the door. Returns TRUE if it is allowed in now (already was, or
-- just admitted), FALSE if the door is shut or full. Called only from the functions below.
CREATE OR REPLACE FUNCTION public.admit_through_door(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT := LOWER(TRIM(COALESCE(p_email, '')));
BEGIN
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;
    IF EXISTS (SELECT 1 FROM public.allowed_emails WHERE email = v_email) THEN
        RETURN TRUE;
    END IF;
    -- One admission at a time, so the count the cap reads is never stale.
    PERFORM pg_advisory_xact_lock(hashtext('public.signup_door'));
    IF NOT public.signup_door_has_room() THEN
        RETURN FALSE;
    END IF;
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'open door')
    ON CONFLICT (email) DO NOTHING;
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.admit_through_door(TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1. is_email_allowed
-- ---------------------------------------------------------------------------------------------
-- From its latest definition (2026-10-10_invite_code_hardening.sql, e), unchanged except the
-- last line. With the door open it answers TRUE for every address, which also stops it saying
-- which addresses are invited. It writes nothing: the row is written when Auth creates the
-- account (2 below), so asking costs no place.
CREATE OR REPLACE FUNCTION public.is_email_allowed(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_client TEXT;
BEGIN
    -- Only calls through the API count. gate_new_auth_user runs this inside Auth's own insert
    -- (session_user is Auth's role there), and account creation must never be rate limited.
    IF session_user = 'authenticator' THEN
        v_client := public.invite_rate_client();
        IF v_client IS NOT NULL THEN
            PERFORM public.bump_invite_rate('allowed:ip:' || v_client, 60);
        END IF;
    END IF;
    RETURN EXISTS (
        SELECT 1 FROM public.allowed_emails
        WHERE email = LOWER(TRIM(p_email))
    ) OR public.signup_door_has_room();
END;
$$;
REVOKE EXECUTE ON FUNCTION public.is_email_allowed(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_email_allowed(TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. gate_new_auth_user
-- ---------------------------------------------------------------------------------------------
-- From its latest definition (2026-09-09_trust_batch.sql; grants from
-- 2026-09-29_backend_audit_b2_b14.sql). An allowlisted address is let in as before; anyone else
-- comes in through the door if it has room, which writes their 'open door' row.
CREATE OR REPLACE FUNCTION public.gate_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.email IS NULL THEN
        RAISE EXCEPTION 'not_invited' USING ERRCODE = 'P0005';
    END IF;
    IF LOWER(TRIM(NEW.email)) = 'review@flim-app.com' THEN
        RETURN NEW;
    END IF;
    IF NOT public.admit_through_door(NEW.email) THEN
        RAISE EXCEPTION 'not_invited' USING ERRCODE = 'P0005';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.gate_new_auth_user() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS gate_new_auth_user_trigger ON auth.users;
CREATE TRIGGER gate_new_auth_user_trigger
    BEFORE INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.gate_new_auth_user();
