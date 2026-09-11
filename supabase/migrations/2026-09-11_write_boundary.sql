-- 1.5.3, audit items 4 (second half) and 5: photo and post writes end at the boundary the UI
-- already respects. Nothing here changes what the app does; it removes what a direct API call
-- with the public key could do that the app never offered.
--
-- photos INSERT: a roll shot needs roll membership, not just ownership. (Develop-time refusal
-- was already there.)
DROP POLICY IF EXISTS "photos: can insert own" ON public.photos;
CREATE POLICY "photos: can insert own"
    ON public.photos FOR INSERT
    WITH CHECK (
        auth.uid() = user_id
        AND (roll_id IS NULL OR (public.is_roll_member(roll_id) AND NOT public.is_roll_developed(roll_id)))
    );

-- photos UPDATE: the app changes one column (is_sorted). Everything else on the row is the
-- server's (paths, roll, develop time, moderation, capture scores). Column-scoped grant, and
-- the default TRUNCATE/REFERENCES/TRIGGER privileges Supabase hands every new table go too.
REVOKE UPDATE, TRUNCATE, REFERENCES, TRIGGER ON public.photos FROM anon, authenticated;
GRANT UPDATE (is_sorted) ON public.photos TO authenticated;

-- posts UPDATE: caption only. hidden and push_sent are server-owned.
REVOKE UPDATE, TRUNCATE, REFERENCES, TRIGGER ON public.posts FROM anon, authenticated;
GRANT UPDATE (caption) ON public.posts TO authenticated;

-- posts paths come from the photo, never from the client. The storage read policy "readable
-- when shared to a post" trusts posts.*_path, so a client that could write any path into a
-- post could expose any object in the bucket to every reader. Now the paths are copied from
-- the photo row the INSERT policy already validated, on insert and on every update, and the
-- photo and author cannot be swapped after the fact. A post whose photo has no thumbnail yet
-- gets null there, exactly as the photo does.
CREATE OR REPLACE FUNCTION public.pin_post_paths()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_storage TEXT;
    v_thumb   TEXT;
    v_feed    TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.photo_id := OLD.photo_id;
        NEW.user_id := OLD.user_id;
    END IF;
    SELECT storage_path, thumb_path, feed_path INTO v_storage, v_thumb, v_feed
    FROM public.photos WHERE id = NEW.photo_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'post_photo_missing' USING ERRCODE = 'P0004';
    END IF;
    NEW.storage_path := v_storage;
    NEW.thumb_path := v_thumb;
    NEW.feed_path := v_feed;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.pin_post_paths() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS pin_post_paths_trigger ON public.posts;
CREATE TRIGGER pin_post_paths_trigger
    BEFORE INSERT OR UPDATE ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.pin_post_paths();

-- One-time: 101 posts (2026-07-02 to 2026-09-10) were missing a thumbnail or feed path their
-- photo has, from before renditions were backfilled. The storage path never differed. Copying
-- the photo's paths only makes the feed load the smaller rendition it should have had.
UPDATE public.posts po
SET storage_path = p.storage_path, thumb_path = p.thumb_path, feed_path = p.feed_path
FROM public.photos p
WHERE p.id = po.photo_id
  AND (po.storage_path IS DISTINCT FROM p.storage_path
       OR po.thumb_path IS DISTINCT FROM p.thumb_path
       OR po.feed_path IS DISTINCT FROM p.feed_path);

-- users.avatar_path / cover_path must sit in the account's own storage folder. The storage read
-- policies "readable when set as avatar/cover" trust these columns the same way, so a row that
-- pointed at another account's object would expose it to everyone. The app only ever writes
-- <uid>/avatar-… and <uid>/cover-…; this pins that.
CREATE OR REPLACE FUNCTION public.lock_users_owned_image_paths()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.avatar_path IS NOT NULL AND NEW.avatar_path IS DISTINCT FROM OLD.avatar_path
       AND NEW.avatar_path NOT LIKE NEW.id::text || '/%' THEN
        RAISE EXCEPTION 'avatar_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    IF NEW.cover_path IS NOT NULL AND NEW.cover_path IS DISTINCT FROM OLD.cover_path
       AND NEW.cover_path NOT LIKE NEW.id::text || '/%' THEN
        RAISE EXCEPTION 'cover_path_not_owned' USING ERRCODE = 'P0005';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_users_owned_image_paths() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lock_users_owned_image_paths_trigger ON public.users;
CREATE TRIGGER lock_users_owned_image_paths_trigger
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.lock_users_owned_image_paths();
