-- FLIM v2 (the Print redesign): friends by request, putting prints away, month covers, and
-- choosing who is in when a roll starts. Applied to the FLIM Dev project (FLIM Beta) only.
--
-- NOT for production as it stands. Section 1 changes who sees whose posts (both people must
-- follow each other), which is product rule 2 and would hide posts from one-way followers in the
-- App Store app. It ships with the v2 launch, when every client reads friends this way. Sections
-- 2 to 4 are additive: they only act on rows v2 writes.

-- ---------------------------------------------------------------------------
-- 1. Friends by request (product rule 2). A friend is someone you follow who follows you back.
--    Following someone who does not follow you is asking to be friends; they see the request,
--    and accepting is following back. Until then neither sees the other's prints (tags aside).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_see_posts_of(p_viewer UUID, p_author UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_viewer IS NOT NULL AND (
        p_viewer = p_author
        OR (EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = p_viewer AND f.following_id = p_author)
            AND EXISTS (SELECT 1 FROM public.follows f WHERE f.follower_id = p_author AND f.following_id = p_viewer))
    );
$$;

-- "Not now": hides a request from the person asked. It tells the asker nothing.
CREATE TABLE IF NOT EXISTS public.friend_request_dismissals (
    user_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    requester_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, requester_id)
);
ALTER TABLE public.friend_request_dismissals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.friend_request_dismissals FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.friend_request_dismissals TO authenticated;
DROP POLICY IF EXISTS "friend_request_dismissals: own" ON public.friend_request_dismissals;
CREATE POLICY "friend_request_dismissals: own"
    ON public.friend_request_dismissals FOR ALL TO authenticated
    USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- The caller's open requests: people who follow the caller, whom the caller does not follow,
-- not dismissed, not blocked either way. With how many of the caller's friends they share.
CREATE OR REPLACE FUNCTION public.friend_requests()
RETURNS TABLE (id UUID, username TEXT, display_name TEXT, avatar_path TEXT, asked_at TIMESTAMPTZ, in_common INT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH me AS (SELECT auth.uid() AS uid),
    friends AS (
        SELECT f.following_id AS fid FROM public.follows f, me
        WHERE f.follower_id = me.uid
          AND EXISTS (SELECT 1 FROM public.follows b WHERE b.follower_id = f.following_id AND b.following_id = me.uid)
    )
    SELECT u.id, u.username, u.display_name, u.avatar_path, f.created_at,
           (SELECT COUNT(*)::INT FROM friends fr
             WHERE EXISTS (SELECT 1 FROM public.follows a WHERE a.follower_id = u.id AND a.following_id = fr.fid)
               AND EXISTS (SELECT 1 FROM public.follows b WHERE b.follower_id = fr.fid AND b.following_id = u.id))
    FROM public.follows f
    JOIN me ON f.following_id = me.uid
    JOIN public.users u ON u.id = f.follower_id
    WHERE me.uid IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.follows back WHERE back.follower_id = me.uid AND back.following_id = f.follower_id)
      AND NOT EXISTS (SELECT 1 FROM public.friend_request_dismissals d WHERE d.user_id = me.uid AND d.requester_id = f.follower_id)
      AND NOT public.is_blocked_either_way(me.uid, f.follower_id)
    ORDER BY f.created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.friend_requests() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.friend_requests() TO authenticated;

-- Someone's friends (mutual follows), blocked parties left out for the caller.
CREATE OR REPLACE FUNCTION public.friends_of(p_user UUID)
RETURNS TABLE (id UUID, username TEXT, display_name TEXT, avatar_path TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id, u.username, u.display_name, u.avatar_path
    FROM public.follows f
    JOIN public.users u ON u.id = f.following_id
    WHERE f.follower_id = p_user
      AND auth.uid() IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.follows b WHERE b.follower_id = f.following_id AND b.following_id = p_user)
      AND NOT public.is_blocked_either_way(auth.uid(), u.id)
    ORDER BY f.created_at ASC;
$$;
REVOKE ALL ON FUNCTION public.friends_of(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.friends_of(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Put away (product rule 4): a print stays on its owner's page and in their months, hidden
--    from everyone else. Nothing is deleted. Default is out.
-- ---------------------------------------------------------------------------
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS put_away BOOLEAN NOT NULL DEFAULT FALSE;
GRANT UPDATE (put_away) ON public.posts TO authenticated;

-- The one place post visibility is decided (the posts policy, the storage policy and
-- chapter_photos all ask it): a put-away post is its owner's alone.
CREATE OR REPLACE FUNCTION public.post_visible_to(p_viewer UUID, p_post_id UUID, p_author UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_viewer = p_author
        OR (NOT COALESCE((SELECT po.put_away FROM public.posts po WHERE po.id = p_post_id), FALSE)
            AND (public.can_see_posts_of(p_viewer, p_author)
                 OR EXISTS (SELECT 1 FROM public.post_tags t WHERE t.post_id = p_post_id AND t.tagged_user_id = p_viewer)));
$$;

-- ---------------------------------------------------------------------------
-- 3. A month's cover, chosen by hand when the month is boxed (rule 4). Without a row the cover
--    is the month's Spotlight print, else its first.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.month_boxes (
    user_id        UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    month_start    DATE NOT NULL,
    cover_photo_id UUID REFERENCES public.photos(id) ON DELETE SET NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, month_start)
);
ALTER TABLE public.month_boxes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.month_boxes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.month_boxes TO authenticated;
DROP POLICY IF EXISTS "month_boxes: readable by friends" ON public.month_boxes;
CREATE POLICY "month_boxes: readable by friends"
    ON public.month_boxes FOR SELECT TO authenticated
    USING (public.can_see_posts_of(auth.uid(), user_id));
DROP POLICY IF EXISTS "month_boxes: own" ON public.month_boxes;
CREATE POLICY "month_boxes: own"
    ON public.month_boxes FOR ALL TO authenticated
    USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4. Who is in, chosen when a roll starts. The same invitation a follow-up roll sends
--    (roll_follow_up_invites): the invitee sees the roll and joins it themselves. Only the roll's
--    members may invite, only their friends, never anyone blocked either way, and not once the
--    roll has developed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.invite_to_roll(p_roll UUID, p_users UUID[])
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_signed_in' USING ERRCODE = 'P0001'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.roll_members WHERE roll_id = p_roll AND user_id = auth.uid()) THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;
    IF public.is_roll_developed(p_roll) THEN RAISE EXCEPTION 'roll_developed' USING ERRCODE = 'P0001'; END IF;
    IF COALESCE(array_length(p_users, 1), 0) > 50 THEN RAISE EXCEPTION 'too_many' USING ERRCODE = 'P0001'; END IF;
    INSERT INTO public.roll_follow_up_invites (roll_id, user_id, invited_by)
    SELECT p_roll, x.uid, auth.uid()
    FROM unnest(p_users) AS x(uid)
    WHERE x.uid <> auth.uid()
      AND public.can_see_posts_of(auth.uid(), x.uid)
      AND NOT public.is_blocked_either_way(auth.uid(), x.uid)
      AND NOT EXISTS (SELECT 1 FROM public.roll_members m WHERE m.roll_id = p_roll AND m.user_id = x.uid)
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.invite_to_roll(UUID, UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invite_to_roll(UUID, UUID[]) TO authenticated;
