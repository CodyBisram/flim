-- The admin's reported-photos card shows the photo and who reported it (2026-09-26). APPLIED to production 2026-09-26, verified as the owner.
--
-- Before this the card had the photographer's username, the latest reason and a time, and nothing
-- else: list_photo_reports() returned no path to draw and no reporter, and storage would not have
-- served the image anyway, because the owner can only read a post they could see as a person
-- (a follow, not hidden, no block). A photo two people reported is hidden by auto_hide_reported,
-- so exactly the photos that most need a look were the ones the owner could not open.
--
-- 1. list_photo_reports() keeps its seven columns, in order, and appends:
--      storage_path, thumb_path, feed_path  the photo's objects, for the admin to sign and draw
--      caption                              the newest post's caption, NULL when never posted
--      posted                               whether any post carries the photo
--      reporters                            every open report on the photo, oldest first, as
--                                           [{"username":text,"reason":text,"created_at":ts}]
--    The return shape grows, so DROP first. Still owner-only (is_owner()), still executable by
--    authenticated only. web/admin.html is its only caller.
--
-- 2. Storage policy "photos: owner reads reported": the owner, and only the owner, can read a
--    photo's objects while that photo has an open (unhandled) report. Dismissing the report ends
--    it. Hiding does not: a hidden photo stays viewable until its report is dismissed, which is
--    what reviewing it needs. The check is _owner_reviews_reported_object(name), SECURITY
--    DEFINER, because the owner's own session cannot see other people's reports or hidden photos.
--
-- 3. The owner check now refuses when there is no user at all (is_owner() IS NOT TRUE): the old
--    NOT is_owner() let a NULL through. Nothing reached that path in production (authenticated
--    callers always have a user id), but a function that lists who reported whom fails closed.
--
-- Safe to re-run: DROP ... IF EXISTS before every recreate. Reads only; no rows change.

DROP FUNCTION IF EXISTS public.list_photo_reports();
CREATE FUNCTION public.list_photo_reports()
RETURNS TABLE (
    report_id         UUID,
    photo_id          UUID,
    reason            TEXT,
    report_count      BIGINT,
    created_at        TIMESTAMPTZ,
    reported_username TEXT,
    hidden            BOOLEAN,
    storage_path      TEXT,
    thumb_path        TEXT,
    feed_path         TEXT,
    caption           TEXT,
    posted            BOOLEAN,
    reporters         JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF public.is_owner() IS NOT TRUE THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH counts AS (
        SELECT
            pr.photo_id,
            COUNT(DISTINCT pr.reporter_id) AS report_count,
            MIN(pr.created_at)             AS first_reported_at
        FROM public.photo_reports pr
        WHERE NOT pr.handled
        GROUP BY pr.photo_id
    ),
    latest AS (
        SELECT DISTINCT ON (pr.photo_id)
            pr.id, pr.photo_id, pr.reason
        FROM public.photo_reports pr
        WHERE NOT pr.handled
        ORDER BY pr.photo_id, pr.created_at DESC
    ),
    who AS (
        SELECT pr.photo_id,
               jsonb_agg(jsonb_build_object(
                   'username',   ru.username,
                   'reason',     pr.reason,
                   'created_at', pr.created_at
               ) ORDER BY pr.created_at ASC) AS reporters
        FROM public.photo_reports pr
        LEFT JOIN public.users ru ON ru.id = pr.reporter_id
        WHERE NOT pr.handled
        GROUP BY pr.photo_id
    )
    SELECT
        latest.id,
        latest.photo_id,
        latest.reason,
        counts.report_count,
        counts.first_reported_at,
        u.username,
        ph.hidden,
        ph.storage_path,
        ph.thumb_path,
        ph.feed_path,
        (SELECT po.caption FROM public.posts po
          WHERE po.photo_id = ph.id ORDER BY po.created_at DESC LIMIT 1),
        EXISTS (SELECT 1 FROM public.posts po WHERE po.photo_id = ph.id),
        who.reporters
    FROM latest
    JOIN counts             ON counts.photo_id = latest.photo_id
    JOIN who                ON who.photo_id = latest.photo_id
    JOIN public.photos ph   ON ph.id = latest.photo_id
    JOIN public.users  u    ON u.id = ph.user_id
    ORDER BY counts.first_reported_at ASC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_photo_reports() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_photo_reports() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_photo_reports() TO authenticated;

-- SECURITY DEFINER because the check reads photo_reports and photos, whose row policies would
-- hide other people's reports and hidden photos from the owner's own session. It answers FALSE
-- for anyone but the owner (and for no user at all), so the grant to authenticated reveals nothing.
CREATE OR REPLACE FUNCTION public._owner_reviews_reported_object(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT public.is_owner() IS TRUE
       AND EXISTS (
           SELECT 1
           FROM public.photos p
           JOIN public.photo_reports pr ON pr.photo_id = p.id AND NOT pr.handled
           WHERE p_name IN (p.storage_path, p.thumb_path, p.feed_path)
       );
$$;
REVOKE ALL ON FUNCTION public._owner_reviews_reported_object(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._owner_reviews_reported_object(TEXT) TO authenticated;

DROP POLICY IF EXISTS "photos: owner reads reported" ON storage.objects;
CREATE POLICY "photos: owner reads reported"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'photos'
        AND public._owner_reviews_reported_object(name)
    );
