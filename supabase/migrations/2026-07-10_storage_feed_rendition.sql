-- ============================================================
-- Migration: storage read policies must cover feed_path renditions
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
--
-- Bug: the Jul 8 egress work added a ~1400px feed rendition (posts.feed_path /
-- photos.feed_path, uploaded as <id>_feed.jpg) that feed cards download — but
-- the storage SELECT policies still whitelisted only (storage_path, thumb_path).
-- Result: nobody could sign anyone ELSE's feed image (400 on createSignedURL);
-- authors were unaffected (own-folder policy), so it only surfaced cross-account
-- and only for posts created after Jul 8. Rule going forward: any new rendition
-- path column MUST be added to both IN lists below.
-- ============================================================

DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path))
    );

DROP POLICY IF EXISTS "photos: roll members can read shared" ON storage.objects;
CREATE POLICY "photos: roll members can read shared"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (
            SELECT 1 FROM public.photos p
            WHERE storage.objects.name IN (p.storage_path, p.thumb_path, p.feed_path)
              AND p.roll_id IS NOT NULL
              AND public.is_roll_member(p.roll_id)
        )
    );
