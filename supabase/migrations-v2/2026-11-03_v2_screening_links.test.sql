-- Scenario test for 2026-11-03_v2_screening_links.sql (rule 9). One transaction, rolled back:
-- nothing persists. Every row of the final result should read ok = true. FLIM Dev only.
-- B shares first, A is in the roll too (and gets B's link), C is a stranger with a print left in
-- the roll, D is in the roll and has blocked A.
BEGIN;
CREATE TEMP TABLE results (step TEXT, ok BOOLEAN) ON COMMIT DROP;
CREATE TEMP TABLE kept (k TEXT PRIMARY KEY, v TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON results TO authenticated, service_role;
GRANT INSERT, SELECT, UPDATE ON kept TO authenticated, service_role;
INSERT INTO public.allowed_emails (email, note) VALUES
 ('sa@test.invalid','rolled back'),('sb@test.invalid','rolled back'),('sc@test.invalid','rolled back'),('sd@test.invalid','rolled back');
INSERT INTO auth.users (id, aud, role, email, instance_id) VALUES
 ('00000000-0000-0000-0000-0000000005a1','authenticated','authenticated','sa@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-0000000005b2','authenticated','authenticated','sb@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-0000000005c3','authenticated','authenticated','sc@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-0000000005d4','authenticated','authenticated','sd@test.invalid','00000000-0000-0000-0000-000000000000');
INSERT INTO public.users (id, username) VALUES
 ('00000000-0000-0000-0000-0000000005a1','screena'),('00000000-0000-0000-0000-0000000005b2','screenb'),
 ('00000000-0000-0000-0000-0000000005c3','screenc'),('00000000-0000-0000-0000-0000000005d4','screend')
 ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username;
-- R developed an hour ago; Q still developing.
INSERT INTO public.rolls (id, name, invite_code, created_by, created_at, reveal_at) VALUES
 ('00000000-0000-0000-0000-000000000501','Lake weekend','SCRN01','00000000-0000-0000-0000-0000000005a1', now() - interval '13 hours', now() - interval '1 hour'),
 ('00000000-0000-0000-0000-000000000502','Not yet','SCRN02','00000000-0000-0000-0000-0000000005a1', now(), now() + interval '12 hours');
INSERT INTO public.roll_members (roll_id, user_id) VALUES
 ('00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005a1'),
 ('00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005b2'),
 ('00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005d4'),
 ('00000000-0000-0000-0000-000000000502','00000000-0000-0000-0000-0000000005a1')
 ON CONFLICT DO NOTHING;
-- Roll prints: A's, B's, B's hidden one, B's dead frame, D's (D blocked A), B's with a path
-- pointing out of B's folder, B's with no feed rendition, C's (C is not in the roll).
-- Written as the server (no auth.uid()), so the path lock does not stop the bad path: the read
-- must drop it on its own.
INSERT INTO public.photos (id, user_id, roll_id, storage_path, feed_path, taken_at, develops_at, hidden, is_miss) VALUES
 ('00000000-0000-0000-0000-0000000005f1','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005a1/r1.heic','00000000-0000-0000-0000-0000000005a1/r1_feed.jpg', now() - interval '5 hours', now() - interval '1 hour', false, false),
 ('00000000-0000-0000-0000-0000000005f2','00000000-0000-0000-0000-0000000005b2','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005b2/r2.heic','00000000-0000-0000-0000-0000000005b2/r2_feed.jpg', now() - interval '4 hours', now() - interval '1 hour', false, false),
 ('00000000-0000-0000-0000-0000000005f3','00000000-0000-0000-0000-0000000005b2','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005b2/r3.heic','00000000-0000-0000-0000-0000000005b2/r3_feed.jpg', now() - interval '3 hours', now() - interval '1 hour', true, false),
 ('00000000-0000-0000-0000-0000000005f4','00000000-0000-0000-0000-0000000005b2','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005b2/r4.heic','00000000-0000-0000-0000-0000000005b2/r4_feed.jpg', now() - interval '2 hours', now() - interval '1 hour', false, true),
 ('00000000-0000-0000-0000-0000000005f5','00000000-0000-0000-0000-0000000005d4','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005d4/r5.heic','00000000-0000-0000-0000-0000000005d4/r5_feed.jpg', now() - interval '2 hours', now() - interval '1 hour', false, false),
 ('00000000-0000-0000-0000-0000000005f6','00000000-0000-0000-0000-0000000005b2','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005b2/r6.heic','00000000-0000-0000-0000-0000000005b2/../../auth/v1/admin/users', now() - interval '90 minutes', now() - interval '1 hour', false, false),
 ('00000000-0000-0000-0000-0000000005f7','00000000-0000-0000-0000-0000000005b2','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005b2/r7.heic', NULL, now() - interval '80 minutes', now() - interval '1 hour', false, false),
 ('00000000-0000-0000-0000-0000000005f8','00000000-0000-0000-0000-0000000005c3','00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-0000000005c3/r8.heic','00000000-0000-0000-0000-0000000005c3/r8_feed.jpg', now() - interval '70 minutes', now() - interval '1 hour', false, false);
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES ('00000000-0000-0000-0000-0000000005d4','00000000-0000-0000-0000-0000000005a1');
-- A's month: one out, one put away, one hidden, and a post of B's roll photo (not A's own).
INSERT INTO public.photos (id, user_id, storage_path, feed_path, taken_at, develops_at) VALUES
 ('00000000-0000-0000-0000-0000000005e1','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005a1/m1.heic','00000000-0000-0000-0000-0000000005a1/m1_feed.jpg', date_trunc('month', now()) + interval '1 day', now()),
 ('00000000-0000-0000-0000-0000000005e2','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005a1/m2.heic','00000000-0000-0000-0000-0000000005a1/m2_feed.jpg', date_trunc('month', now()) + interval '2 days', now()),
 ('00000000-0000-0000-0000-0000000005e3','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005a1/m3.heic','00000000-0000-0000-0000-0000000005a1/m3_feed.jpg', date_trunc('month', now()) + interval '3 days', now());
INSERT INTO public.posts (id, user_id, photo_id, storage_path, feed_path, taken_at, put_away, hidden) VALUES
 ('00000000-0000-0000-0000-0000000005d1','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005e1','00000000-0000-0000-0000-0000000005a1/m1.heic','00000000-0000-0000-0000-0000000005a1/m1_feed.jpg', date_trunc('month', now()) + interval '1 day', false, false),
 ('00000000-0000-0000-0000-0000000005d2','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005e2','00000000-0000-0000-0000-0000000005a1/m2.heic','00000000-0000-0000-0000-0000000005a1/m2_feed.jpg', date_trunc('month', now()) + interval '2 days', true, false),
 ('00000000-0000-0000-0000-0000000005d3','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005e3','00000000-0000-0000-0000-0000000005a1/m3.heic','00000000-0000-0000-0000-0000000005a1/m3_feed.jpg', date_trunc('month', now()) + interval '3 days', false, true),
 ('00000000-0000-0000-0000-0000000005d5','00000000-0000-0000-0000-0000000005a1','00000000-0000-0000-0000-0000000005f2','00000000-0000-0000-0000-0000000005b2/r2.heic','00000000-0000-0000-0000-0000000005b2/r2_feed.jpg', date_trunc('month', now()) + interval '4 days', false, false);

SET LOCAL ROLE authenticated;
-- As C, a stranger to the roll.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005c3","role":"authenticated"}', true);
DO $$ BEGIN
  PERFORM public.screening_link_open('00000000-0000-0000-0000-000000000501', NULL);
  INSERT INTO results VALUES ('stranger cannot share a roll', false);
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO results VALUES ('stranger cannot share a roll', true); END $$;
INSERT INTO results SELECT 'stranger sees no link status', NOT EXISTS (SELECT 1 FROM public.screening_link_status('00000000-0000-0000-0000-000000000501', NULL));
DO $$ BEGIN
  PERFORM public.screening_link_stop('00000000-0000-0000-0000-000000000501', NULL);
  INSERT INTO results VALUES ('stranger cannot stop a roll''s link', false);
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO results VALUES ('stranger cannot stop a roll''s link', true); END $$;
DO $$ BEGIN
  PERFORM count(*) FROM public.screening_links;
  INSERT INTO results VALUES ('the table is unreadable to the app', false);
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO results VALUES ('the table is unreadable to the app', true); END $$;
DO $$ BEGIN
  PERFORM public.screening_by_token('AAAAAAAAAAAAAAAAAAAAAAAA');
  INSERT INTO results VALUES ('the public read is not callable by the app', false);
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO results VALUES ('the public read is not callable by the app', true); END $$;

-- As A: an undeveloped roll cannot be shared.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005a1","role":"authenticated"}', true);
DO $$ BEGIN
  PERFORM public.screening_link_open('00000000-0000-0000-0000-000000000502', NULL);
  INSERT INTO results VALUES ('a roll still developing cannot be shared', false);
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO results VALUES ('a roll still developing cannot be shared', true); END $$;
-- As B: shares the developed roll first.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005b2","role":"authenticated"}', true);
INSERT INTO kept SELECT 'roll', token FROM public.screening_link_open('00000000-0000-0000-0000-000000000501', NULL);
INSERT INTO results SELECT 'the token is 24 url-safe characters', (SELECT v ~ '^[A-Za-z0-9_-]{24}$' FROM kept WHERE k = 'roll');
INSERT INTO results SELECT 'it runs seven days',
  (SELECT expires_at BETWEEN now() + interval '6 days 23 hours' AND now() + interval '7 days 1 minute'
   FROM public.screening_link_status('00000000-0000-0000-0000-000000000501', NULL));
INSERT INTO results SELECT 'sharing again returns the same link',
  (SELECT token FROM public.screening_link_open('00000000-0000-0000-0000-000000000501', NULL)) = (SELECT v FROM kept WHERE k = 'roll');

-- As A: the same link, not A's own.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005a1","role":"authenticated"}', true);
INSERT INTO results SELECT 'another member gets the one live link, marked not theirs',
  (SELECT token = (SELECT v FROM kept WHERE k = 'roll') AND NOT shared_by_me
   FROM public.screening_link_open('00000000-0000-0000-0000-000000000501', NULL));

-- The public read (the edge function's role).
RESET ROLE;
SET LOCAL ROLE service_role;
INSERT INTO kept SELECT 'read', public.screening_by_token((SELECT v FROM kept WHERE k = 'roll'))::text;
INSERT INTO results SELECT 'the read names the roll', (SELECT (v::jsonb)->>'title' = 'Lake weekend' AND (v::jsonb)->>'kind' = 'roll' FROM kept WHERE k = 'read');
-- D blocked A, and every member holds the same link: D could open it and see A's prints, A
-- could see D's. So neither plays; B's one good print does.
INSERT INTO results SELECT 'it plays B''s one good print only',
  (SELECT jsonb_array_length((v::jsonb)->'prints') = 1 FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'only feed renditions, in the author''s own folder',
  (SELECT (v::jsonb)->'prints'->0->>'path' = '00000000-0000-0000-0000-0000000005b2/r2_feed.jpg' FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'a block between two members leaves both of their prints out',
  (SELECT v !~ 'r1_feed' AND v !~ 'r5_feed' FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'a path pointing out of its folder never leaves the read', (SELECT v !~ '\.\.' FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'a print by someone not in the roll is left out', (SELECT v !~ 'r8_feed' FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'a count of the people whose prints play', (SELECT ((v::jsonb)->>'people')::int = 1 FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'no ids or handles in the read',
  (SELECT v !~ 'screen[abcd]' AND v !~ 'Id"' AND v !~ '"(user|author|by)' FROM kept WHERE k = 'read');
INSERT INTO results SELECT 'a malformed token reads nothing', public.screening_by_token('../../etc') IS NULL;
INSERT INTO results SELECT 'an unknown token reads nothing', public.screening_by_token('AAAAAAAAAAAAAAAAAAAAAAAA') IS NULL;
RESET ROLE;

-- B stops it: it ends for everyone.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005b2","role":"authenticated"}', true);
INSERT INTO results SELECT 'any member can stop the roll''s link', public.screening_link_stop('00000000-0000-0000-0000-000000000501', NULL) = 1;
INSERT INTO results SELECT 'stopped: no live link', NOT EXISTS (SELECT 1 FROM public.screening_link_status('00000000-0000-0000-0000-000000000501', NULL));
RESET ROLE;
SET LOCAL ROLE service_role;
INSERT INTO results SELECT 'stopped: the read is gone', public.screening_by_token((SELECT v FROM kept WHERE k = 'roll')) IS NULL;
RESET ROLE;

-- A shares again (a new token), then leaves the roll: A's link ends with A's membership.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005a1","role":"authenticated"}', true);
INSERT INTO kept SELECT 'roll2', token FROM public.screening_link_open('00000000-0000-0000-0000-000000000501', NULL);
INSERT INTO results SELECT 'sharing after a stop makes a new token', (SELECT v FROM kept WHERE k = 'roll2') <> (SELECT v FROM kept WHERE k = 'roll');
RESET ROLE;
DELETE FROM public.roll_members WHERE roll_id = '00000000-0000-0000-0000-000000000501' AND user_id = '00000000-0000-0000-0000-0000000005a1';
SET LOCAL ROLE service_role;
INSERT INTO results SELECT 'a sharer who leaves the roll ends their link', public.screening_by_token((SELECT v FROM kept WHERE k = 'roll2')) IS NULL;
RESET ROLE;

-- A's month.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005a1","role":"authenticated"}', true);
DO $$ BEGIN
  PERFORM public.screening_link_open(NULL, (date_trunc('month', now()) + interval '3 days')::date);
  INSERT INTO results VALUES ('a month is named by its first day', false);
EXCEPTION WHEN insufficient_privilege THEN INSERT INTO results VALUES ('a month is named by its first day', true); END $$;
INSERT INTO kept SELECT 'month', token FROM public.screening_link_open(NULL, date_trunc('month', now())::date, 'UTC');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005b2","role":"authenticated"}', true);
INSERT INTO results SELECT 'someone else sees no link for A''s month',
  NOT EXISTS (SELECT 1 FROM public.screening_link_status(NULL, date_trunc('month', now())::date));
INSERT INTO results SELECT 'someone else cannot stop A''s month', public.screening_link_stop(NULL, date_trunc('month', now())::date) = 0;
RESET ROLE;
SET LOCAL ROLE service_role;
INSERT INTO kept SELECT 'mread', public.screening_by_token((SELECT v FROM kept WHERE k = 'month'))::text;
INSERT INTO results SELECT 'the month plays only A''s own, out prints (not put away, hidden or a roll-mate''s)',
  (SELECT jsonb_array_length((v::jsonb)->'prints') = 1 AND (v::jsonb)->'prints'->0->>'path' = '00000000-0000-0000-0000-0000000005a1/m1_feed.jpg' FROM kept WHERE k = 'mread');
RESET ROLE;
-- Seven days pass.
UPDATE public.screening_links SET expires_at = now() - interval '1 second' WHERE token = (SELECT v FROM kept WHERE k = 'month');
SET LOCAL ROLE service_role;
INSERT INTO results SELECT 'an expired link reads nothing', public.screening_by_token((SELECT v FROM kept WHERE k = 'month')) IS NULL;
RESET ROLE;

-- The minting ceiling: thirty a day.
INSERT INTO public.screening_links (token, created_by, month_start, expires_at, stopped_at)
SELECT 'ceiling' || lpad(g::text, 17, '0'), '00000000-0000-0000-0000-0000000005a1', date_trunc('month', now())::date, now() + interval '7 days', now()
FROM generate_series(1, 30) g;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000005a1","role":"authenticated"}', true);
DO $$ BEGIN
  PERFORM public.screening_link_open(NULL, date_trunc('month', now())::date);
  INSERT INTO results VALUES ('thirty new links a day, then no more', false);
EXCEPTION WHEN program_limit_exceeded THEN INSERT INTO results VALUES ('thirty new links a day, then no more', true); END $$;
RESET ROLE;

SELECT json_agg(r) FROM results r;
ROLLBACK;
