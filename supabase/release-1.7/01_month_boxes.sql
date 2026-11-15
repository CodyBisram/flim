-- FLIM 1.7, production step 1 of 2: putting shots away and choosing a box's cover (Blend 4, 12b).
-- APPLIED to production 2026-11-14 (now supabase/migrations/2026-11-14_17_month_boxes.sql).
--
-- ADDITIVE and safe for 1.6: a new column that defaults to false, a table only 1.7 writes, and
-- post_visible_to taught to skip put-away posts (none exist until 1.7 puts one away). Apply any
-- time BEFORE 1.7 is released, so 1.7's first reads of posts.put_away never hit a missing column.
-- Already on FLIM Dev as supabase/migrations-v2/2026-10-30 (sections 2 to 3) and 2026-10-30b.
-- Then append to supabase/schema.sql and move into supabase/migrations/ with the date applied.

-- A post you put away stays on your page and leaves everyone else's.
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS put_away BOOLEAN NOT NULL DEFAULT FALSE;
GRANT UPDATE (put_away) ON public.posts TO authenticated;

-- Production's body (2026-09-13_followers_only_reads) plus two things: the author always sees
-- their own posts, and a put-away post is seen by nobody else, tags included. Every feed, page
-- and month read already goes through this.
CREATE OR REPLACE FUNCTION public.post_visible_to(p_viewer UUID, p_post_id UUID, p_author UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_viewer = p_author
        OR (NOT COALESCE((SELECT po.put_away FROM public.posts po WHERE po.id = p_post_id), FALSE)
            AND (public.can_see_posts_of(p_viewer, p_author)
                 OR EXISTS (SELECT 1 FROM public.post_tags t WHERE t.post_id = p_post_id AND t.tagged_user_id = p_viewer)));
$$;
REVOKE ALL ON FUNCTION public.post_visible_to(UUID, UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_visible_to(UUID, UUID, UUID) TO authenticated;

-- A month's box: its chosen cover. Readable by anyone who can see the owner's posts.
CREATE TABLE IF NOT EXISTS public.month_boxes (
    user_id        UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    month_start    DATE NOT NULL,
    cover_photo_id UUID REFERENCES public.photos(id) ON DELETE SET NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, month_start)
);
ALTER TABLE public.month_boxes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.month_boxes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.month_boxes TO authenticated;
DROP POLICY IF EXISTS "month_boxes: readable by friends" ON public.month_boxes;
CREATE POLICY "month_boxes: readable by friends"
    ON public.month_boxes FOR SELECT TO authenticated
    USING (public.can_see_posts_of(auth.uid(), user_id));
DROP POLICY IF EXISTS "month_boxes: own" ON public.month_boxes;
CREATE POLICY "month_boxes: own"
    ON public.month_boxes FOR ALL TO authenticated
    USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Each boxed month's chosen cover the caller may see: a cover that was put away, hidden or
-- blocked falls back to the month's own on the client.
CREATE OR REPLACE FUNCTION public.month_box_covers(p_user UUID)
RETURNS TABLE (month_start DATE, cover_path TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT b.month_start, COALESCE(po.thumb_path, po.feed_path, po.storage_path)
    FROM public.month_boxes b
    JOIN LATERAL (
        SELECT p.* FROM public.posts p
        WHERE p.photo_id = b.cover_photo_id AND p.user_id = b.user_id AND NOT p.hidden
        ORDER BY p.created_at DESC LIMIT 1
    ) po ON TRUE
    WHERE b.user_id = p_user
      AND auth.uid() IS NOT NULL
      AND NOT public.is_blocked_either_way(auth.uid(), p_user)
      AND public.post_visible_to(auth.uid(), po.id, po.user_id);
$$;
REVOKE ALL ON FUNCTION public.month_box_covers(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.month_box_covers(UUID) TO authenticated;
