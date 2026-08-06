-- ============================================================
-- Two unrelated one-liners, safe to run together, safe to re-run.
-- Paste into Supabase Dashboard -> SQL Editor.
-- ============================================================

-- 1. Cap what the photos bucket will accept -----------------------------------
--
-- Both limits are currently null: any authenticated user can upload a file of any
-- size and any type. Among 21 friends that is theoretical. At a public launch it is
-- a stranger using your bucket as a file host, on the plan where storage is already
-- the binding constraint.
--
-- 25 MB sits comfortably above a full-resolution capture (the largest object in the
-- bucket today is about 1.4 MB) while ruling out video and archives. The MIME list
-- is JPEG only, which is all the app ever writes: captures, renditions, avatars and
-- covers are encoded as JPEG on device before upload.
--
-- If a future feature needs another type, add it here rather than removing the list.

UPDATE storage.buckets
SET file_size_limit   = 26214400,            -- 25 MB
    allowed_mime_types = ARRAY['image/jpeg']
WHERE id = 'photos';


-- 2. Repair four broken Darkroom tiles ----------------------------------------
--
-- Four photographs from a six-second burst on 21 July have no original and no
-- thumbnail in storage — an interrupted upload months ago, not caused by any sweep
-- (the arithmetic and the keep rule both clear it; see the audit).
--
-- Their 1400px cards survive, so the photographs are not lost: they still render in
-- the reveal and the carousel, which ask for `view_path`. Only the Darkroom grid
-- breaks, because it asks for `thumb_path`, which is set and points at a file that
-- is gone.
--
-- Pointing thumb_path at the card that does exist replaces a broken tile with the
-- picture. Those four cells will pull 384 kB instead of 45 kB, which on four
-- photographs is nothing.
--
-- Scoped by id rather than by "any photo with a missing thumbnail", so it cannot
-- quietly rewrite rows this was not written for.

UPDATE public.photos
SET thumb_path = feed_path
WHERE feed_path IS NOT NULL
  AND id IN ('1d646680-b4bc-4922-a2f2-0bd12c166a7d',
             '34704340-237d-41cc-bed7-4b3cd862b3b9',
             '6dc9cef7-ebcd-4c6e-b33a-228e1b0cbd33',
             '2824fafa-45c4-4888-a727-4f36e388ad90');

-- Verify:
--   select id, thumb_path = feed_path as repaired from public.photos
--   where id in ('1d646680-b4bc-4922-a2f2-0bd12c166a7d',
--                '34704340-237d-41cc-bed7-4b3cd862b3b9',
--                '6dc9cef7-ebcd-4c6e-b33a-228e1b0cbd33',
--                '2824fafa-45c4-4888-a727-4f36e388ad90');
--
--   select id, file_size_limit, allowed_mime_types from storage.buckets;
