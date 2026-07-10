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
-- Small thumbnail uploaded alongside the full image (grids/feeds load ~30KB not MBs). Added
-- here — before the storage policies that reference it — so a fresh run has the column ready.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS thumb_path TEXT;

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
-- Thumbnail denormalized from the photo (see photos.thumb_path), so the feed loads small.
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS thumb_path TEXT;
-- Marked once the push scanner has processed this post (tag + caption-mention notifications).
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS push_sent BOOLEAN DEFAULT FALSE;

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
-- ⚠️ Every rendition column must be listed here. When a new rendition path is
-- added to posts (thumb_path, feed_path, …), it MUST be added to this IN list —
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
-- ============================================================
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS hidden BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.posts  ADD COLUMN IF NOT EXISTS hidden BOOLEAN NOT NULL DEFAULT FALSE;

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
-- Indexes on hot query paths (Postgres does NOT auto-index foreign keys).
-- Cheap now, and they keep the feed / rolls / activity queries index-backed as data grows.
-- ============================================================
CREATE INDEX IF NOT EXISTS posts_user_created_idx      ON public.posts (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS posts_photo_idx             ON public.posts (photo_id);
CREATE INDEX IF NOT EXISTS photos_user_idx             ON public.photos (user_id, taken_at DESC);
CREATE INDEX IF NOT EXISTS photos_roll_idx             ON public.photos (roll_id, develops_at DESC);
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
-- The feed downloads this (~250KB) instead of the full 2048px file (~700KB) — pixel-identical
-- at feed-card width. Full image still used for full-screen / zoom / save. Older photos have
-- NULL and fall back to storage_path.
-- ============================================================
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS feed_path TEXT;
ALTER TABLE public.posts  ADD COLUMN IF NOT EXISTS feed_path TEXT;

-- ============================================================
-- Security-advisor hardening (2026-07). All applied live; kept here as source of truth.
-- ============================================================
-- profiles enforces the QUERYING user's rights (safe columns come from users column grants).
ALTER VIEW public.profiles SET (security_invoker = on);

-- users: any signed-in user may read rows, but ONLY the safe profile columns.
-- email + invite_code are excluded from the grant → unreadable via the API for OTHER users
-- (this also closed a leak where roll co-members could select each other's email).
DROP POLICY IF EXISTS "users: visible to co-members" ON public.users;
DROP POLICY IF EXISTS "users: profiles readable" ON public.users;
CREATE POLICY "users: profiles readable" ON public.users FOR SELECT TO authenticated USING (true);
REVOKE SELECT ON public.users FROM anon, authenticated;
GRANT SELECT (id, username, avatar_path, bio, created_at, display_name, cover_path) ON public.users TO authenticated;

-- Your OWN full row (incl. email + invite_code) via a locked-down RPC.
CREATE OR REPLACE FUNCTION public.get_own_profile()
RETURNS public.users
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$ SELECT * FROM public.users WHERE id = auth.uid() $$;
REVOKE ALL ON FUNCTION public.get_own_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_profile() TO authenticated;

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
REVOKE EXECUTE ON FUNCTION public.is_email_allowed(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_email_allowed(text) TO anon, authenticated;

-- Accepted advisor remainders (intentional):
--  * allowed_emails: RLS on, no policies = deny-all to clients (read via is_email_allowed only).
--  * pg_net in public: the extension does not support SET SCHEMA; its callable API lives in `net`.
--  * leaked-password protection (HIBP): Pro-plan feature — enable in dashboard after upgrading.

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
-- boolean — the same pattern as is_roll_member. STABLE + pinned search_path.
--
-- ⚠️ Grants: `authenticated` MUST keep EXECUTE. SECURITY DEFINER only controls
-- whose privileges the function BODY runs with — the querying role still needs
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

-- Feed posts: hide posts authored by anyone in a block relationship with the viewer.
DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

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

-- Shared-roll photos: hide a blocked party's photos from the roll surface. Preserves
-- the existing membership check; adds the block predicate. (Own photos policy is
-- unchanged — you can never block yourself, CHECK (blocker_id <> blocked_id).)
DROP POLICY IF EXISTS "photos: roll members can see" ON public.photos;
CREATE POLICY "photos: roll members can see"
    ON public.photos FOR SELECT
    USING (
        roll_id IS NOT NULL
        AND public.is_roll_member(roll_id)
        AND NOT public.is_blocked_either_way(auth.uid(), user_id)
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

-- What RLS deliberately does NOT cover (must stay a client-side filter) — see the
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
--  * Storage objects: signed URLs are minted per-path; a stale URL already handed out
--    isn't revoked by a later block. New reads are gated because the photos/posts rows
--    that authorize them are now block-filtered.
