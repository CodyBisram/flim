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

-- Roll membership (max 50 enforced in the join function — keep in sync with Roll.memberCap)
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
-- 50-member cap, and inserts membership atomically — all with definer
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

-- See fellow members — uses the SECURITY DEFINER helper to avoid recursion.
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
-- Storage — private "photos" bucket + per-user RLS policies.
-- Photos are stored under "<owner_uid>/<photo_id>.jpg"; roll-mates read shared
-- photos via short-lived signed URLs minted by the owner's client, so a per-user
-- policy is sufficient. Without these policies, uploads fail with a 403
-- "new row violates row-level security policy" — i.e. capture won't work.
-- ============================================================

-- Create the private bucket if it doesn't exist (Public OFF).
INSERT INTO storage.buckets (id, name, public)
VALUES ('photos', 'photos', false)
ON CONFLICT (id) DO NOTHING;

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

-- Roll members can read a photo that belongs to a roll they're in — this is what
-- lets shared-roll photos (and roll cover thumbnails) load for everyone, not just
-- the photo's owner. Joins the storage object back to its photos row by path.
DROP POLICY IF EXISTS "photos: roll members can read shared" ON storage.objects;
CREATE POLICY "photos: roll members can read shared"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE p.storage_path = storage.objects.name
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
-- Content reports (UGC safety — Guideline 1.2). A user can report a photo they can
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

-- Public profile view — exposes only safe fields (NO email / invite code), readable
-- by any signed-in user so you can browse pages, follow people, and see comment authors.
-- New columns must be appended at the END for CREATE OR REPLACE VIEW (Postgres can't
-- reorder/rename existing view columns) — decode is by name in the app, so order is irrelevant.
CREATE OR REPLACE VIEW public.profiles AS
    SELECT id, username, avatar_path, bio, created_at, display_name, cover_path
    FROM public.users;

GRANT SELECT ON public.profiles TO authenticated, anon;

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

DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "posts: create own" ON public.posts;
CREATE POLICY "posts: create own"
    ON public.posts FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "posts: update own" ON public.posts;
CREATE POLICY "posts: update own"
    ON public.posts FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "posts: delete own" ON public.posts;
CREATE POLICY "posts: delete own"
    ON public.posts FOR DELETE USING (auth.uid() = user_id);

-- A photo shared to a post is readable in Storage by any signed-in user.
DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po WHERE po.storage_path = storage.objects.name)
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
