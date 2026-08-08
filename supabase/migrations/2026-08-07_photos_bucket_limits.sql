-- Pin the photos bucket's upload constraints to what production actually enforces.
--
-- Two things are set here:
--
-- 1. allowed_mime_types stays JPEG-only. HEIC was trialled on 2026-08-07 to cut
--    storage and egress, and measured against the look-regression pin. It failed:
--    localContrast (our grain) dropped on 11 of 11 fixtures, by up to 3.9x the
--    pin's 0.001 tolerance, worst in the dark scenes. A quality sweep from 0.80 to
--    1.00 found no setting that clears the pin while saving bytes, because HEIC
--    only stops undercutting JPEG around q0.90 and at q0.90 just 2 of 11 fixtures
--    pass. Do not widen this without re-running that sweep.
--
-- 2. file_size_limit is stated explicitly. Production has had a 25 MB cap since
--    2026-08-06, but it was set by hand and never mirrored into schema.sql, so a
--    fresh project would come up with no cap at all.
--
-- Idempotent, and safe to re-run.
UPDATE storage.buckets
SET allowed_mime_types = ARRAY['image/jpeg'],
    file_size_limit = 26214400   -- 25 MB
WHERE id = 'photos';
