-- Three contextual suggestions per photo, up from two.
--
-- The reaction bar grows a sixth slot: three fixed reactions, then up to three suggested by
-- on-device classification, backfilled from the fallback set. Measured on device by the owner:
-- six chips plus the picker button all stay legible on a 393pt screen.
--
-- Ships BEFORE the client change: an old client storing two remains valid under the widened
-- check, but a new client storing three under the old check would have every insert rejected,
-- which silently kills the feature for every newly shot photo.
alter table public.photo_suggested_emoji
  drop constraint if exists photo_suggested_emoji_count;
alter table public.photo_suggested_emoji
  add constraint photo_suggested_emoji_count
  check (cardinality(suggested_emoji) between 1 and 3);

-- The RPC carries the same cap in its own body; the two must agree.
CREATE OR REPLACE FUNCTION public.set_photo_suggested_emoji(p_photo_id UUID, p_emoji TEXT[])
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.photos WHERE id = p_photo_id AND user_id = auth.uid()
    ) THEN
        RETURN FALSE;
    END IF;

    IF p_emoji IS NULL OR cardinality(p_emoji) = 0 THEN
        DELETE FROM public.photo_suggested_emoji WHERE photo_id = p_photo_id;
        RETURN TRUE;
    END IF;

    IF cardinality(p_emoji) > 3 THEN
        RAISE EXCEPTION 'at most three suggested emoji' USING ERRCODE = 'P0004';
    END IF;

    IF EXISTS (
        SELECT 1 FROM unnest(p_emoji) e WHERE e IS NULL OR octet_length(e) NOT BETWEEN 1 AND 32
    ) THEN
        RAISE EXCEPTION 'invalid suggested emoji' USING ERRCODE = 'P0004';
    END IF;

    INSERT INTO public.photo_suggested_emoji (photo_id, suggested_emoji, updated_at)
    VALUES (p_photo_id, p_emoji, NOW())
    ON CONFLICT (photo_id) DO UPDATE
        SET suggested_emoji = EXCLUDED.suggested_emoji,
            updated_at      = NOW();

    RETURN TRUE;
END;
$$;
