-- ============================================================
-- Migration: darkroom_month_counts, Phase B of the approved Darkroom
-- redesign (the owner-side piece behind the year jump sheet; the
-- surrounding day-unit/band layout is Phase A, client-only, tracked
-- separately).
--
-- WHY A SERVER AGGREGATE: the jump sheet needs a count per month over the
-- caller's WHOLE personal library, not just whatever page happens to be
-- loaded. Deriving it from loaded 30-row pages is the app's known
-- undercount bug (see PhotoService's pagination trap). One RPC returns
-- the whole archive's month histogram in a single round trip.
--
-- SCOPE: exactly the filter `fetchPersonalPhotos` and `personalPhotoCount`
-- already use, user_id = caller AND is_sorted = true. Nothing about any
-- other user's photos.
--
-- GROUPING: taken_at shifted back 4 hours (FeedUnit.dayBoundaryHour, the
-- app's 04:00 local day boundary), then truncated to month IN THE ZONE
-- THE CLIENT PASSES. The zone is a parameter, never a server default,
-- because the count aggregate and the client's own local grouping have to
-- agree on one zone or the totals won't reconcile with what's on screen.
--
-- INVOKER, NOT DEFINER: this function only ever reads the caller's own
-- rows, filtered explicitly by auth.uid() in the WHERE clause below, so it
-- needs no elevated privilege to see anything RLS would otherwise hide.
-- Running as invoker keeps normal RLS enforcement on public.photos as a
-- second, independent gate on top of the explicit filter, rather than
-- punching through it the way SECURITY DEFINER would. (Contrast
-- is_email_allowed/redeem_invite above, which must read tables RLS
-- deliberately hides from every role, and so must run as definer.)
--
-- AUTHORIZATION: auth.uid() only, never a user-id parameter, a parameter
-- would let any authenticated caller read another user's monthly activity
-- histogram.
--
-- TIMEZONE INPUT: validated against pg_timezone_names. An unrecognized or
-- garbage string falls back to UTC rather than raising, so a client-side
-- typo degrades to a wrong-but-harmless grouping instead of an error the
-- jump sheet has to handle.
-- ============================================================

CREATE OR REPLACE FUNCTION public.darkroom_month_counts(p_timezone TEXT)
RETURNS TABLE(month_start DATE, photo_count INTEGER)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_tz TEXT;
BEGIN
    SELECT name INTO v_tz FROM pg_timezone_names WHERE name = p_timezone;
    IF v_tz IS NULL THEN
        v_tz := 'UTC';
    END IF;

    RETURN QUERY
    SELECT
        date_trunc('month', (p.taken_at - interval '4 hours') AT TIME ZONE v_tz)::date AS month_start,
        count(*)::integer AS photo_count
    FROM public.photos p
    WHERE p.user_id = auth.uid()
      AND p.is_sorted = true
    GROUP BY 1
    ORDER BY 1;
END;
$$;

REVOKE ALL ON FUNCTION public.darkroom_month_counts(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.darkroom_month_counts(TEXT) TO authenticated;
