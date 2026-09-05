-- ============================================================
-- Migration: one-time cosmetic alignment of legacy photos.develops_at to
-- its roll's reveal_at, closing a sub-millisecond truncation artefact left
-- over from develops_at's original backfill.
--
-- DATA AUDIT (2026-09-05): 479 roll photos taken before 2026-09-04 have
-- develops_at off their roll's reveal_at by under one millisecond. Every
-- photo since 2026-09-04 is already exact. This is purely cosmetic:
-- - Every affected roll developed long ago -- is_developed is already true
--   for all of them, and develops_at <= now() was already true before and
--   after this update, so no visibility predicate anywhere in this schema
--   (chapter_photos/chapter_stats/profile_chapters included, all of which
--   filter on develops_at <= now()) changes its answer for a single row.
-- - No client cursor is mid-page on rolls this old; nothing paginating
--   right now can observe the value shift under it.
-- - The app's keyset cursor has used a millisecond-precision band on this
--   column since 2026-09-04 anyway, so even a cursor that somehow started
--   before this ran would tolerate the shift.
--
-- IDEMPOTENT: the WHERE clause only ever matches rows that are still off;
-- re-running this after it has already applied matches zero rows.
-- ============================================================

UPDATE public.photos p
SET develops_at = r.reveal_at
FROM public.rolls r
WHERE p.roll_id = r.id
  AND p.develops_at <> r.reveal_at;
