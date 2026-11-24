-- 1.7.11: decline a friend request.
--
-- Since 1.7 a follow nobody has answered is a friend request (can_see_posts_of is mutual). The
-- person asked could only hide it on their own phone ("Not now"): the request stayed live, came
-- back on another device, and the asker's button said Requested forever. RLS lets you delete only
-- the follows rows you made, so declining someone else's request needs this function.
--
-- Quiet by design (owner, 2026-11-24): no push, no row anywhere saying it happened. The asker's
-- button goes back to Add friend; they can ask again later, and Block covers anyone who keeps
-- asking. It removes only a PENDING request: if you already follow them back you are friends, and
-- Remove friend (deleting your own row) is the way out of that.
--
-- Additive: one new function, nothing existing changes, safe to apply before 1.7.11 ships.
-- Rerunnable.

CREATE OR REPLACE FUNCTION public.decline_friend_request(p_requester uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_me uuid := auth.uid();
    v_removed integer;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'not signed in' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.follows f
    WHERE f.follower_id = p_requester
      AND f.following_id = v_me
      AND NOT EXISTS (
          SELECT 1 FROM public.follows mine
          WHERE mine.follower_id = v_me AND mine.following_id = p_requester
      );
    GET DIAGNOSTICS v_removed = ROW_COUNT;
    RETURN v_removed > 0;
END;
$function$;

REVOKE ALL ON FUNCTION public.decline_friend_request(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decline_friend_request(uuid) TO authenticated;
