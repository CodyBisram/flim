-- ============================================================
-- FLIM — remote push: device token storage
-- Run in the Supabase SQL editor AFTER schema.sql.
-- Needed only for REMOTE push (a roll-mate's photo developing on
-- their device). The app's local notifications cover "your own photo
-- developed" with no backend.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.device_tokens (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    token      TEXT NOT NULL,                       -- APNs device token (hex)
    platform   TEXT NOT NULL DEFAULT 'ios',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, token)
);

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- A user can only see / write their own device tokens.
DROP POLICY IF EXISTS "device_tokens: own tokens" ON public.device_tokens;
CREATE POLICY "device_tokens: own tokens"
    ON public.device_tokens FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Helpful index for the Edge Function fan-out (look up tokens by user).
CREATE INDEX IF NOT EXISTS device_tokens_user_idx ON public.device_tokens (user_id);

-- Track which developed photos have already triggered a remote push so the
-- scheduled Edge Function doesn't notify the same shot twice.
ALTER TABLE public.photos ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- Social push: notify a post's owner when someone comments or reacts. Same "poll +
-- push_sent flag" pattern as develop push (see send-social-push Edge Function).
ALTER TABLE public.post_comments  ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.post_reactions ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS post_comments_unpushed_idx  ON public.post_comments (push_sent) WHERE push_sent = FALSE;
CREATE INDEX IF NOT EXISTS post_reactions_unpushed_idx ON public.post_reactions (push_sent) WHERE push_sent = FALSE;
