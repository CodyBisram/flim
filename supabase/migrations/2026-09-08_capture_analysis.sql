-- Capture-time analysis, stored once so nothing downstream re-runs Vision on downloaded
-- thumbnails. Three columns on photos, written by the shooter's phone in the same insert that
-- already carries burst_group and sharpness (BurstDetector):
--
--   quality  the same 0..1 aesthetics-plus-faces score ChapterCuration used to compute per view,
--            per device, from a re-downloaded thumb. Now computed exactly once, at capture.
--   phash    a 64-bit difference hash of the graded frame. Two frames whose hashes differ in few
--            bits are near-duplicates; curation's diversity rule reads this instead of comparing
--            Vision feature prints it had to regenerate every time.
--   is_miss  the phone's verdict that the frame is a dead one: a lens-covered black frame or an
--            unrecoverable blur. Conservative on purpose. Hidden from chapter covers and from the
--            reveal's playback, still present in grids so nothing silently disappears.
--
-- All three are NULL/false for every photo taken before this shipped; every reader falls back to
-- what it did before when they are missing.

ALTER TABLE public.photos
    ADD COLUMN IF NOT EXISTS quality REAL NULL,
    ADD COLUMN IF NOT EXISTS phash   BIGINT NULL,
    ADD COLUMN IF NOT EXISTS is_miss BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.photos
    DROP CONSTRAINT IF EXISTS photos_quality_range,
    ADD CONSTRAINT photos_quality_range CHECK (quality IS NULL OR (quality >= 0 AND quality <= 1));

COMMENT ON COLUMN public.photos.quality IS 'Capture-time 0..1 aesthetics score (Vision aesthetics + face bonus), same formula ChapterCuration used per view; NULL before 2026-09-08.';
COMMENT ON COLUMN public.photos.phash   IS 'Capture-time 64-bit difference hash of the graded frame, signed bigint holding the raw bits; NULL before 2026-09-08.';
COMMENT ON COLUMN public.photos.is_miss IS 'Capture-time dead-frame verdict (black or unrecoverably blurred). Hidden from chapter covers and reveal playback.';

-- Chapter covers: best-scored posted photo of the month first, never a miss. Months from before
-- the score existed keep the old newest-first rule because every quality there is NULL.
CREATE OR REPLACE FUNCTION public.profile_chapters(p_profile_id UUID)
RETURNS TABLE (
    month_start   DATE,
    shot_count    INTEGER,
    roll_count    INTEGER,
    cover_paths   TEXT[],
    first_shot_at TIMESTAMPTZ,
    last_shot_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        SELECT p.id, po.taken_at, p.roll_id, p.quality, p.is_miss,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    ),
    bucketed AS (
        SELECT
            date_trunc('month', (taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS bucket_month,
            taken_at, roll_id, display_path, quality, is_miss
        FROM source
    ),
    ranked_covers AS (
        SELECT bucket_month, display_path,
               row_number() OVER (
                   PARTITION BY bucket_month
                   ORDER BY quality DESC NULLS LAST, taken_at DESC
               ) AS rn
        FROM bucketed
        WHERE NOT is_miss
    )
    SELECT
        b.bucket_month,
        count(*)::integer,
        count(DISTINCT b.roll_id) FILTER (WHERE b.roll_id IS NOT NULL)::integer,
        COALESCE(
            (SELECT array_agg(rc.display_path ORDER BY rc.rn)
             FROM ranked_covers rc
             WHERE rc.bucket_month = b.bucket_month AND rc.rn <= 4),
            ARRAY[]::text[]
        ),
        min(b.taken_at),
        max(b.taken_at)
    FROM bucketed b
    GROUP BY b.bucket_month
    ORDER BY b.bucket_month DESC;
$$;

REVOKE ALL ON FUNCTION public.profile_chapters(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_chapters(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_chapters(UUID) TO authenticated;

-- chapter_photos carries the stored analysis so curation can run without a single download.
-- Return type changes, so DROP then CREATE (CREATE OR REPLACE cannot alter RETURNS TABLE).
DROP FUNCTION IF EXISTS public.chapter_photos(UUID, DATE);

CREATE FUNCTION public.chapter_photos(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    id           UUID,
    taken_at     TIMESTAMPTZ,
    thumb_path   TEXT,
    feed_path    TEXT,
    storage_path TEXT,
    roll_id      UUID,
    roll_name    TEXT,
    post_id      UUID,
    quality      REAL,
    phash        BIGINT,
    sharpness    REAL,
    is_miss      BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        SELECT p.id, po.taken_at, po.thumb_path, po.feed_path, po.storage_path, p.roll_id,
               po.id AS post_id, p.quality, p.phash, p.sharpness, p.is_miss
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    )
    SELECT s.id, s.taken_at, s.thumb_path, s.feed_path, s.storage_path, s.roll_id, r.name, s.post_id,
           s.quality, s.phash, s.sharpness, s.is_miss
    FROM source s
    LEFT JOIN public.rolls r ON r.id = s.roll_id
    WHERE date_trunc('month', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ORDER BY s.taken_at ASC
    LIMIT 1000;
$$;

REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_photos(UUID, DATE) TO authenticated;
