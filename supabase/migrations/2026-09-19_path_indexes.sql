-- The storage policies match objects by path across photos, posts and users, and none of those
-- columns had an index (scale audit, 2026-09-19): every signed-URL batch was a sequential scan
-- per object, fine at 3,000 photos and the top CPU cost near 50,000. Six btrees.
CREATE INDEX IF NOT EXISTS photos_storage_path_idx ON public.photos (storage_path);
CREATE INDEX IF NOT EXISTS photos_thumb_path_idx   ON public.photos (thumb_path);
CREATE INDEX IF NOT EXISTS photos_feed_path_idx    ON public.photos (feed_path);
CREATE INDEX IF NOT EXISTS posts_storage_path_idx  ON public.posts (storage_path);
CREATE INDEX IF NOT EXISTS posts_thumb_path_idx    ON public.posts (thumb_path);
CREATE INDEX IF NOT EXISTS posts_feed_path_idx     ON public.posts (feed_path);
CREATE INDEX IF NOT EXISTS users_avatar_path_idx   ON public.users (avatar_path);
CREATE INDEX IF NOT EXISTS users_cover_path_idx    ON public.users (cover_path);
