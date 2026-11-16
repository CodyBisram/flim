-- FLIM 1.7, production step 1b: the nightly review's fixes to step 1 (2026-11-15).
-- APPLIED to production 2026-11-15 (from supabase/release-1.7/03_review_fixes.sql). ADDITIVE and
-- safe for 1.6: it only reads put_away, which nothing sets before 1.7, and narrows a cover read
-- only 1.7 makes. Apply any time; step 1 (01_month_boxes.sql) is already on production.
-- Then append to supabase/schema.sql and move into supabase/migrations/ with the date applied.

-- 1. A put-away post leaves Spotlight too. "Put-away shots stay yours" held everywhere except the
--    Spotlight read path: the posts and storage policies OR in spotlight_post_public, which never
--    read put_away, so a chosen frame put away later stayed readable by every signed-in user.
--    Production's body (2026-09-25_spotlight_hardening) plus the put_away test on the published
--    branch; the owner's own review branch is unchanged.
CREATE OR REPLACE FUNCTION public.spotlight_post_public(p_post_id UUID, p_viewer UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_viewer IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.spotlight_entries e
        WHERE e.post_id = p_post_id
          AND e.removed_at IS NULL
          AND (
                (e.chosen_at IS NOT NULL
                 AND NOT COALESCE((SELECT po.put_away FROM public.posts po WHERE po.id = e.post_id), FALSE)
                 AND EXISTS (SELECT 1 FROM public.spotlight_weeks w
                             WHERE w.week_key = e.week_key AND w.published_at IS NOT NULL))
             OR (p_viewer = auth.uid() AND public.is_owner(p_viewer))
          )
    );
$$;
REVOKE ALL ON FUNCTION public.spotlight_post_public(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spotlight_post_public(UUID, UUID) TO authenticated;

--    And the strip, the past weeks and a person's shelf skip it for everyone but its author.
--    Production's body (schema.sql's last definition) plus that one line.
CREATE OR REPLACE FUNCTION public._spotlight_weeks_for(p_user_id UUID, p_before DATE, p_limit INT)
RETURNS TABLE (week_key DATE, published_at TIMESTAMPTZ, frames JSONB)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT w.week_key, w.published_at, f.frames
    FROM public.spotlight_weeks w
    CROSS JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object(
                   'post_id',         e.post_id,
                   'photo_id',        po.photo_id,
                   'user_id',         e.user_id,
                   'username',        u.username,
                   'display_name',    u.display_name,
                   'avatar_path',     u.avatar_path,
                   'thumb_path',      po.thumb_path,
                   'feed_path',       po.feed_path,
                   'storage_path',    po.storage_path,
                   'post_created_at', po.created_at,
                   'chosen_at',       e.chosen_at
               ) ORDER BY e.chosen_at, e.post_id) AS frames
        FROM public.spotlight_entries e
        JOIN public.posts po ON po.id = e.post_id
        JOIN public.users u ON u.id = e.user_id
        WHERE e.week_key = w.week_key
          AND e.chosen_at IS NOT NULL
          AND e.removed_at IS NULL
          AND (p_user_id IS NULL OR e.user_id = p_user_id)
          AND NOT po.hidden
          AND (NOT po.put_away OR po.user_id = auth.uid())
          AND NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = po.photo_id AND ph.hidden)
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    ) f
    WHERE auth.uid() IS NOT NULL
      AND w.published_at IS NOT NULL
      AND (p_before IS NULL OR w.week_key < p_before)
      AND f.frames IS NOT NULL
    ORDER BY w.week_key DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 52);
$$;
REVOKE ALL ON FUNCTION public._spotlight_weeks_for(UUID, DATE, INT) FROM PUBLIC, anon, authenticated;

-- 2. A box's chosen cover, only when the caller may actually see its post, covered windows
--    included: it skipped covered_post_visible, handing a covered post's path to a friend the
--    storage policy then refused. (One post per person per photo, posts_user_id_photo_id_key, so
--    the lateral finds at most one row.)
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
          AND public.post_visible_to(auth.uid(), p.id, p.user_id)
          AND public.covered_post_visible(auth.uid(), p.user_id, p.created_at)
        ORDER BY p.created_at DESC LIMIT 1
    ) po ON TRUE
    WHERE b.user_id = p_user
      AND auth.uid() IS NOT NULL
      AND NOT public.is_blocked_either_way(auth.uid(), p_user);
$$;
REVOKE ALL ON FUNCTION public.month_box_covers(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.month_box_covers(UUID) TO authenticated;
