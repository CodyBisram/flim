-- FLIM v2: the chosen covers on a page's shelf of months. Additive. FLIM Dev only for now.
-- Returns each boxed month's chosen cover as a path the caller may load: the cover's post must be
-- visible to the caller (post_visible_to, so a put-away cover never shows to a visitor; their
-- shelf falls back to the month's own cover).
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
