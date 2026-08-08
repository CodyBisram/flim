-- ============================================================
-- Contextual reaction-bar emoji (FLIM 1.4). The reaction bar's first three emoji
-- (❤️ 🔥 😂) stay fixed; the last two become suggestions derived on-device at
-- capture time from Vision's VNClassifyImageRequest (no model shipped, no image
-- ever leaves the phone for this). This migration stores that result and makes
-- sure it cannot spoil the reveal.
--
-- WHY THIS IS NOT A COLUMN ON public.photos, despite that being the natural first
-- instinct (and how the task that produced this file was originally framed):
--
-- `public.photos` already has table-wide SELECT granted to anon/authenticated
-- (Supabase's default privileges at CREATE TABLE time), and its two SELECT
-- policies ("photos: own photos", "photos: roll members can see") make a roll
-- member's photo ROW readable the moment it's inserted, well before
-- develops_at, RLS on this table has never gated on develops_at, because the
-- client needs the countdown itself. Verified live against production
-- 2026-08-08 (synthetic rows, rolled back, see the agent report for the
-- transcript): as the NON-owning member of a roll whose develops_at was hours in
-- the future, `SELECT * FROM public.photos WHERE id = <roll-mate's photo>`
-- returned the full row.
--
-- A plain new column on that table inherits that exposure, and column-level
-- GRANT/REVOKE cannot fix it. Also verified live: once a table-wide SELECT grant
-- exists, `REVOKE SELECT (col) ... FROM authenticated` is a no-op
-- (has_column_privilege() still returns true for that role/column afterward).
-- The only privilege shape that actually withholds a single column, REVOKE the
-- whole table's SELECT then GRANT back an explicit column allowlist (the same
-- pattern already used for `users`/`profiles` elsewhere in this file), was also
-- verified live to break every existing `.select()` call with no explicit column
-- list in PhotoService/FeedService/RollService: those resolve to `select=*`,
-- which requires table-wide privilege and fails with "permission denied for
-- table photos" the instant that privilege is narrowed to a column allowlist.
-- Fixing that would mean rewriting every such call site to name its columns
-- explicitly, a Swift-side change out of this change's scope and ownership.
--
-- A sibling table sidesteps all of it: it starts with zero grants and zero
-- policies of its own, is reachable only through the two SECURITY DEFINER
-- functions below, and requires no change to any existing photos read path.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_suggested_emoji (
    photo_id        UUID PRIMARY KEY REFERENCES public.photos(id) ON DELETE CASCADE,
    -- TEXT[] over a delimited TEXT: these are two independent, order-meaningful
    -- tokens, not a blob to parse. An array needs no delimiter (and no escaping
    -- headache if an emoji's UTF-8 bytes ever collided with one), decodes to
    -- Swift as a plain `[String]`, and Postgres's array overhead for 1-2 short
    -- text elements is a few bytes, not worth trading query/decode simplicity
    -- for. cardinality is bounded by the CHECK below, not by array length limits.
    suggested_emoji TEXT[] NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT photo_suggested_emoji_count CHECK (cardinality(suggested_emoji) BETWEEN 1 AND 2)
);
-- No row at all is how "classification failed" or "below the confidence floor"
-- is represented, not a NULL array, this table is an optional 1:1 extension of
-- photos, and every existing photo correctly has no row.

ALTER TABLE public.photo_suggested_emoji ENABLE ROW LEVEL SECURITY;
-- No policies, at all, on purpose, same shape as allowed_emails / digest_state /
-- feedback elsewhere in this file: RLS enabled with no matching policy already
-- denies every row to anon/authenticated for every command, and the REVOKE
-- below is defense in depth for exactly the reason this project keeps hitting,
-- Supabase grants ALL on a new table to anon/authenticated at CREATE time, and
-- REVOKE FROM PUBLIC alone does not remove those two roles' own named grants.
REVOKE ALL ON public.photo_suggested_emoji FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Write path: the capturing user sets suggestions for their OWN photo only.
-- Ownership is checked inside this definer body (photos.user_id = auth.uid())
-- rather than via a table policy, because this value's table carries no
-- policies of its own (see above), this is the same authorization SHAPE as
-- "photos: can update own" (the policy PhotoService.uploadRenditions already
-- writes thumb_path/feed_path through), just enforced in code instead of in a
-- USING/WITH CHECK clause, since the value now lives off of `photos` itself.
-- Passing NULL or an empty array clears any existing suggestion (used if a
-- later, better classification run wants to withdraw a low-confidence guess).
-- ------------------------------------------------------------
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

    IF cardinality(p_emoji) > 2 THEN
        RAISE EXCEPTION 'at most two suggested emoji' USING ERRCODE = 'P0004';
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

-- anon explicitly revoked, not just PUBLIC, same reasoning as the REVOKE above.
REVOKE ALL ON FUNCTION public.set_photo_suggested_emoji(UUID, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_photo_suggested_emoji(UUID, TEXT[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_photo_suggested_emoji(UUID, TEXT[]) TO authenticated;

-- ------------------------------------------------------------
-- Read path: the reveal gate. A photo's own owner can always read their own
-- suggestion back (it's their photo; they already know what's in it, no spoiler
-- risk). Anyone else, a fellow roll member, only gets it once that photo's
-- develops_at has passed, mirrors "photos: roll members can see" (roll
-- membership, NOT hidden, NOT blocked) plus the one predicate that policy is
-- missing on purpose everywhere else, develops_at <= now(). Batched by an array
-- of photo ids (feed/roll views render many photos at once, one RPC beats N),
-- and a photo id the caller isn't allowed to see (wrong id, undeveloped
-- roll-mate's photo, blocked party, hidden) is silently absent from the result,
-- never an error, so a client can't distinguish "not visible yet" from "no
-- suggestion exists" by error shape, both just produce no row for that id.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_suggested_emoji(p_photo_ids UUID[])
RETURNS TABLE (photo_id UUID, suggested_emoji TEXT[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT s.photo_id, s.suggested_emoji
    FROM public.photo_suggested_emoji s
    JOIN public.photos p ON p.id = s.photo_id
    WHERE s.photo_id = ANY(p_photo_ids)
      AND NOT p.hidden
      AND (
            p.user_id = auth.uid()
            OR (
                p.roll_id IS NOT NULL
                AND public.is_roll_member(p.roll_id)
                AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
                AND p.develops_at <= now()
              )
          );
$$;

REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_suggested_emoji(UUID[]) TO authenticated;
