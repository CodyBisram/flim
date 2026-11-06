-- Scenario test for 2026-11-06_v2_invited_requests.sql. One transaction, rolled back: nothing
-- persists. Every row of the final result should read ok = true. FLIM Dev only.
-- A invited B with A's own code; C came in some other way; E was let in by someone else's code.
-- B, C and E all follow A (asking to be friends).
BEGIN;
CREATE TEMP TABLE results (step TEXT, ok BOOLEAN) ON COMMIT DROP;
GRANT INSERT, SELECT ON results TO authenticated, service_role;
INSERT INTO public.allowed_emails (email, note, via) VALUES
 ('ia@test.invalid','rolled back', NULL),
 ('ib@test.invalid','invited_by:00000000-0000-0000-0000-0000000006a1','personal'),
 ('ic@test.invalid','rolled back', NULL),
 ('ie@test.invalid','invited_by:00000000-0000-0000-0000-0000000006c3','personal');
INSERT INTO auth.users (id, aud, role, email, instance_id) VALUES
 ('00000000-0000-0000-0000-0000000006a1','authenticated','authenticated','ia@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-0000000006b2','authenticated','authenticated','ib@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-0000000006c3','authenticated','authenticated','ic@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-0000000006e5','authenticated','authenticated','ie@test.invalid','00000000-0000-0000-0000-000000000000');
INSERT INTO public.users (id, username, email) VALUES
 ('00000000-0000-0000-0000-0000000006a1','inva','ia@test.invalid'),('00000000-0000-0000-0000-0000000006b2','invb','IB@test.invalid'),
 ('00000000-0000-0000-0000-0000000006c3','invc','ic@test.invalid'),('00000000-0000-0000-0000-0000000006e5','inve','ie@test.invalid')
 ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username, email = EXCLUDED.email;
-- B asked first, then C, then E: newest-first alone would put E and C above B.
INSERT INTO public.follows (follower_id, following_id, created_at, push_sent) VALUES
 ('00000000-0000-0000-0000-0000000006b2','00000000-0000-0000-0000-0000000006a1', now() - interval '3 hours', true),
 ('00000000-0000-0000-0000-0000000006c3','00000000-0000-0000-0000-0000000006a1', now() - interval '2 hours', true),
 ('00000000-0000-0000-0000-0000000006e5','00000000-0000-0000-0000-0000000006a1', now() - interval '1 hour', true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000006a1","role":"authenticated"}', true);
INSERT INTO results SELECT 'A sees three requests', (SELECT count(*) FROM public.friend_requests()) = 3;
INSERT INTO results SELECT 'B, whom A invited, is flagged (email case ignored)',
  (SELECT invited_by_me FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-0000000006b2');
INSERT INTO results SELECT 'C, no invite, is not',
  NOT (SELECT invited_by_me FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-0000000006c3');
INSERT INTO results SELECT 'E, invited by someone else, is not',
  NOT (SELECT invited_by_me FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-0000000006e5');
INSERT INTO results SELECT 'the invited one sits first, then newest first',
  (SELECT array_agg(username) FROM public.friend_requests()) = ARRAY['invb','inve','invc'];
-- As C: C's code was nobody's, and nobody asked C.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000006c3","role":"authenticated"}', true);
INSERT INTO results SELECT 'C has no requests', NOT EXISTS (SELECT 1 FROM public.friend_requests());
RESET ROLE;
-- A adds B back: B leaves A's requests.
INSERT INTO public.follows (follower_id, following_id, push_sent) VALUES
 ('00000000-0000-0000-0000-0000000006a1','00000000-0000-0000-0000-0000000006b2', true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000006a1","role":"authenticated"}', true);
INSERT INTO results SELECT 'added back, B is a friend, not a request',
  NOT EXISTS (SELECT 1 FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-0000000006b2');
RESET ROLE;
-- Anonymous callers cannot run it.
INSERT INTO results SELECT 'anon has no execute', NOT has_function_privilege('anon', 'public.friend_requests()', 'EXECUTE');

SELECT json_agg(r) FROM results r;
ROLLBACK;
