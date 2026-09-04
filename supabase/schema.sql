-- ============================================================
-- FLIM, Supabase schema
-- Run this in the Supabase SQL editor (Dashboard → SQL Editor).
-- Safe to re-run: policies/functions are dropped & recreated.
-- ============================================================

-- Users (mirrors auth.users)
CREATE TABLE IF NOT EXISTS public.users (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email       TEXT NOT NULL,
    username    TEXT UNIQUE,
    invite_code TEXT UNIQUE NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Rolls (friend groups)
CREATE TABLE IF NOT EXISTS public.rolls (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    invite_code TEXT UNIQUE NOT NULL,
    created_by  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Roll membership (max 50 enforced in the join function, keep in sync with Roll.memberCap)
CREATE TABLE IF NOT EXISTS public.roll_members (
    roll_id     UUID NOT NULL REFERENCES public.rolls(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    joined_at   TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (roll_id, user_id)
);

-- Invite allowlist (FLIM is invite-only)
-- Only emails listed here can request a sign-in code. Add people with:
--   INSERT INTO public.allowed_emails (email) VALUES ('friend@example.com');
-- Emails are stored/compared lower-cased.
CREATE TABLE IF NOT EXISTS public.allowed_emails (
    email      TEXT PRIMARY KEY,
    note       TEXT,
    added_at   TIMESTAMPTZ DEFAULT NOW()
);

-- Photos
CREATE TABLE IF NOT EXISTS public.photos (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    roll_id      UUID REFERENCES public.rolls(id) ON DELETE SET NULL,
    storage_path TEXT NOT NULL,
    taken_at     TIMESTAMPTZ DEFAULT NOW(),
    develops_at  TIMESTAMPTZ NOT NULL,
    is_developed BOOLEAN DEFAULT FALSE
);
-- Small thumbnail uploaded alongside the full image (grids/feeds load ~30KB not MBs). Added
-- here, before the storage policies that reference it, so a fresh run has the column ready.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS thumb_path TEXT;
-- Mid-size feed rendition (see the "Feed-size rendition" section below for why). Added here too,
-- not just at that section, because "photos: roll members can read shared" (storage policy,
-- defined shortly after this table) already reads p.feed_path — a fresh run errored with
-- "column p.feed_path does not exist" until this line moved up to precede it.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS feed_path TEXT;
-- Moderation flag (see the "Auto-moderation" section below for why). Added here too, not just
-- there, because "posts: create own" (defined shortly after the posts table) already reads
-- p.hidden — a fresh run errored with "column p.hidden does not exist" until this line moved up
-- to precede it.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS hidden BOOLEAN NOT NULL DEFAULT FALSE;

-- ============================================================
-- Invite gate: is this email allowed to sign in?
-- Called from the client BEFORE auth (the user has no session yet), so it
-- must be reachable by the `anon` role. SECURITY DEFINER lets it read the
-- allowlist table while RLS keeps that table otherwise unreadable. Returns
-- TRUE/FALSE only, it never reveals the list itself.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_email_allowed(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.allowed_emails
        WHERE email = LOWER(TRIM(p_email))
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_email_allowed(TEXT) TO anon, authenticated;

-- ============================================================
-- Invite-code redemption: turns a friend's invite_code + your email into an
-- allowed_emails row so is_email_allowed() (above) then lets you request an
-- OTP. Called pre-sign-in, same class as is_email_allowed, so it must also be
-- reachable by `anon`.
--
-- Singleton rate-gate table backing a GLOBAL (not per-actor) limit: 30
-- attempts per rolling hour, period, no matter who or how many IPs/emails are
-- behind them. Per-IP or per-email keying would defeat nothing here, since an
-- attacker guessing codes rotates both trivially, and it would add a table
-- that DOES need per-key indexing/cleanup for no real benefit. A flat global
-- gate is simpler, cannot be bypassed by rotating identity, and 30/hour is
-- far above any real invite flow while still crushing the 36^6 code
-- keyspace's brute-force math. `id BOOLEAN PK CHECK (id)` is a standard
-- singleton-row trick: id can only ever be TRUE, and TRUE is already the
-- primary key, so a second row is structurally impossible.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.redeem_invite_rate (
    id           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
INSERT INTO public.redeem_invite_rate (id) VALUES (TRUE) ON CONFLICT DO NOTHING;
ALTER TABLE public.redeem_invite_rate ENABLE ROW LEVEL SECURITY;
-- No policies, and every role's implicit table privileges are stripped below, 
-- this row is readable/writable only from inside redeem_invite()'s definer body.
REVOKE ALL ON public.redeem_invite_rate FROM PUBLIC, anon, authenticated;

-- Invite quota (wired 2026-08-29, supabase/migrations/2026-08-29_invite_quota.sql).
-- Every existing row was backfilled to 3 (the design's "You have 3 invites
-- left" number) and new rows default to 3. NULL's meaning CHANGED here: it no
-- longer means "everyone, because nothing reads this column" (that was true
-- only before this wiring landed); it is now reclaimed as a deliberate,
-- manually-set "this account has unlimited invites" marker an operator sets
-- by hand (e.g. the owner's own account), never something redeem_invite()
-- itself produces. The decrement logic below treats NULL as unlimited: never
-- decremented, never blocks. A CHECK floor keeps the column from ever going
-- negative while still allowing the NULL/unlimited state.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS invite_uses_remaining INT;
ALTER TABLE public.users ALTER COLUMN invite_uses_remaining SET DEFAULT 3;
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_invite_uses_remaining_nonneg,
    ADD CONSTRAINT users_invite_uses_remaining_nonneg
        CHECK (invite_uses_remaining IS NULL OR invite_uses_remaining >= 0);

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
    -- row so two requests can't both read attempts=29 and both slip through.
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
    -- bad code, so exhaustion can never be distinguished from a wrong code.
    IF v_remaining IS NOT NULL AND v_remaining <= 0 THEN
        IF EXISTS (SELECT 1 FROM public.allowed_emails WHERE email = v_email) THEN
            RETURN TRUE;
        ELSE
            RETURN FALSE;
        END IF;
    END IF;

    -- note stores the inviter's UUID, not their username: usernames are
    -- nullable and can change later, so a username snapshot would go stale or
    -- be missing entirely. The UUID is a stable, permanent audit trail back to
    -- `users.id` no matter what the inviter later renames themselves to.
    --
    -- RETURNING TRUE INTO v_did_insert is the load-bearing idempotency check:
    -- it is only non-NULL/true when this call actually added a NEW row. A
    -- repeat call for an email already on the allowlist hits ON CONFLICT DO
    -- NOTHING, returns zero rows, leaves v_did_insert NULL, and costs nothing.
    -- This is what makes the RPC idempotent AND makes the decrement below
    -- exact: redeeming the same valid code for the same email twice
    -- (double-tap, client retry) is always safe, never errors, never writes a
    -- second row, and never burns a second invite, while also closing an
    -- email-enumeration side channel: "already allowed" and "freshly allowed"
    -- still look identical to the caller.
    v_did_insert := FALSE;
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invited_by:' || v_inviter::text)
    ON CONFLICT (email) DO NOTHING
    RETURNING TRUE INTO v_did_insert;

    -- Decrement only on a genuine new admission, and only for a finite
    -- allowance. NULL (unlimited, manually granted -- see column comment
    -- above) is never decremented and never blocks.
    IF v_did_insert IS TRUE AND v_remaining IS NOT NULL THEN
        UPDATE public.users SET invite_uses_remaining = invite_uses_remaining - 1 WHERE id = v_inviter;
    END IF;

    RETURN TRUE;
END;
$$;

-- Explicit REVOKE-then-GRANT-to-both, not just one role: the outage lesson
-- documented at is_blocked_either_way below is that a client-callable
-- function's EXECUTE grants must be spelled out for every role that calls it,
-- because SECURITY DEFINER only changes whose privileges the BODY runs with,
-- it does not substitute for the caller needing EXECUTE. redeem_invite is
-- called pre-sign-in (anon) and is harmless to also allow post-sign-in
-- (authenticated), same shape as is_email_allowed.
REVOKE ALL ON FUNCTION public.redeem_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(TEXT, TEXT) TO anon, authenticated;

-- ============================================================
-- Invite earn-back (wired 2026-08-29, supabase/migrations/2026-08-29_invite_earnback.sql
-- -- read that file's header for the full reasoning behind every choice
-- below). When an invitee takes their FIRST PHOTO (not "shoots a roll" --
-- a roll is a shared container others can shoot into, a photo's user_id is
-- unambiguous and RLS-enforced), their INVITER gets one invite back. Only
-- the inviter is credited, never the invitee (every new account already
-- starts with 3 unspent invites; see the migration header for why crediting
-- both sides would mint supply from nothing).
--
-- invite_earnbacks is keyed on invitee_id alone (PRIMARY KEY) -- that is the
-- entire exactly-once-per-invitee guarantee, leaned on directly by the
-- trigger's `INSERT ... ON CONFLICT (invitee_id) DO NOTHING RETURNING`,
-- never a separate count-then-act check (racy) or a count query (slow,
-- forever, on every photo). inviter_id carries NO foreign key on purpose,
-- same shape as allowed_emails.note: a later-deleted inviter can never
-- block or cascade away the invitee's ledger row, they just silently stop
-- being creditable (WHERE id = v_credited matches zero rows).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.invite_earnbacks (
    invitee_id  UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    inviter_id  UUID NOT NULL,
    credited_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS invite_earnbacks_inviter_idx
    ON public.invite_earnbacks (inviter_id);
ALTER TABLE public.invite_earnbacks ENABLE ROW LEVEL SECURITY;
-- No policies; every role's implicit table privileges are stripped below,
-- same shape as redeem_invite_rate -- reachable only from inside the
-- trigger's SECURITY DEFINER body.
REVOKE ALL ON public.invite_earnbacks FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.credit_invite_earnback()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_note     TEXT;
    v_inviter  UUID;
    v_credited UUID;
BEGIN
    -- FAST PATH 1: already credited. Single PRIMARY KEY probe.
    IF EXISTS (SELECT 1 FROM public.invite_earnbacks WHERE invitee_id = NEW.user_id) THEN
        RETURN NEW;
    END IF;

    -- FAST PATH 2: was this photo's owner ever admitted via an invite code,
    -- and if so whose? One statement, two PRIMARY KEY-indexed point lookups
    -- (users.id, then allowed_emails.email) in a nested loop -- the OPPOSITE
    -- direction from the badge system's inviter-to-invitees join, which
    -- filters allowed_emails by note (unindexed) and would be wrong to run
    -- on every photo insert forever.
    SELECT ae.note INTO v_note
    FROM public.users u
    LEFT JOIN public.allowed_emails ae ON ae.email = lower(u.email)
    WHERE u.id = NEW.user_id;

    -- No allowed_emails row at all (admitted some other way), or a note
    -- that doesn't match the exact 'invited_by:<uuid>' shape redeem_invite()
    -- writes. Both are silent no-ops.
    IF v_note IS NULL OR v_note !~ '^invited_by:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RETURN NEW;
    END IF;

    v_inviter := substring(v_note FROM 12)::UUID; -- strip the 11-char 'invited_by:' prefix

    -- The ledger insert IS the exactly-once guard: whichever concurrent
    -- photo insert for this invitee wins the PRIMARY KEY conflict is the
    -- only one that gets a non-NULL v_credited back.
    INSERT INTO public.invite_earnbacks (invitee_id, inviter_id)
    VALUES (NEW.user_id, v_inviter)
    ON CONFLICT (invitee_id) DO NOTHING
    RETURNING inviter_id INTO v_credited;

    IF v_credited IS NULL THEN
        RETURN NEW;
    END IF;

    -- WHERE id = v_credited silently matches zero rows if the inviter's
    -- account was since deleted. AND invite_uses_remaining IS NOT NULL keeps
    -- NULL ("unlimited") from ever becoming finite by way of an increment.
    UPDATE public.users
    SET invite_uses_remaining = invite_uses_remaining + 1
    WHERE id = v_credited
      AND invite_uses_remaining IS NOT NULL;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Fires on every photo insert, forever. Must never be the reason a
    -- photo upload fails. Same discipline as auto_follow_owner().
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_invite_earnback() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS credit_invite_earnback_trigger ON public.photos;
CREATE TRIGGER credit_invite_earnback_trigger
    AFTER INSERT ON public.photos
    FOR EACH ROW EXECUTE FUNCTION public.credit_invite_earnback();

-- The one-time backfill (crediting invitees who already had a first photo
-- before this trigger existed) is deliberately NOT mirrored here -- it is a
-- data migration against production's existing rows, not bootstrap DDL, and
-- would be a no-op on any fresh environment anyway. See
-- supabase/migrations/2026-08-29_invite_earnback.sql section 3 if you need
-- to re-run it.

-- ============================================================
-- Helper: membership check as SECURITY DEFINER.
-- This is the key to avoiding "infinite recursion detected in policy"
-- (42P17): policies on roll_members must NOT sub-select roll_members
-- directly. Because this function is SECURITY DEFINER it runs with the
-- owner's rights and bypasses RLS internally, so it's safe to call from
-- the very policies that protect these tables.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_roll_member(p_roll UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.roll_members
        WHERE roll_id = p_roll AND user_id = auth.uid()
    );
$$;

-- ============================================================
-- Join-by-code RPC. Looks up a roll by invite code, enforces the
-- 50-member cap, and inserts membership atomically, all with definer
-- rights so a not-yet-member can join without being able to read every
-- roll in the table. Call from the client via supabase.rpc("join_roll").
-- ============================================================
CREATE OR REPLACE FUNCTION public.join_roll(p_code TEXT)
RETURNS public.rolls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r public.rolls;
    member_count INT;
    already_member BOOLEAN;
BEGIN
    SELECT * INTO r FROM public.rolls WHERE invite_code = UPPER(p_code) LIMIT 1;
    IF r.id IS NULL THEN
        RAISE EXCEPTION 'roll_not_found' USING ERRCODE = 'P0002';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.roll_members WHERE roll_id = r.id AND user_id = auth.uid()
    ) INTO already_member;

    -- Invites end when a roll develops (2026-08-26 confirmations redesign,
    -- server-enforced 2026-09-04). Only blocks a caller who is not already a
    -- member, so re-fetching a roll you already joined keeps working after
    -- it develops. Reuses is_roll_developed(uuid) so this cannot drift from
    -- the same check the photos INSERT policy already applies.
    IF NOT already_member AND public.is_roll_developed(r.id) THEN
        RAISE EXCEPTION 'roll_developed' USING ERRCODE = 'P0004';
    END IF;

    IF NOT already_member THEN
        SELECT COUNT(*) INTO member_count FROM public.roll_members WHERE roll_id = r.id;
        IF member_count >= 50 THEN
            RAISE EXCEPTION 'roll_full' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.roll_members (roll_id, user_id)
        VALUES (r.id, auth.uid())
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN r;
END;
$$;

-- ============================================================
-- Row Level Security
-- ============================================================

ALTER TABLE public.users          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rolls          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roll_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photos         ENABLE ROW LEVEL SECURITY;
-- No policies on allowed_emails → unreadable/unwritable from the client.
-- Managed via the SQL editor / service role only; checked via is_email_allowed().
ALTER TABLE public.allowed_emails ENABLE ROW LEVEL SECURITY;

-- USERS ------------------------------------------------------
DROP POLICY IF EXISTS "users: own row" ON public.users;
CREATE POLICY "users: own row"
    ON public.users FOR ALL
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- Members of a shared roll need to read each other's profiles (username, etc.)
DROP POLICY IF EXISTS "users: visible to co-members" ON public.users;
CREATE POLICY "users: visible to co-members"
    ON public.users FOR SELECT
    USING (
        id IN (
            SELECT rm.user_id FROM public.roll_members rm
            WHERE public.is_roll_member(rm.roll_id)
        )
    );

-- Defence in depth, added by 2026-08-29_close_users_privilege_escalation.sql:
-- "users: own row" above is ROW-level only (auth.uid() = id) and cannot by
-- itself stop a signed-in user from rewriting a COLUMN of their own row that
-- a future grant mistake accidentally opens up — which is exactly how that
-- migration's hole existed (Supabase's default table-wide grants, never
-- taken back for INSERT/UPDATE/DELETE the way they now are just above).
-- This trigger pins id/email/invite_code unconditionally (no legitimate
-- UPDATE path exists for any of the three anywhere in this codebase) and
-- invite_uses_remaining conditionally, via current_user, so redeem_invite()
-- and credit_invite_earnback() (both SECURITY DEFINER) keep working. Full
-- reasoning, including why this function must stay SECURITY INVOKER, lives
-- in that migration file and is repeated in the function body below.
CREATE OR REPLACE FUNCTION public.lock_users_privileged_columns()
RETURNS TRIGGER
-- Deliberately SECURITY INVOKER (the default — no SECURITY DEFINER clause).
-- Do NOT add SECURITY DEFINER here "for consistency" with
-- lock_signup_ordinal_trigger. SECURITY DEFINER would swap current_user to
-- THIS function's own owner for the whole of its execution, permanently
-- masking who actually issued the firing UPDATE, and silently turning the
-- invite_uses_remaining branch below into a no-op that never pins it again.
LANGUAGE plpgsql
AS $$
BEGIN
    -- id, email, invite_code: no legitimate UPDATE path exists anywhere in
    -- this codebase for any of the three. id is the auth.users-FK'd primary
    -- key. email and invite_code are written exactly once, at signup (the
    -- INSERT grant just above), and never touched again by any RPC or
    -- trigger. Pinned UNCONDITIONALLY — current_user does not matter for
    -- these three, because no role, trusted or not, has a live reason to
    -- change them via a normal UPDATE. A genuine one-off correction follows
    -- the same convention as lock_signup_ordinal_trigger: disable this
    -- trigger by hand, make the edit, re-enable it.
    NEW.id          := OLD.id;
    NEW.email       := OLD.email;
    NEW.invite_code := OLD.invite_code;

    -- invite_uses_remaining IS legitimately mutated today, by two live
    -- SECURITY DEFINER functions — redeem_invite() (decrement) and
    -- credit_invite_earnback() (increment) — so it cannot be pinned
    -- unconditionally without breaking both on every call. Because this
    -- function is SECURITY INVOKER, current_user here is whoever is truly
    -- driving the firing UPDATE: `authenticated`/`anon` for a direct client
    -- PostgREST write, or that SECURITY DEFINER function's owner (not
    -- authenticated/anon) when the write happens inside redeem_invite() or
    -- credit_invite_earnback() — SECURITY DEFINER holds that identity for
    -- its entire execution, including statements and triggers it fires
    -- internally. So this distinguishes "a client updated their own row
    -- directly" from "a trusted definer function did this on the client's
    -- behalf", independent of table/column GRANTs entirely — the actual
    -- point of this layer.
    IF current_user IN ('anon', 'authenticated') THEN
        NEW.invite_uses_remaining := OLD.invite_uses_remaining;
    END IF;

    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_users_privileged_columns() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lock_users_privileged_columns_trigger ON public.users;
CREATE TRIGGER lock_users_privileged_columns_trigger
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.lock_users_privileged_columns();

-- ROLLS ------------------------------------------------------
DROP POLICY IF EXISTS "rolls: members can read" ON public.rolls;
CREATE POLICY "rolls: members can read"
    ON public.rolls FOR SELECT
    USING (public.is_roll_member(id));

-- Creator can read their roll immediately (needed for INSERT ... RETURNING).
DROP POLICY IF EXISTS "rolls: creator can read" ON public.rolls;
CREATE POLICY "rolls: creator can read"
    ON public.rolls FOR SELECT
    USING (created_by = auth.uid());

DROP POLICY IF EXISTS "rolls: authenticated can create" ON public.rolls;
CREATE POLICY "rolls: authenticated can create"
    ON public.rolls FOR INSERT
    WITH CHECK (auth.uid() = created_by);

-- Creator-chosen roll cover (a photo's storage_path); falls back to the latest developed shot.
ALTER TABLE public.rolls ADD COLUMN IF NOT EXISTS cover_path TEXT;

-- The creator can rename or delete their roll. Deleting cascades memberships; each
-- photo's roll_id is set NULL (ON DELETE SET NULL) so owners keep their shots personally.
DROP POLICY IF EXISTS "rolls: creator can update" ON public.rolls;
CREATE POLICY "rolls: creator can update"
    ON public.rolls FOR UPDATE
    USING (created_by = auth.uid())
    WITH CHECK (created_by = auth.uid());

DROP POLICY IF EXISTS "rolls: creator can delete" ON public.rolls;
CREATE POLICY "rolls: creator can delete"
    ON public.rolls FOR DELETE
    USING (created_by = auth.uid());

-- ROLL MEMBERS ----------------------------------------------
DROP POLICY IF EXISTS "roll_members: own membership" ON public.roll_members;
CREATE POLICY "roll_members: own membership"
    ON public.roll_members FOR SELECT
    USING (user_id = auth.uid());

-- See fellow members, uses the SECURITY DEFINER helper to avoid recursion.
DROP POLICY IF EXISTS "roll_members: can see fellow members" ON public.roll_members;
CREATE POLICY "roll_members: can see fellow members"
    ON public.roll_members FOR SELECT
    USING (public.is_roll_member(roll_id));

DROP POLICY IF EXISTS "roll_members: can join" ON public.roll_members;
CREATE POLICY "roll_members: can join"
    ON public.roll_members FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Leave a roll (delete own membership), and the roll's creator can remove anyone
-- (moderation). The creator check reads public.rolls, not roll_members, so no recursion.
DROP POLICY IF EXISTS "roll_members: leave or creator removes" ON public.roll_members;
CREATE POLICY "roll_members: leave or creator removes"
    ON public.roll_members FOR DELETE
    USING (
        user_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.rolls r
            WHERE r.id = roll_members.roll_id AND r.created_by = auth.uid()
        )
    );

-- PHOTOS -----------------------------------------------------
DROP POLICY IF EXISTS "photos: own photos" ON public.photos;
CREATE POLICY "photos: own photos"
    ON public.photos FOR SELECT
    USING (user_id = auth.uid());

DROP POLICY IF EXISTS "photos: roll members can see" ON public.photos;
CREATE POLICY "photos: roll members can see"
    ON public.photos FOR SELECT
    USING (roll_id IS NOT NULL AND public.is_roll_member(roll_id));

-- A roll is "developed" 12h after it was CREATED (the clock starts at creation, not the first
-- shot), so the deadline is fixed up front and holds even for a roll with no photos.
-- SECURITY DEFINER so the INSERT policy can check it without recursing on photos' RLS.
CREATE OR REPLACE FUNCTION public.is_roll_developed(p_roll UUID)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.rolls
        WHERE id = p_roll AND created_at + interval '12 hours' <= now()
    );
$$;

-- Once a roll has developed, NO ONE (member or creator) can add more shots to it.
DROP POLICY IF EXISTS "photos: can insert own" ON public.photos;
CREATE POLICY "photos: can insert own"
    ON public.photos FOR INSERT
    WITH CHECK (
        auth.uid() = user_id
        AND (roll_id IS NULL OR NOT public.is_roll_developed(roll_id))
    );

DROP POLICY IF EXISTS "photos: can update own" ON public.photos;
CREATE POLICY "photos: can update own"
    ON public.photos FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "photos: can delete own" ON public.photos;
CREATE POLICY "photos: can delete own"
    ON public.photos FOR DELETE
    USING (auth.uid() = user_id);

-- ============================================================
-- Storage, private "photos" bucket + per-user RLS policies.
-- Photos are stored under "<owner_uid>/<photo_id>.jpg"; roll-mates read shared
-- photos via short-lived signed URLs minted by the owner's client, so a per-user
-- policy is sufficient. Without these policies, uploads fail with a 403
-- "new row violates row-level security policy", i.e. capture won't work.
-- ============================================================

-- Create the private bucket if it doesn't exist (Public OFF).
INSERT INTO storage.buckets (id, name, public)
VALUES ('photos', 'photos', false)
ON CONFLICT (id) DO NOTHING;

-- JPEG only. HEIC was measured against the look-regression pin on 2026-08-07 and
-- rejected: at every quality that saves bytes it smooths our grain away, moving
-- localContrast on all 11 fixtures by up to 3.9x the pin's tolerance, and the only
-- qualities that mostly clear the pin produce files larger than the JPEG they
-- replace. Do not widen this without re-running that sweep.
--
-- The size limit matches production. Without it a fresh project accepts uploads of
-- any size, which is both a storage-cost and an abuse problem on a private beta.
UPDATE storage.buckets
SET allowed_mime_types = ARRAY['image/jpeg'],
    file_size_limit = 26214400   -- 25 MB
WHERE id = 'photos';

-- Authenticated users may upload only into their own "<auth.uid()>/…" folder.
DROP POLICY IF EXISTS "photos: insert own folder" ON storage.objects;
CREATE POLICY "photos: insert own folder"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'photos'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

-- …and read their own objects.
DROP POLICY IF EXISTS "photos: read own folder" ON storage.objects;
CREATE POLICY "photos: read own folder"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

-- …and delete their own objects (used when a user deletes a photo).
DROP POLICY IF EXISTS "photos: delete own folder" ON storage.objects;
CREATE POLICY "photos: delete own folder"
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'photos'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

-- Roll members can read a photo that belongs to a roll they're in, this is what
-- lets shared-roll photos (and roll cover thumbnails) load for everyone, not just
-- the photo's owner. Joins the storage object back to its photos row by path.
DROP POLICY IF EXISTS "photos: roll members can read shared" ON storage.objects;
CREATE POLICY "photos: roll members can read shared"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE storage.objects.name IN (p.storage_path, p.thumb_path, p.feed_path)
              AND p.roll_id IS NOT NULL
              AND public.is_roll_member(p.roll_id)
        )
    );

-- ============================================================
-- Account deletion (App Store Guideline 5.1.1(v) requires in-app account deletion).
-- Deleting the auth.users row cascades to public.users (ON DELETE CASCADE), which
-- cascades to that user's rolls, memberships, photos, and reports. SECURITY DEFINER
-- runs as the function owner (postgres), which can delete from the auth schema.
-- The client calls supabase.rpc("delete_account") then signs out.
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    DELETE FROM auth.users WHERE id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_account() TO authenticated;

-- ============================================================
-- Content reports (UGC safety, Guideline 1.2). A user can report a photo they can
-- see; the row is write-only from the client (no SELECT policy) and reviewed out-of-band.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_reports (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    photo_id    UUID NOT NULL REFERENCES public.photos(id) ON DELETE CASCADE,
    reporter_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    reason      TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.photo_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "photo_reports: can file own" ON public.photo_reports;
CREATE POLICY "photo_reports: can file own"
    ON public.photo_reports FOR INSERT
    WITH CHECK (auth.uid() = reporter_id);

-- ============================================================
-- Personalization: photo captions, profile bio/avatar, and reactions.
-- ============================================================

-- A caption on your own photo (owner-editable via the existing "photos: can update own").
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS caption TEXT;

-- (photos.thumb_path is added right under the photos table, above the storage policies.)

-- Sort/triage state: new personal "instants" land unsorted (is_sorted = false) and are
-- swiped into the Darkroom (archive) or Feed (publish) via the sort deck. Roll shots skip
-- the deck (inserted sorted). Existing photos are treated as already sorted.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS is_sorted BOOLEAN NOT NULL DEFAULT FALSE;
-- One-time backfill (run once when the column was added; NOT here, so re-running schema.sql
-- doesn't clear photos currently waiting in the sort deck):
--   UPDATE public.photos SET is_sorted = TRUE WHERE is_sorted = FALSE;

-- Profile bio + avatar (avatar_path points at one of the user's own photos in Storage).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS bio TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_path TEXT;
-- Optional first/display name, used in greetings + shown on the profile (falls back to username).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS display_name TEXT;
-- Profile cover/header image (its own Storage copy, independent of any photo/post).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS cover_path TEXT;

-- Reactions to photos (mainly for shared rolls). One row per (photo, user, emoji).
CREATE TABLE IF NOT EXISTS public.photo_reactions (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    photo_id   UUID NOT NULL REFERENCES public.photos(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    emoji      TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (photo_id, user_id, emoji)
);

ALTER TABLE public.photo_reactions ENABLE ROW LEVEL SECURITY;

-- See reactions on any photo you can see (your own, or one in a roll you belong to).
DROP POLICY IF EXISTS "reactions: visible on visible photos" ON public.photo_reactions;
CREATE POLICY "reactions: visible on visible photos"
    ON public.photo_reactions FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.photos p
            WHERE p.id = photo_reactions.photo_id
              AND (p.user_id = auth.uid()
                   OR (p.roll_id IS NOT NULL AND public.is_roll_member(p.roll_id)))
        )
    );

DROP POLICY IF EXISTS "reactions: add own" ON public.photo_reactions;
CREATE POLICY "reactions: add own"
    ON public.photo_reactions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "reactions: remove own" ON public.photo_reactions;
CREATE POLICY "reactions: remove own"
    ON public.photo_reactions FOR DELETE
    USING (auth.uid() = user_id);

-- ============================================================
-- Social layer: public profiles, a follow graph, shared posts (photos a user
-- publishes to their page/feed), and reactions + comments on those posts.
-- ============================================================

-- Public profile view, exposes only safe fields (NO email / invite code), readable
-- by any signed-in user so you can browse pages, follow people, and see comment authors.
-- New columns must be appended at the END for CREATE OR REPLACE VIEW (Postgres can't
-- reorder/rename existing view columns), decode is by name in the app, so order is irrelevant.
-- hidden_from_discovery keeps an account out of Discover's suggestions. Added as
-- supabase/migrations/2026-08-04_hidden_from_discovery.sql for the App Store Review account,
-- which must be a fully functional real account without being offered to users as someone to
-- follow. A general flag rather than a hardcoded id, so a support or demo account later needs no
-- code change.
--
-- It is a SUGGESTION FILTER, NOT A PRIVACY BOUNDARY, and the client filters on it. The account
-- stays visible in followers and roll member lists (hiding it there would mean lying about who is
-- in a roll), and its profile is still reachable by anyone who knows the username, because
-- "users: profiles readable" is USING (true) on purpose: that is what makes mentions resolve,
-- tags render names, and profiles open from a post.
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS hidden_from_discovery boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS users_hidden_from_discovery_idx
    ON public.users (id) WHERE hidden_from_discovery;

-- chapter_public_stats: the profile owner's own allow-list of which Chapters
-- "month in numbers" stat_key values everyone ELSE may see on their card,
-- folded in from supabase/migrations/2026-09-04_chapter_stats.sql. The column
-- (and its CHECK) live here, ahead of the users column-level SELECT GRANT
-- further down that must cover it, and ahead of the profiles view, for the
-- same load-ordering reason hidden_from_discovery/signup_ordinal do: a
-- from-scratch run reads top to bottom and the GRANT below would fail with
-- "column does not exist" otherwise. The chapter_stats() and
-- set_chapter_public_stats() functions that read/write it live later, in the
-- Chapters section, alongside profile_chapters/chapter_photos -- see that
-- section's own comment for the full visibility contract. EMPTY ARRAY means
-- "everything public" (the default, and every existing account's current
-- value), so this column changes nothing for anyone who has never opened the
-- picker; the CHECK constraint pins the array to the exact same fixed key
-- list set_chapter_public_stats() validates against, so a typo can neither
-- silently hide a real stat nor silently grant visibility to one
-- chapter_stats() does not know how to filter by.
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS chapter_public_stats TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_chapter_public_stats_keys_check,
    ADD CONSTRAINT users_chapter_public_stats_keys_check
        CHECK (chapter_public_stats <@ ARRAY[
            'most_reacted', 'most_commented', 'reactions_received', 'comments_received',
            'top_reaction', 'busiest_day', 'night_shots', 'streak_days', 'rolls_count',
            'people_shot_with', 'first_shot', 'last_shot', 'shots'
        ]::text[]);

-- signup_ordinal: a permanent "you are the Nth member" number, folded in from
-- supabase/migrations/2026-08-17_profile_identity.sql. Production has carried this column, its
-- backfill, both triggers below, and its GRANT since that migration ran; this file did not, until
-- now (see the NOTE this replaces, near the users column-level SELECT GRANT further down).
--
-- Nullable at first, same reason every other folded ADD COLUMN in this file is: the backfill
-- immediately below needs real NULL rows to target before NOT NULL is enforced. On a from-scratch
-- load the table is empty, so the backfill matches zero rows and the NOT NULL step is a trivial
-- no-op; both are safe to run every time this file re-runs.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS signup_ordinal INT;

-- One-time backfill for EXISTING users, folded here as executable SQL (unlike the is_sorted
-- backfill above, which is commented out) because this one already only touches rows where
-- signup_ordinal IS NULL: re-running it against a fully-backfilled production database, or
-- running it against a brand-new empty table, both match zero rows and change nothing. Ordered by
-- created_at ascending, id as a deterministic tiebreaker for any exact-same-timestamp rows, and
-- must run before the assignment trigger below exists: that trigger derives its next number from
-- MAX(signup_ordinal), so if it started assigning to brand-new signups while older rows were still
-- NULL, a new signup could grab "#1" out from under the actual first member.
WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
    FROM public.users
    WHERE signup_ordinal IS NULL
)
UPDATE public.users u
SET signup_ordinal = ranked.rn
FROM ranked
WHERE u.id = ranked.id;

ALTER TABLE public.users ALTER COLUMN signup_ordinal SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_signup_ordinal_unique_idx ON public.users (signup_ordinal);

-- Assignment, BEFORE INSERT. Overwrites NEW.signup_ordinal unconditionally, even if a caller
-- supplied one, so the server is the only source of truth regardless of what a crafted INSERT
-- body contains. pg_advisory_xact_lock is transaction-scoped (acquired here, released
-- automatically at COMMIT or ROLLBACK of the inserting transaction), so a second concurrent
-- signup's trigger blocks on the SAME lock until the first finishes before it can read
-- MAX(signup_ordinal), which is what makes two simultaneous signups structurally unable to
-- observe the same MAX and hand out the same number. Full sequence-vs-lock tradeoff (why a plain
-- SEQUENCE was rejected: nextval() is not transactional, so a rolled-back signup would burn a
-- number forever) lives in 2026-08-17_profile_identity.sql.
CREATE OR REPLACE FUNCTION public.assign_signup_ordinal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_next INT;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('public.users.signup_ordinal'));
    SELECT COALESCE(MAX(signup_ordinal), 0) + 1 INTO v_next FROM public.users;
    NEW.signup_ordinal := v_next;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.assign_signup_ordinal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS assign_signup_ordinal_trigger ON public.users;
CREATE TRIGGER assign_signup_ordinal_trigger
    BEFORE INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.assign_signup_ordinal();

-- Immutability, BEFORE UPDATE. Pins signup_ordinal to its OLD value on every UPDATE,
-- unconditionally: table-level UPDATE on `users` is granted to `authenticated` (see the GRANT
-- UPDATE further down) and RLS is row-level, not column-level, so nothing else in this schema
-- stops a signed-in user from rewriting their own number without this trigger. This is a
-- SEPARATE BEFORE UPDATE trigger from lock_users_privileged_columns_trigger above (that one pins
-- id/email/invite_code/invite_uses_remaining; this one pins only signup_ordinal); Postgres runs
-- both on every UPDATE with no ordering hazard between them since they touch disjoint columns.
-- Manual correction (owner only, SQL editor):
--   ALTER TABLE public.users DISABLE TRIGGER lock_signup_ordinal_trigger;
--   UPDATE public.users SET signup_ordinal = <n> WHERE id = '<uuid>';
--   ALTER TABLE public.users ENABLE TRIGGER lock_signup_ordinal_trigger;
CREATE OR REPLACE FUNCTION public.lock_signup_ordinal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.signup_ordinal := OLD.signup_ordinal;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_signup_ordinal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lock_signup_ordinal_trigger ON public.users;
CREATE TRIGGER lock_signup_ordinal_trigger
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.lock_signup_ordinal();

CREATE OR REPLACE VIEW public.profiles AS
    SELECT id, username, avatar_path, bio, created_at, display_name, cover_path,
           hidden_from_discovery, signup_ordinal
    FROM public.users;

-- security_invoker = on as of 2026-09-02 (supabase/migrations/2026-09-02_profiles_security_invoker.sql).
-- The view now runs with the CALLING role's own privileges, not the view owner's. That is safe
-- because every column profiles selects is also directly readable by `authenticated` on
-- public.users, via the column-scoped SELECT grant immediately below in the
-- "Security-advisor hardening" block (id, username, avatar_path, bio, created_at, display_name,
-- cover_path, hidden_from_discovery). email and invite_code stay unreachable through profiles for
-- a reason that has nothing to do with invoker vs definer: they are simply never in that grant and
-- never in this view's SELECT list, in either mode.
--
-- READ ONLY, and the REVOKE is the part that matters, independent of invoker mode.
--
-- A single-table view like this one is AUTO-UPDATABLE, so a write through it runs with whatever
-- privileges are in force for the read (the caller's, now) and could otherwise bypass the
-- intended write path entirely. Supabase's default privileges grant INSERT/UPDATE/DELETE to anon
-- and authenticated on every new object in `public`, and a bare `GRANT SELECT` does not take those
-- away. That combination meant anyone holding the publishable key (which ships inside the app
-- binary) could PATCH or DELETE any user's row through this view, bypassing the "users: own row"
-- policy entirely. Verified against production on 2026-08-05: an unauthenticated PATCH returned
-- 200, not 403.
--
-- Nothing reads or writes profiles except SELECTs (the app writes profile fields to `users`,
-- where RLS gates them), so the view is revoked down to SELECT, for `authenticated` only. `anon`
-- held SELECT here from 2026-08-05 until 2026-09-02; nothing ever depended on it (no SQL function
-- or view reachable pre-session selects from profiles, and every app read already carries a
-- session), and under invoker mode it would only fail anyway, since anon has no SELECT grant on
-- `users` at all. Keep the REVOKE ahead of the GRANT: this file is re-run in production as the
-- standing workflow, and a re-created view picks the default privileges back up.
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;

-- TRUNCATE is not subject to row level security, so the "users: own row" policy does not contain
-- it. PostgREST cannot issue one, which is the only reason this was not reachable, and that is
-- too thin a thing to rely on.
REVOKE TRUNCATE ON public.users FROM anon, authenticated;

-- FOLLOWS ----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.follows (
    follower_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    following_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (follower_id, following_id),
    CHECK (follower_id <> following_id)
);
ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "follows: readable by authenticated" ON public.follows;
CREATE POLICY "follows: readable by authenticated"
    ON public.follows FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "follows: create own" ON public.follows;
CREATE POLICY "follows: create own"
    ON public.follows FOR INSERT WITH CHECK (auth.uid() = follower_id);

DROP POLICY IF EXISTS "follows: delete own" ON public.follows;
CREATE POLICY "follows: delete own"
    ON public.follows FOR DELETE USING (auth.uid() = follower_id);

-- ============================================================
-- Auto-follow the owner at signup.
--
-- Every new account should follow the owner from the moment it exists, at
-- his request. This fires on public.users, not auth.users / a Supabase Auth
-- hook: public.users is the row the app actually inserts on first login
-- (AuthService.completeOnboarding's `INSERT INTO users`). Defined here
-- (right after the follows table it targets) because, unlike
-- is_blocked_either_way's consumers, nothing about this function needs
-- anything defined later in this file.
--
-- Resolved by public.owner_user_id() (defined near is_owner(uuid) further
-- down this file) since 2026-09-01_pin_owner_identity_everywhere.sql. Before
-- that it matched lower(email) = lower('codyysb@gmail.com') directly: left
-- alone by 2026-08-29_close_users_privilege_escalation.sql because, unlike
-- is_owner(), this trigger grants no privilege, only an auto-follow row, so
-- a forged email here produced at worst a wrong follow target, not an
-- escalation, but three copies of "trust email" already proved to be one
-- too many, so this one was finished too.
--
-- Resilience, each one deliberate:
--   1. No owner row yet (fresh database, or the owner hasn't completed
--      onboarding on this environment) -> the EXISTS check below is FALSE ->
--      RETURN NEW immediately, no INSERT attempted. A signup must NEVER fail
--      because this could not find someone to follow. (owner_user_id()
--      always returns the same constant regardless of whether that row
--      exists here yet, unlike the old lower(email) lookup which naturally
--      returned NULL in that case, hence the explicit EXISTS check now,
--      to keep this exact early-return behaviour.)
--   2. The row being inserted IS the owner's own account -> skip before
--      attempting the INSERT. follows already has CHECK (follower_id <>
--      following_id), which would abort the very transaction that creates
--      the owner's own account if this relied on the constraint alone
--      instead of checking first — the constraint is a backstop, not the
--      mechanism.
--   3. ON CONFLICT DO NOTHING against the (follower_id, following_id) PK:
--      idempotent if this ever runs twice for the same pair.
--   4. EXCEPTION WHEN OTHERS swallows anything else unforeseen (some future
--      constraint, etc.) and still returns NEW. The one job this trigger is
--      not allowed to do is take down account creation.
--
-- push_sent is deliberately left at its column default (FALSE): a freshly
-- signed-up user auto-following the owner is a real "someone joined" event,
-- and at signup volume this is one push per new account, not a burst. That
-- is a genuine judgment call (arguably useful, arguably noise) — landed on
-- "useful" because it is low-volume by construction and mirrors what would
-- happen if that same person had tapped Follow by hand. The BACKFILL for
-- existing accounts is the actual burst case; it lives in its own one-time
-- migration (supabase/migrations/2026-08-14_auto_follow_owner_backfill.sql,
-- NOT mirrored here — see that file for why) and marks its rows
-- push_sent = TRUE up front so send-social-push's poll never fires on them.
--
-- Trigger function, not called by any client role, so no role needs
-- EXECUTE — same shape as block_severs_follows/auto_hide_reported above.
-- ============================================================
CREATE OR REPLACE FUNCTION public.auto_follow_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner_id UUID := public.owner_user_id();
BEGIN
    IF NEW.id = v_owner_id THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_owner_id) THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.follows (follower_id, following_id)
    VALUES (NEW.id, v_owner_id)
    ON CONFLICT (follower_id, following_id) DO NOTHING;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.auto_follow_owner() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS auto_follow_owner_trigger ON public.users;
CREATE TRIGGER auto_follow_owner_trigger
    AFTER INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.auto_follow_owner();

-- To undo (two statements):
--   1. DROP TRIGGER IF EXISTS auto_follow_owner_trigger ON public.users;
--      -- stops future signups from auto-following the owner.
--   2. See supabase/migrations/2026-08-14_auto_follow_owner_backfill.sql
--      for the matching DELETE that removes exactly the rows the backfill
--      created (nothing this trigger created — those are ordinary follows
--      indistinguishable from, and as reversible as, any user tapping
--      Follow themselves, i.e. by that user unfollowing in the app).

-- POSTS ------------------------------------------------------
-- storage_path + taken_at are denormalized from the photo so the feed needs no
-- cross-user access to the photos table; posts themselves are public to signed-in users.
CREATE TABLE IF NOT EXISTS public.posts (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    photo_id     UUID NOT NULL REFERENCES public.photos(id) ON DELETE CASCADE,
    storage_path TEXT NOT NULL,
    taken_at     TIMESTAMPTZ NOT NULL,
    caption      TEXT,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (user_id, photo_id)
);
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
-- Thumbnail denormalized from the photo (see photos.thumb_path), so the feed loads small.
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS thumb_path TEXT;
-- Mid-size feed rendition denormalized from the photo (see photos.feed_path above, and the
-- "Feed-size rendition" section below). Moved up for the same reason as photos.feed_path: the
-- "posts: readable when shared to a post" storage policy defined shortly after this table
-- already reads po.feed_path.
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS feed_path TEXT;
-- Marked once the push scanner has processed this post (tag + caption-mention notifications).
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS push_sent BOOLEAN DEFAULT FALSE;

DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated USING (true);

-- A post must be attributed to the caller (unchanged) AND reference a photo the caller can
-- actually see: their own, or any photo in a roll they're a member of, sharing a roll-mate's
-- shot to your own page is a real feature (anyone in the roll can share anything in it), not a
-- gap. Before this, the WITH CHECK only verified the former: nothing tied photo_id to something
-- the poster was actually allowed to see, so a forged INSERT (bypassing the app's UI, which only
-- ever offers photo_ids it legitimately fetched) could have turned ANY photo in the database, 
-- including someone else's private, non-roll shot, into a public post, since "posts: readable
-- by authenticated" and the storage read policy both key off the post existing, not off the
-- underlying photo's own visibility. `NOT p.hidden` is explicit here rather than assumed via
-- `photos`' own SELECT policies (own-photo visibility deliberately ignores hidden, so a reported
-- photo could otherwise still be freshly shared by its owner even after auto-hiding).
DROP POLICY IF EXISTS "posts: create own" ON public.posts;
CREATE POLICY "posts: create own"
    ON public.posts FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE p.id = photo_id
              AND NOT p.hidden
              AND (p.user_id = auth.uid() OR (p.roll_id IS NOT NULL AND public.is_roll_member(p.roll_id)))
        )
    );

DROP POLICY IF EXISTS "posts: update own" ON public.posts;
CREATE POLICY "posts: update own"
    ON public.posts FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "posts: delete own" ON public.posts;
CREATE POLICY "posts: delete own"
    ON public.posts FOR DELETE USING (auth.uid() = user_id);

-- A photo shared to a post is readable in Storage by any signed-in user.
-- ⚠️ Every rendition column must be listed here. When a new rendition path is
-- added to posts (thumb_path, feed_path, …), it MUST be added to this IN list, 
-- feed_path was missed for 2 days and no one could load anyone else's feed
-- images (sign → 400; authors unaffected via the own-folder policy, so it
-- only surfaces cross-account).
DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path))
    );

-- A photo used as someone's avatar is readable by any signed-in user (so avatars load
-- on pages, feed cards, etc. even when that photo was never shared as a post).
DROP POLICY IF EXISTS "photos: readable when set as avatar" ON storage.objects;
CREATE POLICY "photos: readable when set as avatar"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.users u WHERE u.avatar_path = storage.objects.name)
    );

-- A profile cover image is readable by any signed-in user.
DROP POLICY IF EXISTS "photos: readable when set as cover" ON storage.objects;
CREATE POLICY "photos: readable when set as cover"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.users u WHERE u.cover_path = storage.objects.name)
    );

-- POST REACTIONS ---------------------------------------------
CREATE TABLE IF NOT EXISTS public.post_reactions (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id    UUID NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    emoji      TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (post_id, user_id, emoji)
);
ALTER TABLE public.post_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "post_reactions: readable" ON public.post_reactions;
CREATE POLICY "post_reactions: readable"
    ON public.post_reactions FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "post_reactions: add own" ON public.post_reactions;
CREATE POLICY "post_reactions: add own"
    ON public.post_reactions FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "post_reactions: remove own" ON public.post_reactions;
CREATE POLICY "post_reactions: remove own"
    ON public.post_reactions FOR DELETE USING (auth.uid() = user_id);

-- POST TAGS (people tagged on the photo, Instagram-style) -----
CREATE TABLE IF NOT EXISTS public.post_tags (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id        UUID NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    tagged_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    x              DOUBLE PRECISION NOT NULL,   -- 0..1 normalized position on the photo
    y              DOUBLE PRECISION NOT NULL,
    created_at     TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (post_id, tagged_user_id)
);
ALTER TABLE public.post_tags ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "post_tags: readable" ON public.post_tags;
CREATE POLICY "post_tags: readable"
    ON public.post_tags FOR SELECT TO authenticated USING (true);
-- Only the post's owner can add/remove tags on it.
DROP POLICY IF EXISTS "post_tags: owner adds" ON public.post_tags;
CREATE POLICY "post_tags: owner adds"
    ON public.post_tags FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_id AND p.user_id = auth.uid())
    );
DROP POLICY IF EXISTS "post_tags: owner removes" ON public.post_tags;
CREATE POLICY "post_tags: owner removes"
    ON public.post_tags FOR DELETE USING (
        EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_id AND p.user_id = auth.uid())
    );

-- Push notifications for a tag added AFTER its post was already announced ("Edit tags",
-- FeedService.setTags): the "New posts" block in send-social-push only scans posts where
-- push_sent = false, so a tag added once that flips true would otherwise never be picked up by
-- anything. post_tags already has its own `id` primary key (unlike comment_likes, which needed a
-- surrogate added in 2026-08-12_comment_likes_push_sent.sql), so only push_sent itself is needed
-- here, no id column. The one-time backfill that marks every PRE-EXISTING tag row
-- push_sent = TRUE (so the first poll after this column exists doesn't blast a push for every tag
-- ever created) deliberately does NOT live here; see
-- supabase/migrations/2026-08-17_post_tags_push_sent.sql for why and run it before this file is
-- re-applied against a database that already has this column.
ALTER TABLE public.post_tags ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS post_tags_unpushed_idx ON public.post_tags (push_sent) WHERE push_sent = FALSE;

-- POST COMMENTS ----------------------------------------------
CREATE TABLE IF NOT EXISTS public.post_comments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id    UUID NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.post_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "post_comments: readable" ON public.post_comments;
CREATE POLICY "post_comments: readable"
    ON public.post_comments FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "post_comments: add own" ON public.post_comments;
CREATE POLICY "post_comments: add own"
    ON public.post_comments FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "post_comments: delete own" ON public.post_comments;
CREATE POLICY "post_comments: delete own"
    ON public.post_comments FOR DELETE USING (auth.uid() = user_id);

-- Likes on comments (so comments can be hearted + ranked "most relevant").
CREATE TABLE IF NOT EXISTS public.comment_likes (
    comment_id UUID NOT NULL REFERENCES public.post_comments(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (comment_id, user_id)
);
ALTER TABLE public.comment_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "comment_likes: readable" ON public.comment_likes;
CREATE POLICY "comment_likes: readable"
    ON public.comment_likes FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "comment_likes: add own" ON public.comment_likes;
CREATE POLICY "comment_likes: add own"
    ON public.comment_likes FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "comment_likes: remove own" ON public.comment_likes;
CREATE POLICY "comment_likes: remove own"
    ON public.comment_likes FOR DELETE USING (auth.uid() = user_id);

-- Push notifications for comment likes ("<name> liked your comment"), same poll +
-- push_sent-flag pattern as every other table send-social-push scans. comment_likes'
-- primary key is the composite (comment_id, user_id) above and stays that way; `id` is a
-- surrogate added ONLY so a batch of likes can be marked done with `.in("id", ids)`, the
-- same shape post_reactions/photo_reactions/post_comments/photo_comments already use,
-- instead of one UPDATE per (comment_id, user_id) pair. gen_random_uuid() is volatile, so
-- backfilling this column assigns a genuinely distinct id to every existing row.
-- The one-time backfill that marks every PRE-EXISTING like push_sent = TRUE (so the first
-- poll after deploy doesn't blast a push for the entire historical table) deliberately does
-- NOT live here; see supabase/migrations/2026-08-12_comment_likes_push_sent.sql for why and
-- run it before this file is re-applied against a database that already has that column.
ALTER TABLE public.comment_likes ADD COLUMN IF NOT EXISTS id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.comment_likes ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX IF NOT EXISTS comment_likes_id_idx ON public.comment_likes (id);
CREATE INDEX IF NOT EXISTS comment_likes_unpushed_idx ON public.comment_likes (push_sent) WHERE push_sent = FALSE;

-- ROLL PHOTO COMMENTS -----------------------------------------
-- Comments on a shared roll's photos. Visible to roll members; notifications go only to the
-- photo's owner + people already in that photo's thread (see send-social-push), never the
-- whole roll.
CREATE TABLE IF NOT EXISTS public.photo_comments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    photo_id   UUID NOT NULL REFERENCES public.photos(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE public.photo_comments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS photo_comments_photo_idx ON public.photo_comments (photo_id);

DROP POLICY IF EXISTS "photo_comments: readable by roll members" ON public.photo_comments;
CREATE POLICY "photo_comments: readable by roll members"
    ON public.photo_comments FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                   AND (p.user_id = auth.uid() OR public.is_roll_member(p.roll_id))));
DROP POLICY IF EXISTS "photo_comments: insert as roll member" ON public.photo_comments;
CREATE POLICY "photo_comments: insert as roll member"
    ON public.photo_comments FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid()
                AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                            AND public.is_roll_member(p.roll_id)));
DROP POLICY IF EXISTS "photo_comments: delete own" ON public.photo_comments;
CREATE POLICY "photo_comments: delete own"
    ON public.photo_comments FOR DELETE USING (user_id = auth.uid());

-- Per-user, per-roll notification mute (so a busy roll can be silenced without leaving it).
CREATE TABLE IF NOT EXISTS public.roll_notification_mutes (
    roll_id UUID NOT NULL REFERENCES public.rolls(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    PRIMARY KEY (roll_id, user_id)
);
ALTER TABLE public.roll_notification_mutes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "roll_mutes: own" ON public.roll_notification_mutes;
CREATE POLICY "roll_mutes: own"
    ON public.roll_notification_mutes FOR ALL
    USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- BLOCKS + USER REPORTS (UGC safety) --------------------------
CREATE TABLE IF NOT EXISTS public.blocks (
    blocker_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    blocked_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "blocks: readable own" ON public.blocks;
CREATE POLICY "blocks: readable own"
    ON public.blocks FOR SELECT TO authenticated USING (auth.uid() = blocker_id);
DROP POLICY IF EXISTS "blocks: create own" ON public.blocks;
CREATE POLICY "blocks: create own"
    ON public.blocks FOR INSERT WITH CHECK (auth.uid() = blocker_id);
DROP POLICY IF EXISTS "blocks: delete own" ON public.blocks;
CREATE POLICY "blocks: delete own"
    ON public.blocks FOR DELETE USING (auth.uid() = blocker_id);

CREATE TABLE IF NOT EXISTS public.user_reports (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    reported_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    reason      TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_reports: file own" ON public.user_reports;
CREATE POLICY "user_reports: file own"
    ON public.user_reports FOR INSERT WITH CHECK (auth.uid() = reporter_id);

-- ============================================================
-- Optional cron: auto-mark developed photos server-side.
-- Supabase Dashboard → Database → Functions (or schedule via pg_cron).
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_developed_photos()
RETURNS void
LANGUAGE sql
AS $$
    UPDATE public.photos
    SET is_developed = TRUE
    WHERE is_developed = FALSE
      AND develops_at <= NOW();
$$;

-- ============================================================
-- Invite allowlist seed
-- Add the owner up-front so you can't lock yourself out. Add friends the
-- same way (email is lower-cased on check, so case here doesn't matter):
--   INSERT INTO public.allowed_emails (email, note) VALUES ('them@x.com', 'Jamie');
-- ============================================================
INSERT INTO public.allowed_emails (email, note)
VALUES ('codyysb@gmail.com', 'owner')
ON CONFLICT (email) DO NOTHING;

-- ============================================================
-- Auto-moderation (Guideline 1.2)
-- Once a photo is reported by >= 2 DISTINCT users, hide it (and any feed posts of it) pending
-- review. The client filters hidden content out of feeds + shared rolls. Review/restore from the
-- dashboard: SELECT * FROM photos WHERE hidden;  then UPDATE ... SET hidden = FALSE (or delete).
--
-- photos.hidden itself is added earlier now (right after the photos table, near line 65), for
-- the same "a policy defined before this section already reads it" reason as photos.feed_path.
-- posts.hidden's first read (the "readable when shared to a post" storage policy) comes after
-- this point, so it can stay here.
-- ============================================================
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS hidden BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION public.auto_hide_reported()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (SELECT COUNT(DISTINCT reporter_id) FROM public.photo_reports WHERE photo_id = NEW.photo_id) >= 2 THEN
        UPDATE public.photos SET hidden = TRUE WHERE id = NEW.photo_id;
        UPDATE public.posts  SET hidden = TRUE WHERE photo_id = NEW.photo_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS auto_hide_reported_trigger ON public.photo_reports;
CREATE TRIGGER auto_hide_reported_trigger
    AFTER INSERT ON public.photo_reports
    FOR EACH ROW EXECUTE FUNCTION public.auto_hide_reported();

-- ============================================================
-- Auto-moderation, enforced at RLS (not just client-side).
-- The four policies this section touches gate "can you see this content" (rows AND storage
-- bytes) and were defined before `hidden` existed on this table, so `NOT hidden` couldn't be
-- added inline back then without breaking a from-scratch run of this file. Without this, "the
-- client filters hidden content out" was the ONLY enforcement: a reported-and-hidden photo or
-- post was still fully readable by calling the Supabase REST/Storage API directly, bypassing the
-- app UI entirely, RLS is the actual security boundary, a client query filter is not. Owners
-- keep seeing their own hidden photo ("photos: own photos" is untouched), hiding is about
-- hiding FROM OTHERS, not from yourself, and the dashboard review/restore flow above still needs
-- a way for that to make sense.
--
-- "photos: roll members can see" and "posts: readable by authenticated" are NOT redefined here:
-- both are redefined again, further down, by the block-enforcement section (search
-- "READ policies: drop the blocked party's content from every shared surface"), and since this
-- file runs top to bottom with DROP POLICY IF EXISTS + CREATE POLICY, whichever definition runs
-- last wins, a `NOT hidden` predicate added here would be silently discarded the moment the
-- block-enforcement section's own CREATE POLICY for the same two names runs after it. The
-- `NOT hidden` check for those two lives on the block-enforcement versions instead, alongside
-- the block check, so it actually survives a full run of this file.
-- ============================================================
-- ⚠️ These two are redefined AGAIN, further down, by the block-enforcement
-- section (search "READ policies: drop the blocked party's content from every
-- shared surface"), which is where the block predicate actually gets added.
-- It cannot be added here: public.is_blocked_either_way is not created until
-- that later section, and CREATE POLICY resolves function calls in its USING
-- clause at creation time, so referencing it here would fail on a from-scratch
-- run of this file (function does not exist yet). Same reasoning the comment
-- above already documents for NOT hidden on the two table-level policies.
DROP POLICY IF EXISTS "photos: roll members can read shared" ON storage.objects;
CREATE POLICY "photos: roll members can read shared"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE storage.objects.name IN (p.storage_path, p.thumb_path, p.feed_path)
              AND p.roll_id IS NOT NULL
              AND NOT p.hidden
              AND public.is_roll_member(p.roll_id)
        )
    );

DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path)
                      AND NOT po.hidden)
    );

-- ============================================================
-- Indexes on hot query paths (Postgres does NOT auto-index foreign keys).
-- Cheap now, and they keep the feed / rolls / activity queries index-backed as data grows.
-- ============================================================
CREATE INDEX IF NOT EXISTS posts_user_created_idx      ON public.posts (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS posts_photo_idx             ON public.posts (photo_id);
CREATE INDEX IF NOT EXISTS photos_user_idx             ON public.photos (user_id, taken_at DESC);
CREATE INDEX IF NOT EXISTS photos_roll_idx             ON public.photos (roll_id, develops_at DESC);
-- photos_roll_user_idx: folded in from supabase/migrations/2026-08-17_profile_identity.sql
-- alongside the badge system further down this file (see "Badges" below). Neither
-- photos_user_idx nor photos_roll_idx above serves "this user's photos within this
-- specific roll" well, which is the shape the full_roll/cover_to_cover badge predicates
-- run on every profile view. Partial on roll_id IS NOT NULL since that's the only case
-- either predicate ever hits.
CREATE INDEX IF NOT EXISTS photos_roll_user_idx
    ON public.photos (roll_id, user_id)
    WHERE roll_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS post_comments_post_idx      ON public.post_comments (post_id);
CREATE INDEX IF NOT EXISTS post_reactions_post_idx     ON public.post_reactions (post_id);
CREATE INDEX IF NOT EXISTS follows_follower_idx        ON public.follows (follower_id);
CREATE INDEX IF NOT EXISTS follows_following_idx       ON public.follows (following_id);
CREATE INDEX IF NOT EXISTS post_tags_tagged_idx        ON public.post_tags (tagged_user_id);
CREATE INDEX IF NOT EXISTS roll_members_user_idx       ON public.roll_members (user_id);
CREATE INDEX IF NOT EXISTS photo_reports_photo_idx     ON public.photo_reports (photo_id);
CREATE INDEX IF NOT EXISTS blocks_blocker_idx          ON public.blocks (blocker_id);

-- ============================================================
-- Feed-size rendition (egress): a ~1400px mid-size JPEG uploaded alongside the full image.
-- The feed downloads this (~250KB) instead of the full 2048px file (~700KB), pixel-identical
-- at feed-card width. Full image still used for full-screen / zoom / save. Older photos have
-- NULL and fall back to storage_path.
--
-- The two ADD COLUMN statements that used to live here now run right after the photos/posts
-- CREATE TABLE blocks (near lines 44 and 632) instead: the storage policies defined shortly
-- after each table already SELECT feed_path, and a fresh top-to-bottom run errored with
-- "column p.feed_path does not exist" before that column existed. Left as a marker so the
-- column's purpose stays documented at the point it was originally introduced.
-- ============================================================

-- ============================================================
-- Security-advisor hardening (2026-07). All applied live; kept here as source of truth.
-- ============================================================
-- profiles ran with the VIEW OWNER's rights, not the querying user's, from when this view was
-- introduced through 2026-09-01. That was load-bearing at the time: the column-level grants on
-- `users` below did not yet cover every column the view selected, so a caller running as itself
-- (security_invoker) could not have read them directly, and turning it on would have made every
-- profile read fail with "permission denied for table users" -- no handles, no avatars, no
-- mentions, no profile pages, app-wide. (Verified against production 2026-08-08:
-- pg_class.reloptions for this view was NULL, i.e. security_invoker was OFF and always had been,
-- despite once being listed under a header claiming "all applied live".)
--
-- As of 2026-09-02 (supabase/migrations/2026-09-02_profiles_security_invoker.sql), that premise no
-- longer holds: the GRANT immediately below now covers every column public.profiles selects,
-- hidden_from_discovery and signup_ordinal included, so the view is safe to run as invoker and
-- now does. The reason
-- it is now SAFE is exactly this GRANT plus the "users: profiles readable" USING (true) policy
-- below -- not anything about the view itself. What still keeps `email` and `invite_code` out of
-- reach is unrelated to invoker vs definer in either direction: they are simply never listed in
-- this GRANT and never in the view's SELECT list. `anon` has no profile access at all now, by
-- design (see the view's own comment above): it never had a SELECT grant on `users`, so an anon
-- profiles read fails immediately under invoker mode instead of silently running as the owner.
ALTER VIEW public.profiles SET (security_invoker = on);

-- users: any signed-in user may read rows, but ONLY the safe profile columns.
-- email + invite_code are excluded from the grant → unreadable via the API for OTHER users
-- (this also closed a leak where roll co-members could select each other's email).
DROP POLICY IF EXISTS "users: visible to co-members" ON public.users;
DROP POLICY IF EXISTS "users: profiles readable" ON public.users;
CREATE POLICY "users: profiles readable" ON public.users FOR SELECT TO authenticated USING (true);
REVOKE SELECT ON public.users FROM anon, authenticated;
-- hidden_from_discovery: added 2026-09-02 so this list covers every column public.profiles
-- selects, matching the view's own security_invoker note above.
--
-- signup_ordinal: folded in here (found 2026-09-03) alongside its column, backfill, and both
-- triggers, added earlier in this file next to the `profiles` view definition -- see the block
-- starting "signup_ordinal: a permanent 'you are the Nth member' number" above. Production has
-- carried this exact GRANT since 2026-08-17_profile_identity.sql; this file previously did not,
-- so a from-scratch load used to diverge from production on this one column. It no longer does.
GRANT SELECT (id, username, avatar_path, bio, created_at, display_name, cover_path,
              hidden_from_discovery, signup_ordinal) ON public.users TO authenticated;

-- chapter_public_stats: a SEPARATE grant, not folded into the list above,
-- because it is NOT one of the columns public.profiles selects (see the
-- Chapters section's own comment on this column for why -- no client
-- surface needs another profile's pick list, only a caller reading their
-- OWN row for the settings screen does). Still column-scoped, same
-- REVOKE-then-GRANT discipline: the REVOKE SELECT above already covers
-- this column too since it runs table-wide.
GRANT SELECT (chapter_public_stats) ON public.users TO authenticated;

-- INSERT/UPDATE/DELETE: column-scoped, same discipline as SELECT above.
-- Supabase's default privileges hand INSERT/UPDATE/DELETE to anon AND
-- authenticated on every new table in public, TABLE-WIDE (every column,
-- including email/invite_code/invite_uses_remaining/id) unless explicitly
-- taken back — this REVOKE + re-GRANT is that takeback. Closed as
-- 2026-08-29_close_users_privilege_escalation.sql: the table-wide UPDATE
-- combined with the row-level-only "users: own row" policy let any signed-in
-- user PATCH their own row's `email` to the owner's, which is the sole input
-- is_owner() used to trust (see that function below). REVOKE must run before
-- each GRANT, every time this file re-runs, for the same reason the SELECT
-- REVOKE above does: a bare GRANT does not remove the wider default.
REVOKE INSERT, UPDATE, DELETE ON public.users FROM anon, authenticated;
-- Signup only (AuthService.setUsername's InsertUser). The caller already
-- holds a session before this INSERT runs, so `anon` never needs it.
GRANT INSERT (id, email, username, invite_code, display_name) ON public.users TO authenticated;
-- Every column the client legitimately updates directly. displayed_badges
-- goes through set_displayed_badges() (SECURITY DEFINER); signup_ordinal,
-- invite_uses_remaining, email, invite_code and id have no direct-UPDATE
-- client path at all, by design, and are deliberately not listed here.
GRANT UPDATE (username, display_name, bio, avatar_path, cover_path) ON public.users TO authenticated;
-- No DELETE grant to anyone: account deletion runs through the SECURITY
-- DEFINER public.delete_account() RPC, whose `DELETE FROM auth.users`
-- cascades to this table via the id column's own FK, with the function
-- OWNER's privileges — independent of what authenticated/anon hold here.

-- Your OWN full row (incl. email + invite_code) via a locked-down RPC.
CREATE OR REPLACE FUNCTION public.get_own_profile()
RETURNS public.users
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$ SELECT * FROM public.users WHERE id = auth.uid() $$;
REVOKE ALL ON FUNCTION public.get_own_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_profile() TO authenticated;

-- Your OWN remaining invite count, and nothing else's. Zero parameters and
-- auth.uid() pinned inside the SECURITY DEFINER body, so there is no argument
-- a caller could pass to read someone else's row. An RPC rather than a
-- `profiles` column because that view deliberately excludes every invite
-- field, same leak class the view already closed for email/invite_code.
-- NULL return means unlimited (see the invite_uses_remaining column comment
-- above); any other value, including 0, is the caller's real remaining count.
CREATE OR REPLACE FUNCTION public.get_own_invite_quota()
RETURNS INT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$ SELECT invite_uses_remaining FROM public.users WHERE id = auth.uid() $$;
REVOKE ALL ON FUNCTION public.get_own_invite_quota() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_invite_quota() TO authenticated;

-- Your OWN invite history: who you've invited (handle, or NULL if they have
-- not signed up yet), when, and whether they've taken a photo since. Full
-- reasoning (the note-match regex, why allowed_emails.email never leaves this
-- function, the account-deletion behavior, and why blocking is deliberately
-- NOT applied here) lives in
-- supabase/migrations/2026-08-29_get_own_invites_sent.sql -- read that before
-- touching this function.
CREATE OR REPLACE FUNCTION public.get_own_invites_sent()
RETURNS TABLE (
    handle    TEXT,
    sent_at   TIMESTAMPTZ,
    activated BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT
        u.username AS handle,
        ae.added_at AS sent_at,
        EXISTS (
            SELECT 1 FROM public.photos p WHERE p.user_id = u.id
        ) AS activated
    FROM public.allowed_emails ae
    LEFT JOIN public.users u ON lower(u.email) = ae.email
    WHERE auth.uid() IS NOT NULL
      AND ae.note ~ ('^invited_by:' || auth.uid()::text || '$')
    ORDER BY ae.added_at ASC;
$$;
REVOKE ALL ON FUNCTION public.get_own_invites_sent() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_invites_sent() TO authenticated;

-- Function hygiene: pin the one mutable search_path; internal functions unreachable via RPC;
-- signed-in-only actions closed to anon. is_email_allowed stays anon-callable BY DESIGN
-- (the invite gate runs before sign-in; it returns only a boolean).
ALTER FUNCTION public.mark_developed_photos() SET search_path = public;
REVOKE EXECUTE ON FUNCTION public.auto_hide_reported() FROM PUBLIC, anon, authenticated;
-- rls_auto_enable() exists only in the live DB (event-trigger helper, never mirrored here);
-- guard the REVOKE so a fresh run of this file doesn't abort on the missing function.
DO $$
BEGIN
  IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION public.mark_developed_photos() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.delete_account() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.join_roll(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_roll_member(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_roll_developed(uuid) FROM PUBLIC, anon;
-- These three were the only functions in the file revoked without being granted back, relying
-- silently on Supabase's default privileges having handed `authenticated` execute when they were
-- first created. Production is fine, because that grant has never been disturbed. A genuine
-- rebuild from this file was not: `authenticated` came out with no execute on any of them, which
-- breaks join_roll outright and, worse, breaks every RLS policy that calls is_roll_member or
-- is_roll_developed inside USING or WITH CHECK, across photos, rolls, roll_members,
-- photo_comments, photo_reactions, post_tags and roll_notification_mutes, for every signed-in
-- user at once. Relying on a platform default is not the same as stating the grant.
GRANT EXECUTE ON FUNCTION public.join_roll(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_roll_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_roll_developed(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.is_email_allowed(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_email_allowed(text) TO anon, authenticated;

-- Accepted advisor remainders (intentional):
--  * allowed_emails: RLS on, no policies = deny-all to clients (read via is_email_allowed only).
--  * pg_net in public: the extension does not support SET SCHEMA; its callable API lives in `net`.
--  * leaked-password protection (HIBP): Pro-plan feature, enable in dashboard after upgrading.

-- ============================================================
-- Covered posts: a bounded set of POSTS hidden from everyone except their
-- authors and the owner. Applied separately as
-- supabase/migrations/2026-08-12_covered_posts.sql (that file also carries
-- the one-time username-keyed seed, deliberately NOT mirrored here; this
-- file is re-run in production as the standing workflow, and re-seeding on
-- every run is not what a schema source of truth should do).
--
-- This restricts who can SEE a bounded set of posts. It does not touch
-- accounts, follows, comments, reactions, Discover, or search, and it does
-- not restrict what the covered authors themselves can see — their own
-- feeds, search, and everyone else's non-covered posts are all unaffected.
--
-- Membership AND the window are DATA (public.covered_post_windows), not
-- literals in a policy body. The window is compared only against a POST's
-- OWN created_at, never against now() — this is a permanent restriction on
-- WHICH posts are covered, not a timer, and it must never be turned into
-- one: adding any now()-relative clause here would silently republish these
-- posts on a schedule nobody asked for. Flip every row's `active` to FALSE
-- and both predicates below evaluate back to their pre-covered-posts value
-- (unconditionally TRUE) with no other change, because post_is_covered
-- short-circuits to FALSE the moment no matching row is active.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.covered_post_windows (
    user_id      UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    window_start TIMESTAMPTZ NOT NULL,
    window_end   TIMESTAMPTZ NOT NULL,
    active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    CHECK (window_end > window_start)
);
ALTER TABLE public.covered_post_windows ENABLE ROW LEVEL SECURITY;
-- No policies -> deny-all to every client role, same shape as
-- allowed_emails above. Readable only through the SECURITY DEFINER helpers
-- below; writable only via the SQL editor / service role.

-- The single pinned owner constant, added by
-- 2026-09-01_pin_owner_identity_everywhere.sql. Same UUID
-- 2026-08-29_close_users_privilege_escalation.sql pinned directly into
-- is_owner()/is_owner(uuid); f43287d4-f239-415b-af45-650bbee62e83, signup_ordinal
-- 1, per the owner. Both is_owner() and is_owner(uuid) below read it from
-- here instead of repeating the literal, and so do the auto-follow trigger
-- further down this file and send-social-push/send-daily-digest (via RPC,
-- since those run under the service role, not `authenticated`): one place
-- spells out the UUID, everything else calls this. It carries no privilege
-- by itself (it returns an identifier, not a boolean gate), and that
-- identifier is already discoverable by any authenticated client today:
-- every account auto-follows the owner at signup, and "follows: readable by
-- authenticated" already exposes every row of public.follows. Even so, anon
-- is revoked, same as every other signed-in-only RPC in this schema: nothing
-- needs it (no unauthenticated Swift call path exists, and both edge
-- functions run as service_role), so it stays narrow on general
-- least-privilege grounds rather than because holding it back is load
-- bearing. Plain SECURITY INVOKER SQL: it touches no table, so there is
-- nothing for a caller's privileges to matter to.
CREATE OR REPLACE FUNCTION public.owner_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
    SELECT 'f43287d4-f239-415b-af45-650bbee62e83'::uuid;
$$;
REVOKE ALL ON FUNCTION public.owner_user_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.owner_user_id() FROM anon;
GRANT EXECUTE ON FUNCTION public.owner_user_id() TO authenticated, service_role;

-- Owner exemption, tested by uuid so it composes inside a two-argument
-- visibility predicate the same way is_blocked_either_way(a, b) does. This
-- is a NEW OVERLOAD of is_owner() (no args, defined further down this file
-- for the admin dashboard's RPCs); that function is untouched, its calls are
-- unaffected. Created here defensively with CREATE OR REPLACE rather than
-- assumed to already exist, so this file has no ordering dependency on any
-- other migration having run first.
--
-- Re-pointed at the owner's immutable auth id by
-- 2026-08-29_close_users_privilege_escalation.sql, replacing a
-- lower(email) = lower('codyysb@gmail.com') comparison: email was a plain
-- client-writable column (AuthService.setUsername's signup INSERT accepts
-- an arbitrary email), so any signed-in account could make this TRUE for
-- itself with one write. id is the primary key, is pinned to auth.uid() by
-- the "users: own row" RLS policy, and is what every foreign key in this
-- schema actually references — it cannot be claimed by another account the
-- way email could. Body updated by
-- 2026-09-01_pin_owner_identity_everywhere.sql to read the constant from
-- owner_user_id() instead of repeating the literal; behaviour unchanged.
CREATE OR REPLACE FUNCTION public.is_owner(p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_user = public.owner_user_id();
$$;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner(uuid) TO authenticated;

-- TRUE only when p_author has an ACTIVE covered_post_windows row whose
-- [window_start, window_end) contains p_created_at. STABLE, SECURITY
-- DEFINER so it can bypass covered_post_windows' own deny-all RLS to be
-- callable from the posts/storage policies at all, same reason
-- is_blocked_either_way and is_roll_member are definer functions.
CREATE OR REPLACE FUNCTION public.post_is_covered(p_author UUID, p_created_at TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.covered_post_windows w
        WHERE w.user_id = p_author
          AND w.active
          AND p_created_at >= w.window_start
          AND p_created_at <  w.window_end
    );
$$;
REVOKE ALL ON FUNCTION public.post_is_covered(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_is_covered(uuid, timestamptz) TO authenticated;

-- The predicate "posts: readable by authenticated" and "photos: readable
-- when shared to a post" (storage.objects) both add below. FALSE only when
-- the post IS covered AND the viewer is neither the owner nor one of the
-- covered authors (symmetric: any active row in covered_post_windows is
-- enough to see any covered post, regardless of whose post it is — this is
-- deliberately NOT a mutual seal: it grants extra visibility into a bounded
-- set of posts, it never removes visibility the viewer already had).
CREATE OR REPLACE FUNCTION public.covered_post_visible(p_viewer UUID, p_author UUID, p_created_at TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        NOT public.post_is_covered(p_author, p_created_at)
        OR public.is_owner(p_viewer)
        OR EXISTS (
            SELECT 1 FROM public.covered_post_windows w
            WHERE w.user_id = p_viewer AND w.active
        );
$$;
REVOKE ALL ON FUNCTION public.covered_post_visible(uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.covered_post_visible(uuid, uuid, timestamptz) TO authenticated;

-- ============================================================
-- Block enforcement at the RLS level (App Store Guideline 1.2).
-- Blocking used to be a client-only filter, so a blocked user's comments,
-- reactions, tags, and roll photos still surfaced (and the block was one-way).
-- We now push blocking into the read/write policies so it is bidirectional and
-- holds regardless of client: if A blocked B (or B blocked A) neither sees the
-- other's UGC, and neither can act on the other's content going forward.
--
-- `blocks` has an owner-only SELECT policy, so a policy on some OTHER table
-- (posts, comments, …) can't read it directly. This SECURITY DEFINER helper
-- runs with owner rights (bypassing blocks' RLS internally) and returns only a
-- boolean, the same pattern as is_roll_member. STABLE + pinned search_path.
--
-- ⚠️ Grants: `authenticated` MUST keep EXECUTE. SECURITY DEFINER only controls
-- whose privileges the function BODY runs with, the querying role still needs
-- EXECUTE to call it, and RLS policies evaluate as the querying role. Revoking
-- authenticated here took production down ("permission denied for function
-- is_blocked_either_way" on every read/write). Same grant shape as
-- is_roll_member: revoke PUBLIC + anon only. Accepted remainder: a signed-in
-- user can probe block relationships between two arbitrary user ids via RPC
-- (same exposure class as probing roll membership via is_roll_member).
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_blocked_either_way(a UUID, b UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.blocks
        WHERE (blocker_id = a AND blocked_id = b)
           OR (blocker_id = b AND blocked_id = a)
    );
$$;
REVOKE EXECUTE ON FUNCTION public.is_blocked_either_way(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_blocked_either_way(uuid, uuid) TO authenticated;

-- Reverse-direction index so the OR-branch (blocker=b AND blocked=a) is index-backed.
-- The blocks PK (blocker_id, blocked_id) already covers the forward lookup.
CREATE INDEX IF NOT EXISTS blocks_blocked_idx ON public.blocks (blocked_id, blocker_id);

-- --- READ policies: drop the blocked party's content from every shared surface ---

-- Feed posts: hide posts authored by anyone in a block relationship with the viewer, and
-- anything auto-hidden by moderation (see "Auto-moderation, enforced at RLS" above, this is
-- the definition of this policy name that actually survives a full run of this file). Also
-- adds public.covered_post_visible (see "Covered posts" above): a covered post is readable
-- only by its author, the other covered authors, or the owner.
DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated
    USING (
        NOT hidden
        AND NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND public.covered_post_visible(auth.uid(), user_id, created_at)
    );

-- Post comments: hide comments authored by a blocked party (even on posts you can see).
DROP POLICY IF EXISTS "post_comments: readable" ON public.post_comments;
CREATE POLICY "post_comments: readable"
    ON public.post_comments FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

-- Post reactions: hide reactions from a blocked party (feed cards + Activity).
DROP POLICY IF EXISTS "post_reactions: readable" ON public.post_reactions;
CREATE POLICY "post_reactions: readable"
    ON public.post_reactions FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

-- Post tags: hide tags that point at a blocked party.
DROP POLICY IF EXISTS "post_tags: readable" ON public.post_tags;
CREATE POLICY "post_tags: readable"
    ON public.post_tags FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), tagged_user_id));

-- Comment likes: hide likes from a blocked party (comment ranking + counts).
DROP POLICY IF EXISTS "comment_likes: readable" ON public.comment_likes;
CREATE POLICY "comment_likes: readable"
    ON public.comment_likes FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

-- Shared-roll photos: hide a blocked party's photos from the roll surface, and anything
-- auto-hidden by moderation (see "Auto-moderation, enforced at RLS" above, this is the
-- definition of this policy name that actually survives a full run of this file). Preserves
-- the existing membership check; adds the block predicate. (Own photos policy is
-- unchanged, you can never block yourself, CHECK (blocker_id <> blocked_id).)
DROP POLICY IF EXISTS "photos: roll members can see" ON public.photos;
CREATE POLICY "photos: roll members can see"
    ON public.photos FOR SELECT
    USING (
        roll_id IS NOT NULL
        AND NOT hidden
        AND public.is_roll_member(roll_id)
        AND NOT public.is_blocked_either_way(auth.uid(), user_id)
    );

-- Shared-roll photo BYTES (storage.objects): the row policy above already hides a blocked
-- party's photo row, but blocking never touches roll_members, so a blocked user still passes
-- is_roll_member(roll_id) at the storage layer. Without this, a storage path cached on-device
-- (SignedURLStore.ttl, up to 7 days) could still mint a fresh signed URL for a roll-mate's bytes
-- after the block, even though every row-level surface had already hidden it. This is the
-- definition of this policy name that actually survives a full run of this file (the storage
-- bootstrap section above only has bucket/rendition-path/roll-membership/hidden; it predates
-- is_blocked_either_way, which isn't created until further up in this file, so the block
-- predicate has to live in this later redefinition, same reasoning as "NOT hidden" above).
DROP POLICY IF EXISTS "photos: roll members can read shared" ON storage.objects;
CREATE POLICY "photos: roll members can read shared"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE storage.objects.name IN (p.storage_path, p.thumb_path, p.feed_path)
              AND p.roll_id IS NOT NULL
              AND NOT p.hidden
              AND public.is_roll_member(p.roll_id)
              AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
        )
    );

-- Posted photo BYTES (storage.objects): mirrors "posts: readable by authenticated" above,
-- which already keys NOT hidden and the block check off po.user_id. Same cached-path risk as
-- the roll-photo policy just above; this closes it for photos shared to a post. Also mirrors
-- the covered_post_visible check: verified in Docker that a plain (non-SECURITY-DEFINER)
-- EXISTS subquery against public.posts is already subject to posts' own RLS for the querying
-- role, so a covered post's bytes were already unreachable through this subquery even before
-- this line existed; it's added anyway for the same "don't rely on implicit RLS propagation
-- across a subquery" reasoning the NOT hidden / block checks just above it were already added
-- for, not because a leak was found.
DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path)
                      AND NOT po.hidden
                      AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
                      AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at))
    );

-- Roll photo comments: keep the membership/ownership check, drop the blocked author's.
DROP POLICY IF EXISTS "photo_comments: readable by roll members" ON public.photo_comments;
CREATE POLICY "photo_comments: readable by roll members"
    ON public.photo_comments FOR SELECT TO authenticated
    USING (
        NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                    AND (p.user_id = auth.uid() OR public.is_roll_member(p.roll_id)))
    );

-- Roll photo reactions: keep the visible-photo check, drop the blocked reactor's.
DROP POLICY IF EXISTS "reactions: visible on visible photos" ON public.photo_reactions;
CREATE POLICY "reactions: visible on visible photos"
    ON public.photo_reactions FOR SELECT
    USING (
        NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE p.id = photo_reactions.photo_id
              AND (p.user_id = auth.uid()
                   OR (p.roll_id IS NOT NULL AND public.is_roll_member(p.roll_id)))
        )
    );

-- --- WRITE policies: a blocked party can't act on the blocker's content going forward ---
-- (Closes the one-directional gap: previously the blocked user could still comment/
-- react on the blocker. Reads are already hidden above; these stop new interactions.)

-- Can't comment on a post whose author is in a block relationship with you.
DROP POLICY IF EXISTS "post_comments: add own" ON public.post_comments;
CREATE POLICY "post_comments: add own"
    ON public.post_comments FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_id
                    AND NOT public.is_blocked_either_way(auth.uid(), p.user_id))
    );

-- Can't react on a post whose author is in a block relationship with you.
DROP POLICY IF EXISTS "post_reactions: add own" ON public.post_reactions;
CREATE POLICY "post_reactions: add own"
    ON public.post_reactions FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_id
                    AND NOT public.is_blocked_either_way(auth.uid(), p.user_id))
    );

-- Can't like a comment authored by a block-related party.
DROP POLICY IF EXISTS "comment_likes: add own" ON public.comment_likes;
CREATE POLICY "comment_likes: add own"
    ON public.comment_likes FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.post_comments c WHERE c.id = comment_id
                    AND NOT public.is_blocked_either_way(auth.uid(), c.user_id))
    );

-- Can't comment on a roll photo whose owner is a block-related party (keeps membership check).
DROP POLICY IF EXISTS "photo_comments: insert as roll member" ON public.photo_comments;
CREATE POLICY "photo_comments: insert as roll member"
    ON public.photo_comments FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid()
                AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                            AND public.is_roll_member(p.roll_id)
                            AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)));

-- Can't react on a roll photo whose owner is a block-related party. (photo_reactions'
-- INSERT was CHECK (auth.uid() = user_id) only; we now also verify the photo owner.)
DROP POLICY IF EXISTS "reactions: add own" ON public.photo_reactions;
CREATE POLICY "reactions: add own"
    ON public.photo_reactions FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                    AND NOT public.is_blocked_either_way(auth.uid(), p.user_id))
    );

-- Can't follow a block-related party.
DROP POLICY IF EXISTS "follows: create own" ON public.follows;
CREATE POLICY "follows: create own"
    ON public.follows FOR INSERT WITH CHECK (
        auth.uid() = follower_id
        AND NOT public.is_blocked_either_way(auth.uid(), following_id)
    );

-- What RLS deliberately does NOT cover (must stay a client-side filter), see the
-- report handed to the Swift agent:
--  * public.profiles / public.users rows: readable by every signed-in user by design
--    (comment authors, page browsing). Hiding a blocked user's whole profile row would
--    break unrelated joins; the client hides the profile surface instead.
--  * roll member lists (roll_members): membership stays visible so counts/avatars render;
--    the client greys/omits a blocked co-member in the roster.
--  * follows READ: the graph stays readable (follower/following counts); the client
--    filters blocked users out of follower/following LISTS.
--  * Activity aggregation: assembled client-side from now-block-filtered reaction/comment/
--    tag rows, but any purely client-derived activity items must also be filtered there.
--  * Storage objects: a signed URL ALREADY handed out to a client before a block still
--    works for the rest of its short TTL; Storage has no revocation-on-block mechanism,
--    and this schema doesn't attempt one. What IS covered: "photos: roll members can read
--    shared" and "photos: readable when shared to a post" (storage.objects, both further
--    above) now carry the same is_blocked_either_way predicate as their public.photos /
--    public.posts row counterparts, so minting a NEW signed URL for a blocked party's
--    bytes fails at RLS even if the client still holds the raw path (e.g. from
--    SignedURLStore's on-device cache, which persists a path for up to 7 days). Before
--    2026-08-07 this bullet incorrectly assumed the row-level block filter alone protected
--    Storage; it does not, storage.objects has its own independent RLS policies that must
--    carry the predicate themselves. That gap is what closed on 2026-08-07.

-- ============================================================
-- Block severs the follow graph (fixes a follower-count asymmetry).
--
-- When A blocks B, the client optimistically deletes A→B (unfollow). But the
-- follows DELETE policy is `follower_id = auth.uid()`, A can delete only its
-- OWN follower_id row, never B's B→A row. So B→A survived every block:
--   - the blocker vanished from the blocked user's follower LIST (the client
--     filters blockedIds out of the list), but
--   - the follower COUNT stayed unchanged (count queries count raw rows), while
--     the following count dropped correctly.
-- Observed live after Sabirah blocked Cody: confusing, looked broken.
--
-- Fix it server-side and BIDIRECTIONALLY: an AFTER INSERT trigger on blocks
-- deletes BOTH follow edges between the pair (follower/following either way).
-- SECURITY DEFINER so it runs with owner rights and bypasses the follows DELETE
-- policy, the client role could never delete the counterparty's row. Pinned
-- search_path = public, same as the other definer/trigger functions.
--
-- Grants: a trigger function is invoked by the trigger mechanism, NOT called by
-- a client role via RPC, so no role needs EXECUTE on it. We still revoke from
-- PUBLIC/anon/authenticated to match the auto_hide_reported convention above, 
-- nothing can call it directly. The blocks INSERT policy (blocker_id =
-- auth.uid()) is unchanged; the trigger just fires after a legit block lands.
-- All blocks come from the client table INSERT (FeedService.block); there is no
-- block-creating RPC or edge function, so this trigger covers every path.
-- ============================================================
CREATE OR REPLACE FUNCTION public.block_severs_follows()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.follows
    WHERE (follower_id = NEW.blocker_id AND following_id = NEW.blocked_id)
       OR (follower_id = NEW.blocked_id AND following_id = NEW.blocker_id);
    RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.block_severs_follows() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS block_severs_follows_trigger ON public.blocks;
CREATE TRIGGER block_severs_follows_trigger
    AFTER INSERT ON public.blocks
    FOR EACH ROW EXECUTE FUNCTION public.block_severs_follows();

-- ============================================================
-- Report notifications (App Store Guideline 1.2, act on UGC reports within 24h).
-- The auto_hide_reported trigger above hides content at >= 2 distinct reporters,
-- but nothing told the owner a report happened. Rather than add a pg_net trigger
-- (which would need the service key + function URL in the DB, deliberately not
-- how push works here), we reuse the existing scheduled poll + push_sent pattern:
-- the every-1-minute send-social-push Edge Function scans photo_reports and
-- user_reports for push_sent = FALSE and pushes to the OWNER's device_tokens
-- (owner resolved by the note='owner' allowed_emails / OWNER_EMAIL constant in
-- that function), then flips the flag. Every report notifies, not just the
-- auto-hide threshold. Daily-check backstop (for when the owner has no device on
-- file) lives in the 2026-07-10_report_notifications.sql migration header.
-- ============================================================
ALTER TABLE public.photo_reports ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.user_reports  ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS photo_reports_unpushed_idx ON public.photo_reports (push_sent) WHERE push_sent = FALSE;
CREATE INDEX IF NOT EXISTS user_reports_unpushed_idx  ON public.user_reports  (push_sent) WHERE push_sent = FALSE;

-- ============================================================
-- Crash/hang/CPU-exception diagnostics (MetricKit, on-device, see CrashReporter.swift).
-- Before this, the only way to see a hang or CPU-exception diagnostic (Xcode Organizer's
-- Crashes tab doesn't show either) was physically connecting the exact device it happened on
-- to Xcode and pulling its container, meaning in practice, only the owner's own test device
-- was ever actually visible. This makes every diagnostic reach a place the owner can query.
--
-- Write-only from the client, deliberately: any signed-in user can log their own device's
-- diagnostics, and a not-yet-signed-in device can log one with no user_id, but there is no
-- SELECT policy for authenticated or anon at all. Reading this table means the Supabase
-- Dashboard or the Management API with an owner-supplied token, both of which use the service
-- role and bypass RLS entirely, never the app itself.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.crash_diagnostics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    kind text NOT NULL CHECK (kind IN ('crash', 'hang', 'cpuException')),
    detail text NOT NULL,
    app_version text,
    call_stack_tree text,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- Context needed to act on a row, added as
    -- supabase/migrations/2026-08-03_crash_diagnostics_context.sql.
    --
    -- app_build: every CI build of 1.2 has its own dSYM, and a MetricKit stack is raw binary
    --   offsets that only the exact matching dSYM resolves. Without this you cannot tell which
    --   artifact to symbolicate against.
    -- occurred_at: created_at is when the row was UPLOADED. MetricKit only hands diagnostics over
    --   on a later launch, so several rows arriving at once are a flush at app start, not several
    --   crashes at that instant.
    -- os_version / device_model: separate "everyone" from "one person on one old phone".
    --
    -- All nullable: existing rows predate them, and a diagnostic retried from a pre-update
    -- on-device queue legitimately has none of them. Missing means unknown, never a dropped row.
    app_build text,
    os_version text,
    device_model text,
    occurred_at timestamptz
);

CREATE INDEX IF NOT EXISTS crash_diagnostics_created_at_idx ON public.crash_diagnostics (created_at DESC);
CREATE INDEX IF NOT EXISTS crash_diagnostics_kind_idx ON public.crash_diagnostics (kind);
-- Triage reads newest-first by when the crash HAPPENED, and almost always filters to one build.
CREATE INDEX IF NOT EXISTS crash_diagnostics_occurred_at_idx
    ON public.crash_diagnostics (occurred_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS crash_diagnostics_build_idx
    ON public.crash_diagnostics (app_version, app_build);

ALTER TABLE public.crash_diagnostics ENABLE ROW LEVEL SECURITY;

-- Ties an authenticated insert to the caller's own uid (can't attribute a diagnostic to
-- someone else) and only allows a claimed-anonymous insert (no session) to carry a null
-- user_id (can't claim to be a specific user without a valid JWT either).
DROP POLICY IF EXISTS "crash_diagnostics: insert" ON public.crash_diagnostics;
CREATE POLICY "crash_diagnostics: insert"
    ON public.crash_diagnostics FOR INSERT TO anon, authenticated
    WITH CHECK (
        (auth.uid() IS NOT NULL AND auth.uid() = user_id)
        OR (auth.uid() IS NULL AND user_id IS NULL)
    );

-- ============================================================
-- Roll-photo reaction pushes (the reveal's "communal" pull-back loop).
-- When someone reacts to a roll photo, notify the photo's OWNER (never self), so a reaction
-- left during the reveal pulls its owner back even if they revealed early and saw it thin.
-- Same poll + push_sent-flag pattern as post reactions and reports: send-social-push scans
-- unpushed rows every minute, batches per reactor, respects roll_notification_mutes, flips
-- the flag. push_sent defaults FALSE, which is also the normal in-flight state for a brand
-- new reaction awaiting its push, so the one-time backfill that marks pre-existing reactions
-- as already handled is NOT run here (an unconditional `UPDATE ... WHERE push_sent = FALSE`
-- in this always-safe-to-re-run file would permanently drop the push for every reaction
-- currently pending send). That backfill lives once, guarded, in
-- supabase/migrations/2026-07-31_photo_reactions_push_backfill.sql.
-- ============================================================
ALTER TABLE public.photo_reactions ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- ============================================================
-- Follow notifications
--
-- A new follower was the one social event that showed up in the in-app Activity
-- feed (ActivityFeedView renders `.follow` rows, with a follow-back control) but
-- never reached the phone. Someone could follow you and nothing would tell you
-- unless you happened to open Activity.
--
-- Same poll + push_sent-flag pattern as posts, reactions, comments and reports:
-- send-social-push scans follows for push_sent = FALSE every minute, pushes to
-- the followed user, then flips the flag. Blocks are enforced by that function's
-- `notify` helper, which every user-to-user push goes through.
--
-- As with photo_reactions, the one-time backfill marking pre-existing follows as
-- already handled is NOT here: this file is re-run in production as the standing
-- workflow, and an unconditional UPDATE would permanently swallow the push for
-- any follow mid-flight at that moment. It lives once, with a fixed cutoff, in
-- supabase/migrations/2026-08-05_follow_push_backfill.sql.
-- ============================================================
ALTER TABLE public.follows ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- The partial index every other push_sent table already has, and this one was missing.
--
-- send-social-push asks `where push_sent = false` every sixty seconds, forever. Without this it
-- is a sequential scan, and `follows` is the table that grows fastest with the user base: n users
-- can produce up to n² edges, while the rows the scan actually wants stay near zero because they
-- are flipped within a minute of being written. A partial index is the right shape precisely
-- because the interesting set is tiny and the table is not.
CREATE INDEX IF NOT EXISTS follows_unpushed_idx
    ON public.follows (push_sent) WHERE (push_sent = false);
CREATE INDEX IF NOT EXISTS photo_reactions_unpushed_idx ON public.photo_reactions (push_sent) WHERE push_sent = FALSE;

-- ============================================================
-- Roll reveal views (the async "communal" presence: "you're the Nth of M to open this roll").
-- One row per member who has opened a roll's reveal. Lets the reveal show how many of the group
-- have seen it yet, so it feels shared even though everyone arrives at their own time, without
-- any realtime infra. A member records their own view; any member can read the roster's views
-- for a roll they belong to (is_roll_member gates both). PK makes re-opening idempotent.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.roll_reveal_views (
    roll_id   uuid NOT NULL REFERENCES public.rolls(id) ON DELETE CASCADE,
    user_id   uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    viewed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (roll_id, user_id)
);

ALTER TABLE public.roll_reveal_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "reveal_views: record own" ON public.roll_reveal_views;
CREATE POLICY "reveal_views: record own"
    ON public.roll_reveal_views FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id AND public.is_roll_member(roll_id));

DROP POLICY IF EXISTS "reveal_views: read for member rolls" ON public.roll_reveal_views;
CREATE POLICY "reveal_views: read for member rolls"
    ON public.roll_reveal_views FOR SELECT TO authenticated
    USING (public.is_roll_member(roll_id));

-- ============================================================
-- Tag self-removal. Being tagged used to be one-way: post_tags allowed DELETE only to the post's
-- owner, so the only person who could untag you was the person who tagged you. Postgres ORs
-- permissive policies, so this adds to the owner policy rather than replacing it, and is scoped
-- to your own row only: it grants no ability to remove anyone else's tag, and INSERT is untouched
-- so it cannot be used to ADD a tag. Applied separately as
-- supabase/migrations/2026-08-01_tag_self_removal.sql.
-- ============================================================
DROP POLICY IF EXISTS "post_tags: tagged user removes self" ON public.post_tags;
CREATE POLICY "post_tags: tagged user removes self"
    ON public.post_tags FOR DELETE TO authenticated
    USING (tagged_user_id = auth.uid());

-- ============================================================
-- Daily digest state. One row per user, recording the last time they were sent a "your friends
-- posted" digest, so the hourly job is idempotent and a missed run rolls into the next one rather
-- than dropping a day's posts. RLS is ON with NO policies: only the service role (which bypasses
-- RLS) ever touches this, and no client has any business reading delivery bookkeeping. Applied
-- separately as supabase/migrations/2026-08-03_daily_digest_state.sql.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.digest_state (
    user_id      uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    last_sent_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.digest_state ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Owner gate. Everything owner-gated below (the invite queue, the report
-- queue, feedback, every admin_* analytics RPC) calls this, so it must be
-- defined first. Applied separately as
-- supabase/migrations/2026-08-07_admin_dashboard.sql.
--
-- Re-pointed at the owner's immutable auth id by
-- 2026-08-29_close_users_privilege_escalation.sql. This used to resolve
-- against lower(public.users.email) = lower('codyysb@gmail.com') (same
-- identity check send-social-push's OWNER_EMAIL constant still uses,
-- unrelated to this function) "rather than pinning a UUID that would go
-- stale if the owner's row is ever recreated" — that rationale did not
-- account for `email` being an ordinary client-writable column: with
-- public.users' table-wide UPDATE grant (also closed by that migration),
-- any signed-in user could PATCH their own row's email to the owner's and
-- make this function return TRUE for them, unlocking the entire admin
-- surface. id is the primary key, is pinned to auth.uid() by the
-- "users: own row" RLS policy, and is what every foreign key in this schema
-- actually references — accept a manual update to this constant on the
-- rare, owner-initiated event of the owner's auth row being recreated, in
-- exchange for removing a live, universally-reachable escalation.
-- auth.uid() with no session is NULL, which does not equal the pinned uuid
-- and returns FALSE, not an error.
--
-- Body updated by 2026-09-01_pin_owner_identity_everywhere.sql to read the
-- constant from public.owner_user_id() (defined earlier in this file, next
-- to is_owner(uuid)) instead of repeating the literal a second time;
-- behaviour unchanged. That same migration also finished the job this
-- comment describes: send-social-push's OWNER_EMAIL constant, referenced two
-- paragraphs up, no longer exists: it and send-daily-digest's copy both
-- resolve the owner via RPC to owner_user_id() now, and the auto-follow
-- trigger further down this file no longer resolves by email either.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() = public.owner_user_id();
$$;
REVOKE ALL ON FUNCTION public.is_owner() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner() TO authenticated;

-- ============================================================
-- Usage events: day-bucketed, privacy-preserving instrumentation.
-- Folded in from supabase/migrations/2026-08-17_usage_events.sql, CHECK widened by
-- 2026-08-31_invite_source_events.sql. Production has carried this table since
-- 2026-08-17; this file did not, until now -- found while folding the badge system
-- below (2026-09-03), whose 'regular' badge (see _ratchet_badges) reads usage_events
-- directly and would fail at call time on a fresh load without it.
--
-- Day buckets (user_id, event, day) with a counter, never a timestamped row per
-- occurrence: a stamped stream would reconstruct a behavioural timeline (when someone
-- opens the app, down to the minute), which is exactly what FLIM's "no algorithm, no
-- strangers" posture is about. ON CONFLICT DO UPDATE lets the client fire this
-- carelessly on every occurrence; the database is what keeps it to one row per user
-- per event per day.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.usage_events (
    user_id     UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    event       TEXT NOT NULL,
    -- UTC, not the user's local day -- FLIM has no timezone column, and inventing one
    -- to make buckets prettier would collect location-adjacent data to improve a chart.
    day         DATE NOT NULL DEFAULT (now() AT TIME ZONE 'utc')::date,
    occurrences INT  NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, event, day),
    CONSTRAINT usage_events_event_check CHECK (event IN (
        'app_open', 'photo_captured', 'post_shared', 'feed_viewed', 'reveal_watched',
        -- invite_shared_*: which surface an invite share came from, added by
        -- 2026-08-31_invite_source_events.sql. invite_sent (activation_events) still
        -- fires the once-ever funnel milestone; these carry the per-surface volume.
        'invite_shared_profile', 'invite_shared_feed', 'invite_shared_reveal'
    ))
);
CREATE INDEX IF NOT EXISTS usage_events_day_event_idx ON public.usage_events (day, event);

-- RLS: owner-only SELECT, and deliberately NO INSERT/UPDATE/DELETE policy for anyone --
-- RLS default-denies any command with no matching policy, so the increment inside
-- log_usage_event() below is the only way this table ever moves, even though this
-- project's stock default privileges also grant table-level INSERT/UPDATE/DELETE to
-- anon/authenticated (as they do on every new table in public).
ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "usage_events: owner reads" ON public.usage_events;
CREATE POLICY "usage_events: owner reads"
    ON public.usage_events FOR SELECT TO authenticated
    USING (public.is_owner());

CREATE OR REPLACE FUNCTION public.log_usage_event(p_event TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN;
    END IF;

    -- Unqualified `usage_events` here: ON CONFLICT DO UPDATE binds the target by the
    -- name used in the INSERT, and schema-qualifying it is a syntax error.
    INSERT INTO public.usage_events (user_id, event, occurrences)
    VALUES (auth.uid(), p_event, 1)
    ON CONFLICT (user_id, event, day)
    DO UPDATE SET occurrences = usage_events.occurrences + 1;
END;
$$;
REVOKE ALL ON FUNCTION public.log_usage_event(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_usage_event(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_usage_event(TEXT) TO authenticated;

-- ============================================================
-- Badges: a permanent, earned-only achievement ledger, plus the four-slot profile
-- display picker built on top of it.
--
-- Folded in from the migration chain dated 2026-08-17/2026-08-18 --
-- profile_identity.sql (signup_ordinal is folded separately, above; this is PARTS 2&3),
-- earned_badges.sql, five_more_badges.sql, displayed_badges.sql,
-- own_effective_displayed_badges.sql, nine_more_badges.sql, retire_test_roll.sql,
-- medal_ladder_seven_more.sql, good_company_five.sql, good_company_ten.sql,
-- full_set_twenty.sql, one_year_still_shooting.sql, earned_badges_push_sent.sql --
-- roughly a dozen files that each amended the one before by CREATE OR REPLACE, three
-- of them (full_set_twenty, good_company_five, good_company_ten) with a narrow,
-- explicitly-reasoned DELETE against rows the ledger itself had just written, when a
-- threshold changed under badges less than a day old that nobody had been notified
-- about yet. Production has carried the FINAL shape below since 2026-08-18; this file
-- did not, until now -- found 2026-09-03 alongside signup_ordinal, which
-- profile_badges also depends on for the founding_100 predicate.
--
-- This block lands the CURRENT shape only, verified directly against production
-- (pg_get_functiondef / pg_get_constraintdef), not a replay of that file-by-file
-- history -- a fresh load gets the twenty-nine-badge catalog production actually
-- serves today, never an intermediate rung like the original ten-badge full_set or
-- the one-follower good_company.
--
-- THE RATCHET. earned_badges is append-only: a predicate-earned row, once inserted,
-- is never deleted or re-evaluated on the strength of its predicate going false
-- later. PRIMARY KEY (user_id, badge_id) is what makes every INSERT below an
-- "ON CONFLICT DO NOTHING" no-op after the first time it fires. The one documented
-- exception is revoke_badge, an owner-only admin undo scoped to granted_by IS NOT
-- NULL -- it can undo a MISTAKEN GRANT, never touch a predicate-earned row.
--
-- WHO CAN SEE WHAT. profile_badges(uuid) is SECURITY DEFINER, callable about ANY
-- profile by any authenticated caller, and deliberately bypasses the normal
-- roll-membership RLS boundary -- badges are identity elements, the same posture
-- signup_ordinal already takes. The profile's OWNER always sees every badge they
-- hold. Anyone else sees that profile's chosen four (set_displayed_badges) or, if
-- nothing has been chosen, an automatic default: founder, then founding_crew, then
-- founding_100 (whichever of the three the profile actually holds, in that order --
-- see _resolve_effective_displayed_badges' slot_rank), then its rarest remaining
-- badges by holder count. Both branches omit a 'shared' row a covered-post viewer is
-- not allowed to know about (public.covered_post_visible, 2026-08-12_covered_posts.sql)
-- -- filtered inside the same WHERE that feeds the LIMIT 4, never after it, so an
-- invisible badge can never crowd out a visible one from the four slots.
--
-- two_up (a two-CONTRIBUTOR roll badge) shipped in the original design and was CUT
-- before the ledger existed: an exact "=" contributor-count predicate cannot be a
-- ratchet (a later third contributor makes it re-evaluate false), which is exactly
-- why every threshold badge below (full_house, packed_house, front_row, patron,
-- open_door, cover_to_cover, kept_one, regular, ten_frames, good_company, full_set)
-- is written as "rank the Nth qualifying event, ON CONFLICT DO NOTHING" instead --
-- once the Nth thing happens, a later N+1th can never un-rank it. Do not reintroduce
-- an exact-count predicate.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.earned_badges (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    badge_id   TEXT NOT NULL,
    earned_at  TIMESTAMPTZ NOT NULL,
    -- NULL = earned by a predicate in _ratchet_badges below; a uuid = hand-granted by
    -- that owner via grant_badge. Must never surface to any other reader -- every
    -- function below selects only (badge_id, earned_at), and this table carries no
    -- policies at all (see the RLS note further down), so there is no direct grant to
    -- leak it through even from a typo.
    granted_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    -- NULL = earned but never shown to its owner. Only mark_own_badges_seen() moves
    -- this, and only for auth.uid()'s own rows.
    seen_at    TIMESTAMPTZ,
    -- push_sent: added by 2026-08-18_earned_badges_push_sent.sql so send-social-push
    -- can notify a newly-earned badge, the same way it already does posts/tags/
    -- reactions/follows. No backfill runs here -- a fresh table starts empty, so
    -- there is no pre-existing row that would otherwise fire a burst of pushes for
    -- badges "earned" before this column existed (that migration's own backfill was
    -- the one-time fix for production's already-populated table; it has no
    -- equivalent needed on a from-scratch load).
    push_sent  BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (user_id, badge_id),
    -- The full automatic + grantable catalog, verified against production's live
    -- constraint 2026-09-03. test_roll is NOT in this list: it was retired into
    -- founding_crew by 2026-08-18_retire_test_roll.sql and no longer exists anywhere.
    CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (
        'brought_someone', 'chimed_in', 'chipped_in', 'cover_to_cover', 'darkroom',
        'first_in', 'first_light', 'founder', 'founding_100', 'founding_crew',
        'front_row', 'full_house', 'full_roll', 'full_set', 'good_company', 'in_frame',
        'joined_in', 'kept_one', 'one_year', 'open_door', 'packed_house', 'patron',
        'regular', 'roll_maker', 'said_it', 'shared', 'spotter', 'ten_frames', 'well_met'
    )),
    -- The table-level backstop for grant_badge: a granted row (granted_by IS NOT
    -- NULL) may only ever carry one of these two ids, enforced here so even a future
    -- rewrite of grant_badge that forgets its own early check cannot mint one of the
    -- twenty-seven predicate-only ids.
    CONSTRAINT earned_badges_grantable_check CHECK (
        granted_by IS NULL OR badge_id IN ('founding_crew', 'founder')
    )
);

-- granted_by is the one foreign key here without index coverage from the primary key
-- (user_id, badge_id) -- partial, since it is only ever non-NULL for the small
-- minority of hand-granted rows.
CREATE INDEX IF NOT EXISTS earned_badges_granted_by_idx
    ON public.earned_badges (granted_by)
    WHERE granted_by IS NOT NULL;

-- Supports the rarity subquery inside _resolve_effective_displayed_badges below
-- (GROUP BY badge_id) -- the primary key leads with user_id and does not serve that
-- scan, which runs on every non-owner profile view with no explicit selection set.
CREATE INDEX IF NOT EXISTS earned_badges_badge_id_idx
    ON public.earned_badges (badge_id);

-- RLS ON, deliberately NO policies -- same shape as allowed_emails and usage_events
-- above: a table that must never be readable or writable directly by any client
-- role, only through the SECURITY DEFINER functions below.
ALTER TABLE public.earned_badges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.earned_badges FROM PUBLIC, anon, authenticated;

-- users.displayed_badges: the profile owner's chosen four badge ids, in their own
-- chosen order. NULL ("no choice made, fall back to the automatic default computed
-- in _resolve_effective_displayed_badges") and '{}' ("chose to show nothing") are
-- distinct, persisted states -- see set_displayed_badges below for how a caller moves
-- between all three. Readable through get_own_profile() (SELECT * FROM users) for
-- the caller's own row automatically; deliberately NOT added to public.profiles or to
-- any column-level grant on users for OTHER people's rows -- profile_badges /
-- own_effective_displayed_badges below are the only sanctioned way anyone else ever
-- learns what a selection resolves to.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS displayed_badges TEXT[];
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_displayed_badges_check;
ALTER TABLE public.users ADD CONSTRAINT users_displayed_badges_check
    CHECK (displayed_badges IS NULL OR COALESCE(array_length(displayed_badges, 1), 0) <= 4);

-- _ratchet_badges(p_user_id): the one and only place every predicate lives. Both
-- profile_badges and refresh_own_badges call this, then each does its own read
-- afterward -- see PART header above for why this must never be reproduced a second
-- time inline. INTERNAL ONLY: EXECUTE is revoked from PUBLIC, anon, AND authenticated,
-- since a SECURITY DEFINER function always retains implicit EXECUTE on another
-- function owned by the same role regardless of that REVOKE -- the REVOKE only ever
-- stops a different role from calling it directly.
CREATE OR REPLACE FUNCTION public._ratchet_badges(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- first_light: their first frame ever, full stop.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'first_light', MIN(p.taken_at)
    FROM public.photos p
    WHERE p.user_id = p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_roll: shot into the roll on both sides of its halfway point, on a
    -- roll that actually developed.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'full_roll', MIN(agg.earned_at)
    FROM (
        SELECT
            BOOL_OR(p.taken_at < r.created_at + INTERVAL '6 hours') AS shot_early,
            MIN(p.taken_at) FILTER (WHERE p.taken_at >= r.created_at + INTERVAL '6 hours') AS earned_at
        FROM public.rolls r
        JOIN public.photos p ON p.roll_id = r.id AND p.user_id = p_user_id
        WHERE public.is_roll_developed(r.id)
        GROUP BY r.id, r.created_at
    ) agg
    WHERE agg.shot_early AND agg.earned_at IS NOT NULL
    HAVING MIN(agg.earned_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- darkroom: had a perfect reveal-opening streak at some point, across
    -- every developed roll they were ever a member of. Frozen the instant
    -- this INSERT first lands -- a later skipped reveal no longer removes it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'darkroom', MAX(v.viewed_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    LEFT JOIN public.roll_reveal_views v
        ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
    WHERE rm.user_id = p_user_id
      AND public.is_roll_developed(r.id)
    HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(v.viewed_at)
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- founding_100: signup_ordinal <= 100. earned_at = the account's own
    -- created_at (the ordinal was decided at signup), never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT u.id, 'founding_100', u.created_at
    FROM public.users u
    WHERE u.id = p_user_id AND u.signup_ordinal <= 100
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- first_in: first to open a roll's reveal, on a roll with >= 2 MEMBERS
    -- (an empty race beats no one). Ranked with a deterministic tiebreak so
    -- this is stable forever once earned.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    )
    SELECT p_user_id, 'first_in', MIN(r.viewed_at)
    FROM ranked r
    JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
    WHERE r.user_id = p_user_id AND r.rn = 1
    HAVING MIN(r.viewed_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- roll_maker: created a roll that went on to hold at least one photo
    -- from anyone. The photo requirement keeps this from being farmable by
    -- creating and abandoning empty rolls.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'roll_maker', MIN(r.created_at)
    FROM public.rolls r
    WHERE r.created_by = p_user_id
      AND EXISTS (SELECT 1 FROM public.photos p WHERE p.roll_id = r.id)
    HAVING MIN(r.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- brought_someone: someone signed up using this user's invite code.
    -- Records only that it happened and when (u.created_at), never who.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'brought_someone', MIN(u.created_at)
    FROM public.allowed_emails ae
    JOIN public.users u ON lower(u.email) = ae.email
    WHERE ae.note = 'invited_by:' || p_user_id::text
    HAVING MIN(u.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- joined_in: joined a roll (roll_members) that somebody ELSE created.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'joined_in', MIN(rm.joined_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    WHERE rm.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(rm.joined_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chipped_in: shot at least one photo into a roll they did not create.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chipped_in', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.rolls r ON r.id = p.roll_id
    WHERE p.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- shared: posted a frame to the feed, full stop. earned_at is the
    -- honest global first posts.created_at; the covered-post gate is
    -- applied at READ time by profile_badges, not here.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'shared', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- well_met: somebody ELSE reacted to one of their photos. Excludes
    -- self-reactions. Deliberately photo_reactions (not post_reactions) --
    -- reactions can happen long before a photo is ever posted, so
    -- post_reactions would carry no reliable correlation to whether a post
    -- was covered.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'well_met', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE p.user_id = p_user_id
      AND pr.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_house: a roll reaches >= 5 DISTINCT CONTRIBUTORS, and this user
    -- is one of them. >= not =, and ranked by the 5th contributor's own
    -- first-shot time, so a later 6th contributor can never un-earn it --
    -- this exact shape is why two_up (an exact-count predicate) was cut.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH roll_contributors AS (
        SELECT p.roll_id, p.user_id AS contributor_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        WHERE p.roll_id IS NOT NULL
        GROUP BY p.roll_id, p.user_id
    ), ranked AS (
        SELECT roll_id, contributor_id, first_shot,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY first_shot ASC, contributor_id ASC) AS rn
        FROM roll_contributors
    ), roll_threshold AS (
        SELECT roll_id, first_shot AS threshold_at
        FROM ranked
        WHERE rn = 5
    )
    SELECT p_user_id, 'full_house', MIN(rt.threshold_at)
    FROM roll_threshold rt
    JOIN ranked me ON me.roll_id = rt.roll_id AND me.contributor_id = p_user_id
    HAVING MIN(rt.threshold_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- front_row: first to open the reveal, on FIVE separate qualifying rolls
    -- (first_in above is the same race, once).
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    ), my_wins AS (
        SELECT r.roll_id, r.viewed_at,
               ROW_NUMBER() OVER (ORDER BY r.viewed_at ASC, r.roll_id ASC) AS frn
        FROM ranked r
        JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
        WHERE r.user_id = p_user_id AND r.rn = 1
    )
    SELECT p_user_id, 'front_row', viewed_at
    FROM my_wins
    WHERE frn = 5
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- packed_house: identical to full_house above, rn = 10 not 5.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH roll_contributors AS (
        SELECT p.roll_id, p.user_id AS contributor_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        WHERE p.roll_id IS NOT NULL
        GROUP BY p.roll_id, p.user_id
    ), ranked AS (
        SELECT roll_id, contributor_id, first_shot,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY first_shot ASC, contributor_id ASC) AS rn
        FROM roll_contributors
    ), roll_threshold AS (
        SELECT roll_id, first_shot AS threshold_at
        FROM ranked
        WHERE rn = 10
    )
    SELECT p_user_id, 'packed_house', MIN(rt.threshold_at)
    FROM roll_threshold rt
    JOIN ranked me ON me.roll_id = rt.roll_id AND me.contributor_id = p_user_id
    HAVING MIN(rt.threshold_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- patron: identical lineage join to brought_someone above, rn = 5 over
    -- this caller's own invitees ordered by their own created_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH invitees AS (
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || p_user_id::text
    ), ranked AS (
        SELECT created_at,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, invitee_id ASC) AS rn
        FROM invitees
    )
    SELECT p_user_id, 'patron', created_at
    FROM ranked
    WHERE rn = 5
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- cover_to_cover: ten rolls shot into before they developed, counted
    -- cumulatively (not "every developed roll ever been a member of" --
    -- that version had a floor of one roll and was unearnable forever after
    -- a single miss). Ranked so a later eleventh roll can never displace
    -- the recorded earned_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH mine AS (
        SELECT p.roll_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        JOIN public.rolls r ON r.id = p.roll_id
        WHERE p.user_id = p_user_id
          AND public.is_roll_developed(r.id)
        GROUP BY p.roll_id
    ), ranked AS (
        SELECT first_shot,
               ROW_NUMBER() OVER (ORDER BY first_shot ASC, roll_id ASC) AS rn
        FROM mine
    )
    SELECT p_user_id, 'cover_to_cover', first_shot
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- kept_one: let TEN developed photos go unshared. develops_at <= now(),
    -- not is_developed (a cron-maintained cache that can lag the real
    -- deadline). No covered-post gate needed: a kept photo was never posted,
    -- so it can never be a covered post.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH kept AS (
        SELECT p.taken_at, p.id,
               ROW_NUMBER() OVER (ORDER BY p.taken_at ASC, p.id ASC) AS rn
        FROM public.photos p
        WHERE p.user_id = p_user_id
          AND p.develops_at <= now()
          AND NOT EXISTS (SELECT 1 FROM public.posts po WHERE po.photo_id = p.id)
    )
    SELECT p_user_id, 'kept_one', taken_at
    FROM kept
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- regular: seven distinct app_open days (public.usage_events, above).
    -- Not retroactive before usage_events began collecting app_open.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH days AS (
        SELECT DISTINCT day
        FROM public.usage_events
        WHERE user_id = p_user_id AND event = 'app_open'
    ), ranked AS (
        SELECT day, ROW_NUMBER() OVER (ORDER BY day ASC) AS rn
        FROM days
    )
    SELECT p_user_id, 'regular', day::timestamptz
    FROM ranked
    WHERE rn = 7
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- one_year: a year old, AND still shooting -- needs a frame taken ON OR
    -- AFTER the first anniversary, not pure tenure (which would have made
    -- this the only badge in the catalog reachable by doing nothing at all).
    -- Monotonic and never blocked: miss the anniversary week and any later
    -- frame still earns it. earned_at is that qualifying frame, never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'one_year', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.users u ON u.id = p.user_id
    WHERE p.user_id = p_user_id
      AND p.taken_at >= u.created_at + INTERVAL '1 year'
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- open_door: same lineage join as patron/brought_someone, rn = 10.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH invitees AS (
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || p_user_id::text
    ), ranked AS (
        SELECT created_at,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, invitee_id ASC) AS rn
        FROM invitees
    )
    SELECT p_user_id, 'open_door', created_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chimed_in: reacted to SOMEBODY ELSE'S photo -- the mirror of well_met.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chimed_in', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE pr.user_id = p_user_id
      AND p.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- in_frame: somebody tagged you in a photo. Nothing you can do to cause
    -- it, by design -- it marks being part of someone else's roll.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'in_frame', MIN(pt.created_at)
    FROM public.post_tags pt
    WHERE pt.tagged_user_id = p_user_id
    HAVING MIN(pt.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- spotter: you tagged someone else in one of your own posts. Self-tags
    -- excluded, or this would fire for anyone who tapped their own face once.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'spotter', MIN(pt.created_at)
    FROM public.post_tags pt
    JOIN public.posts po ON po.id = pt.post_id
    WHERE po.user_id = p_user_id
      AND pt.tagged_user_id <> p_user_id
    HAVING MIN(pt.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- said_it: wrote a caption. Reads posts.caption, NOT photos.caption -- a
    -- caption is typed when a frame is posted, so photos.caption is unused.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'said_it', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
      AND po.caption IS NOT NULL
      AND btrim(po.caption) <> ''
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- ten_frames: the tenth frame ever shot, ranked so a later eleventh can
    -- never move the recorded earned_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT p.taken_at,
               ROW_NUMBER() OVER (ORDER BY p.taken_at ASC, p.id ASC) AS rn
        FROM public.photos p
        WHERE p.user_id = p_user_id
    )
    SELECT p_user_id, 'ten_frames', taken_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- good_company: TEN people follow you. Ranked by the tenth follow so an
    -- eleventh can never move it. (Started as "somebody followed you", which
    -- every account held on arrival via the auto-follow-the-owner backfill;
    -- ten is where the holder curve actually flattens.)
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked_follows AS (
        SELECT f.created_at,
               ROW_NUMBER() OVER (ORDER BY f.created_at ASC, f.follower_id ASC) AS rn
        FROM public.follows f
        WHERE f.following_id = p_user_id
    )
    SELECT p_user_id, 'good_company', created_at
    FROM ranked_follows
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_set: TWENTY other badge ids, LAST -- the only predicate that reads
    -- the ledger it writes to, so it must run after every predicate above in
    -- this same pass. WHERE badge_id <> 'full_set' is the explicit
    -- cannot-count-itself guarantee. Twenty (not the original ten) is 80% of
    -- the twenty-five a normal account can actually obtain (founder/
    -- founding_crew are hand-granted, founding_100's window is shut).
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT eb.earned_at,
               ROW_NUMBER() OVER (ORDER BY eb.earned_at ASC, eb.badge_id ASC) AS rn
        FROM public.earned_badges eb
        WHERE eb.user_id = p_user_id AND eb.badge_id <> 'full_set'
    )
    SELECT p_user_id, 'full_set', earned_at
    FROM ranked
    WHERE rn = 20
    ON CONFLICT (user_id, badge_id) DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM anon;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM authenticated;

-- _resolve_effective_displayed_badges(p_profile_id, p_viewer): the shared
-- non-owner resolution -- "stored selection, else the automatic default, gated on
-- covered-shared" lives in exactly this one place, called by profile_badges'
-- non-owner branch (with p_viewer = the real caller) and by
-- own_effective_displayed_badges (with p_viewer = NULL, standing in for "a
-- stranger" -- see that function's own comment for why NULL, specifically, is what
-- makes that true). INTERNAL ONLY, same REVOKE posture as _ratchet_badges: p_viewer
-- is a trusted argument only because both callers pin it themselves.
--
-- slot_rank pins founder, then founding_crew, then founding_100 (whichever the
-- profile holds) ahead of the ordinary rarity sort in the automatic default -- the
-- two hand-granted badges exist because someone decided this account mattered, which
-- says more about the specific profile than founding_100 does once most accounts
-- hold it. When none of the three is held, every row gets the same slot_rank and the
-- ORDER BY reduces to the plain rarity sort, so this is a superset of the original
-- behaviour, not a divergent rewrite.
CREATE OR REPLACE FUNCTION public._resolve_effective_displayed_badges(p_profile_id UUID, p_viewer UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_selection TEXT[];
BEGIN
    SELECT u.displayed_badges INTO v_selection
    FROM public.users u
    WHERE u.id = p_profile_id;

    IF v_selection IS NULL THEN
        RETURN QUERY
        SELECT c.badge_id, c.earned_at
        FROM (
            SELECT eb.badge_id, eb.earned_at,
                   CASE eb.badge_id
                       WHEN 'founder'       THEN 0
                       WHEN 'founding_crew' THEN 1
                       WHEN 'founding_100'  THEN 2
                       ELSE 3
                   END AS slot_rank,
                   rarity.holder_count
            FROM public.earned_badges eb
            JOIN (
                SELECT eb2.badge_id, COUNT(DISTINCT eb2.user_id) AS holder_count
                FROM public.earned_badges eb2
                GROUP BY eb2.badge_id
            ) rarity ON rarity.badge_id = eb.badge_id
            WHERE eb.user_id = p_profile_id
              AND (
                  eb.badge_id <> 'shared'
                  OR public.covered_post_visible(p_viewer, p_profile_id, eb.earned_at)
              )
        ) c
        ORDER BY c.slot_rank ASC, c.holder_count ASC, c.earned_at ASC, c.badge_id ASC
        LIMIT 4;
        RETURN;
    END IF;

    -- Explicit selection, possibly '{}' (show none). Never reordered.
    RETURN QUERY
    SELECT eb.badge_id, eb.earned_at
    FROM unnest(v_selection) WITH ORDINALITY AS sel(badge_id, ord)
    JOIN public.earned_badges eb
        ON eb.user_id = p_profile_id AND eb.badge_id = sel.badge_id
    WHERE eb.badge_id <> 'shared'
       OR public.covered_post_visible(p_viewer, p_profile_id, eb.earned_at)
    ORDER BY sel.ord ASC;
END;
$$;
REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM authenticated;

-- profile_badges(p_profile_id): the earned-badge list, callable about ANY profile by
-- any authenticated caller (see the "Badges" header above for why). The profile's
-- own owner sees every earned badge unfiltered (still covered-post gated on
-- 'shared', which is always a no-op for a self-view -- covered_post_visible is TRUE
-- whenever the viewer equals the covered account itself). Anyone else gets
-- _resolve_effective_displayed_badges' resolved four.
CREATE OR REPLACE FUNCTION public.profile_badges(p_profile_id UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM public._ratchet_badges(p_profile_id);

    IF p_profile_id = auth.uid() THEN
        RETURN QUERY
        SELECT eb.badge_id, eb.earned_at
        FROM public.earned_badges eb
        WHERE eb.user_id = p_profile_id
          AND (
              eb.badge_id <> 'shared'
              OR public.covered_post_visible(auth.uid(), p_profile_id, eb.earned_at)
          )
        ORDER BY eb.earned_at ASC;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT r.badge_id, r.earned_at
    FROM public._resolve_effective_displayed_badges(p_profile_id, auth.uid()) r;
END;
$$;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_badges(UUID) TO authenticated;

-- profile_film_stats(p_profile_id): frames shot / rolls developed / shooting since,
-- replacing follower/following counts on the profile by design -- those can only
-- ever look like failure on a new account; these three numbers only ever go up.
-- Same SECURITY DEFINER / callable-about-anyone posture as profile_badges.
-- shooting_since is NULL for an account with zero photos; the client should simply
-- not render the line rather than treating NULL as an error.
CREATE OR REPLACE FUNCTION public.profile_film_stats(p_profile_id UUID)
RETURNS TABLE (
    frames_shot     BIGINT,
    rolls_developed BIGINT,
    shooting_since  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        COUNT(*)::BIGINT AS frames_shot,
        COUNT(DISTINCT p.roll_id) FILTER (
            WHERE p.roll_id IS NOT NULL AND public.is_roll_developed(p.roll_id)
        )::BIGINT AS rolls_developed,
        MIN(p.taken_at) AS shooting_since
    FROM public.photos p
    WHERE p.user_id = p_profile_id;
$$;
REVOKE ALL ON FUNCTION public.profile_film_stats(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_film_stats(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_film_stats(UUID) TO authenticated;

-- ============================================================
-- Chapters: profile_chapters() + chapter_photos(), folded from
-- supabase/migrations/2026-09-03_chapters.sql and rewritten posted-only by
-- supabase/migrations/2026-09-04_chapters_posted_only.sql. The profile's
-- monthly recap -- a shelf of month covers on the profile (design 3a) and
-- a per-month reveal-style playback (design 3b). See the 2026-09-04
-- migration for the full rationale (the self-case proof in particular);
-- summarized here so a fresh run needs no other file.
--
-- MONTHS ARE COMPUTED, NOT STORED: no backfill table, no data migration --
-- a month exists purely because posts rows fall in it, LIVE AND GROWING
-- (the current month included), all the way back to a person's first
-- post.
--
-- VISIBILITY (OWNER DECISION 2026-09-04, one rule for every viewer,
-- including the profile's own owner): a chapter is what you shared. Only
-- POSTED photos count -- unposted developed photos and private roll shots
-- are excluded even from the shooter's own page now -- gated by the exact
-- predicate "posts: readable by authenticated" already enforces (not
-- hidden, not blocked either way, not covered), confirmed live via
-- FeedService.fetchUserPosts (the profile grid's own query), reusing the
-- same covered_post_visible/is_blocked_either_way helpers that policy
-- calls rather than re-deriving the rule. shot_count means posted shots;
-- roll_count means distinct rolls among those posted shots. The viewer
-- looking at their own page needs no special-casing: covered_post_visible
-- resolves to TRUE for viewer = author regardless of is_owner (the
-- covered_post_windows row that makes post_is_covered true for the author
-- is the SAME row the third disjunct's EXISTS checks for viewer = author),
-- and is_blocked_either_way(x, x) is always FALSE because public.blocks
-- carries CHECK (blocker_id <> blocked_id).
--
-- MONTH BOUNDARY: taken_at shifted back 4 hours (FeedUnit.dayBoundaryHour)
-- before truncating to month, same shift darkroom_month_summary applies,
-- fixed at UTC rather than a client-supplied zone -- FLIM stores no
-- per-user timezone column by design (see usage_events above), and this
-- function's signature is the agreed Swift contract with no zone
-- parameter. Accepted deviation: a shot within a few hours of local
-- midnight near a month boundary can land in a different month here than
-- in the Darkroom's own, locally-zoned month view for a user far from UTC.
--
-- COVERS: up to 4, most recent first (NOT the Darkroom's oldest-first
-- filmstrip -- the Chapters contract calls for a preview of the month's
-- latest activity), COALESCE(thumb_path, storage_path) for the same
-- pre-thumb-column fallback every other cover path in this schema uses.
--
-- SECURITY DEFINER on both: required to read public.photos for roll_id
-- (posts does not denormalize it), for a viewer who is not that photo's
-- owner or roll member -- public.photos' own RLS would otherwise hide it.
-- There is no own-page branch anymore, so there is nothing for the
-- elevated rights to leak: every row returned already passed the exact
-- posts-visibility predicate RLS enforces for every caller. chapter_photos
-- is capped at 1000 rows (PostgREST caps a SETOF result anyway; this makes
-- it explicit).
-- ============================================================

CREATE OR REPLACE FUNCTION public.profile_chapters(p_profile_id UUID)
RETURNS TABLE (
    month_start   DATE,
    shot_count    INTEGER,
    roll_count    INTEGER,
    cover_paths   TEXT[],
    first_shot_at TIMESTAMPTZ,
    last_shot_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Posted photos only, one rule for every viewer including the
        -- profile's own owner -- see the header above for why the self
        -- case needs no special handling. Joined to photos only for
        -- roll_id, which posts does not denormalize; the join is safe
        -- because the row is only reachable once the post itself has
        -- passed the visibility gate below.
        SELECT p.id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    ),
    bucketed AS (
        SELECT
            date_trunc('month', (taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS bucket_month,
            taken_at, roll_id, display_path
        FROM source
    ),
    ranked_covers AS (
        SELECT bucket_month, display_path,
               row_number() OVER (PARTITION BY bucket_month ORDER BY taken_at DESC) AS rn
        FROM bucketed
    )
    SELECT
        b.bucket_month,
        count(*)::integer,
        count(DISTINCT b.roll_id) FILTER (WHERE b.roll_id IS NOT NULL)::integer,
        COALESCE(
            (SELECT array_agg(rc.display_path ORDER BY rc.rn)
             FROM ranked_covers rc
             WHERE rc.bucket_month = b.bucket_month AND rc.rn <= 4),
            ARRAY[]::text[]
        ),
        min(b.taken_at),
        max(b.taken_at)
    FROM bucketed b
    GROUP BY b.bucket_month
    ORDER BY b.bucket_month DESC;
$$;

REVOKE ALL ON FUNCTION public.profile_chapters(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_chapters(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_chapters(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.chapter_photos(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    id           UUID,
    taken_at     TIMESTAMPTZ,
    thumb_path   TEXT,
    feed_path    TEXT,
    storage_path TEXT,
    roll_id      UUID,
    roll_name    TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Same posted-only rule as profile_chapters above.
        SELECT p.id, po.taken_at, po.thumb_path, po.feed_path, po.storage_path, p.roll_id
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    )
    SELECT s.id, s.taken_at, s.thumb_path, s.feed_path, s.storage_path, s.roll_id, r.name
    FROM source s
    LEFT JOIN public.rolls r ON r.id = s.roll_id
    WHERE date_trunc('month', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ORDER BY s.taken_at ASC
    LIMIT 1000;
$$;

REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_photos(UUID, DATE) TO authenticated;

-- New hot-path index: both functions above filter posts by user_id and
-- bucket/order by taken_at. posts_user_created_idx (above) covers user_id +
-- created_at, a different column, so this is a genuinely new index.
CREATE INDEX IF NOT EXISTS posts_user_taken_idx ON public.posts (user_id, taken_at DESC);

-- ============================================================
-- chapter_stats(): the "month in numbers" superset, folded from
-- supabase/migrations/2026-09-04_chapter_stats.sql. See that file's header
-- for the full visibility/omission/timezone contract; the block below is
-- the current shape verbatim.
--
-- VISIBILITY OF THE UNDERLYING PHOTOS: computed ONLY over the exact same
-- posted photos chapter_photos(p_profile_id, p_month_start) would return
-- to THIS caller for THIS month -- the "source" CTE below is a
-- byte-for-byte copy of chapter_photos' own source CTE, narrowed to the
-- one month. A stat can never reference a photo the caller could not
-- already see in that profile's grid or Chapters playback.
--
-- REACTIONS/COMMENTS SOURCE: chapter_photos deals only in POSTED photos,
-- each with exactly one row in public.posts. The feed's own reaction/
-- comment batching (FeedService.batchReactions / batchComments) counts a
-- shared post via public.post_reactions / public.post_comments keyed on
-- post_id -- NOT public.photo_reactions / public.photo_comments, which
-- back the separate roll-photo-thread UI and are never joined into a feed
-- card's own counts. This function counts post_reactions / post_comments
-- for the same reason: a chapter stat about "reactions received" must
-- match what the feed itself would have shown on that same shared post.
--
-- NIGHT_SHOTS TIMEZONE ASSUMPTION: "22:00-04:00" is evaluated in
-- America/New_York, FLIM's current user base, not a per-user zone (FLIM
-- has none). Documented known gap, not an oversight.
--
-- OMISSION RULE: a stat row is omitted entirely, never returned as a
-- zero, whenever there is nothing to say for it that month.
-- shots/first_shot/last_shot/streak_days are the only rows guaranteed
-- present whenever the month has any posted shots at all.
--
-- VISIBILITY PICK: users.chapter_public_stats is the profile owner's own
-- allow-list of which stat_key values everyone ELSE may see on their
-- card. The EMPTY array (the default) means "everything public", so this
-- migration changes nothing for anyone who has never opened the picker.
-- The profile owner always sees every row regardless of their own pick.
-- The column itself (and its CHECK, and its authenticated column-level
-- SELECT grant) live earlier in this file, next to
-- hidden_from_discovery/signup_ordinal -- see that block's own comment
-- for why the load-ordering matters.
-- ============================================================

CREATE OR REPLACE FUNCTION public.chapter_stats(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    stat_key         TEXT,
    value_int        INTEGER,
    value_text       TEXT,
    photo_id         UUID,
    photo_thumb_path TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Byte-for-byte the same predicate as chapter_photos' own source CTE,
        -- narrowed to the one month up front so every CTE below it is already
        -- scoped correctly.
        SELECT po.id AS post_id, p.id AS photo_id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
          AND date_trunc('month', (po.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ),
    reaction_counts AS (
        SELECT s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY s.photo_id, s.display_path, s.taken_at
    ),
    comment_counts AS (
        SELECT s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_comments pc ON pc.post_id = s.post_id
        GROUP BY s.photo_id, s.display_path, s.taken_at
    ),
    reaction_emoji AS (
        SELECT pr.emoji, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY pr.emoji
    ),
    day_bucketed AS (
        SELECT date_trunc('day', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS shot_day
        FROM source s
    ),
    day_counts AS (
        SELECT shot_day, count(*) AS cnt FROM day_bucketed GROUP BY shot_day
    ),
    streaks AS (
        -- Classic gaps-and-islands: within a sequence of distinct days, a run of
        -- CONSECUTIVE days shares the same (day - row_number()) value.
        SELECT shot_day, shot_day - (row_number() OVER (ORDER BY shot_day))::int AS grp
        FROM (SELECT DISTINCT shot_day FROM day_bucketed) d
    ),
    streak_lengths AS (
        SELECT grp, count(*) AS len FROM streaks GROUP BY grp
    ),
    roll_ids AS (
        SELECT DISTINCT roll_id FROM source WHERE roll_id IS NOT NULL
    ),
    stats (stat_key, value_int, value_text, photo_id, photo_thumb_path) AS (
        (SELECT 'shots'::text, count(*)::int, NULL::text, NULL::uuid, NULL::text
         FROM source
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'reactions_received', count(*)::int, NULL, NULL, NULL
         FROM source s JOIN public.post_reactions pr ON pr.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'comments_received', count(*)::int, NULL, NULL, NULL
         FROM source s JOIN public.post_comments pc ON pc.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'most_reacted', rc.cnt::int, NULL, rc.photo_id, rc.display_path
         FROM reaction_counts rc
         ORDER BY rc.cnt DESC, rc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'most_commented', cc.cnt::int, NULL, cc.photo_id, cc.display_path
         FROM comment_counts cc
         ORDER BY cc.cnt DESC, cc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_reaction', re.cnt::int, re.emoji, NULL, NULL
         FROM reaction_emoji re
         ORDER BY re.cnt DESC, re.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'busiest_day', dc.cnt::int, to_char(dc.shot_day, 'YYYY-MM-DD'), NULL, NULL
         FROM day_counts dc
         ORDER BY dc.cnt DESC, dc.shot_day DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'night_shots', count(*)::int, NULL, NULL, NULL
         FROM source s
         WHERE EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) >= 22
            OR EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) < 4
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'streak_days', max(len)::int, NULL, NULL, NULL
         FROM streak_lengths)

        UNION ALL
        (SELECT 'rolls_count', count(*)::int, NULL, NULL, NULL
         FROM roll_ids
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'people_shot_with', count(DISTINCT rm.user_id)::int, NULL, NULL, NULL
         FROM public.roll_members rm
         WHERE rm.roll_id IN (SELECT roll_id FROM roll_ids)
           AND rm.user_id <> p_profile_id
         HAVING count(DISTINCT rm.user_id) > 0)

        UNION ALL
        (SELECT 'first_shot', NULL, NULL, s.photo_id, s.display_path
         FROM source s
         ORDER BY s.taken_at ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'last_shot', NULL, NULL, s.photo_id, s.display_path
         FROM source s
         ORDER BY s.taken_at DESC
         LIMIT 1)
    ),
    owner_pick AS (
        SELECT chapter_public_stats FROM public.users WHERE id = p_profile_id
    )
    SELECT st.stat_key, st.value_int, st.value_text, st.photo_id, st.photo_thumb_path
    FROM stats st
    WHERE auth.uid() = p_profile_id
       OR EXISTS (
            SELECT 1 FROM owner_pick op
            WHERE COALESCE(array_length(op.chapter_public_stats, 1), 0) = 0
               OR st.stat_key = ANY(op.chapter_public_stats)
          );
$$;

REVOKE ALL ON FUNCTION public.chapter_stats(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_stats(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_stats(UUID, DATE) TO authenticated;

-- set_chapter_public_stats(p_keys): the only write path for a user's own
-- chapter_public_stats pick. Pattern after set_displayed_badges below:
-- zero-trust on input, pinned to auth.uid() (no p_user_id argument, nothing to
-- spoof), NULL treated the same as '{}' (both mean "show everything" per the
-- empty-array convention above), every element validated against the exact
-- same fixed key list the table CHECK constraint enforces, idempotent, and the
-- saved array is returned so the caller can confirm what stuck without a
-- second round trip.
CREATE OR REPLACE FUNCTION public.set_chapter_public_stats(p_keys TEXT[])
RETURNS TEXT[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keys TEXT[] := COALESCE(p_keys, ARRAY[]::text[]);
BEGIN
    IF array_position(v_keys, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'chapter_public_stats: key cannot be null';
    END IF;

    IF NOT (v_keys <@ ARRAY[
        'most_reacted', 'most_commented', 'reactions_received', 'comments_received',
        'top_reaction', 'busiest_day', 'night_shots', 'streak_days', 'rolls_count',
        'people_shot_with', 'first_shot', 'last_shot', 'shots'
    ]::text[]) THEN
        RAISE EXCEPTION 'chapter_public_stats: unknown stat key';
    END IF;

    UPDATE public.users SET chapter_public_stats = v_keys WHERE id = auth.uid();

    RETURN v_keys;
END;
$$;
REVOKE ALL ON FUNCTION public.set_chapter_public_stats(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_chapter_public_stats(TEXT[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_chapter_public_stats(TEXT[]) TO authenticated;

-- set_displayed_badges(p_badge_ids): the only write path for a user's own
-- displayed_badges selection. Zero-trust on input: pinned to auth.uid() (no
-- p_user_id argument exists, so nothing to spoof), NULL clears back to the
-- automatic default, '{}' is accepted and stored as "show none", at most 4 ids, no
-- NULL element, no duplicates, and every id must already be held in earned_badges --
-- validated against the ledger directly rather than any badge catalog, so this stays
-- correct with no edit needed whenever the catalog above grows. The caller's own
-- given order is preserved exactly as provided.
CREATE OR REPLACE FUNCTION public.set_displayed_badges(p_badge_ids TEXT[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_len   INT;
    v_distinct_count INT;
    v_held_count     INT;
BEGIN
    IF p_badge_ids IS NULL THEN
        UPDATE public.users SET displayed_badges = NULL WHERE id = auth.uid();
        RETURN;
    END IF;

    IF array_position(p_badge_ids, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'displayed_badges: badge id cannot be null';
    END IF;

    v_len := COALESCE(array_length(p_badge_ids, 1), 0);

    IF v_len > 4 THEN
        RAISE EXCEPTION 'displayed_badges: at most 4 badges, got %', v_len;
    END IF;

    SELECT COUNT(DISTINCT x) INTO v_distinct_count FROM unnest(p_badge_ids) AS x;
    IF v_distinct_count <> v_len THEN
        RAISE EXCEPTION 'displayed_badges: duplicate badge id';
    END IF;

    SELECT COUNT(*) INTO v_held_count
    FROM public.earned_badges eb
    WHERE eb.user_id = auth.uid() AND eb.badge_id = ANY(p_badge_ids);
    IF v_held_count <> v_len THEN
        RAISE EXCEPTION 'displayed_badges: caller has not earned every selected badge';
    END IF;

    UPDATE public.users SET displayed_badges = p_badge_ids WHERE id = auth.uid();
END;
$$;
REVOKE ALL ON FUNCTION public.set_displayed_badges(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_displayed_badges(TEXT[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_displayed_badges(TEXT[]) TO authenticated;

-- own_effective_displayed_badges(): the caller's own resolved "what a stranger sees
-- on my profile right now" list, in display order, own profile only, no argument.
-- Zero arguments, hard-pinned to auth.uid() -- same non-negotiable rule every other
-- "own state" function in this file follows. Calls the shared resolver with
-- p_viewer = NULL (a stranger, never the caller themselves -- see
-- _resolve_effective_displayed_badges' own header) so a profile owner can answer
-- "which four actually show" without the resolver's covered-post gate reading as
-- "can I see my own badge," which is always yes. Does NOT ratchet -- profile_badges
-- and refresh_own_badges already own recording.
CREATE OR REPLACE FUNCTION public.own_effective_displayed_badges()
RETURNS TABLE (badge_id TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT r.badge_id
    FROM public._resolve_effective_displayed_badges(auth.uid(), NULL::uuid) WITH ORDINALITY
        AS r(badge_id, earned_at, ord)
    ORDER BY r.ord ASC;
END;
$$;
REVOKE ALL ON FUNCTION public.own_effective_displayed_badges() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.own_effective_displayed_badges() FROM anon;
GRANT EXECUTE ON FUNCTION public.own_effective_displayed_badges() TO authenticated;

-- refresh_own_badges(): ratchets the CALLER's own predicates (profile_badges only
-- ever ratchets the profile being VIEWED, so nothing ever recorded a badge for the
-- person who earned it unless somebody else happened to open their profile first).
-- Zero arguments, hard-pinned to auth.uid(). Returns the caller's own unseen count
-- in the same round trip. Call this right after finishing a reveal, posting to the
-- feed, or on an app-foreground check -- anywhere the client wants to make sure
-- anything just-earned actually gets recorded, not just displayed.
CREATE OR REPLACE FUNCTION public.refresh_own_badges()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM public._ratchet_badges(auth.uid());

    RETURN (
        SELECT COUNT(*)::BIGINT
        FROM public.earned_badges
        WHERE user_id = auth.uid() AND seen_at IS NULL
    );
END;
$$;
REVOKE ALL ON FUNCTION public.refresh_own_badges() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_own_badges() FROM anon;
GRANT EXECUTE ON FUNCTION public.refresh_own_badges() TO authenticated;

-- mark_own_badges_seen() / unseen_badge_count() / own_unseen_badges(): all three
-- take NO p_profile_id argument, on purpose, and resolve everything from
-- auth.uid() -- profile_badges can write to ANY profile's earned_badges as a side
-- effect of being viewed, so if any of these three trusted a caller-supplied
-- profile id instead, a caller could mark ANOTHER user's badge seen before that
-- user ever saw it, or read another user's unseen state outright.
CREATE OR REPLACE FUNCTION public.mark_own_badges_seen()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.earned_badges
    SET seen_at = now()
    WHERE user_id = auth.uid() AND seen_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION public.unseen_badge_count()
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COUNT(*)::BIGINT
    FROM public.earned_badges
    WHERE user_id = auth.uid() AND seen_at IS NULL;
$$;

-- badge_id ONLY -- no earned_at, no seen_at -- because the one thing this answers
-- is "which ids animate" at render time. Do not use earned_at ordering as a proxy
-- for "which are new": it is the date the thing HAPPENED, not when the ratchet
-- recorded it, so a badge inserted today can carry an old earned_at.
CREATE OR REPLACE FUNCTION public.own_unseen_badges()
RETURNS TABLE (badge_id TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT eb.badge_id
    FROM public.earned_badges eb
    WHERE eb.user_id = auth.uid() AND eb.seen_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.mark_own_badges_seen() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_own_badges_seen() FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_own_badges_seen() TO authenticated;

REVOKE ALL ON FUNCTION public.unseen_badge_count() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unseen_badge_count() FROM anon;
GRANT EXECUTE ON FUNCTION public.unseen_badge_count() TO authenticated;

REVOKE ALL ON FUNCTION public.own_unseen_badges() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.own_unseen_badges() FROM anon;
GRANT EXECUTE ON FUNCTION public.own_unseen_badges() TO authenticated;

-- grant_badge / revoke_badge: owner-only hand-grant and its undo, for the two
-- badges with no predicate at all (founder, founding_crew). Same owner gate as
-- every other admin RPC in this schema: `IF NOT is_owner() THEN RAISE EXCEPTION`,
-- not a REVOKE, so a non-owner's call fails with a clean error rather than a
-- permission-denied at the transport layer. The grantable allow-list is checked
-- here AND enforced independently by earned_badges_grantable_check on the table
-- itself (the real backstop). revoke_badge is scoped to granted_by IS NOT NULL, so
-- it can only ever undo a hand-grant, never strip a predicate-earned badge -- the
-- "a badge, once earned, is never removed" guarantee holds even with an admin undo
-- tool in place. test_roll (retired into founding_crew) is no longer grantable.
CREATE OR REPLACE FUNCTION public.grant_badge(p_user_id UUID, p_badge_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    IF p_badge_id NOT IN ('founding_crew', 'founder') THEN
        RAISE EXCEPTION 'badge % is not grantable', p_badge_id;
    END IF;

    INSERT INTO public.earned_badges (user_id, badge_id, earned_at, granted_by)
    VALUES (p_user_id, p_badge_id, now(), auth.uid())
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_badge(p_user_id UUID, p_badge_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    DELETE FROM public.earned_badges
    WHERE user_id = p_user_id
      AND badge_id = p_badge_id
      AND granted_by IS NOT NULL;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_badge(UUID, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.revoke_badge(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_badge(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.revoke_badge(UUID, TEXT) TO authenticated;

-- ============================================================
-- Remote push: device token storage. Needed only for REMOTE push (a roll-mate's
-- photo developing on their device); local notifications cover "your own photo
-- developed" with no backend. Applied separately as supabase/push/device_tokens.sql,
-- with the token-as-primary-key fix from supabase/migrations/2026-08-06_device_token_one_per_device.sql
-- folded in directly since this file reflects the current shape, not the history.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.device_tokens (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    token      TEXT PRIMARY KEY,                    -- APNs device token (hex)
    platform   TEXT NOT NULL DEFAULT 'ios',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- A user can only see / write their own device tokens.
DROP POLICY IF EXISTS "device_tokens: own tokens" ON public.device_tokens;
CREATE POLICY "device_tokens: own tokens"
    ON public.device_tokens FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Helpful index for the Edge Function fan-out (look up tokens by user). Not implied
-- by the primary key, which is the token.
CREATE INDEX IF NOT EXISTS device_tokens_user_idx ON public.device_tokens (user_id);

-- Registration has to be able to move a device from one account to another, and
-- plain RLS cannot: an upsert becomes ON CONFLICT (token) DO UPDATE, whose USING
-- clause is checked against the row that still belongs to the previous account, so
-- the reassignment is silently filtered out. This function is the only way in.
-- It writes auth.uid() and nothing else, so a caller can only ever claim a device
-- for themselves.
CREATE OR REPLACE FUNCTION public.register_device_token(
    p_token    TEXT,
    p_platform TEXT DEFAULT 'ios'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'register_device_token: not authenticated';
    END IF;

    IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
        RAISE EXCEPTION 'register_device_token: token required';
    END IF;

    DELETE FROM public.device_tokens
    WHERE token = p_token
      AND user_id <> auth.uid();

    INSERT INTO public.device_tokens (user_id, token, platform, updated_at)
    VALUES (auth.uid(), p_token, COALESCE(p_platform, 'ios'), NOW())
    ON CONFLICT (token) DO UPDATE
        SET user_id    = auth.uid(),
            platform   = EXCLUDED.platform,
            updated_at = NOW();
END;
$$;

-- anon is revoked explicitly: Supabase's stock default privileges grant EXECUTE on
-- every new function to anon, and revoking PUBLIC leaves that grant in place.
REVOKE ALL ON FUNCTION public.register_device_token(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_device_token(TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.register_device_token(TEXT, TEXT) TO authenticated;

-- Track which developed photos / comments have already triggered a remote push so the
-- scheduled Edge Functions don't notify the same row twice. (post_reactions.push_sent,
-- follows.push_sent and photo_reactions.push_sent are already added above, closer to
-- their own tables; these three were missing from this file even though production has
-- carried them since the push feature shipped.)
ALTER TABLE public.photos         ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.post_comments  ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.photo_comments ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS post_comments_unpushed_idx  ON public.post_comments (push_sent) WHERE push_sent = FALSE;
CREATE INDEX IF NOT EXISTS photo_comments_unpushed_idx ON public.photo_comments (push_sent) WHERE push_sent = FALSE;

-- ============================================================
-- Invite requests from the website (request_invite RPC). The landing page asks a
-- stranger for their email and a line about who they'd put on a roll. They have no
-- session, so this follows the same shape as redeem_invite: an anon-callable
-- SECURITY DEFINER function in front of tables no client role can touch directly.
-- This does NOT allowlist anyone, it only records the ask. Applied separately as
-- supabase/migrations/2026-08-07_invite_requests.sql.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.invite_requests (
    email      TEXT PRIMARY KEY,
    note       TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    handled    BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS public.invite_request_rate (
    id           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
INSERT INTO public.invite_request_rate (id) VALUES (TRUE) ON CONFLICT DO NOTHING;

ALTER TABLE public.invite_requests     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_request_rate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invite_requests     FROM anon, authenticated;
REVOKE ALL ON public.invite_request_rate FROM anon, authenticated;

-- Always returns TRUE for a well-formed address, whether the row was new, already
-- there, or dropped by the rate gate. A caller therefore cannot use this to test
-- whether an address has already asked. The only FALSE is a malformed address.
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

    INSERT INTO public.invite_requests (email, note)
    VALUES (v_email, v_note)
    ON CONFLICT (email) DO UPDATE
        SET note = COALESCE(EXCLUDED.note, public.invite_requests.note);

    RETURN TRUE;
END;
$$;

-- anon is the point here: the caller is a stranger on the website with no session.
-- authenticated is included so an existing user passing the link on doesn't error.
REVOKE ALL ON FUNCTION public.request_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_invite(TEXT, TEXT) TO anon, authenticated;

-- ============================================================
-- SQL layer for the flim-app.com/admin dashboard: invite queue. The dashboard is a
-- static page calling Supabase from the browser with the publishable key and the
-- owner's own logged-in session, so grants alone can't be the gate — is_owner()
-- inside each body is. Every mutation raises, every list function quietly returns
-- nothing, for any non-owner caller. Applied separately as
-- supabase/migrations/2026-08-07_admin_dashboard.sql (this is the final, gated
-- shape of approve_invite_request; it superseded the ungated version originally
-- shipped in supabase/migrations/2026-08-07_approve_invite_request.sql).
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_invite_requests()
RETURNS TABLE (
    email      TEXT,
    note       TEXT,
    created_at TIMESTAMPTZ
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
    SELECT ir.email, ir.note, ir.created_at
    FROM public.invite_requests ir
    WHERE NOT ir.handled
    ORDER BY ir.created_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;

    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invite request')
    ON CONFLICT (email) DO NOTHING;

    UPDATE public.invite_requests SET handled = TRUE WHERE email = v_email;

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.decline_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    IF NOT public.is_owner() THEN
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

REVOKE ALL ON FUNCTION public.list_invite_requests() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_invite_requests() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_invite_requests() TO authenticated;

REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_invite_request(TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.decline_invite_request(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decline_invite_request(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.decline_invite_request(TEXT) TO authenticated;

-- ============================================================
-- SQL layer for the flim-app.com/admin dashboard: report queue. Same is_owner()
-- gate as the invite queue above. Neither report table tracked whether a report
-- had been looked at before this; push_sent (added near the block-enforcement
-- section above) tracks whether send-social-push already notified the owner's
-- phone, which is a separate concern from `handled`. Applied separately as
-- supabase/migrations/2026-08-07_admin_dashboard.sql.
-- ============================================================
ALTER TABLE public.photo_reports ADD COLUMN IF NOT EXISTS handled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.user_reports  ADD COLUMN IF NOT EXISTS handled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS photo_reports_unhandled_idx ON public.photo_reports (handled) WHERE handled = FALSE;
CREATE INDEX IF NOT EXISTS user_reports_unhandled_idx  ON public.user_reports  (handled) WHERE handled = FALSE;

CREATE OR REPLACE FUNCTION public.list_photo_reports()
RETURNS TABLE (
    report_id         UUID,
    photo_id          UUID,
    reason            TEXT,
    report_count      BIGINT,
    created_at        TIMESTAMPTZ,
    reported_username TEXT,
    hidden            BOOLEAN
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
    WITH counts AS (
        SELECT
            pr.photo_id,
            COUNT(DISTINCT pr.reporter_id) AS report_count,
            MIN(pr.created_at)             AS first_reported_at
        FROM public.photo_reports pr
        WHERE NOT pr.handled
        GROUP BY pr.photo_id
    ),
    latest AS (
        SELECT DISTINCT ON (pr.photo_id)
            pr.id, pr.photo_id, pr.reason
        FROM public.photo_reports pr
        WHERE NOT pr.handled
        ORDER BY pr.photo_id, pr.created_at DESC
    )
    SELECT
        latest.id,
        latest.photo_id,
        latest.reason,
        counts.report_count,
        counts.first_reported_at,
        u.username,
        ph.hidden
    FROM latest
    JOIN counts             ON counts.photo_id = latest.photo_id
    JOIN public.photos ph   ON ph.id = latest.photo_id
    JOIN public.users  u    ON u.id = ph.user_id
    ORDER BY counts.first_reported_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_user_reports()
RETURNS TABLE (
    report_id         UUID,
    reported_id       UUID,
    reported_username TEXT,
    reason            TEXT,
    report_count      BIGINT,
    created_at        TIMESTAMPTZ
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
    WITH counts AS (
        SELECT
            ur.reported_id,
            COUNT(DISTINCT ur.reporter_id) AS report_count,
            MIN(ur.created_at)             AS first_reported_at
        FROM public.user_reports ur
        WHERE NOT ur.handled
        GROUP BY ur.reported_id
    ),
    latest AS (
        SELECT DISTINCT ON (ur.reported_id)
            ur.id, ur.reported_id, ur.reason
        FROM public.user_reports ur
        WHERE NOT ur.handled
        ORDER BY ur.reported_id, ur.created_at DESC
    )
    SELECT
        latest.id,
        latest.reported_id,
        u.username,
        latest.reason,
        counts.report_count,
        counts.first_reported_at
    FROM latest
    JOIN counts          ON counts.reported_id = latest.reported_id
    JOIN public.users u  ON u.id = latest.reported_id
    ORDER BY counts.first_reported_at ASC;
END;
$$;

-- Hide or restore a reported photo by hand. photos.hidden is what auto_hide_reported
-- flips automatically at >= 2 distinct reporters; a manual call here either backs
-- that up early or overrides a false positive. posts denormalizes the same photo,
-- so a manual override has to touch both or the feed and the photo disagree.
CREATE OR REPLACE FUNCTION public.set_photo_hidden(p_photo_id UUID, p_hidden BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.photos SET hidden = p_hidden WHERE id = p_photo_id;
    UPDATE public.posts  SET hidden = p_hidden WHERE photo_id = p_photo_id;

    RETURN TRUE;
END;
$$;

-- Dismissing a row from list_photo_reports clears every report underneath that
-- photo, not just one, or the photo would reappear next load carrying whichever
-- report happened to survive.
CREATE OR REPLACE FUNCTION public.dismiss_photo_report(p_photo_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.photo_reports SET handled = TRUE WHERE photo_id = p_photo_id AND NOT handled;

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.dismiss_user_report(p_reported_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.user_reports SET handled = TRUE WHERE reported_id = p_reported_id AND NOT handled;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.list_photo_reports() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_photo_reports() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_photo_reports() TO authenticated;

REVOKE ALL ON FUNCTION public.list_user_reports() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_user_reports() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_user_reports() TO authenticated;

REVOKE ALL ON FUNCTION public.set_photo_hidden(UUID, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_photo_hidden(UUID, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_photo_hidden(UUID, BOOLEAN) TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_photo_report(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dismiss_photo_report(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.dismiss_photo_report(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_user_report(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dismiss_user_report(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.dismiss_user_report(UUID) TO authenticated;

-- ============================================================
-- In-app feedback capture. The app's only feedback path used to be a mailto:
-- draft; this lands the report directly in the database plus build/device
-- context. Shape mirrors invite_requests / redeem_invite: a table with RLS on
-- and no policies, reachable only through SECURITY DEFINER functions, plus a
-- singleton rate-gate table. Unlike invite_requests, the caller is a signed-in
-- app user, so submit_feedback is granted to authenticated only, never anon,
-- and records auth.uid() itself rather than trusting a caller-supplied id.
-- Applied separately as supabase/migrations/2026-08-07_feedback.sql.
-- ============================================================
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

CREATE INDEX IF NOT EXISTS feedback_unhandled_idx ON public.feedback (created_at) WHERE NOT handled;
CREATE INDEX IF NOT EXISTS feedback_user_id_idx ON public.feedback (user_id);

CREATE TABLE IF NOT EXISTS public.feedback_rate (
    id           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
INSERT INTO public.feedback_rate (id) VALUES (TRUE) ON CONFLICT DO NOTHING;
ALTER TABLE public.feedback_rate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feedback_rate FROM PUBLIC, anon, authenticated;

-- auth.uid() is the only source of the author; a caller cannot claim to be
-- someone else. An empty/whitespace-only message returns FALSE rather than
-- erroring (client-side validation miss, not abuse); an over-length message is
-- silently trimmed to 2000 characters rather than rejected.
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
    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    v_message := LEFT(TRIM(COALESCE(p_message, '')), 2000);
    IF v_message = '' THEN
        RETURN FALSE;
    END IF;

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

REVOKE ALL ON FUNCTION public.submit_feedback(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_feedback(TEXT, TEXT, TEXT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_feedback(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.list_feedback() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_feedback() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_feedback() TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_feedback(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dismiss_feedback(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.dismiss_feedback(UUID) TO authenticated;

-- ============================================================
-- Server-side sweep for orphaned objects in the `photos` bucket. Three client bugs
-- can strand a Storage object without ever writing the row that references it; this
-- gives that class of bug a permanent backstop. READ side only: a SECURITY DEFINER
-- function that finds candidate orphans. It does not delete anything itself and does
-- not touch storage.objects rows directly — deletion happens exclusively through the
-- Storage HTTP API, from the sweep-orphaned-storage Edge Function.
--
-- Orphan definition: an object in bucket `photos` whose name appears in none of
-- photos.{storage_path,thumb_path,feed_path}, posts.{storage_path,thumb_path,feed_path},
-- users.{avatar_path,cover_path}, rolls.cover_path — AND older than p_min_age_hours
-- (default 48, since Storage uploads land bytes before the row referencing them is
-- written, so a recent unreferenced object is very likely a capture still in flight).
-- If a future migration adds another column that can hold a `photos` object name, it
-- MUST be added to the UNION below or this function will misreport live files.
-- Applied separately as supabase/migrations/2026-08-08_orphaned_storage_sweep.sql.
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_orphaned_photos_objects(
    p_min_age_hours INTEGER DEFAULT 48,
    p_max_rows      INTEGER DEFAULT 5000
)
RETURNS TABLE (
    object_name TEXT,
    size_bytes  BIGINT,
    created_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH referenced AS (
        SELECT storage_path AS p FROM public.photos WHERE storage_path IS NOT NULL
        UNION SELECT thumb_path  FROM public.photos WHERE thumb_path  IS NOT NULL
        UNION SELECT feed_path   FROM public.photos WHERE feed_path   IS NOT NULL
        UNION SELECT storage_path FROM public.posts WHERE storage_path IS NOT NULL
        UNION SELECT thumb_path   FROM public.posts WHERE thumb_path   IS NOT NULL
        UNION SELECT feed_path    FROM public.posts WHERE feed_path    IS NOT NULL
        UNION SELECT avatar_path FROM public.users WHERE avatar_path IS NOT NULL
        UNION SELECT cover_path  FROM public.users WHERE cover_path  IS NOT NULL
        UNION SELECT cover_path  FROM public.rolls WHERE cover_path  IS NOT NULL
    )
    SELECT o.name, (o.metadata ->> 'size')::BIGINT, o.created_at
    FROM storage.objects o
    WHERE o.bucket_id = 'photos'
      AND o.created_at < now() - make_interval(hours => p_min_age_hours)
      AND o.name NOT IN (SELECT p FROM referenced)
    ORDER BY o.created_at ASC
    LIMIT p_max_rows;
$$;

-- Internal function: only the sweep Edge Function (service_role) has any business
-- calling this. It reads across photos/posts/users/rolls/storage.objects, none of
-- which a client should be able to enumerate wholesale.
REVOKE ALL ON FUNCTION public.list_orphaned_photos_objects(INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_orphaned_photos_objects(INTEGER, INTEGER) FROM anon, authenticated;

-- ============================================================
-- Activation instrumentation (FLIM 1.4). The app ships with no analytics of any
-- kind today, and this is a deliberate in-house replacement for a third-party SDK
-- (PostHog, Amplitude, etc): FLIM's own App Store listing promises "no algorithm,
-- no strangers", and shipping behavioural data off-device to a third party
-- contradicts that and adds a privacy disclosure. A table in a database the owner
-- already runs is cheaper, more private, and enough at this scale.
--
-- Every row is a "first time X happened" MILESTONE per user, not an event stream:
-- (user_id, event) is unique. This is what lets the client fire e.g. `first_shot`
-- on every single capture rather than maintaining a local "have I already logged
-- this" flag, simpler and less bug-prone on the client, the database is what makes
-- it idempotent, not client state.
--
-- Cost: capped at one row per (user, event) across the 8 known events below, so at
-- 1,000 users this is at most 8,000 rows, ever. Negligible.
--
-- Applied separately as supabase/migrations/2026-08-08_activation_events.sql.
-- ⚠️ run this BEFORE pushing the Swift client that calls log_activation_event.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.activation_events (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    event      TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- A typo in the client (or a future event nobody wired up here) is a loud
    -- constraint-violation error, not a silently-accepted junk row.
    CONSTRAINT activation_events_event_check CHECK (event IN (
        'first_launch', 'first_shot', 'roll_created', 'roll_joined',
        'invite_sent', 'invite_redeemed', 'post_shared', 'reveal_watched'
    ))
);

-- The idempotence guarantee itself, and the ON CONFLICT target
-- log_activation_event() below relies on.
CREATE UNIQUE INDEX IF NOT EXISTS activation_events_user_event_idx
    ON public.activation_events (user_id, event);
-- activation_funnel() groups by event across every user; cheap at this row count
-- regardless, but free to have.
CREATE INDEX IF NOT EXISTS activation_events_event_idx ON public.activation_events (event);

ALTER TABLE public.activation_events ENABLE ROW LEVEL SECURITY;

-- A user may insert only their own row, and in practice only ever does so through
-- log_activation_event() below (SECURITY DEFINER, runs as the table owner, which
-- bypasses this policy entirely). Kept anyway as the actual enforced boundary, not
-- "the RPC happens to be the only caller today".
DROP POLICY IF EXISTS "activation_events: insert own" ON public.activation_events;
CREATE POLICY "activation_events: insert own"
    ON public.activation_events FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id);

-- NOBODY may SELECT directly, not even the row's own user, only the owner, gated
-- the same way list_feedback / list_invite_requests / list_photo_reports already
-- are. Reads go through activation_funnel() below. No UPDATE or DELETE policy
-- exists at all, so both are refused outright under RLS, this table is append-only.
DROP POLICY IF EXISTS "activation_events: owner reads" ON public.activation_events;
CREATE POLICY "activation_events: owner reads"
    ON public.activation_events FOR SELECT TO authenticated
    USING (public.is_owner());

-- Writer RPC the client calls on every relevant action. No-op (not an error) when
-- auth.uid() is null, so a client bug (a stray call before sign-in, a race during
-- sign-out) can never crash a capture call. An unknown p_event still raises loudly
-- via the CHECK constraint above, that failure mode is intentional.
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

-- anon is revoked explicitly, not just PUBLIC: Supabase's stock default privileges
-- grant EXECUTE to anon at CREATE time, and REVOKE FROM PUBLIC does not remove a
-- role's own named grant. This project has been bitten by that more than once
-- (see register_device_token, submit_feedback above), so it's spelled out again.
REVOKE ALL ON FUNCTION public.log_activation_event(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_activation_event(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_activation_event(TEXT) TO authenticated;

-- Reader RPC, owner-gated exactly like list_feedback/list_invite_requests: a
-- non-owner caller gets an empty result set, never an error and never real rows.
-- One row per KNOWN event, even ones with zero occurrences so far (LEFT JOIN, not
-- a plain GROUP BY over the table), so "0 of N have done this yet" is a visible
-- row rather than a missing one, plus the current total user count on every row,
-- so "of everyone who signed up, how many took a shot / joined a roll / invited
-- someone" reads off a single query.
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

REVOKE ALL ON FUNCTION public.activation_funnel() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.activation_funnel() FROM anon;
GRANT EXECUTE ON FUNCTION public.activation_funnel() TO authenticated;

-- ============================================================
-- Backfill: derive what the existing data already proves happened, so the funnel
-- isn't empty on day one. Every INSERT below uses that event's REAL historical
-- timestamp (never now()), and ON CONFLICT DO NOTHING makes each one idempotent,
-- safe to re-run every time this file runs, and safe to run alongside the live RPC
-- (whichever writes a given (user, event) row first wins; nothing is ever
-- overwritten, so a real captured event is never clobbered by a coarser backfilled
-- one or vice versa).
--
-- Derived, because the existing data unambiguously proves the event happened at a
-- specific, recoverable time:
--   first_shot      <- earliest public.photos row per user (taken_at)
--   roll_created     <- earliest public.rolls row per creator (created_at)
--   roll_joined      <- earliest public.roll_members row per user (joined_at)
--   reveal_watched   <- earliest public.roll_reveal_views row per user (viewed_at)
--   post_shared      <- earliest public.posts row per user (created_at); a posts
--                        row IS the "shared a photo to the feed" action, there is
--                        no other write path that creates one
--   invite_redeemed  <- redeem_invite() stamps allowed_emails.note with
--                        'invited_by:<uuid>' the moment a code is redeemed; joined
--                        back to the user who went on to sign up with that email,
--                        timestamped by allowed_emails.added_at (when the
--                        redemption itself happened, not when they later signed up)
--
-- NOT derived. No evidence exists anywhere in this schema for either, so nothing
-- is invented:
--   first_launch  <- nothing has ever recorded a launch or session; this table did
--                     not exist before this change, and there is no proxy for it
--                     (sign-in only proves an account exists, not that any
--                     particular later launch happened).
--   invite_sent   <- redeem_invite() records that a code WAS redeemed by someone,
--                     never that the owner's code was shared/sent out; a code that
--                     was sent but never used leaves no row anywhere. Only the
--                     client, going forward, can know this.
-- ============================================================
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

-- ============================================================
-- Contextual reaction-bar emoji (FLIM 1.4). The reaction bar's first three emoji
-- (❤️ 🔥 😂) stay fixed; the last two become suggestions derived on-device at
-- capture time from Vision's VNClassifyImageRequest (no model shipped, no image
-- ever leaves the phone for this). This section stores that result and makes
-- sure it cannot spoil the reveal. Applied separately as
-- supabase/migrations/2026-08-08_photo_suggested_emoji.sql.
--
-- WHY THIS IS NOT A COLUMN ON public.photos, despite that being the natural first
-- instinct:
--
-- `public.photos` already has table-wide SELECT granted to anon/authenticated
-- (Supabase's default privileges at CREATE TABLE time), and its two SELECT
-- policies ("photos: own photos", "photos: roll members can see") make a roll
-- member's photo ROW readable the moment it's inserted, well before
-- develops_at, RLS on this table has never gated on develops_at, because the
-- client needs the countdown itself. Verified live against production
-- 2026-08-08 (synthetic rows, rolled back): as the NON-owning member of a roll
-- whose develops_at was hours in the future, `SELECT * FROM public.photos WHERE
-- id = <roll-mate's photo>` returned the full row.
--
-- A plain new column on that table inherits that exposure, and column-level
-- GRANT/REVOKE cannot fix it. Also verified live: once a table-wide SELECT grant
-- exists, `REVOKE SELECT (col) ... FROM authenticated` is a no-op
-- (has_column_privilege() still returns true for that role/column afterward).
-- The only privilege shape that actually withholds a single column, REVOKE the
-- whole table's SELECT then GRANT back an explicit column allowlist (the same
-- pattern already used for `users`/`profiles` above), was also verified live to
-- break every existing `.select()` call with no explicit column list in
-- PhotoService/FeedService/RollService: those resolve to `select=*`, which
-- requires table-wide privilege and fails with "permission denied for table
-- photos" the instant that privilege is narrowed to a column allowlist. Fixing
-- that would mean rewriting every such call site to name its columns explicitly,
-- a Swift-side change out of this change's scope and ownership.
--
-- A sibling table sidesteps all of it: it starts with zero grants and zero
-- policies of its own, is reachable only through the two SECURITY DEFINER
-- functions below, and requires no change to any existing photos read path.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_suggested_emoji (
    photo_id        UUID PRIMARY KEY REFERENCES public.photos(id) ON DELETE CASCADE,
    -- TEXT[] over a delimited TEXT: these are two independent, order-meaningful
    -- tokens, not a blob to parse. An array needs no delimiter (and no escaping
    -- headache if an emoji's UTF-8 bytes ever collided with one), decodes to
    -- Swift as a plain `[String]`, and Postgres's array overhead for 1-2 short
    -- text elements is a few bytes, not worth trading query/decode simplicity
    -- for. cardinality is bounded by the CHECK below, not by array length limits.
    suggested_emoji TEXT[] NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT photo_suggested_emoji_count CHECK (cardinality(suggested_emoji) BETWEEN 1 AND 3)
);
-- No row at all is how "classification failed" or "below the confidence floor"
-- is represented, not a NULL array, this table is an optional 1:1 extension of
-- photos, and every existing photo correctly has no row.

ALTER TABLE public.photo_suggested_emoji ENABLE ROW LEVEL SECURITY;
-- No policies, at all, on purpose, same shape as allowed_emails / digest_state /
-- feedback elsewhere in this file: RLS enabled with no matching policy already
-- denies every row to anon/authenticated for every command, and the REVOKE
-- below is defense in depth for exactly the reason this project keeps hitting,
-- Supabase grants ALL on a new table to anon/authenticated at CREATE time, and
-- REVOKE FROM PUBLIC alone does not remove those two roles' own named grants.
REVOKE ALL ON public.photo_suggested_emoji FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Write path: the capturing user sets suggestions for their OWN photo only.
-- Ownership is checked inside this definer body (photos.user_id = auth.uid())
-- rather than via a table policy, because this value's table carries no
-- policies of its own (see above), this is the same authorization SHAPE as
-- "photos: can update own" (the policy PhotoService.uploadRenditions already
-- writes thumb_path/feed_path through), just enforced in code instead of in a
-- USING/WITH CHECK clause, since the value now lives off of `photos` itself.
-- Passing NULL or an empty array clears any existing suggestion (used if a
-- later, better classification run wants to withdraw a low-confidence guess).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_photo_suggested_emoji(p_photo_id UUID, p_emoji TEXT[])
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.photos WHERE id = p_photo_id AND user_id = auth.uid()
    ) THEN
        RETURN FALSE;
    END IF;

    IF p_emoji IS NULL OR cardinality(p_emoji) = 0 THEN
        DELETE FROM public.photo_suggested_emoji WHERE photo_id = p_photo_id;
        RETURN TRUE;
    END IF;

    IF cardinality(p_emoji) > 3 THEN
        RAISE EXCEPTION 'at most three suggested emoji' USING ERRCODE = 'P0004';
    END IF;

    IF EXISTS (
        SELECT 1 FROM unnest(p_emoji) e WHERE e IS NULL OR octet_length(e) NOT BETWEEN 1 AND 32
    ) THEN
        RAISE EXCEPTION 'invalid suggested emoji' USING ERRCODE = 'P0004';
    END IF;

    INSERT INTO public.photo_suggested_emoji (photo_id, suggested_emoji, updated_at)
    VALUES (p_photo_id, p_emoji, NOW())
    ON CONFLICT (photo_id) DO UPDATE
        SET suggested_emoji = EXCLUDED.suggested_emoji,
            updated_at      = NOW();

    RETURN TRUE;
END;
$$;

-- anon explicitly revoked, not just PUBLIC, same reasoning as the REVOKE above.
REVOKE ALL ON FUNCTION public.set_photo_suggested_emoji(UUID, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_photo_suggested_emoji(UUID, TEXT[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_photo_suggested_emoji(UUID, TEXT[]) TO authenticated;

-- ------------------------------------------------------------
-- Read path: the reveal gate. A photo's own owner can always read their own
-- suggestion back (it's their photo; they already know what's in it, no spoiler
-- risk). A fellow roll member only gets it once that photo's develops_at has
-- passed, mirrors "photos: roll members can see" (roll membership, NOT hidden,
-- NOT blocked) plus the one predicate that policy is missing on purpose
-- everywhere else, develops_at <= now(). A third branch, added when this
-- function shipped without it and the feed silently showed no suggestions at
-- all (every feed photo is visible via a follow, not a roll, so the roll
-- branch above never matched): anyone who can see the photo because it was
-- shared as a post. This mirrors "photos: readable when shared to a post"
-- (storage.objects) exactly: EXISTS a post row for this photo, NOT
-- posts.hidden, NOT is_blocked_either_way keyed off the POST's user_id (the
-- sharer, who can be a roll-mate re-sharing someone else's shot onto their own
-- page, not necessarily p.user_id). No develops_at check in this branch,
-- deliberately, for two reasons: the storage policy it mirrors has none
-- either (posting is an act of publishing, not gated on the source photo's
-- reveal timer, "posts: create own" itself never checks develops_at), and a
-- suggestion is strictly less sensitive than the pixels describing it, so
-- gating the emoji tighter than the photo it's attached to would protect
-- nothing: anyone who could construct a post for an undeveloped photo already
-- exposed its bytes through the mirrored storage policy, adding a develops_at
-- check here would just make the emoji lag behind a photo the caller can
-- already open. Batched by an array of photo ids (feed/roll views render many
-- photos at once, one RPC beats N), and a photo id the caller isn't allowed to
-- see (wrong id, undeveloped roll-mate's photo, blocked party, hidden) is
-- silently absent from the result, never an error, so a client can't
-- distinguish "not visible yet" from "no suggestion exists" by error shape,
-- both just produce no row for that id.
--
-- The post-sharing branch also carries public.covered_post_visible(auth.uid(),
-- po.user_id, po.created_at), added 2026-08-14 (see
-- supabase/migrations/2026-08-14_suggested_emoji_covered_posts.sql). This
-- SECURITY DEFINER function bypasses "posts: readable by authenticated" RLS
-- by construction, so it needed to be taught the same covered-post rule that
-- policy enforces, or a caller holding a covered post's photo_id could still
-- read its suggested-emoji array after the post row and photo bytes were
-- hidden. Reuses the existing helper rather than re-deriving the rule, same
-- as the posts/storage policies do. Per-row: a mixed array containing one
-- covered id and one ordinary id returns only the ordinary row, not zero
-- rows and not an error. Cost: one extra STABLE, PK-indexed, short-
-- circuiting boolean call, only inside this branch's EXISTS, only for ids
-- that already matched a post row.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_suggested_emoji(p_photo_ids UUID[])
RETURNS TABLE (photo_id UUID, suggested_emoji TEXT[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT s.photo_id, s.suggested_emoji
    FROM public.photo_suggested_emoji s
    JOIN public.photos p ON p.id = s.photo_id
    WHERE s.photo_id = ANY(p_photo_ids)
      AND NOT p.hidden
      AND (
            p.user_id = auth.uid()
            OR (
                p.roll_id IS NOT NULL
                AND public.is_roll_member(p.roll_id)
                AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
                AND p.develops_at <= now()
              )
            OR EXISTS (
                SELECT 1 FROM public.posts po
                WHERE po.photo_id = p.id
                  AND NOT po.hidden
                  AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
                  AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
              )
          );
$$;

REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_suggested_emoji(UUID[]) TO authenticated;

-- ============================================================
-- Widen public.activation_events' event allowlist by exactly two values, so
-- the funnel can explain its biggest leak instead of only measuring it: 9 of
-- 25 accounts never took a photo, and until now nothing was recorded between
-- `first_launch` and `first_shot`, so the data could only ever say "they
-- launched and never shot", conflating abandoning onboarding, denying camera
-- permission, and reaching a working camera and leaving. Those need three
-- different responses.
--
-- New events, in the funnel's narrative order right after first_launch and
-- before first_shot:
--   onboarding_finished  <- reached the end of onboarding
--   camera_authorized    <- camera permission was granted
--
-- Applied separately as
-- supabase/migrations/2026-08-12_activation_events_onboarding_camera.sql.
-- ⚠️ run this BEFORE pushing the Swift client that calls
--    log_activation_event('onboarding_finished') /
--    log_activation_event('camera_authorized').
--
-- No table, index, RLS policy, or RPC signature changes here, only the CHECK
-- constraint's allowed set and activation_funnel()'s known-event list widen.
-- The DROP/ADD below are two clauses of the SAME ALTER TABLE statement (one
-- atomic DDL command, not two separate ones): if the new constraint's
-- validation scan against existing rows ever failed, Postgres rolls the whole
-- statement back and the table keeps its prior constraint, never
-- unconstrained. Every existing row only ever contains the original 8 event
-- values, all of which remain in this list, so that scan is guaranteed to
-- pass.
-- ============================================================
ALTER TABLE public.activation_events
    DROP CONSTRAINT IF EXISTS activation_events_event_check,
    ADD CONSTRAINT activation_events_event_check CHECK (event IN (
        'first_launch', 'onboarding_finished', 'camera_authorized', 'first_shot',
        'roll_created', 'roll_joined', 'invite_sent', 'invite_redeemed',
        'post_shared', 'reveal_watched'
    ));

-- activation_funnel()'s known-event list is hardcoded (not derived from the
-- CHECK constraint or any other source), so it must be widened here too, in
-- the same order, or the two new events would silently never appear in the
-- very report they exist to feed.
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

-- Grants unchanged, re-stated for safety; CREATE OR REPLACE FUNCTION does not
-- touch existing grants, but re-asserting costs nothing and keeps this
-- section self-contained the same way earlier REPLACE'd functions in this
-- file do. log_activation_event(TEXT) itself is untouched here: same
-- signature, same body, same grants.
REVOKE ALL ON FUNCTION public.activation_funnel() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.activation_funnel() FROM anon;
GRANT EXECUTE ON FUNCTION public.activation_funnel() TO authenticated;

-- No backfill for either new event: unlike first_shot (proved by
-- photos.taken_at), nothing in the existing schema is evidence that
-- onboarding finished or camera permission was granted, same policy as
-- first_launch and invite_sent above, so both start empty and are populated
-- only by the client going forward.

-- ============================================================
-- App version gate (single-row config table). Applied separately as
-- supabase/migrations/2026-08-13_app_release_gate.sql; read that file's
-- header comment for the full danger explanation, the arm/disarm sequence,
-- and how this was verified. Summary only, here:
--
-- ⚠️ minimum_version must NEVER exceed a build that is already APPROVED AND
-- RELEASED on the App Store, never one merely submitted. Raising it above a
-- build nobody has yet is an install-bricking mistake with no in-app
-- recovery, not a bug to file. Sequence: ship → wait until it's actually
-- live → only then raise minimum_version.
--
-- Seeded INERT ('0.0.0' / '0.0.0') so a fresh run of this file does nothing
-- until the owner deliberately arms it. ON CONFLICT DO NOTHING so re-running
-- this file never stomps a value the owner has since raised in production.
-- Single-row-ness is structural (id BOOLEAN PK CHECK (id)), same trick as
-- redeem_invite_rate / invite_request_rate above.
--
-- RLS: SELECT open to anon AND authenticated (has to be readable pre-sign-in,
-- so a hard-blocked client never reaches the auth screen). No write policy of
-- any kind, and the REVOKE below is the part that matters, not the absence
-- of a write policy: Supabase's default privileges grant INSERT/UPDATE/
-- DELETE (and TRUNCATE) to anon/authenticated on every new public table at
-- CREATE time, and a bare GRANT SELECT does not remove them. Verified in
-- Docker against the actual grant catalog (information_schema.
-- role_table_grants), not just against RLS: after REVOKE ALL + GRANT SELECT,
-- anon/authenticated show SELECT only, and INSERT/UPDATE/DELETE/TRUNCATE all
-- fail with "permission denied for table", at the grant layer, before RLS is
-- even evaluated.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.app_release_gate (
    id               BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),  -- single-row table
    minimum_version  TEXT NOT NULL DEFAULT '0.0.0',   -- below this: hard block
    latest_version   TEXT NOT NULL DEFAULT '0.0.0',   -- below this: dismissible nudge
    message          TEXT,                             -- optional custom line, NULL uses the app's default copy
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.app_release_gate (id, minimum_version, latest_version)
VALUES (TRUE, '0.0.0', '0.0.0')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.app_release_gate ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_release_gate: readable by anyone" ON public.app_release_gate;
CREATE POLICY "app_release_gate: readable by anyone"
    ON public.app_release_gate FOR SELECT
    TO anon, authenticated
    USING (true);

REVOKE ALL ON public.app_release_gate FROM anon, authenticated, PUBLIC;
GRANT SELECT ON public.app_release_gate TO anon, authenticated;

-- Keeps updated_at honest on every UPDATE (owner arming/disarming the gate),
-- without relying on a manual SET updated_at = NOW() being remembered.
CREATE OR REPLACE FUNCTION public.app_release_gate_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.app_release_gate_touch_updated_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS app_release_gate_touch_updated_at ON public.app_release_gate;
CREATE TRIGGER app_release_gate_touch_updated_at
    BEFORE UPDATE ON public.app_release_gate
    FOR EACH ROW EXECUTE FUNCTION public.app_release_gate_touch_updated_at();
