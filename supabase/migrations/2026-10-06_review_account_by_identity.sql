-- The review login is recognised by who it is, not by what it is called (2026-10-06). NOT YET
-- APPLIED. The owner applies it. Idempotent: safe to re-run. Changes no existing row.
--
-- 2026-09-29_review_account_takes_no_seat.sql kept the App Review login out of the member numbers
-- by matching its username, lower(username) ~ '^applereview[0-9]*$'. Two problems, both from the
-- nightly review (docs/reviews/OPEN.md, 2026-09-30):
--
--   1. assign_signup_ordinal gave NULL to ANY new account with a matching username, so a real
--      person who picked "applereview2" lost their member number for good (the number is fixed at
--      signup and lock_signup_ordinal_trigger pins it on every UPDATE).
--   2. The one-time renumbering shift in that migration (folded into schema.sql) was guarded by
--      the same pattern, so a real member who later renamed to "applereview3" would have fired it
--      again on the next schema.sql reapply: their number set to NULL and everyone above them
--      moved down one, out of step with founding_100 badges already granted.
--
-- The review login has one fixed identity: its sign-in address, review@flim-app.com, the only
-- address gate_new_auth_user lets through without an invite and the only one AuthService offers
-- the password sign-in. auth.users.email is written by Auth, not by the app (public.users.email
-- is client-written at signup and is NOT used here), and a change of auth email has to be
-- confirmed from the new inbox, which is the owner's. So:
--
--   a. is_review_account(uuid): true only for the account whose auth email is that address.
--      Internal: EXECUTE revoked from PUBLIC, anon and authenticated.
--   b. assign_signup_ordinal: the review login (by identity) gets NULL at signup; everyone else
--      gets MAX + 1 as before, whatever their username. Takes effect for new signups only.
--   c. The shift (schema.sql's fold and the 2026-09-29 file itself) now fires only for the review
--      login by identity, only if it signed up before the shift existed (auth created_at before
--      2026-09-30), and only while no account holds NULL yet, which was true exactly once: in
--      production before 2026-09-29. Edited in place there, since that block is what reruns; this
--      file carries no shift of its own.
--   d. schema.sql's original backfill (the ROW_NUMBER pass beside the signup_ordinal column) also
--      skips the review login by identity on a rerun, as well as by the old name test.
--
-- Production outcome: none on existing rows. Every number stays where it is; the review login
-- keeps NULL; real members keep theirs. Only who gets NULL at future signups changes.
--
-- Before applying, confirm production's review login really is that address (expect 1 | t):
--   SELECT count(*), bool_and(u.signup_ordinal IS NULL)
--   FROM public.users u JOIN auth.users a ON a.id = u.id
--   WHERE lower(a.email) = 'review@flim-app.com';
-- After applying (expect 1 NULL row, the review login, and no gaps; same numbers as before):
--   SELECT count(*) FILTER (WHERE signup_ordinal IS NULL), count(signup_ordinal),
--          min(signup_ordinal), max(signup_ordinal), count(DISTINCT signup_ordinal)
--   FROM public.users;

-- ---------------------------------------------------------------------------
-- a. Who the review login is
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_review_account(p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM auth.users a
        WHERE a.id = p_user
          AND lower(a.email) = 'review@flim-app.com'
    );
$$;
REVOKE ALL ON FUNCTION public.is_review_account(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- b. Assignment: the review login gets no number, nobody else is affected by their name
-- ---------------------------------------------------------------------------
-- Same signature, trigger and lock as the 2026-09-29 definition. NEW.id is the caller's own
-- auth.uid() ("users: own row" pins it), and the auth row exists before the profile row does, so
-- the identity is known at INSERT time.
CREATE OR REPLACE FUNCTION public.assign_signup_ordinal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_next INT;
BEGIN
    -- The App Review login is not a member: no number, no seat. Set explicitly so a crafted
    -- INSERT can never choose one either.
    IF public.is_review_account(NEW.id) THEN
        NEW.signup_ordinal := NULL;
        RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('public.users.signup_ordinal'));
    -- MAX skips NULLs, so the review login never moves the count.
    SELECT COALESCE(MAX(signup_ordinal), 0) + 1 INTO v_next FROM public.users;
    NEW.signup_ordinal := v_next;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.assign_signup_ordinal() FROM PUBLIC, anon, authenticated;
