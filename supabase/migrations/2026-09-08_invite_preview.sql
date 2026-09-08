-- invite_preview: who a personal invite code belongs to, so the sign-in screen can say "@maya
-- invited you" the moment six characters are typed (or arrive by link), before any email is sent.
--
-- Deliberately narrow. It answers only for a code that redeem_invite would currently accept (the
-- owner has uses left, or is unlimited), and it says nothing at all otherwise: an exhausted code
-- and a code that never existed look identical here, exactly as they do in redeem_invite, so
-- this adds no way to tell real codes from guesses that the redeem path did not already allow.
-- It shares redeem_invite's global rate gate (redeem_invite_rate, 30 an hour across everyone),
-- so probing through this function is bounded the same way probing through that one is.
--
-- Returns the inviter's id, username and display name: the id is what the new account follows
-- once it exists, the names are what the screen shows.
CREATE OR REPLACE FUNCTION public.invite_preview(p_code TEXT)
RETURNS TABLE (inviter_id UUID, username TEXT, display_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_code     TEXT := UPPER(TRIM(p_code));
    v_window   TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;

    SELECT window_start, attempts INTO v_window, v_attempts
    FROM public.redeem_invite_rate
    WHERE id = TRUE
    FOR UPDATE;
    IF v_window < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.redeem_invite_rate SET window_start = NOW(), attempts = 1 WHERE id = TRUE;
    ELSIF v_attempts >= 30 THEN
        RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0003';
    ELSE
        UPDATE public.redeem_invite_rate SET attempts = attempts + 1 WHERE id = TRUE;
    END IF;

    RETURN QUERY
    SELECT u.id, u.username, u.display_name
    FROM public.users u
    WHERE u.invite_code = v_code
      AND (u.invite_uses_remaining IS NULL OR u.invite_uses_remaining > 0)
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.invite_preview(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_preview(TEXT) TO anon, authenticated;
