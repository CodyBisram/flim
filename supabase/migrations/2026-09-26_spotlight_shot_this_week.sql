-- Spotlight: a frame goes up only if it was SHOT this week (2026-09-26, the owner's rule).
-- NOT APPLIED: the owner applies it before 1.6.0 is released.
--
-- put_up_for_spotlight already required the post to be made this week. A frame shot months ago
-- and posted today passed that, while the app says "one frame you shot that week". This adds one
-- check, the photo's own capture time (photos.taken_at) in the current week, refused as
-- 'not_this_week'; the app maps that to "Only frames shot this week can go up." and its menu no
-- longer offers such a frame. Everything else in the function is unchanged. A frame already up
-- this week is not touched: the check runs only on a put-up.
--
-- Same signature and return shape, so CREATE OR REPLACE is enough; grants restated as before.

CREATE OR REPLACE FUNCTION public.put_up_for_spotlight(p_post_id UUID)
RETURNS TABLE (
    week_key                 DATE,
    week_starts_at           TIMESTAMPTZ,
    week_closes_at           TIMESTAMPTZ,
    post_id                  UUID,
    put_up_at                TIMESTAMPTZ,
    replaced_post_id         UUID,
    replaced_post_created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_uid        UUID := auth.uid();
    v_week       DATE := public.spotlight_week_key(now());
    v_post       RECORD;
    v_old_post   UUID;
    v_old_at     TIMESTAMPTZ;
    v_put        TIMESTAMPTZ;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_signed_in' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('spotlight:' || v_uid::text, 0));

    SELECT po.id, po.photo_id, po.hidden, po.created_at INTO v_post
    FROM public.posts po
    WHERE po.id = p_post_id AND po.user_id = v_uid
    FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = v_post.photo_id AND ph.user_id = v_uid) THEN
        RAISE EXCEPTION 'not_photographer' USING ERRCODE = 'P0001';
    END IF;
    IF v_post.hidden OR EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = v_post.photo_id AND ph.hidden) THEN
        RAISE EXCEPTION 'hidden' USING ERRCODE = 'P0001';
    END IF;
    IF v_post.created_at IS NULL OR public.spotlight_week_key(v_post.created_at) <> v_week THEN
        RAISE EXCEPTION 'week_closed' USING ERRCODE = 'P0001';
    END IF;
    -- Shot this week, not only posted this week: a frame dug out of the Darkroom from months ago
    -- posts today but was not this week's. The capture time is the photo's own taken_at.
    IF NOT EXISTS (SELECT 1 FROM public.photos ph
                   WHERE ph.id = v_post.photo_id AND ph.taken_at IS NOT NULL
                     AND public.spotlight_week_key(ph.taken_at) = v_week) THEN
        RAISE EXCEPTION 'not_this_week' USING ERRCODE = 'P0001';
    END IF;
    IF public.post_is_covered(v_uid, v_post.created_at) THEN
        RAISE EXCEPTION 'covered' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.post_tags t WHERE t.post_id = p_post_id) THEN
        RAISE EXCEPTION 'tagged' USING ERRCODE = 'P0001';
    END IF;

    SELECT e.post_id, po.created_at INTO v_old_post, v_old_at
    FROM public.spotlight_entries e
    LEFT JOIN public.posts po ON po.id = e.post_id
    WHERE e.user_id = v_uid AND e.week_key = v_week;

    INSERT INTO public.spotlight_entries AS e (post_id, user_id, week_key, put_up_at)
    VALUES (p_post_id, v_uid, v_week, now())
    ON CONFLICT (user_id, week_key) DO UPDATE
        SET post_id   = EXCLUDED.post_id,
            put_up_at = CASE WHEN e.post_id = EXCLUDED.post_id THEN e.put_up_at ELSE EXCLUDED.put_up_at END
        WHERE e.chosen_at IS NULL AND e.removed_at IS NULL
    RETURNING e.put_up_at INTO v_put;
    IF v_put IS NULL THEN
        -- The row exists and is chosen or removed: only possible for a week that has closed.
        RAISE EXCEPTION 'week_closed' USING ERRCODE = 'P0001';
    END IF;

    RETURN QUERY SELECT
        v_week,
        public._spotlight_week_start(v_week),
        public._spotlight_week_start(v_week + 7),
        p_post_id,
        v_put,
        CASE WHEN v_old_post IS DISTINCT FROM p_post_id THEN v_old_post END,
        CASE WHEN v_old_post IS DISTINCT FROM p_post_id THEN v_old_at END;
END;
$$;
REVOKE ALL ON FUNCTION public.put_up_for_spotlight(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.put_up_for_spotlight(UUID) TO authenticated;
