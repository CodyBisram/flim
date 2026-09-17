-- The feed header's count, from the server (2026-09-17). The client's ledger counted only the
-- posts it had loaded, so "5 shots from 1 friend" grew to 18 as pages arrived. This counts the
-- whole seven-day window in one query: posts by people you follow (posts RLS applies, this is
-- SECURITY INVOKER), not your own, minus the ones your account has reached (post_seen). The
-- client uploads any device-only marks before asking, so the two agree.
CREATE OR REPLACE FUNCTION public.feed_unseen_count()
RETURNS TABLE (shots BIGINT, friends BIGINT)
LANGUAGE sql
SECURITY INVOKER
STABLE
SET search_path = public
AS $$
    SELECT COUNT(*)::bigint, COUNT(DISTINCT p.user_id)::bigint
    FROM public.posts p
    WHERE p.user_id <> auth.uid()
      AND p.created_at > NOW() - INTERVAL '7 days'
      AND EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = auth.uid() AND f.following_id = p.user_id)
      AND NOT EXISTS (SELECT 1 FROM public.post_seen s WHERE s.user_id = auth.uid() AND s.post_id = p.id);
$$;
REVOKE ALL ON FUNCTION public.feed_unseen_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.feed_unseen_count() TO authenticated;
