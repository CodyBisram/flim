-- The owner's cohort code becomes FLIMGO (asked 2026-09-11 morning: something unique rather than
-- the date) and runs through the end of 2026-09-12 in New York. SEPT11 had zero uses. The code is
-- the primary key, so the row is replaced; idempotent, a second run finds no SEPT11 and inserts
-- nothing. Checked first that no personal or roll code is FLIMGO.
WITH gone AS (
    DELETE FROM public.invite_campaigns WHERE code = 'SEPT11' AND uses = 0 RETURNING inviter_id, valid_from
)
INSERT INTO public.invite_campaigns (code, inviter_id, valid_from, valid_until, max_uses, note)
SELECT 'FLIMGO', inviter_id, valid_from,
       timestamptz '2026-09-13 00:00 America/New_York',
       NULL, 'Cohort code, 2026-09-11 through 2026-09-12, attributed to the owner (was SEPT11)'
FROM gone
ON CONFLICT (code) DO NOTHING;
