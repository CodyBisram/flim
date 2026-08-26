-- ============================================================
-- Migration: index hygiene, from the 2026-08-26 database audit.
-- Four items, all additive except one deliberate index REPLACEMENT
-- whose predecessor becomes a strict prefix-subset (see item 1).
-- Idempotent; safe to re-run.
--
-- 1. THE PERSONAL-PHOTOS COMPOSITE. Every hot personal query filters
--    user_id AND is_sorted and orders taken_at DESC, id DESC (the
--    keyset), but photos_user_idx only covers (user_id, taken_at DESC):
--    is_sorted is filtered row-by-row after the index, and the keyset's
--    id tiebreak has no index backing. The new composite serves
--    fetchPersonalPhotos (both variants), fetchDarkroom, fetchUnsorted,
--    personalPhotoCount, AND the initial scan of darkroom_month_counts /
--    darkroom_month_summary. photos_user_idx then duplicates a prefix of
--    it and is dropped so photo writes do not pay for two indexes where
--    one serves.
--
-- 2. THE MISSING push_sent PARTIAL on photos. Every other push-scanned
--    table (post_tags, follows, photo_reactions, post_comments,
--    photo_comments, comment_likes, photo_reports, user_reports) carries
--    a WHERE flag = FALSE partial index for its cron scan; photos, the
--    largest table, scanned every 5 minutes by send-develop-push, is the
--    one that does not. Same pattern, overdue.
--
-- 3. post_reactions.push_sent DRIFT FIX. send-social-push reads and
--    writes this column in production, but no migration and no
--    schema.sql statement creates it: a fresh environment built from the
--    repo would break the reaction-push path. ADD COLUMN IF NOT EXISTS
--    restores repo/production parity (a no-op in production, where the
--    column already exists), and the partial index matches its siblings.
--
-- 4. THE UNDEVELOPED PARTIAL. mark_developed_photos() flips
--    is_developed with no index support: a sequential scan of photos on
--    every run. The partial keeps that scan bounded to the (small) set
--    of still-developing rows.
--    OWNER STEP, separate from this paste: the cron schedule for
--    mark_developed_photos is not tracked anywhere in the repo. Check
--    Dashboard -> Database -> Cron Jobs for its cadence and record it in
--    the next migration touching crons.
-- ============================================================

-- 1. Personal-photos composite, then retire the redundant prefix index.
CREATE INDEX IF NOT EXISTS photos_user_sorted_taken_idx
    ON public.photos (user_id, is_sorted, taken_at DESC, id DESC);
DROP INDEX IF EXISTS public.photos_user_idx;

-- 2. The develop-push cron's scan.
CREATE INDEX IF NOT EXISTS photos_unpushed_develop_idx
    ON public.photos (push_sent) WHERE push_sent = FALSE;

-- 3. Repo/production drift fix + the sibling-pattern partial.
ALTER TABLE public.post_reactions
    ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS post_reactions_unpushed_idx
    ON public.post_reactions (push_sent) WHERE push_sent = FALSE;

-- 4. The developed-flag flip's scan.
CREATE INDEX IF NOT EXISTS photos_undeveloped_idx
    ON public.photos (develops_at) WHERE is_developed = FALSE;
