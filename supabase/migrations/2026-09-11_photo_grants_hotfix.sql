-- HOTFIX, 2026-09-11 evening. The write-boundary migration (2026-09-11_write_boundary.sql) granted
-- clients UPDATE on photos.is_sorted only, on the belief that the app changed nothing else. Wrong:
-- the shipped client (build 365) patches thumb_path and feed_path after uploading the renditions,
-- burst_group when a burst resolves, and is_developed when it notices a develop time has passed.
-- Every capture since the migration went live uploaded its renditions and then failed to link
-- them: 17 of 26 new photos had no thumbnail or feed path, against 7 of 674 before. Found by the
-- 2026-09-11 audit (finding 1), confirmed in production.
--
-- Fix: grant exactly the columns the shipped client writes, and make the path columns safe by a
-- trigger instead of by withholding the grant: a client may only ever point a photo at objects
-- in its own folder. That also closes the audit's finding 2 (a photo row referencing someone
-- else's object, then a post copying that path into the shared-post read policy). Rows written
-- by the server itself (no auth.uid()) are not checked; one seeded review-account row from August
-- points at the owner's folder and stays as it is.
GRANT UPDATE (is_sorted, thumb_path, feed_path, burst_group, is_developed) ON public.photos TO authenticated;

CREATE OR REPLACE FUNCTION public.lock_photo_paths_to_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_prefix TEXT := NEW.user_id::text || '/';
BEGIN
    IF auth.uid() IS NULL THEN RETURN NEW; END IF;
    IF (TG_OP = 'INSERT' OR NEW.storage_path IS DISTINCT FROM OLD.storage_path)
       AND NEW.storage_path NOT LIKE v_prefix || '%' THEN
        RAISE EXCEPTION 'storage_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    IF NEW.thumb_path IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.thumb_path IS DISTINCT FROM OLD.thumb_path)
       AND NEW.thumb_path NOT LIKE v_prefix || '%' THEN
        RAISE EXCEPTION 'thumb_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    IF NEW.feed_path IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.feed_path IS DISTINCT FROM OLD.feed_path)
       AND NEW.feed_path NOT LIKE v_prefix || '%' THEN
        RAISE EXCEPTION 'feed_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_photo_paths_to_owner() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lock_photo_paths_to_owner_trigger ON public.photos;
CREATE TRIGGER lock_photo_paths_to_owner_trigger
    BEFORE INSERT OR UPDATE ON public.photos
    FOR EACH ROW EXECUTE FUNCTION public.lock_photo_paths_to_owner();

-- Relink the captures the broken grant stranded: their renditions were uploaded under the
-- deterministic names, only the row patch failed. Only rows whose objects actually exist.
UPDATE public.photos p
SET thumb_path = replace(p.storage_path, '.jpg', '_thumb.jpg')
WHERE p.thumb_path IS NULL
  AND EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'photos' AND o.name = replace(p.storage_path, '.jpg', '_thumb.jpg'));
UPDATE public.photos p
SET feed_path = replace(p.storage_path, '.jpg', '_feed.jpg')
WHERE p.feed_path IS NULL
  AND EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'photos' AND o.name = replace(p.storage_path, '.jpg', '_feed.jpg'));
