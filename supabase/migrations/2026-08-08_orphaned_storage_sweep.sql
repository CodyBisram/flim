-- ============================================================
-- Server-side sweep for orphaned objects in the `photos` bucket
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- Three client bugs were found today that can strand a Storage object
-- without ever writing the row that references it (upload succeeds, then
-- the app is killed / the network drops / the insert fails before the row
-- lands). One of them -- the app being killed between the Storage PUT and
-- the row insert -- cannot be fixed from the client at all: there is no
-- Swift-side hook that fires reliably on a kill. This gives that class of
-- bug a permanent backstop instead of chasing every way it can happen.
--
-- This migration only adds the READ side: a SECURITY DEFINER function that
-- finds candidate orphans. It does not delete anything itself, and it does
-- not touch storage.objects rows -- deleting storage.objects rows directly
-- would remove Supabase's metadata while leaving the underlying file in the
-- backing store, which makes the object permanently untrackable. Deletion
-- happens exclusively through the Storage HTTP API, from the
-- sweep-orphaned-storage Edge Function (supabase/functions/sweep-orphaned-storage).
-- ============================================================

-- ------------------------------------------------------------
-- Orphan definition: an object in bucket `photos` whose name appears in
-- NONE of the columns below. This list was built by querying
-- information_schema.columns for every text/character-varying column in
-- `public` (not just the obvious photo columns) and checking each one that
-- could plausibly hold a Storage object name. `profiles` was checked too --
-- it is a read-only view over `users` (avatar_path/cover_path come straight
-- from users), so it is not a separate source and is intentionally left out
-- to avoid double-counting, not because it was missed:
--
--   public.photos.storage_path, public.photos.thumb_path, public.photos.feed_path
--   public.posts.storage_path,  public.posts.thumb_path,  public.posts.feed_path
--   public.users.avatar_path,   public.users.cover_path
--   public.rolls.cover_path
--
-- Avatars, covers and roll covers live in the SAME `photos` bucket as
-- captures. An earlier draft of this sweep checked only photos+posts and
-- would have classified 12 live avatars/covers as orphans -- deleting them
-- would have destroyed six users' profile pictures. If a future migration
-- adds another column that can hold a `photos` object name, it MUST be
-- added to the UNION below or this function will start reporting (and,
-- outside the dry run, deleting) live files.
--
-- AND older than p_min_age_hours (default 48). Storage uploads land bytes
-- BEFORE the row referencing them is written, so a recent unreferenced
-- object is very likely a capture still in flight, not garbage.
--
-- p_max_rows is a sanity bound on the query result only (keeps a pathological
-- run from pulling an unbounded result set into memory); it is NOT the safety
-- cap. The real cap (500) is enforced in the Edge Function, which aborts
-- without deleting anything if the candidate count exceeds it.
-- ------------------------------------------------------------
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
    ORDER BY o.created_at ASC
    LIMIT p_max_rows;
$$;

-- Internal function: only the sweep Edge Function (service_role) has any
-- business calling this. It reads across photos/posts/users/rolls/storage.objects,
-- none of which a client should be able to enumerate wholesale, so it is
-- revoked from PUBLIC, anon and authenticated -- same pattern as the other
-- internal/trigger functions in schema.sql.
REVOKE ALL ON FUNCTION public.list_orphaned_photos_objects(INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_orphaned_photos_objects(INTEGER, INTEGER) FROM anon, authenticated;

-- Verify:
--   SELECT count(*), sum(size_bytes) FROM public.list_orphaned_photos_objects();
--   -- Should match the dry-run report from the sweep-orphaned-storage function.
