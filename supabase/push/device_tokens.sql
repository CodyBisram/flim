-- ============================================================
-- FLIM, remote push: device token storage
-- Run in the Supabase SQL editor AFTER schema.sql.
-- Needed only for REMOTE push (a roll-mate's photo developing on
-- their device). The app's local notifications cover "your own photo
-- developed" with no backend.
-- ============================================================

-- The key is the token alone. A token identifies one physical device, and a device
-- has exactly one account signed in at a time, so keying on (user_id, token) would
-- let one phone belong to several accounts at once and receive all of their pushes.
-- An existing install is moved to this shape by
-- ../migrations/2026-08-06_device_token_one_per_device.sql, which explains the leak
-- that made it necessary.
CREATE TABLE IF NOT EXISTS public.device_tokens (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    token      TEXT PRIMARY KEY,                    -- APNs device token (hex)
    platform   TEXT NOT NULL DEFAULT 'ios',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- A user can only see / write their own device tokens.
DROP POLICY IF EXISTS "device_tokens: own tokens" ON public.device_tokens;
CREATE POLICY "device_tokens: own tokens"
    ON public.device_tokens FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Helpful index for the Edge Function fan-out (look up tokens by user). Not implied
-- by the primary key, which is the token.
CREATE INDEX IF NOT EXISTS device_tokens_user_idx ON public.device_tokens (user_id);

-- Registration has to be able to move a device from one account to another, and
-- plain RLS cannot: an upsert becomes ON CONFLICT (token) DO UPDATE, whose USING
-- clause is checked against the row that still belongs to the previous account, so
-- the reassignment is silently filtered out. This function is the only way in.
-- It writes auth.uid() and nothing else, so a caller can only ever claim a device
-- for themselves.
CREATE OR REPLACE FUNCTION public.register_device_token(
    p_token    TEXT,
    p_platform TEXT DEFAULT 'ios'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'register_device_token: not authenticated';
    END IF;

    IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
        RAISE EXCEPTION 'register_device_token: token required';
    END IF;

    DELETE FROM public.device_tokens
    WHERE token = p_token
      AND user_id <> auth.uid();

    INSERT INTO public.device_tokens (user_id, token, platform, updated_at)
    VALUES (auth.uid(), p_token, COALESCE(p_platform, 'ios'), NOW())
    ON CONFLICT (token) DO UPDATE
        SET user_id    = auth.uid(),
            platform   = EXCLUDED.platform,
            updated_at = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.register_device_token(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_device_token(TEXT, TEXT) TO authenticated;

-- Track which developed photos have already triggered a remote push so the
-- scheduled Edge Function doesn't notify the same shot twice.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- Social push: notify a post's owner when someone comments or reacts. Same "poll +
-- push_sent flag" pattern as develop push (see send-social-push Edge Function).
ALTER TABLE public.post_comments  ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.post_reactions ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS post_comments_unpushed_idx  ON public.post_comments (push_sent) WHERE push_sent = FALSE;
CREATE INDEX IF NOT EXISTS post_reactions_unpushed_idx ON public.post_reactions (push_sent) WHERE push_sent = FALSE;

-- Roll photo comments: notify the photo owner + that photo's thread (see send-social-push).
ALTER TABLE public.photo_comments ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS photo_comments_unpushed_idx ON public.photo_comments (push_sent) WHERE push_sent = FALSE;
