-- BALI26 (2026-09-17): the cohort code on the Bali promo card. 24 seats, one week, attributed
-- to the owner, so an arrival follows him and, on 1.5.4, lands on Find friends. 24 rather than
-- the 29 Founding spots left, the owner's number: the card says "Next cohort, 24 seats", and a
-- code that fills is the honest scarcity the Founding 100 badge already carries.
INSERT INTO public.invite_campaigns (code, inviter_id, valid_from, valid_until, max_uses, note)
VALUES ('BALI26',
        'f43287d4-f239-415b-af45-650bbee62e83',
        NOW(),
        timestamptz '2026-09-25 00:00 America/New_York',
        24,
        'Bali promo cohort, 2026-09-17 through 2026-09-24, 24 seats, attributed to the owner')
ON CONFLICT (code) DO NOTHING;
