-- Account deletion removes every byte, server side (2026-09-24, repository audit finding 1).
--
-- The client now calls delete_account() as its ONLY deletion step, so the server owns byte
-- removal end to end. Two gaps closed here:
--
-- (a) A roll cover could keep a deleted photo alive forever. rolls.cover_path is one of the
--     roll's own photos (lock_roll_cover_to_roll accepts any of its three renditions; the app
--     writes storage_path), but nothing cleared it when that photo went away. The object stayed
--     "referenced", so the orphan sweep never removed it, and every other member saw a broken
--     cover because the shared-read storage policy needs the photo row. That happened on an
--     ordinary photo delete and on account deletion (photos cascade from users) alike.
--
-- (b) A deleted account's objects waited behind the 48h age check and counted toward the
--     sweep's 500-object HARD_CAP, so any account with more than about 170 photos stopped the
--     whole daily sweep until someone ran it by hand. An object whose top-level folder is the id
--     of no current account is dead by construction: the account is gone, and the storage
--     insert policy only ever lets a signed-in user write under their own id, so nothing
--     legitimate can land there again.
-- ============================================================

-- ---------------------------------------------------------------------------
-- (a) Clear a roll cover when the photo it shows is deleted.
--
-- Exact equality on the deleted photo's own paths and nothing broader. The NOT EXISTS keeps a
-- cover that another surviving photo row still carries (a duplicate path should not exist,
-- since lock_photo_paths_to_owner pins paths to the owner's folder, but clearing a cover that
-- still resolves would be a visible regression for no gain). Runs as the definer because the
-- rolls touched belong to other people (the roll creator), who never granted the deleter
-- UPDATE on them; lock_roll_cover_to_roll lets a NULL through, so this write is not refused.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS rolls_cover_path_idx ON public.rolls (cover_path) WHERE cover_path IS NOT NULL;

CREATE OR REPLACE FUNCTION public.clear_roll_cover_on_photo_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.rolls r
    SET cover_path = NULL
    WHERE r.cover_path IS NOT NULL
      AND r.cover_path IN (OLD.storage_path, OLD.thumb_path, OLD.feed_path)
      AND NOT EXISTS (
          SELECT 1 FROM public.photos p
          WHERE p.storage_path = r.cover_path
             OR p.thumb_path   = r.cover_path
             OR p.feed_path    = r.cover_path
      );
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.clear_roll_cover_on_photo_delete() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS clear_roll_cover_on_photo_delete_trigger ON public.photos;
CREATE TRIGGER clear_roll_cover_on_photo_delete_trigger
    AFTER DELETE ON public.photos
    FOR EACH ROW EXECUTE FUNCTION public.clear_roll_cover_on_photo_delete();

-- ---------------------------------------------------------------------------
-- (b) Dead-owner objects: one definition, used by both sweep functions below.
--
-- Dead means ALL of:
--   * bucket `photos`, and the top-level folder is a lower-case uuid (the only shape the
--     insert policy can produce: it compares against auth.uid()::text). Anything else falls
--     through to the ordinary age-and-cap path, never to this one;
--   * that uuid is neither a public.users id NOR an auth.users id. auth.users is checked too
--     because public.users is written by the client at the end of onboarding, so a brand-new
--     account has an auth row, and can upload, before it has a profile row;
--   * the name is referenced by no path column (the same list list_orphaned_photos_objects
--     uses). Belt and braces: a referenced object is never removed by this path;
--   * public.users is not empty. A sanity stop: if the table ever read empty, every object in
--     the bucket would look dead.
-- No age threshold: a dead owner has no upload in flight. If a column that can hold a
-- `photos` object name is ever added, it MUST be added to BOTH unions in this file.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._dead_owner_photos_objects()
RETURNS TABLE (object_name TEXT, size_bytes BIGINT, created_at TIMESTAMPTZ)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH live_owners AS (
        SELECT id::text AS id FROM public.users
        UNION SELECT id::text FROM auth.users
    ),
    referenced AS (
        SELECT storage_path AS p FROM public.photos WHERE storage_path IS NOT NULL
        UNION SELECT thumb_path  FROM public.photos WHERE thumb_path  IS NOT NULL
        UNION SELECT feed_path   FROM public.photos WHERE feed_path   IS NOT NULL
        UNION SELECT storage_path FROM public.posts WHERE storage_path IS NOT NULL
        UNION SELECT thumb_path   FROM public.posts WHERE thumb_path   IS NOT NULL
        UNION SELECT feed_path    FROM public.posts WHERE feed_path    IS NOT NULL
        UNION SELECT avatar_path FROM public.users WHERE avatar_path IS NOT NULL
        UNION SELECT cover_path  FROM public.users WHERE cover_path  IS NOT NULL
        UNION SELECT cover_path  FROM public.rolls WHERE cover_path  IS NOT NULL
    )
    SELECT o.name, (o.metadata ->> 'size')::BIGINT, o.created_at
    FROM storage.objects o
    WHERE o.bucket_id = 'photos'
      AND EXISTS (SELECT 1 FROM public.users)
      AND split_part(o.name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      AND split_part(o.name, '/', 1) NOT IN (SELECT id FROM live_owners)
      AND o.name NOT IN (SELECT p FROM referenced);
$$;
REVOKE ALL ON FUNCTION public._dead_owner_photos_objects() FROM PUBLIC, anon, authenticated;

-- What the sweep deletes first, oldest first, bounded per run.
CREATE OR REPLACE FUNCTION public.list_dead_owner_photos_objects(
    p_max_rows INTEGER DEFAULT 5000
)
RETURNS TABLE (object_name TEXT, size_bytes BIGINT, created_at TIMESTAMPTZ)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT d.object_name, d.size_bytes, d.created_at
    FROM public._dead_owner_photos_objects() d
    ORDER BY d.created_at ASC
    LIMIT p_max_rows;
$$;
REVOKE ALL ON FUNCTION public.list_dead_owner_photos_objects(INTEGER) FROM PUBLIC, anon, authenticated;

-- The ordinary orphan list, now WITHOUT dead-owner objects, so they neither wait 48h nor count
-- toward the sweep's HARD_CAP. Same signature and return shape as before, so CREATE OR REPLACE
-- is enough and the currently deployed sweep keeps working until it is redeployed (in that
-- window dead-owner objects are simply held back, not lost).
CREATE OR REPLACE FUNCTION public.list_orphaned_photos_objects(
    p_min_age_hours INTEGER DEFAULT 48,
    p_max_rows      INTEGER DEFAULT 5000
)
RETURNS TABLE (
    object_name TEXT,
    size_bytes  BIGINT,
    created_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH referenced AS (
        SELECT storage_path AS p FROM public.photos WHERE storage_path IS NOT NULL
        UNION SELECT thumb_path  FROM public.photos WHERE thumb_path  IS NOT NULL
        UNION SELECT feed_path   FROM public.photos WHERE feed_path   IS NOT NULL
        UNION SELECT storage_path FROM public.posts WHERE storage_path IS NOT NULL
        UNION SELECT thumb_path   FROM public.posts WHERE thumb_path   IS NOT NULL
        UNION SELECT feed_path    FROM public.posts WHERE feed_path    IS NOT NULL
        UNION SELECT avatar_path FROM public.users WHERE avatar_path IS NOT NULL
        UNION SELECT cover_path  FROM public.users WHERE cover_path  IS NOT NULL
        UNION SELECT cover_path  FROM public.rolls WHERE cover_path  IS NOT NULL
    )
    SELECT o.name, (o.metadata ->> 'size')::BIGINT, o.created_at
    FROM storage.objects o
    WHERE o.bucket_id = 'photos'
      AND o.created_at < now() - make_interval(hours => p_min_age_hours)
      AND o.name NOT IN (SELECT p FROM referenced)
      AND o.name NOT IN (SELECT d.object_name FROM public._dead_owner_photos_objects() d)
    ORDER BY o.created_at ASC
    LIMIT p_max_rows;
$$;
REVOKE ALL ON FUNCTION public.list_orphaned_photos_objects(INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_orphaned_photos_objects(INTEGER, INTEGER) FROM anon, authenticated;
