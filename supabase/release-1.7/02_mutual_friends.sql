-- FLIM 1.7, production step 2 of 2: friends by request. NOT additive.
--
-- A friend is someone you follow who follows you back; following someone who doesn't follow
-- you is asking to be friends, and until they do, neither sees the other's posts (tags aside).
-- Every existing one-way follow becomes a request (61 of 969 on 2026-11-13).
--
-- ORDER (owner, 2026-11-14): 1.7 live on the App Store, THEN app_release_gate.minimum_version
-- set to '1.7' so every 1.6 install must update, THEN this. 1.6 would show a Follow button that
-- no longer shows anyone's posts. Never before the minimum version is raised.
-- Already on FLIM Dev as section 1 of supabase/migrations-v2/2026-10-30.
-- THE SAME DAY IT IS APPLIED: append this file to supabase/schema.sql and move it into
-- supabase/migrations/ with the date, or a fresh bootstrap keeps the one-way can_see_posts_of
-- while production is mutual (nightly review, 2026-11-15).

CREATE OR REPLACE FUNCTION public.can_see_posts_of(p_viewer UUID, p_author UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_viewer IS NOT NULL AND (
        p_viewer = p_author
        OR (EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = p_viewer AND f.following_id = p_author)
            AND EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = p_author AND f.following_id = p_viewer))
    );
$$;
REVOKE ALL ON FUNCTION public.can_see_posts_of(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_see_posts_of(UUID, UUID) TO authenticated;
