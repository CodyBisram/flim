-- Scenario test for 2026-11-24_1711_decline_friend_request.sql on a staging copy
-- (scripts/schema_bootstrap.sh --keep, then apply the migration). One transaction, rolled back.
-- Every row of the final result should read ok = true.
--   psql postgresql://postgres:postgres@localhost:54329/postgres -v ON_ERROR_STOP=1 \
--     -f supabase/migrations/2026-11-24_1711_decline_friend_request.test.sql
BEGIN;
CREATE TEMP TABLE results (step TEXT, ok BOOLEAN) ON COMMIT DROP;
GRANT INSERT, SELECT ON results TO authenticated;
INSERT INTO public.allowed_emails (email, note) VALUES ('a@test.invalid','rolled back'),('b@test.invalid','rolled back'),
 ('c@test.invalid','rolled back');
INSERT INTO auth.users (id, aud, role, email, instance_id) VALUES
 ('00000000-0000-0000-0000-00000000a001','authenticated','authenticated','a@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000b002','authenticated','authenticated','b@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000c003','authenticated','authenticated','c@test.invalid','00000000-0000-0000-0000-000000000000');
INSERT INTO public.users (id, username) VALUES
 ('00000000-0000-0000-0000-00000000a001','testa'),('00000000-0000-0000-0000-00000000b002','testb'),
 ('00000000-0000-0000-0000-00000000c003','testc')
 ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username;
-- A asked B (pending). B and C are friends. C also follows A one way (a request to A).
INSERT INTO public.follows (follower_id, following_id) VALUES
 ('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000b002'),
 ('00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-00000000c003'),
 ('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-00000000b002'),
 ('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-00000000a001');

-- As B.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000b002', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b002","role":"authenticated"}', true);

INSERT INTO results SELECT 'B declines A''s pending request -> true',
  public.decline_friend_request('00000000-0000-0000-0000-00000000a001') = true;
INSERT INTO results SELECT 'declining it again -> false',
  public.decline_friend_request('00000000-0000-0000-0000-00000000a001') = false;
INSERT INTO results SELECT 'B cannot "decline" C: they are friends -> false',
  public.decline_friend_request('00000000-0000-0000-0000-00000000c003') = false;
INSERT INTO results SELECT 'B declining touches nobody else''s rows -> false',
  public.decline_friend_request('00000000-0000-0000-0000-00000000b002') = false;
-- Direct delete of someone else's row is still refused by RLS (0 rows).
WITH d AS (DELETE FROM public.follows WHERE follower_id = '00000000-0000-0000-0000-00000000c003'
           AND following_id = '00000000-0000-0000-0000-00000000a001' RETURNING 1)
INSERT INTO results SELECT 'RLS still blocks deleting another pair''s row', count(*) = 0 FROM d;
RESET ROLE;

INSERT INTO results SELECT 'A->B row is gone', NOT EXISTS (SELECT 1 FROM public.follows
  WHERE follower_id = '00000000-0000-0000-0000-00000000a001' AND following_id = '00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'B<->C friendship untouched', (SELECT count(*) FROM public.follows
  WHERE (follower_id, following_id) IN (('00000000-0000-0000-0000-00000000b002'::uuid,'00000000-0000-0000-0000-00000000c003'::uuid),
                                        ('00000000-0000-0000-0000-00000000c003'::uuid,'00000000-0000-0000-0000-00000000b002'::uuid))) = 2;
INSERT INTO results SELECT 'C->A request untouched', EXISTS (SELECT 1 FROM public.follows
  WHERE follower_id = '00000000-0000-0000-0000-00000000c003' AND following_id = '00000000-0000-0000-0000-00000000a001');
INSERT INTO results SELECT 'anon cannot execute',
  NOT has_function_privilege('anon', 'public.decline_friend_request(uuid)', 'EXECUTE');
INSERT INTO results SELECT 'authenticated can execute',
  has_function_privilege('authenticated', 'public.decline_friend_request(uuid)', 'EXECUTE');

-- Signed out raises.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claims', '{}', true);
DO $$ BEGIN
  PERFORM public.decline_friend_request('00000000-0000-0000-0000-00000000a001');
  INSERT INTO results VALUES ('signed out raises', false);
EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO results VALUES ('signed out raises', true);
END $$;
RESET ROLE;

SELECT step, ok FROM results;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) AS total FROM results;
ROLLBACK;
