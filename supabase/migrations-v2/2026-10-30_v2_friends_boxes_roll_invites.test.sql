-- Scenario test for 2026-10-30_v2_friends_boxes_roll_invites.sql. Runs in one transaction and rolls
-- back, so nothing persists: three stand-in people, a request, Not now, accepting, put away,
-- and who can see what. Every row of the final result should read ok = true. FLIM Dev only.
-- Rolled back at the end: nothing persists.
BEGIN;
CREATE TEMP TABLE results (step TEXT, ok BOOLEAN) ON COMMIT DROP;
GRANT INSERT, SELECT ON results TO authenticated;
INSERT INTO public.allowed_emails (email, note) VALUES ('a@test.invalid','rolled back'),('b@test.invalid','rolled back'),('c@test.invalid','rolled back');
INSERT INTO auth.users (id, aud, role, email, instance_id) VALUES
 ('00000000-0000-0000-0000-00000000a001','authenticated','authenticated','a@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000b002','authenticated','authenticated','b@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000c003','authenticated','authenticated','c@test.invalid','00000000-0000-0000-0000-000000000000');
INSERT INTO public.users (id, username) VALUES
 ('00000000-0000-0000-0000-00000000a001','testa'),('00000000-0000-0000-0000-00000000b002','testb'),('00000000-0000-0000-0000-00000000c003','testc')
 ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username;
INSERT INTO public.photos (id, user_id, storage_path, develops_at) VALUES
 ('00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-00000000b002','b/1.jpg', now()),
 ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-00000000b002','b/2.jpg', now());
INSERT INTO public.posts (id, user_id, photo_id, storage_path, taken_at) VALUES
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-0000000000f1','b/1.jpg', now()),
 ('00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-0000000000f2','b/2.jpg', now());
-- A asks B (follows one way).
INSERT INTO public.follows (follower_id, following_id) VALUES ('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'one-way follow cannot see posts', NOT public.can_see_posts_of('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000b002');
-- As B: A's request shows.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b002","role":"authenticated"}', true);
INSERT INTO results SELECT 'B sees A asked', EXISTS (SELECT 1 FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-00000000a001');
-- B dismisses, the request goes; undismiss for the next step.
INSERT INTO public.friend_request_dismissals (user_id, requester_id) VALUES ('00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-00000000a001');
INSERT INTO results SELECT 'Not now hides it', NOT EXISTS (SELECT 1 FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-00000000a001');
DELETE FROM public.friend_request_dismissals WHERE user_id = '00000000-0000-0000-0000-00000000b002';
-- B accepts: follows back.
INSERT INTO public.follows (follower_id, following_id) VALUES ('00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-00000000a001');
INSERT INTO results SELECT 'accepted request leaves the list', NOT EXISTS (SELECT 1 FROM public.friend_requests() WHERE id = '00000000-0000-0000-0000-00000000a001');
INSERT INTO results SELECT 'friends_of B lists A', EXISTS (SELECT 1 FROM public.friends_of('00000000-0000-0000-0000-00000000b002') WHERE id = '00000000-0000-0000-0000-00000000a001');
-- B puts a post away.
UPDATE public.posts SET put_away = true WHERE id = '00000000-0000-0000-0000-0000000000e2';
INSERT INTO results SELECT 'owner can put away own post', (SELECT put_away FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e2');
INSERT INTO results SELECT 'owner still sees put-away post', EXISTS (SELECT 1 FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e2');
-- As A (friend now).
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
INSERT INTO results SELECT 'friend sees out post', EXISTS (SELECT 1 FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e1');
INSERT INTO results SELECT 'friend does not see put-away post', NOT EXISTS (SELECT 1 FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e2');
UPDATE public.posts SET put_away = true WHERE id = '00000000-0000-0000-0000-0000000000e1';
RESET ROLE;
INSERT INTO results SELECT 'friend cannot put away someone else''s post', NOT (SELECT put_away FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e1');
SET LOCAL ROLE authenticated;
-- As C (stranger).
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000c003","role":"authenticated"}', true);
INSERT INTO results SELECT 'stranger sees nothing', NOT EXISTS (SELECT 1 FROM public.posts WHERE user_id = '00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'stranger cannot write a box for B',
  (SELECT COUNT(*) = 0 FROM public.month_boxes WHERE user_id = '00000000-0000-0000-0000-00000000b002');
RESET ROLE;
SELECT json_agg(r) FROM results r;
ROLLBACK;
