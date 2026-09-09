-- The owner's one-day cohort moved from 2026-09-10 to 2026-09-11 (asked 2026-09-09, before the
-- SEPT10 window opened and with zero uses). The code is the primary key, so the row is replaced.
-- Idempotent: a second run finds no SEPT10 row and inserts nothing.
WITH gone AS (
    DELETE FROM public.invite_campaigns WHERE code = 'SEPT10' AND uses = 0 RETURNING inviter_id
)
INSERT INTO public.invite_campaigns (code, inviter_id, valid_from, valid_until, max_uses, note)
SELECT 'SEPT11', inviter_id,
       timestamptz '2026-09-11 00:00 America/New_York', timestamptz '2026-09-12 00:00 America/New_York',
       NULL, 'One-day cohort code, 2026-09-11, attributed to the owner (moved from 2026-09-10)'
FROM gone
ON CONFLICT (code) DO NOTHING;
