-- ============================================================
-- Migration: burst grouping metadata on photos.
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
--
-- WHAT THESE TWO COLUMNS ARE
-- ----------------------------------------------------------------------
-- The app is gaining on-device burst detection at capture: when a shot is
-- taken within a few seconds of the shooter's previous shot into the same
-- roll (or the same personal stream) and looks the same by Vision feature
-- print, the phone assigns both shots the same burst_group id and records a
-- sharpness score for each. The reveal slideshow plays the sharpest photo of
-- each burst and the roll grid shows a burst as one stack. Both values are
-- computed entirely on device; nothing about the image itself leaves the
-- phone to produce them.
--   - burst_group: a UUID shared by every photo in the same detected burst.
--     NULL means "not part of a detected burst" (the overwhelming common
--     case, and the only state any photo has today).
--   - sharpness: a relative sharpness score in [0, 1] for this shot, used to
--     pick the one frame of a burst the reveal/grid show. NULL means "not
--     scored" (same population as burst_group IS NULL, but not enforced as
--     such -- a photo could theoretically be scored without ever joining a
--     burst).
--
-- WHY burst_group CAN BE UPDATED AFTER INSERT
-- ----------------------------------------------------------------------
-- Burst detection is pairwise and retroactive: the phone only learns a shot
-- was part of a burst once the SECOND frame arrives close enough in time and
-- similar enough by feature print to the first. The first frame's row is
-- already sitting in Postgres by then with burst_group NULL, so the client
-- must be able to go back and UPDATE that earlier row's burst_group once the
-- pairing is discovered. That is the only reason "photos: can update own"
-- needs to reach these columns -- and it already does, unconditionally, so
-- no policy or grant change is needed (see below).
--
-- GRANTS -- NOTHING TO WIDEN
-- ----------------------------------------------------------------------
-- Checked production before writing this: public.photos carries TABLE-WIDE
-- (not column-scoped) INSERT and UPDATE grants for `authenticated`, unlike
-- public.users, which enumerates columns. A fresh ALTER TABLE ... ADD COLUMN
-- is automatically covered by an existing table-wide grant -- there is no
-- column list to append these two names to. Authorization for both new
-- columns is therefore carried entirely by the existing row-level policies
-- below, unchanged by this migration:
--   * "photos: can insert own"  (FOR INSERT, auth.uid() = user_id)
--   * "photos: can update own"  (FOR UPDATE, USING/WITH CHECK auth.uid() = user_id)
-- Both already govern every column on the row, so a signed-in user can set
-- or change burst_group/sharpness only on their OWN photos, and can never
-- touch another user's row. Nothing here changes who can read a photo row;
-- every existing SELECT * carries the two new columns for free.
-- ============================================================

ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS burst_group UUID NULL;
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS sharpness REAL NULL;

ALTER TABLE public.photos
    DROP CONSTRAINT IF EXISTS photos_sharpness_range,
    ADD CONSTRAINT photos_sharpness_range
        CHECK (sharpness IS NULL OR (sharpness >= 0 AND sharpness <= 1));

-- Partial index: only burst members are ever looked up by burst_group (to
-- assemble a stack), and burst_group IS NULL is the overwhelming majority of
-- rows, so indexing only the non-NULL subset keeps this cheap forever.
CREATE INDEX IF NOT EXISTS photos_burst_group_idx
    ON public.photos (burst_group) WHERE burst_group IS NOT NULL;

-- ---- Verify -----------------------------------------------------------------
--
--   -- Columns and index exist:
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--     WHERE table_schema = 'public' AND table_name = 'photos'
--     AND column_name IN ('burst_group', 'sharpness');
--   SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'photos'
--     AND indexname = 'photos_burst_group_idx';
--
--   -- CHECK rejects out-of-range, accepts NULL/0/1 (run as any role that can
--   -- insert a photos row; rolls back the whole block either way):
--   BEGIN;
--     -- expect: ERROR, violates check constraint "photos_sharpness_range"
--     UPDATE public.photos SET sharpness = 1.5 WHERE false;
--   ROLLBACK;
-- ============================================================
