-- Photo paths: one exact shape, not just the right prefix (security review, 2026-11-03).
--
-- lock_photo_paths_to_owner (2026-09-11) checked that a client-written path STARTS with the
-- writer's own folder: `storage_path LIKE '<uid>/%'`. A path like `<uid>/../<someone>/<photo>.jpg`
-- or `<uid>/../../auth/v1/admin/users` passes that check. Paths are read back by code holding the
-- service key, which bypasses every storage policy: send-social-push and send-daily-digest sign
-- `feed_path` for the push image, and the storage client does not encode the path, so the `..`
-- segments resolve against the API root. A client could have a push carry someone else's photo.
--
-- Now every client-written path must be exactly `<uid>/<name>.<jpg|jpeg|heic|png>`, the only
-- shape the app has ever written (PhotoService: `<uid>/<photo id>[_thumb|_feed].<ext>`). One `/`,
-- no `..`, no query string. Rows written by the server (no auth.uid()) are still not checked, as
-- before. posts take their paths from the photo (pin_post_paths, sync_post_paths_from_photo), so
-- this covers them too.
--
-- Only new writes are checked; existing rows are left as they are. Before applying, run the
-- check at the bottom: it lists existing rows that do not have this shape (expected: none).
CREATE OR REPLACE FUNCTION public.lock_photo_paths_to_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_shape TEXT := '^' || NEW.user_id::text || '/[A-Za-z0-9_-]+\.(jpe?g|heic|png)$';
BEGIN
    IF auth.uid() IS NULL THEN RETURN NEW; END IF;
    IF (TG_OP = 'INSERT' OR NEW.storage_path IS DISTINCT FROM OLD.storage_path)
       AND NEW.storage_path !~ v_shape THEN
        RAISE EXCEPTION 'storage_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    IF NEW.thumb_path IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.thumb_path IS DISTINCT FROM OLD.thumb_path)
       AND NEW.thumb_path !~ v_shape THEN
        RAISE EXCEPTION 'thumb_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    IF NEW.feed_path IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.feed_path IS DISTINCT FROM OLD.feed_path)
       AND NEW.feed_path !~ v_shape THEN
        RAISE EXCEPTION 'feed_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_photo_paths_to_owner() FROM PUBLIC, anon, authenticated;

-- The check (read-only; run it first):
-- SELECT id, user_id, storage_path, thumb_path, feed_path FROM public.photos
-- WHERE storage_path !~ ('^' || user_id::text || '/[A-Za-z0-9_-]+\.(jpe?g|heic|png)$')
--    OR (thumb_path IS NOT NULL AND thumb_path !~ ('^' || user_id::text || '/[A-Za-z0-9_-]+\.(jpe?g|heic|png)$'))
--    OR (feed_path  IS NOT NULL AND feed_path  !~ ('^' || user_id::text || '/[A-Za-z0-9_-]+\.(jpe?g|heic|png)$'));
