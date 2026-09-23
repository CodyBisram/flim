-- Feed seen-marks land through a function instead of a plain upsert (2026-09-23).
--
-- post_seen.post_id references posts, so the client's 500-row upsert failed as a whole the
-- moment one mark was for a post deleted since, every flush, until that mark aged out a day
-- later; and the client's age rule then dropped every OTHER mark older than a day in the
-- batch too, permanently, so the server never learned those days were read and the feed
-- header counted them again after the next reload. This inserts only the ids that still
-- exist and answers with them; a mark for a post that is gone has nothing to land on and the
-- client settles it.
--
-- SECURITY INVOKER on purpose: "exists" means "exists for this viewer" under the posts
-- policy, which is the same policy feed_unseen_count() counts under, so a post the viewer
-- cannot see is neither counted nor recorded, and the two never disagree. The insert runs
-- under post_seen's own "record own" policy; user_id is auth.uid() and nothing else.
-- Data-modifying CTEs run exactly once whether or not the final SELECT reads them.
CREATE OR REPLACE FUNCTION public.record_posts_seen(p_post_ids uuid[], p_seen_at timestamptz[])
RETURNS uuid[]
LANGUAGE sql
SECURITY INVOKER
SET search_path = public
AS $$
    WITH input AS (
        SELECT t.id, t.seen_at
        FROM unnest(p_post_ids, p_seen_at) AS t(id, seen_at)
        WHERE t.id IS NOT NULL
    ),
    live AS (
        SELECT i.id, COALESCE(i.seen_at, now()) AS seen_at
        FROM input i
        WHERE EXISTS (SELECT 1 FROM public.posts p WHERE p.id = i.id)
    ),
    ins AS (
        INSERT INTO public.post_seen (user_id, post_id, seen_at)
        SELECT auth.uid(), l.id, l.seen_at FROM live l
        ON CONFLICT (user_id, post_id) DO NOTHING
        RETURNING post_id
    )
    SELECT COALESCE(array_agg(l.id), '{}'::uuid[]) FROM live l;
$$;
REVOKE ALL ON FUNCTION public.record_posts_seen(uuid[], timestamptz[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_posts_seen(uuid[], timestamptz[]) TO authenticated;
