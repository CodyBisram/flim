-- ============================================================
-- Migration: make the dormant invite quota real (invite_uses_remaining)
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
-- Statements are in dependency order (backfill + default + guard rail on the
-- column, then the redeem_invite() rewrite that reads/decrements it, then the
-- new self-lookup RPC).
--
-- Context: 2026-07-15_redeem_invite.sql added users.invite_uses_remaining as
-- a forward-compat hook and explicitly did NOT wire it in. Its own comment
-- said NULL = unlimited "which is every existing row and everything v1
-- enforces." This migration is that wiring. The design doc's copy is
-- "You have 3 invites left" -> 3 is the owner-confirmed number every existing
-- account gets, one time, right now.
--
-- NULL's MEANING CHANGES HERE, ON PURPOSE. Before this migration NULL meant
-- "everyone, because nothing reads this column yet." After this migration
-- every row gets backfilled to 3 and every new row defaults to 3, so NULL no
-- longer occurs naturally. NULL is reclaimed as a deliberate, manually-set
-- "this specific account has unlimited invites" marker (e.g. the owner's own
-- account, or a press/partner account) -- something an operator sets by hand
-- later with a plain UPDATE, never something redeem_invite() itself produces.
-- The decrement logic below treats NULL as unlimited (never decremented,
-- never blocks), exactly like v1 treated it, it is just no longer the
-- default for ordinary accounts.
--
-- IDEMPOTENCY IS THE HARD PART, READ BEFORE TOUCHING THIS FUNCTION.
-- redeem_invite() is deliberately idempotent: redeeming the same valid code
-- for the same email twice (double-tap, client retry) must always return
-- TRUE, never error, never write a second allowed_emails row, and -- new in
-- this migration -- never cost the inviter a second invite. A naive
-- "decrement then insert" or "insert then always decrement" burns two
-- invites for one person on a double-tap. The fix ties the decrement
-- strictly to the INSERT actually adding a new allowed_emails row: it uses
-- `ON CONFLICT (email) DO NOTHING RETURNING TRUE INTO v_did_insert`, and only
-- decrements when a row truly came back. A repeat redeem hits the conflict
-- branch, inserts nothing, decrements nothing, and still returns TRUE.
--
-- EXHAUSTION LOOKS LIKE A BAD CODE, ON PURPOSE. When the inviter has 0
-- remaining and the email is brand new, this returns FALSE -- the exact same
-- value as "no such code." No distinct error, no different message. The
-- original migration's whole point was that "already allowed" and "freshly
-- allowed" look identical to the caller so nobody can enumerate the
-- allowed_emails table one guess at a time; "exhausted" and "wrong" must look
-- just as identical, or a caller could binary-search which codes are real by
-- watching for a different failure once a code is spent.
--
-- One wrinkle that combination creates: if the inviter is currently at 0 but
-- the email in question was ALREADY let in (by this inviter earlier, or by
-- someone else entirely), that redeem call must still return TRUE and must
-- still cost nothing -- it is a replay, not a new spend. So the exhausted
-- branch does not just return FALSE outright: it first checks (read-only,
-- no write) whether the email is already in allowed_emails, and only returns
-- FALSE if it genuinely is not. This is what keeps a double-tap safe even
-- when it happens to land after the inviter's allowance already hit zero
-- from someone else's redemption in between.
--
-- CONCURRENCY: two people redeeming the SAME code at the same instant must
-- not both read remaining=1 and both slip through. This reuses the exact
-- discipline the rate gate above it already uses: `SELECT ... FOR UPDATE` on
-- the inviter's own users row, taken as the very first thing after the code
-- match, held for the rest of the function. The second concurrent caller
-- blocks on that row lock until the first caller's transaction commits (or
-- rolls back), then reads the POST-decrement value, so the exhaustion check
-- is never evaluated against a stale count. A conditional
-- `UPDATE ... WHERE invite_uses_remaining > 0` would also work, but it can't
-- by itself give the "already-allowed email replays for free even at zero"
-- exemption above without a second existence check anyway, so the row lock
-- (read remaining + hold it across the whole decision) is the simpler single
-- mechanism here.
--
-- OUT OF SCOPE, DELIBERATELY: earn-back (crediting an invite when the
-- invitee shoots their first roll). No trigger for it is added here. That is
-- a separate, later change with its own decision about what event fires it
-- and whether it should ever push someone from a finite count back past 3.
-- ============================================================

-- 1. Backfill every existing row to 3 (the design's number), default new
--    rows to 3, and add a floor so the column can never go negative even if
--    a future bug tries. `invite_uses_remaining IS NULL` stays a legal state
--    (see header) so the constraint allows NULL explicitly.
UPDATE public.users SET invite_uses_remaining = 3 WHERE invite_uses_remaining IS NULL;
ALTER TABLE public.users ALTER COLUMN invite_uses_remaining SET DEFAULT 3;
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_invite_uses_remaining_nonneg,
    ADD CONSTRAINT users_invite_uses_remaining_nonneg
        CHECK (invite_uses_remaining IS NULL OR invite_uses_remaining >= 0);

-- 1b. THE SEEDING EXCEPTION. Read this before running, and delete it if you
--     disagree: it is deliberately one statement so it is easy to drop.
--
--     Measured against production on 2026-08-29, before any of this was
--     applied: 51 users, 44 invites ever redeemed through a code, and only 6
--     accounts have ever sent one. The distribution is not flat. Account
--     signup_ordinal 1 has sent 26 of those 44, and the next most active has
--     sent 9. Everyone else is at 3 or below.
--
--     Nobody is debited for history: the decrement below only fires on FUTURE
--     redemptions, so a flat backfill of 3 cannot push anyone negative. The
--     problem is forward-looking. Capping the account that has personally
--     brought in more than half the app at 3 would throttle the app's main
--     distribution channel the moment this runs, which is the opposite of
--     what a growth mechanic is for.
--
--     So ordinal 1 keeps NULL, the unlimited marker. Keyed on signup_ordinal
--     rather than a pasted UUID because signup_ordinal is permanent,
--     gap-free and immutable by trigger, so this statement says WHY that
--     account is exempt instead of just naming it.
--
--     This is a policy choice, not a technical requirement. Delete this
--     statement and the owner is capped at 3 like everyone else.
UPDATE public.users SET invite_uses_remaining = NULL WHERE signup_ordinal = 1;

-- 2. redeem_invite() rewrite: same signature, same rate gate, same
--    case/whitespace handling, plus the read-lock/decrement/exhaustion logic
--    described above. See the header for why the ordering here is not
--    arbitrary.
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code TEXT, p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_email      TEXT := LOWER(TRIM(p_email));
    v_code       TEXT := UPPER(TRIM(p_code));
    v_inviter    UUID;
    v_remaining  INT;
    v_did_insert BOOLEAN;
    v_window     TIMESTAMPTZ;
    v_attempts   INT;
BEGIN
    -- Global rate gate. FOR UPDATE serializes concurrent callers on the single
    -- row so two requests can't both read attempts=29 and slip through together.
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
    -- FOR UPDATE locks the inviter's row for the rest of this call: a second,
    -- concurrent redemption of the same code blocks here until this one
    -- commits, then re-reads the post-decrement remaining count instead of a
    -- stale one. Same discipline as the rate gate above.
    SELECT id, invite_uses_remaining INTO v_inviter, v_remaining
    FROM public.users
    WHERE invite_code = v_code
    FOR UPDATE;

    IF v_inviter IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Exhausted (0, not NULL/unlimited). Still must be a free, TRUE-returning
    -- no-op for a replay of an email that already got through -- either from
    -- this inviter earlier or from someone else entirely -- so check for that
    -- before treating this as a spend attempt. Only a genuinely NEW email
    -- against a genuinely exhausted inviter comes back FALSE, identical to a
    -- bad code, per the header's enumeration note.
    IF v_remaining IS NOT NULL AND v_remaining <= 0 THEN
        IF EXISTS (SELECT 1 FROM public.allowed_emails WHERE email = v_email) THEN
            RETURN TRUE;
        ELSE
            RETURN FALSE;
        END IF;
    END IF;

    -- note stores the inviter's UUID, not their username: usernames are
    -- nullable and can change, so a username snapshot would go stale or be
    -- missing. The UUID is a stable, permanent audit trail back to users.id.
    --
    -- RETURNING TRUE INTO v_did_insert is the load-bearing idempotency check:
    -- it is only non-NULL/true when this call actually added a NEW row. A
    -- repeat call for an email already on the allowlist hits ON CONFLICT DO
    -- NOTHING, returns zero rows, leaves v_did_insert NULL, and costs nothing.
    v_did_insert := FALSE;
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invited_by:' || v_inviter::text)
    ON CONFLICT (email) DO NOTHING
    RETURNING TRUE INTO v_did_insert;

    -- Decrement only on a genuine new admission, and only for a finite
    -- allowance. NULL (unlimited, manually granted -- see header) is never
    -- decremented and never blocks.
    IF v_did_insert IS TRUE AND v_remaining IS NOT NULL THEN
        UPDATE public.users SET invite_uses_remaining = invite_uses_remaining - 1 WHERE id = v_inviter;
    END IF;

    -- Unconditional TRUE on every path that reaches here (new admission or
    -- harmless replay) is what makes the RPC idempotent and closes the
    -- email-enumeration side channel: "already allowed" and "freshly allowed"
    -- still look identical to the caller.
    RETURN TRUE;
END;
$$;

-- 3. Grants: explicit REVOKE-then-GRANT-to-both, restated even though the
--    signature didn't change, so this file stays self-contained. Same
--    reasoning as 2026-07-15_redeem_invite.sql: SECURITY DEFINER only changes
--    whose privileges the BODY runs with, callers still need EXECUTE spelled
--    out. redeem_invite runs pre-sign-in (anon) and is harmless to also allow
--    post-sign-in (authenticated).
REVOKE ALL ON FUNCTION public.redeem_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(TEXT, TEXT) TO anon, authenticated;

-- 4. Self-lookup RPC: the caller's own remaining count, nothing else's.
--    Pinned to auth.uid() inside a SECURITY DEFINER body, takes zero
--    parameters, so there is no argument a caller could substitute to read
--    someone else's row. Same shape as get_own_profile(). This is an RPC and
--    not a `profiles` view column because that view deliberately excludes
--    every invite field (email, invite_code, and now this), same leak class
--    as the one profiles already closed.
--
--    Return type is a plain nullable INT: NULL means unlimited, any other
--    value is the caller's real remaining count including 0 (exhausted). The
--    Swift side maps this straight onto Int? with no extra wrapper type.
CREATE OR REPLACE FUNCTION public.get_own_invite_quota()
RETURNS INT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$ SELECT invite_uses_remaining FROM public.users WHERE id = auth.uid() $$;
REVOKE ALL ON FUNCTION public.get_own_invite_quota() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_invite_quota() TO authenticated;
