-- SPOT26 (2026-09-26): the cohort code on the Instagram reel for Spotlight. Attributed to the
-- owner, so an arrival follows him and lands on Find friends, like BALI26. Unlimited uses: the
-- first arrivals take the Founding 100 seats still open, and anyone after that is free to join
-- while the code lasts. Open from when this runs through the end of the seventh day after it,
-- New York time, so running it on the day the reel posts gives the reel its first week.
-- NOT APPLIED: the owner runs it on the day the reel goes up.
--
-- SELECT from users rather than VALUES, so a fresh bootstrap (no owner row) inserts nothing.
-- A personal code or a roll code named SPOT26 would win over a campaign code at sign-up, so
-- this inserts nothing if either exists; the SELECT after it shows whether the row landed.
INSERT INTO public.invite_campaigns (code, inviter_id, valid_from, valid_until, max_uses, note)
SELECT 'SPOT26', u.id, NOW(),
       (((NOW() AT TIME ZONE 'America/New_York')::date + 8)::timestamp) AT TIME ZONE 'America/New_York',
       NULL,
       'Spotlight reel cohort (Instagram), seven days from posting, unlimited, attributed to the owner'
FROM public.users u
WHERE u.id = 'f43287d4-f239-415b-af45-650bbee62e83'
  AND NOT EXISTS (SELECT 1 FROM public.users WHERE UPPER(invite_code) = 'SPOT26')
  AND NOT EXISTS (SELECT 1 FROM public.rolls WHERE UPPER(invite_code) = 'SPOT26')
ON CONFLICT (code) DO NOTHING;

SELECT code, valid_from AT TIME ZONE 'America/New_York' AS opens_new_york,
       valid_until AT TIME ZONE 'America/New_York' AS closes_new_york, max_uses, uses
FROM public.invite_campaigns WHERE code = 'SPOT26';
