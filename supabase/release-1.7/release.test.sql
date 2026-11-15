-- Scenario test for 01_month_boxes.sql, 03_review_fixes.sql, then 02_mutual_friends.sql, in that order on a
-- staging copy (scripts/schema_bootstrap.sh --keep). One transaction, rolled back: nothing
-- persists. Every row of the final result should read ok = true.
--   psql postgresql://postgres:postgres@localhost:54329/postgres -v ON_ERROR_STOP=1 \
--     -f supabase/release-1.7/release.test.sql
BEGIN;
CREATE TEMP TABLE results (step TEXT, ok BOOLEAN) ON COMMIT DROP;
GRANT INSERT, SELECT ON results TO authenticated;
INSERT INTO public.allowed_emails (email, note) VALUES ('a@test.invalid','rolled back'),('b@test.invalid','rolled back'),
 ('c@test.invalid','rolled back'),('d@test.invalid','rolled back');
INSERT INTO auth.users (id, aud, role, email, instance_id) VALUES
 ('00000000-0000-0000-0000-00000000a001','authenticated','authenticated','a@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000b002','authenticated','authenticated','b@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000c003','authenticated','authenticated','c@test.invalid','00000000-0000-0000-0000-000000000000'),
 ('00000000-0000-0000-0000-00000000d004','authenticated','authenticated','d@test.invalid','00000000-0000-0000-0000-000000000000');
INSERT INTO public.users (id, username) VALUES
 ('00000000-0000-0000-0000-00000000a001','testa'),('00000000-0000-0000-0000-00000000b002','testb'),
 ('00000000-0000-0000-0000-00000000c003','testc'),('00000000-0000-0000-0000-00000000d004','testd')
 ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username;
INSERT INTO public.photos (id, user_id, storage_path, develops_at) VALUES
 ('00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-00000000b002','b/1.jpg', now()),
 ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-00000000b002','b/2.jpg', now());
INSERT INTO public.posts (id, user_id, photo_id, storage_path, taken_at) VALUES
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-0000000000f1','b/1.jpg', now()),
 ('00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-0000000000f2','b/2.jpg', now());
-- A follows B one way; B and C follow each other; D is tagged on e2 and follows nobody.
INSERT INTO public.follows (follower_id, following_id) VALUES
 ('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000b002'),
 ('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-00000000b002'),
 ('00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-00000000c003');
INSERT INTO public.post_tags (post_id, tagged_user_id, x, y) VALUES
 ('00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000d004', 0.5, 0.5);

\i supabase/release-1.7/01_month_boxes.sql

-- Step 1 changes nothing for anyone until a post is put away.
INSERT INTO results SELECT 'step 1: a one-way follower still sees posts (1.6 rules)',
  public.post_visible_to('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'step 1: a tagged person sees the post they are tagged in',
  public.post_visible_to('00000000-0000-0000-0000-00000000d004','00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002');

-- B, signed in, puts e2 away and makes f1 the cover of this month's box.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b002","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000b002', true);  -- older auth.uid() reads this
UPDATE public.posts SET put_away = true WHERE id = '00000000-0000-0000-0000-0000000000e2';
INSERT INTO public.month_boxes (user_id, month_start, cover_photo_id)
  VALUES ('00000000-0000-0000-0000-00000000b002', date_trunc('month', now())::date, '00000000-0000-0000-0000-0000000000f1');
INSERT INTO results SELECT 'B can put away their own post',
  (SELECT put_away FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e2');
RESET ROLE;

INSERT INTO results SELECT 'put away: the author still sees it',
  public.post_visible_to('00000000-0000-0000-0000-00000000b002','00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'put away: a friend does not',
  NOT public.post_visible_to('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'put away: a tagged person does not',
  NOT public.post_visible_to('00000000-0000-0000-0000-00000000d004','00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'put away: the other post is still seen by a friend',
  public.post_visible_to('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002');

-- C, signed in, reads B's box cover; and cannot put B's post away.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000c003","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c003', true);  -- older auth.uid() reads this
INSERT INTO results SELECT 'a friend sees the chosen cover',
  EXISTS (SELECT 1 FROM public.month_box_covers('00000000-0000-0000-0000-00000000b002') WHERE cover_path = 'b/1.jpg');
UPDATE public.posts SET put_away = false WHERE id = '00000000-0000-0000-0000-0000000000e2';
RESET ROLE;
INSERT INTO results SELECT 'a friend cannot bring back someone else''s post',
  (SELECT put_away FROM public.posts WHERE id = '00000000-0000-0000-0000-0000000000e2');

\i supabase/release-1.7/03_review_fixes.sql

-- Step 1b. e1 and the put-away e2 were each chosen in a published Spotlight week.
INSERT INTO public.spotlight_weeks (week_key, published_at) VALUES ('2026-11-02', now()), ('2026-11-09', now());
INSERT INTO public.spotlight_entries (post_id, user_id, week_key, chosen_at) VALUES
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002','2026-11-02', now()),
 ('00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000b002','2026-11-09', now());
INSERT INTO results SELECT 'step 1b: a chosen frame is still public',
  public.spotlight_post_public('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000d004');
INSERT INTO results SELECT 'step 1b: a chosen frame put away is not',
  NOT public.spotlight_post_public('00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-00000000d004');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000d004","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d004', true);
INSERT INTO results SELECT 'step 1b: a stranger''s view of the shelf skips the put-away frame',
  NOT EXISTS (SELECT 1 FROM public._spotlight_weeks_for('00000000-0000-0000-0000-00000000b002', NULL, 12) w,
              jsonb_array_elements(w.frames) f WHERE f->>'post_id' = '00000000-0000-0000-0000-0000000000e2')
  AND EXISTS (SELECT 1 FROM public._spotlight_weeks_for('00000000-0000-0000-0000-00000000b002', NULL, 12) w,
              jsonb_array_elements(w.frames) f WHERE f->>'post_id' = '00000000-0000-0000-0000-0000000000e1');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b002","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000b002', true);
INSERT INTO results SELECT 'step 1b: the author''s own shelf keeps it',
  EXISTS (SELECT 1 FROM public._spotlight_weeks_for('00000000-0000-0000-0000-00000000b002', NULL, 12) w,
          jsonb_array_elements(w.frames) f WHERE f->>'post_id' = '00000000-0000-0000-0000-0000000000e2');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000c003","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c003', true);
INSERT INTO results SELECT 'step 1b: a friend still sees the chosen cover',
  EXISTS (SELECT 1 FROM public.month_box_covers('00000000-0000-0000-0000-00000000b002') WHERE cover_path = 'b/1.jpg');

\i supabase/release-1.7/02_mutual_friends.sql

INSERT INTO results SELECT 'step 2: a one-way follower no longer sees posts',
  NOT public.post_visible_to('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'step 2: friends still see each other',
  public.post_visible_to('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-00000000b002');
INSERT INTO results SELECT 'step 2: authors still see their own',
  public.can_see_posts_of('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000a001');

SELECT step, ok FROM results ORDER BY ok, step;
ROLLBACK;
