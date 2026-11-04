-- FLIM v2, product rule 9: a screening anyone can watch from a link. Additive. FLIM Dev only for
-- now; production only with v2's launch, after the public page ships.
--
-- What the owner decided (2026-11-03):
--   * A roll's link plays the whole roll, everyone's prints, and ANY member can stop it.
--   * Every link ends after 7 days; stopping it sooner is always possible.
--   * The public page shows no names: the roll's name (or the month), the dates and the prints.
--
-- The shape, and why:
--   * One table, readable by nobody but these functions (RLS on, no policies, no grants). The
--     token is the whole secret: 18 random bytes (144 bits), url-safe base64, 24 characters.
--   * One live link per roll, shared by every member: a member who shares finds the link already
--     there instead of minting a second, and "Stop sharing" ends it for everyone. A month's link
--     is its owner's alone.
--   * The public read is NOT granted to anon. Only service_role may call it, from the
--     public-screening edge function, which streams the bytes of the prints the read names (no
--     storage URL, which would carry an account id, ever leaves). Nobody signed out ever touches
--     a table, a policy or the storage bucket directly.
--   * What plays is decided at watch time, not at share time: a print deleted, hidden, put away
--     or covered since the link was made drops out; so does every print by someone blocked
--     either way with ANY current member (one link serves every member, so the block rule has
--     to hold for all of them), and every print by someone no longer in the roll (they could not
--     stop it); a sharer who leaves the roll ends their link.
--   * Only the feed rendition plays (JPEG, 1400px), never the full-size master, and only a path
--     of exactly `<author id>/<name>.jpg`: a path is client-writable, and the function reads it
--     with the service key, so anything else (a `..`, a query string) never leaves this read.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.screening_links (
    token       TEXT PRIMARY KEY CHECK (token ~ '^[A-Za-z0-9_-]{24}$'),
    created_by  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    roll_id     UUID REFERENCES public.rolls(id) ON DELETE CASCADE,
    month_start DATE CHECK (month_start IS NULL OR month_start = date_trunc('month', month_start)::date),
    -- The month's own zone, as chapter_photos buckets it; fixed at share time.
    timezone    TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ NOT NULL,
    stopped_at  TIMESTAMPTZ,
    stopped_by  UUID REFERENCES public.users(id) ON DELETE SET NULL,
    CHECK ((roll_id IS NULL) <> (month_start IS NULL))
);
ALTER TABLE public.screening_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.screening_links FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS screening_links_roll ON public.screening_links (roll_id) WHERE roll_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS screening_links_month ON public.screening_links (created_by, month_start) WHERE month_start IS NOT NULL;

-- A link that still plays.
CREATE OR REPLACE FUNCTION public.screening_link_is_live(l public.screening_links)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT l.stopped_at IS NULL
       AND l.expires_at > now()
       AND (l.roll_id IS NULL
            OR EXISTS (SELECT 1 FROM public.roll_members m WHERE m.roll_id = l.roll_id AND m.user_id = l.created_by));
$$;
REVOKE ALL ON FUNCTION public.screening_link_is_live(public.screening_links) FROM PUBLIC, anon, authenticated;

-- Whether the caller may share, see or stop a link for this target: a member of a developed roll,
-- or the owner of the month.
CREATE OR REPLACE FUNCTION public.screening_target_allowed(p_roll_id UUID, p_month_start DATE)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() IS NOT NULL
       AND ((p_roll_id IS NULL) <> (p_month_start IS NULL))
       AND CASE
             WHEN p_roll_id IS NOT NULL THEN
                 EXISTS (SELECT 1 FROM public.roll_members m WHERE m.roll_id = p_roll_id AND m.user_id = auth.uid())
                 AND public.is_roll_developed(p_roll_id)
             ELSE p_month_start = date_trunc('month', p_month_start)::date
           END;
$$;
REVOKE ALL ON FUNCTION public.screening_target_allowed(UUID, DATE) FROM PUBLIC, anon, authenticated;

-- The live link for a roll (any member's) or for the caller's own month, if there is one.
CREATE OR REPLACE FUNCTION public.screening_link_status(p_roll_id UUID DEFAULT NULL, p_month_start DATE DEFAULT NULL)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ, shared_by_me BOOLEAN)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT l.token, l.expires_at, l.created_by = auth.uid()
    FROM public.screening_links l
    WHERE public.screening_target_allowed(p_roll_id, p_month_start)
      AND public.screening_link_is_live(l)
      AND CASE WHEN p_roll_id IS NOT NULL THEN l.roll_id = p_roll_id
               ELSE l.month_start = p_month_start AND l.created_by = auth.uid() END
    ORDER BY l.created_at DESC
    LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.screening_link_status(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.screening_link_status(UUID, DATE) TO authenticated;

-- Shares: returns the live link for the target, minting one (7 days) when there is none.
CREATE OR REPLACE FUNCTION public.screening_link_open(p_roll_id UUID DEFAULT NULL, p_month_start DATE DEFAULT NULL,
                                                      p_timezone TEXT DEFAULT 'America/New_York')
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ, shared_by_me BOOLEAN)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_token TEXT;
BEGIN
    IF NOT public.screening_target_allowed(p_roll_id, p_month_start) THEN
        RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
    END IF;
    -- One live link per roll (and per month): serialize sharers of the same target.
    PERFORM pg_advisory_xact_lock(hashtext('screening:' || COALESCE(p_roll_id::text, auth.uid()::text || ':' || p_month_start::text)));
    RETURN QUERY SELECT * FROM public.screening_link_status(p_roll_id, p_month_start);
    IF FOUND THEN RETURN; END IF;
    -- A ceiling on minting, not on sharing: thirty new links a day per person is far past any use.
    IF (SELECT count(*) FROM public.screening_links WHERE created_by = auth.uid() AND created_at > now() - interval '1 day') >= 30 THEN
        RAISE EXCEPTION 'too many links today' USING ERRCODE = '54000';
    END IF;
    v_token := translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_');
    INSERT INTO public.screening_links (token, created_by, roll_id, month_start, timezone, expires_at)
    VALUES (v_token, auth.uid(), p_roll_id, p_month_start,
            CASE WHEN p_month_start IS NOT NULL THEN public.chapter_timezone(p_timezone) END,
            now() + interval '7 days');
    RETURN QUERY SELECT * FROM public.screening_link_status(p_roll_id, p_month_start);
END;
$$;
REVOKE ALL ON FUNCTION public.screening_link_open(UUID, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.screening_link_open(UUID, DATE, TEXT) TO authenticated;

-- Stops every live link for the target: any member, for a roll; the owner, for a month.
CREATE OR REPLACE FUNCTION public.screening_link_stop(p_roll_id UUID DEFAULT NULL, p_month_start DATE DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- A roll's member may stop it even if the roll somehow reads undeveloped again; membership is
    -- what matters for stopping.
    IF auth.uid() IS NULL OR ((p_roll_id IS NULL) = (p_month_start IS NULL))
       OR (p_roll_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.roll_members m WHERE m.roll_id = p_roll_id AND m.user_id = auth.uid())) THEN
        RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
    END IF;
    UPDATE public.screening_links l
    SET stopped_at = now(), stopped_by = auth.uid()
    WHERE l.stopped_at IS NULL
      AND CASE WHEN p_roll_id IS NOT NULL THEN l.roll_id = p_roll_id
               ELSE l.month_start = p_month_start AND l.created_by = auth.uid() END;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.screening_link_stop(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.screening_link_stop(UUID, DATE) TO authenticated;

-- The public read, for the public-screening edge function ONLY (service_role). NULL for a token
-- that does not play, whatever the reason, so the page cannot tell expired from never-existed.
-- Returns the prints' storage paths (the function streams them and never passes a path on),
-- when each was taken, burst grouping so the page can play a burst as one print as the app does
-- (a burst is one person's, so it groups those prints, nothing more), and a count of people.
CREATE OR REPLACE FUNCTION public.screening_by_token(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    l public.screening_links;
    v_title TEXT;
    v_prints JSONB;
    v_people INTEGER := 1;
BEGIN
    IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{24}$' THEN RETURN NULL; END IF;
    SELECT * INTO l FROM public.screening_links WHERE token = p_token;
    IF NOT FOUND OR NOT public.screening_link_is_live(l) THEN RETURN NULL; END IF;

    IF l.roll_id IS NOT NULL THEN
        SELECT r.name INTO v_title FROM public.rolls r WHERE r.id = l.roll_id AND r.reveal_at <= now();
        IF v_title IS NULL THEN RETURN NULL; END IF;
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'path', p.feed_path,
                   'takenAt', p.taken_at,
                   'burst', p.burst_group,
                   'sharpness', p.sharpness) ORDER BY p.taken_at), '[]'::jsonb),
               count(DISTINCT p.user_id)
        INTO v_prints, v_people
        FROM (
            SELECT p.*
            FROM public.photos p
            WHERE p.roll_id = l.roll_id
              AND NOT p.hidden
              AND NOT COALESCE(p.is_miss, FALSE)
              AND p.feed_path ~ ('^' || p.user_id::text || '/[A-Za-z0-9_-]+\.jpe?g$')
              AND EXISTS (SELECT 1 FROM public.roll_members m WHERE m.roll_id = l.roll_id AND m.user_id = p.user_id)
              AND NOT EXISTS (SELECT 1 FROM public.roll_members m
                              WHERE m.roll_id = l.roll_id AND public.is_blocked_either_way(m.user_id, p.user_id))
            ORDER BY p.taken_at
            LIMIT 500
        ) p;
    ELSE
        v_title := to_char(l.month_start, 'FMMonth YYYY');
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'path', s.feed_path,
                   'takenAt', s.taken_at,
                   'burst', NULL,
                   'sharpness', NULL) ORDER BY s.taken_at), '[]'::jsonb)
        INTO v_prints
        FROM (
            SELECT po.feed_path, po.taken_at
            FROM public.posts po
            JOIN public.photos ph ON ph.id = po.photo_id
            WHERE po.user_id = l.created_by
              -- Their own photographs: a post can carry a roll-mate's photo, and that person
              -- never chose this page and could not stop it.
              AND ph.user_id = l.created_by
              AND NOT ph.hidden
              AND po.feed_path ~ ('^' || l.created_by::text || '/[A-Za-z0-9_-]+\.jpe?g$')
              AND NOT po.hidden
              AND NOT po.put_away
              AND NOT COALESCE(ph.is_miss, FALSE)
              AND NOT public.post_is_covered(po.user_id, po.created_at)
              AND date_trunc('month', po.taken_at AT TIME ZONE COALESCE(l.timezone, 'America/New_York'))::date = l.month_start
            ORDER BY po.taken_at
            LIMIT 500
        ) s;
    END IF;

    RETURN jsonb_build_object(
        'kind', CASE WHEN l.roll_id IS NOT NULL THEN 'roll' ELSE 'month' END,
        'title', v_title,
        'expiresAt', l.expires_at,
        -- How many took the prints, never who: the closing card's "by six friends".
        'people', v_people,
        'prints', v_prints);
END;
$$;
REVOKE ALL ON FUNCTION public.screening_by_token(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.screening_by_token(TEXT) TO service_role;
