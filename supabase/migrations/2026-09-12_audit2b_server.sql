-- Audit 2 follow-up (2026-09-11 evening), server side: finding G, the roll INSERT timing hole,
-- and posts lagging a photo relink.

-- G. The daily follow-up quota is checked INSIDE the per-caller lock, after the same-request
-- lookup, so concurrent calls with distinct request ids cannot all see four and each make a
-- fifth. Deleting a roll still frees its slot (a roll that no longer exists cost nobody a push
-- that persists), which is deliberate.
CREATE OR REPLACE FUNCTION public.start_follow_up_roll(p_parent UUID, p_name TEXT, p_request UUID DEFAULT NULL)
RETURNS public.rolls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_name TEXT := TRIM(p_name);
    v_code TEXT;
    r      public.rolls;
    i      INT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_signed_in' USING ERRCODE = 'P0001'; END IF;
    IF v_name = '' OR LENGTH(v_name) > 60 THEN RAISE EXCEPTION 'bad_name' USING ERRCODE = 'P0001'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.roll_members WHERE roll_id = p_parent AND user_id = auth.uid()) THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;
    IF NOT public.is_roll_developed(p_parent) THEN
        RAISE EXCEPTION 'parent_not_developed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('start_follow_up_roll:' || auth.uid()::text));
    IF p_request IS NOT NULL THEN
        SELECT ro.* INTO r FROM public.roll_follow_up_requests q JOIN public.rolls ro ON ro.id = q.roll_id
        WHERE q.request_id = p_request AND q.created_by = auth.uid();
        IF r.id IS NOT NULL THEN RETURN r; END IF;
    END IF;
    IF (SELECT COUNT(*) FROM public.rolls WHERE created_by = auth.uid() AND parent_roll_id IS NOT NULL
        AND created_at > NOW() - INTERVAL '1 day') >= 5 THEN
        RAISE EXCEPTION 'too_many_follow_ups_today' USING ERRCODE = 'P0003';
    END IF;
    FOR i IN 1..20 LOOP
        v_code := UPPER(SUBSTRING(md5(gen_random_uuid()::text) FROM 1 FOR 6));
        EXIT WHEN v_code ~ '^[A-Z0-9]{6}$'
             AND NOT EXISTS (SELECT 1 FROM public.rolls WHERE invite_code = v_code)
             AND NOT EXISTS (SELECT 1 FROM public.users WHERE invite_code = v_code);
        v_code := NULL;
    END LOOP;
    IF v_code IS NULL THEN RAISE EXCEPTION 'no_code' USING ERRCODE = 'P0001'; END IF;
    INSERT INTO public.rolls (name, invite_code, created_by, parent_roll_id)
    VALUES (v_name, v_code, auth.uid(), p_parent)
    RETURNING * INTO r;
    INSERT INTO public.roll_members (roll_id, user_id) VALUES (r.id, auth.uid()) ON CONFLICT DO NOTHING;
    INSERT INTO public.roll_follow_up_invites (roll_id, user_id, invited_by)
    SELECT r.id, m.user_id, auth.uid()
    FROM public.roll_members m
    WHERE m.roll_id = p_parent
      AND m.user_id <> auth.uid()
      AND NOT public.is_blocked_either_way(auth.uid(), m.user_id)
    ON CONFLICT DO NOTHING;
    IF p_request IS NOT NULL THEN
        INSERT INTO public.roll_follow_up_requests (request_id, roll_id, created_by) VALUES (p_request, r.id, auth.uid());
    END IF;
    RETURN r;
END;
$$;

-- A client creates a roll with a name, a code and itself as creator. The reveal time is the
-- server's (trigger default, movable only through set_roll_reveal_at); the parent is the
-- follow-up RPC's. Column-scoped INSERT, like UPDATE already is.
REVOKE INSERT ON public.rolls FROM anon, authenticated;
GRANT INSERT (name, invite_code, created_by) ON public.rolls TO authenticated;

-- A post's paths are copied from its photo at insert; when the photo's renditions are linked
-- later (the client's repair, or a server relink like the 2026-09-11 hotfix), the post kept its
-- nulls and the feed kept loading the master. Follow the photo.
CREATE OR REPLACE FUNCTION public.sync_post_paths_from_photo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.storage_path IS DISTINCT FROM OLD.storage_path
       OR NEW.thumb_path IS DISTINCT FROM OLD.thumb_path
       OR NEW.feed_path IS DISTINCT FROM OLD.feed_path THEN
        UPDATE public.posts
        SET storage_path = NEW.storage_path, thumb_path = NEW.thumb_path, feed_path = NEW.feed_path
        WHERE photo_id = NEW.id
          AND (storage_path IS DISTINCT FROM NEW.storage_path
               OR thumb_path IS DISTINCT FROM NEW.thumb_path
               OR feed_path IS DISTINCT FROM NEW.feed_path);
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_post_paths_from_photo() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS sync_post_paths_from_photo_trigger ON public.photos;
CREATE TRIGGER sync_post_paths_from_photo_trigger
    AFTER UPDATE OF storage_path, thumb_path, feed_path ON public.photos
    FOR EACH ROW EXECUTE FUNCTION public.sync_post_paths_from_photo();

-- One-time: posts left behind by relinks that happened before this trigger existed.
UPDATE public.posts po
SET storage_path = p.storage_path, thumb_path = p.thumb_path, feed_path = p.feed_path
FROM public.photos p
WHERE p.id = po.photo_id
  AND (po.thumb_path IS DISTINCT FROM p.thumb_path OR po.feed_path IS DISTINCT FROM p.feed_path);
