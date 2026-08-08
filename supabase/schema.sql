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

-- Forward-compat hook for scarce invites (e.g. "this code works N times").
-- NULL = unlimited, which is what every existing row gets and what v1 enforces
-- for everyone, redeem_invite() does not read or decrement this column yet.
-- Wiring it in later is additive: no shape change needed when that ships.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS invite_uses_remaining INT;

CREATE OR REPLACE FUNCTION public.redeem_invite(p_code TEXT, p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_email    TEXT := LOWER(TRIM(p_email));
    v_code     TEXT := UPPER(TRIM(p_code));
    v_inviter  UUID;
    v_window   TIMESTAMPTZ;
    v_attempts INT;
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
    SELECT id INTO v_inviter FROM public.users WHERE invite_code = v_code LIMIT 1;

    IF v_inviter IS NULL THEN
        RETURN FALSE;
    END IF;

    -- note stores the inviter's UUID, not their username: usernames are
    -- nullable and can change later, so a username snapshot would go stale or
    -- be missing entirely. The UUID is a stable, permanent audit trail back to
    -- `users.id` no matter what the inviter later renames themselves to.
    --
    -- ON CONFLICT DO NOTHING + unconditional RETURN TRUE: whether v_email was
    -- already on the allowlist or was just added is indistinguishable to the
    -- caller, by design. This is what makes the RPC idempotent, redeeming the
    -- same valid code for the same email twice (double-tap, client retry) is
    -- always safe, never errors, and never writes a second row, and it also
    -- closes an email-enumeration side channel: a caller can't use the return
    -- value to learn whether an email was allowed before they submitted it.
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invited_by:' || v_inviter::text)
    ON CONFLICT (email) DO NOTHING;

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

CREATE OR REPLACE VIEW public.profiles AS
    SELECT id, username, avatar_path, bio, created_at, display_name, cover_path,
           hidden_from_discovery
    FROM public.users;

-- READ ONLY, and the REVOKE is the part that matters.
--
-- This view is the door clients read identities through: `users` deliberately withholds SELECT
-- from anon and authenticated (only service_role has it), because RLS is row-level and cannot
-- hide the email and invite_code COLUMNS. Exposing a narrower view instead is the whole design,
-- and it depends on the view running as its owner rather than as the caller. That is what
-- Supabase's linter reports as "Security Definer View", and here it is load-bearing: adding
-- `security_invoker = true` would make every profile read fail, because the caller has no SELECT
-- on `users`.
--
-- The danger is the other half of that same property. A single-table view like this one is
-- AUTO-UPDATABLE, so a write through it also runs as the owner and also bypasses RLS. Supabase's
-- default privileges grant INSERT/UPDATE/DELETE to anon and authenticated on every new object in
-- `public`, and a bare `GRANT SELECT` does not take those away. That combination meant anyone
-- holding the publishable key (which ships inside the app binary) could PATCH or DELETE any
-- user's row through this view, bypassing the "users: own row" policy entirely. Verified against
-- production on 2026-08-05: an unauthenticated PATCH returned 200, not 403.
--
-- Nothing reads or writes profiles except SELECTs (the app writes profile fields to `users`,
-- where RLS gates them), so the view is revoked down to SELECT. Keep the REVOKE ahead of the
-- GRANT: this file is re-run in production as the standing workflow, and a re-created view picks
-- the default privileges back up.
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated, anon;

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
-- ============================================================
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS feed_path TEXT;
ALTER TABLE public.posts  ADD COLUMN IF NOT EXISTS feed_path TEXT;

-- ============================================================
-- Security-advisor hardening (2026-07). All applied live; kept here as source of truth.
-- ============================================================
-- profiles deliberately runs with the VIEW OWNER's rights, not the querying user's.
--
-- Do not turn security_invoker on. The line below is what Supabase's security advisor asks for
-- when it flags "Security Definer View", and it is wrong for this view: `profiles` reads
-- `public.users`, which the querying role cannot read directly, so invoker rights make every
-- profile read fail with "permission denied for table users". No handles, no avatars, no
-- mentions, no profile pages, app-wide. The safe columns are already constrained by the
-- column-level grants on `users` immediately below, which is what makes owner rights safe here.
--
-- Verified against production 2026-08-08: pg_class.reloptions for this view is NULL, i.e.
-- security_invoker is OFF and always has been. The statement was listed under a header claiming
-- "all applied live" but never was, so running this file as written would have been the first
-- time it took effect, and it would have broken profile reads for everyone.
--
-- ALTER VIEW public.profiles SET (security_invoker = on);   -- DO NOT ENABLE, see above

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
--  * leaked-password protection (HIBP): Pro-plan feature, enable in dashboard after upgrading.

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
-- the definition of this policy name that actually survives a full run of this file).
DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated
    USING (NOT hidden AND NOT public.is_blocked_either_way(auth.uid(), user_id));

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
-- the roll-photo policy just above; this closes it for photos shared to a post.
DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path)
                      AND NOT po.hidden
                      AND NOT public.is_blocked_either_way(auth.uid(), po.user_id))
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
