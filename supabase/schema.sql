-- ============================================================
-- FLIM — Supabase schema
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

-- Roll membership (max 10 enforced in the join function)
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

-- ============================================================
-- Invite gate: is this email allowed to sign in?
-- Called from the client BEFORE auth (the user has no session yet), so it
-- must be reachable by the `anon` role. SECURITY DEFINER lets it read the
-- allowlist table while RLS keeps that table otherwise unreadable. Returns
-- TRUE/FALSE only — it never reveals the list itself.
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
-- 10-member cap, and inserts membership atomically — all with definer
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

    IF NOT already_member THEN
        SELECT COUNT(*) INTO member_count FROM public.roll_members WHERE roll_id = r.id;
        IF member_count >= 10 THEN
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

-- ROLL MEMBERS ----------------------------------------------
DROP POLICY IF EXISTS "roll_members: own membership" ON public.roll_members;
CREATE POLICY "roll_members: own membership"
    ON public.roll_members FOR SELECT
    USING (user_id = auth.uid());

-- See fellow members — uses the SECURITY DEFINER helper to avoid recursion.
DROP POLICY IF EXISTS "roll_members: can see fellow members" ON public.roll_members;
CREATE POLICY "roll_members: can see fellow members"
    ON public.roll_members FOR SELECT
    USING (public.is_roll_member(roll_id));

DROP POLICY IF EXISTS "roll_members: can join" ON public.roll_members;
CREATE POLICY "roll_members: can join"
    ON public.roll_members FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- PHOTOS -----------------------------------------------------
DROP POLICY IF EXISTS "photos: own photos" ON public.photos;
CREATE POLICY "photos: own photos"
    ON public.photos FOR SELECT
    USING (user_id = auth.uid());

DROP POLICY IF EXISTS "photos: roll members can see" ON public.photos;
CREATE POLICY "photos: roll members can see"
    ON public.photos FOR SELECT
    USING (roll_id IS NOT NULL AND public.is_roll_member(roll_id));

DROP POLICY IF EXISTS "photos: can insert own" ON public.photos;
CREATE POLICY "photos: can insert own"
    ON public.photos FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "photos: can update own" ON public.photos;
CREATE POLICY "photos: can update own"
    ON public.photos FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- Storage
-- Create a PRIVATE bucket named "photos" in the Supabase dashboard:
--   Storage → New bucket → name: "photos", Public: OFF
--
-- Then add these storage policies (Dashboard → Storage → photos → Policies):
--   SELECT: authenticated users can download if (storage.foldername(name))[1] = auth.uid()::text
--   INSERT: authenticated users can upload   if (storage.foldername(name))[1] = auth.uid()::text
--
-- NOTE: photos are stored under "<owner_uid>/<photo_id>.jpg". Roll-mates read
-- shared photos through short-lived signed URLs minted by the owner's client,
-- so the per-user storage policy above is sufficient for the MVP.
-- ============================================================

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
