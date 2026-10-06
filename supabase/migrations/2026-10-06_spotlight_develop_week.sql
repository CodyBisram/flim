-- Spotlight: a frame can also go up in the week it developed (2026-10-06, nightly review
-- findings in docs/reviews/OPEN.md, both raised 2026-09-27). NOT YET APPLIED to production.
--
-- 1. The rule. put_up_for_spotlight (2026-09-26_spotlight_shot_this_week.sql) needs the post
--    made this week AND the photo shot this week. A roll frame shot Sunday night whose roll
--    develops after Monday 04:00 New York could not go up in the week it was shot (it was not
--    developed yet, so it could not be posted) and was refused in the next (shot last week), so
--    it could never go up at all. The same for a personal frame shot just before the boundary.
--    A frame now fits a week when it was SHOT that week, or DEVELOPED that week no more than
--    eight days after it was shot:
--
--        taken_at IS NOT NULL AND (
--            spotlight_week_key(taken_at) = week
--         OR (develops_at IS NOT NULL
--             AND spotlight_week_key(develops_at) = week
--             AND develops_at <= taken_at + 8 days))
--
--    Why that does not open the door to old frames: photos.develops_at is not client-writable
--    after insert (UPDATE on photos is column-scoped and leaves it out); a roll frame's is pinned
--    to rolls.reveal_at at insert by pin_roll_photo_develops_at and moved only by
--    set_roll_reveal_at, which bounds a reveal to seven days after the roll was made and refuses
--    once it has developed; a personal frame's is its capture plus the phone's short delay. Every
--    honest frame develops within seven days of being shot, so the eight-day bound (a day of
--    slack for a phone clock) admits all of them and nothing dug out of an older week: a frame
--    can be up in at most two consecutive weeks' windows, the one it was shot in and the one it
--    developed in. The rule lives in one helper, _spotlight_frame_fits_week, which the put-up
--    and the owner's queue both read, so the two cannot drift. The refusal is still
--    'not_this_week'. The app mirrors it (Flim/Models/Spotlight.swift); until the app does, the
--    app keeps hiding the item for such frames, which is the old behaviour, never a wrong offer.
--
-- 2. The queue. An entry put up before the 2026-09-26 rule existed, for a frame shot outside its
--    week, was choosable with nothing to tell it apart. list_spotlight_queue now returns the
--    frame's taken_at and develops_at and `outside_week`, TRUE when the frame does not fit its
--    entry's week by the rule above. A flag for the owner's judgement, like hidden_from_discovery;
--    choose_spotlight_entry does not refuse it. The return shape changes, so the old function is
--    dropped first. Owner-gated inside its body as before; EXECUTE stays revoked from anon.
--
-- Rerunnable as a whole. No table, column, policy or table grant changes.

-- ---------------------------------------------------------------------------------------------
-- 1. The rule, in one place.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._spotlight_frame_fits_week(
    p_taken_at    TIMESTAMPTZ,
    p_develops_at TIMESTAMPTZ,
    p_week        DATE
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_taken_at IS NOT NULL AND p_week IS NOT NULL AND (
        public.spotlight_week_key(p_taken_at) = p_week
        OR (p_develops_at IS NOT NULL
            AND public.spotlight_week_key(p_develops_at) = p_week
            AND p_develops_at <= p_taken_at + INTERVAL '8 days')
    );
$$;
REVOKE ALL ON FUNCTION public._spotlight_frame_fits_week(TIMESTAMPTZ, TIMESTAMPTZ, DATE) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. put_up_for_spotlight: the shot-this-week check reads the helper. Everything else is the
--    2026-09-26 definition unchanged. Same signature and return shape.
-- ---------------------------------------------------------------------------------------------
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
    -- This week's frame: shot this week, or developed this week (a roll that revealed after
    -- Monday 04:00), never an older frame dug out of the Darkroom. See _spotlight_frame_fits_week.
    IF NOT EXISTS (SELECT 1 FROM public.photos ph
                   WHERE ph.id = v_post.photo_id
                     AND public._spotlight_frame_fits_week(ph.taken_at, ph.develops_at, v_week)) THEN
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

-- ---------------------------------------------------------------------------------------------
-- 3. The queue says when each frame was shot and developed, and flags one outside its week.
--    The 2026-09-25_spotlight_hardening.sql definition plus three trailing columns.
-- ---------------------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_spotlight_queue(DATE);
CREATE FUNCTION public.list_spotlight_queue(p_week_key DATE DEFAULT NULL)
RETURNS TABLE (
    week_key              DATE,
    published_at          TIMESTAMPTZ,
    week_starts_at        TIMESTAMPTZ,
    post_id               UUID,
    user_id               UUID,
    username              TEXT,
    caption               TEXT,
    thumb_path            TEXT,
    feed_path             TEXT,
    storage_path          TEXT,
    post_created_at       TIMESTAMPTZ,
    put_up_at             TIMESTAMPTZ,
    chosen_at             TIMESTAMPTZ,
    removed_at            TIMESTAMPTZ,
    hidden                BOOLEAN,
    covered               BOOLEAN,
    tagged                BOOLEAN,
    hidden_from_discovery BOOLEAN,
    blocked_with_owner    BOOLEAN,
    taken_at              TIMESTAMPTZ,
    develops_at           TIMESTAMPTZ,
    outside_week          BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
    IF NOT public.is_owner() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT e.week_key,
           w.published_at,
           public._spotlight_week_start(e.week_key),
           e.post_id,
           e.user_id,
           u.username,
           po.caption,
           po.thumb_path,
           po.feed_path,
           po.storage_path,
           po.created_at,
           e.put_up_at,
           e.chosen_at,
           e.removed_at,
           (po.hidden OR COALESCE(ph.hidden, FALSE)),
           public.post_is_covered(po.user_id, po.created_at),
           EXISTS (SELECT 1 FROM public.post_tags t WHERE t.post_id = e.post_id),
           u.hidden_from_discovery,
           public.is_blocked_either_way(auth.uid(), e.user_id),
           ph.taken_at,
           ph.develops_at,
           NOT public._spotlight_frame_fits_week(ph.taken_at, ph.develops_at, e.week_key)
    FROM public.spotlight_entries e
    JOIN public.posts po ON po.id = e.post_id
    JOIN public.users u ON u.id = e.user_id
    LEFT JOIN public.photos ph ON ph.id = po.photo_id
    LEFT JOIN public.spotlight_weeks w ON w.week_key = e.week_key
    WHERE CASE
            WHEN p_week_key IS NULL THEN public._spotlight_week_pending(e.week_key)
            ELSE e.week_key = p_week_key
          END
    ORDER BY e.week_key DESC, e.put_up_at ASC, e.post_id ASC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_spotlight_queue(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_spotlight_queue(DATE) TO authenticated;
