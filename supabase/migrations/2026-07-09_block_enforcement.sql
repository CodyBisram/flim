-- ============================================================
-- Migration: RLS-level block enforcement (App Store Guideline 1.2)
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
-- ⚠️ run this BEFORE pushing the follow-up Swift client changes.
-- Statements are in dependency order (helper + index first, then policies).
-- ============================================================

-- 1. Helper: bidirectional block check (SECURITY DEFINER so policies on other
--    tables can read the owner-only `blocks` table). Revoked from PUBLIC/anon
--    only — `authenticated` MUST keep EXECUTE: RLS policies evaluate as the
--    querying role, which needs EXECUTE to call the function (SECURITY DEFINER
--    only affects the body's privileges). Revoking authenticated = full outage.
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

-- 2. Reverse-direction index (the PK covers the forward lookup).
CREATE INDEX IF NOT EXISTS blocks_blocked_idx ON public.blocks (blocked_id, blocker_id);

-- 3. READ policies -------------------------------------------------------------
DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

DROP POLICY IF EXISTS "post_comments: readable" ON public.post_comments;
CREATE POLICY "post_comments: readable"
    ON public.post_comments FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

DROP POLICY IF EXISTS "post_reactions: readable" ON public.post_reactions;
CREATE POLICY "post_reactions: readable"
    ON public.post_reactions FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

DROP POLICY IF EXISTS "post_tags: readable" ON public.post_tags;
CREATE POLICY "post_tags: readable"
    ON public.post_tags FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), tagged_user_id));

DROP POLICY IF EXISTS "comment_likes: readable" ON public.comment_likes;
CREATE POLICY "comment_likes: readable"
    ON public.comment_likes FOR SELECT TO authenticated
    USING (NOT public.is_blocked_either_way(auth.uid(), user_id));

DROP POLICY IF EXISTS "photos: roll members can see" ON public.photos;
CREATE POLICY "photos: roll members can see"
    ON public.photos FOR SELECT
    USING (
        roll_id IS NOT NULL
        AND public.is_roll_member(roll_id)
        AND NOT public.is_blocked_either_way(auth.uid(), user_id)
    );

DROP POLICY IF EXISTS "photo_comments: readable by roll members" ON public.photo_comments;
CREATE POLICY "photo_comments: readable by roll members"
    ON public.photo_comments FOR SELECT TO authenticated
    USING (
        NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                    AND (p.user_id = auth.uid() OR public.is_roll_member(p.roll_id)))
    );

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

-- 4. WRITE policies ------------------------------------------------------------
DROP POLICY IF EXISTS "post_comments: add own" ON public.post_comments;
CREATE POLICY "post_comments: add own"
    ON public.post_comments FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_id
                    AND NOT public.is_blocked_either_way(auth.uid(), p.user_id))
    );

DROP POLICY IF EXISTS "post_reactions: add own" ON public.post_reactions;
CREATE POLICY "post_reactions: add own"
    ON public.post_reactions FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_id
                    AND NOT public.is_blocked_either_way(auth.uid(), p.user_id))
    );

DROP POLICY IF EXISTS "comment_likes: add own" ON public.comment_likes;
CREATE POLICY "comment_likes: add own"
    ON public.comment_likes FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.post_comments c WHERE c.id = comment_id
                    AND NOT public.is_blocked_either_way(auth.uid(), c.user_id))
    );

DROP POLICY IF EXISTS "photo_comments: insert as roll member" ON public.photo_comments;
CREATE POLICY "photo_comments: insert as roll member"
    ON public.photo_comments FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid()
                AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                            AND public.is_roll_member(p.roll_id)
                            AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)));

DROP POLICY IF EXISTS "reactions: add own" ON public.photo_reactions;
CREATE POLICY "reactions: add own"
    ON public.photo_reactions FOR INSERT WITH CHECK (
        auth.uid() = user_id
        AND EXISTS (SELECT 1 FROM public.photos p WHERE p.id = photo_id
                    AND NOT public.is_blocked_either_way(auth.uid(), p.user_id))
    );

DROP POLICY IF EXISTS "follows: create own" ON public.follows;
CREATE POLICY "follows: create own"
    ON public.follows FOR INSERT WITH CHECK (
        auth.uid() = follower_id
        AND NOT public.is_blocked_either_way(auth.uid(), following_id)
    );
