-- ============================================================
-- Migration: one device token belongs to exactly one account
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- THE BUG THIS FIXES
--
-- device_tokens was created with PRIMARY KEY (user_id, token). A token identifies
-- a physical device, so a composite key says "this device may belong to any number
-- of accounts at once", which is never true. Signing in as a second account on one
-- phone inserted a SECOND row rather than moving the device, and signing out
-- deleted nothing at all. Every account that had ever signed in on a device kept a
-- live row pointing at it.
--
-- The push functions then did exactly what they were told: they looked up the
-- recipient's tokens and delivered. So a digest addressed to account A arrived on
-- the phone of whoever was currently signed in as account B, carrying A's follow
-- list in the title. That is a privacy leak, not just a stray notification, which
-- is why the backfill below deletes rather than reassigns anything it cannot
-- attribute with confidence.
--
-- AFTER THIS RUNS
--
--   * token is the primary key, so a device exists once.
--   * register_device_token() moves a device between accounts, which plain RLS
--     cannot do (see the comment on the function).
--   * The client deletes its row on sign-out.
-- ============================================================

-- ---- 1. Collapse duplicates -------------------------------------------------
--
-- Keep only the most recently updated row per token: that is the account that
-- registered the device last, which is the best available evidence of who is
-- actually holding the phone. Every other row is a stale registration from an
-- account that signed out (or was signed out from under) long ago.
--
-- ctid rather than a column tiebreak so this is exact even when two rows share an
-- updated_at to the microsecond.

DELETE FROM public.device_tokens dt
WHERE dt.ctid NOT IN (
    SELECT DISTINCT ON (token) ctid
    FROM public.device_tokens
    ORDER BY token, updated_at DESC, ctid DESC
);

-- ---- 2. token becomes the primary key ---------------------------------------
--
-- Guarded on the key still being composite, so re-running this file is a no-op
-- rather than an error.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'device_tokens'
          AND c.contype = 'p'
          AND array_length(c.conkey, 1) = 2
    ) THEN
        ALTER TABLE public.device_tokens DROP CONSTRAINT device_tokens_pkey;
        ALTER TABLE public.device_tokens ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (token);
    END IF;
END $$;

-- The fan-out still looks tokens up by user, and that index is no longer implied
-- by the primary key now that the key is token alone.
CREATE INDEX IF NOT EXISTS device_tokens_user_idx ON public.device_tokens (user_id);

-- ---- 3. Registration, which has to cross accounts ---------------------------
--
-- SECURITY DEFINER is load-bearing here, not convenience. With token as the key,
-- a client upsert becomes INSERT ... ON CONFLICT (token) DO UPDATE. RLS evaluates
-- the UPDATE arm's USING clause against the EXISTING row, which still belongs to
-- the previous account, so `user_id = auth.uid()` is false and the reassignment is
-- silently filtered out. The device would stay attached to the old account and the
-- bug would survive the schema change.
--
-- The function is still tightly bound: it only ever writes auth.uid(), so a caller
-- cannot attach a device to anyone but themselves, and it refuses to run
-- unauthenticated. search_path is pinned so a caller cannot shadow public.
--
-- It also covers the case sign-out cannot: reinstalling the app, or restoring the
-- phone, where the old row was never deleted because sign-out never happened.

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

    -- This device is no longer any other account's device.
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

-- Sign-out needs no function: the row belongs to the caller at that moment, so the
-- existing "own tokens" policy already permits the DELETE.
