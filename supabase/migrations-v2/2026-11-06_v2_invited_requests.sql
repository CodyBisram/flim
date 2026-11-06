-- FLIM v2: a friend request from someone who joined with your own invite says so, and sits first.
-- Applied to the FLIM Dev project (FLIM Beta) only, like the rest of migrations-v2.
--
-- A new account follows whoever's code let it in (UsernameView.save). With friends mutual
-- (2026-10-30, section 1), that follow is a request, and until the inviter adds them back the
-- newcomer sees nobody's prints. The request list called them "new here" like any stranger.
-- redeem_invite already records who let them in (allowed_emails.note = 'invited_by:<uuid>',
-- via = 'personal'), the same fact send-social-push reads for "joined with your invite".
--
-- The return type changes (one more column), so the function is dropped first.
DROP FUNCTION IF EXISTS public.friend_requests();
CREATE FUNCTION public.friend_requests()
RETURNS TABLE (id UUID, username TEXT, display_name TEXT, avatar_path TEXT, asked_at TIMESTAMPTZ,
               in_common INT, invited_by_me BOOLEAN)
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
    ),
    asks AS (
        SELECT u.id, u.username, u.display_name, u.avatar_path, f.created_at AS asked_at,
               (SELECT COUNT(*)::INT FROM friends fr
                 WHERE EXISTS (SELECT 1 FROM public.follows a WHERE a.follower_id = u.id AND a.following_id = fr.fid)
                   AND EXISTS (SELECT 1 FROM public.follows b WHERE b.follower_id = fr.fid AND b.following_id = u.id)) AS in_common,
               EXISTS (SELECT 1 FROM public.allowed_emails ae
                        WHERE u.email IS NOT NULL AND ae.email = lower(u.email)
                          AND ae.via = 'personal' AND ae.note = 'invited_by:' || me.uid::text) AS invited_by_me
        FROM public.follows f
        JOIN me ON f.following_id = me.uid
        JOIN public.users u ON u.id = f.follower_id
        WHERE me.uid IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.follows back WHERE back.follower_id = me.uid AND back.following_id = f.follower_id)
          AND NOT EXISTS (SELECT 1 FROM public.friend_request_dismissals d WHERE d.user_id = me.uid AND d.requester_id = f.follower_id)
          AND NOT public.is_blocked_either_way(me.uid, f.follower_id)
    )
    SELECT * FROM asks ORDER BY invited_by_me DESC, asked_at DESC;
$$;
REVOKE ALL ON FUNCTION public.friend_requests() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.friend_requests() TO authenticated;
