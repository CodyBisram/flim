-- Detach a device from push when the app has lost its session (2026-09-24, repository audit
-- finding 2).
--
-- A server-forced sign-out (expired or revoked refresh token) leaves the client with no
-- session, so it cannot use the RLS-gated delete on device_tokens ("device_tokens: own
-- tokens" needs auth.uid()), and the row kept routing that account's pushes to a phone that
-- is signed out. The APNs token is the one thing the phone still holds. It is not exposed
-- anywhere else (device_tokens is readable only by its own account and by the service role),
-- and detaching it only stops pushes to that device: it reads nothing and writes nothing
-- else, so anon may call it. Deleting by token alone matches the table's key (one row per
-- device, see register_device_token).
CREATE OR REPLACE FUNCTION public.detach_device_token(p_token TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
        RAISE EXCEPTION 'detach_device_token: token required';
    END IF;

    DELETE FROM public.device_tokens
    WHERE token = p_token;
END;
$$;

-- anon is granted on purpose: the caller has no session by definition.
REVOKE ALL ON FUNCTION public.detach_device_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.detach_device_token(TEXT) TO anon, authenticated;
