-- Spotlight hardening (2026-09-25), after the independent audit of 1.6.0. Runs after
-- 2026-09-25_spotlight.sql, which is applied to production; nothing here edits that file's rows.
--
--   1. Weeks can be skipped, and go stale. spotlight_weeks.skipped_at, set only by the owner's
--      close_spotlight_week. A week whose close was more than 14 days ago is stale. Neither kind
--      can be chosen in, unchosen in or published (week_skipped, week_stale), both leave the
--      queue and the Monday alert, and neither locks tags or captions any more.
--   2. Captions lock the way tags do. A caption can no longer change while a frame is up this
--      week, or chosen in a week that is published or still pending, because the posts policy
--      serves the caption to everyone once the week is published.
--   3. Strangers cannot hide a published frame by reporting it. On a photo that has been in
--      Spotlight, the automatic hide counts only reporters in its pre-Spotlight audience
--      (followers, tagged people, the author, members of its roll). Every report still inserts
--      and still reaches the owner's reported-photos queue.
--   4. Choose refuses a frame in a block with the owner (blocked). Publish counts, and badges,
--      only frames that are not hidden (post or photo) and not covered; so does the ratchet's
--      spotlight predicate, which every profile read runs, so a later ratchet cannot award it,
--      and the public reads skip a hidden photo as they already skipped a hidden post.
--   5. Withdraw works until publish. The photographer can take their entry down from a closed
--      week that is still pending (not published, skipped or stale), chosen or not; the week row
--      lock makes withdraw and publish serialise. own_spotlight_entry() names that entry.
--
-- Pinned contracts: the caption refusal is P0001 'in_spotlight'. own_spotlight_entry() gains
-- pending_week_key TEXT, pending_post_id UUID, pending_photo_id UUID, all NULL when nothing is
-- pending; its existing columns are unchanged.
--
-- Safe to re-run: IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF EXISTS before every recreate.
-- Nothing here deletes or rewrites existing rows.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Skipped and stale weeks.
-- ---------------------------------------------------------------------------
ALTER TABLE public.spotlight_weeks ADD COLUMN IF NOT EXISTS skipped_at TIMESTAMPTZ;

-- TRUE once more than 14 days have passed since the week closed (its next Monday, 04:00 Eastern).
-- p_now exists so the Monday alert can ask about its own clock; everything else passes nothing.
CREATE OR REPLACE FUNCTION public._spotlight_week_stale(p_week DATE, p_now TIMESTAMPTZ DEFAULT now())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_now > public._spotlight_week_start(p_week + 7) + INTERVAL '14 days';
$$;
REVOKE ALL ON FUNCTION public._spotlight_week_stale(DATE, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- A week still waiting on the owner: closed, not published, not skipped, not stale. A week with
-- no row yet (nobody has chosen or skipped in it) is unpublished and unskipped.
CREATE OR REPLACE FUNCTION public._spotlight_week_pending(p_week DATE, p_now TIMESTAMPTZ DEFAULT now())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_week < public.spotlight_week_key(p_now)
       AND NOT public._spotlight_week_stale(p_week, p_now)
       AND NOT EXISTS (SELECT 1 FROM public.spotlight_weeks w
                       WHERE w.week_key = p_week
                         AND (w.published_at IS NOT NULL OR w.skipped_at IS NOT NULL));
$$;
REVOKE ALL ON FUNCTION public._spotlight_week_pending(DATE, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- The owner's writes that change a week's outcome (choose, unchoose, publish) lock the week row,
-- then refuse, in this order: an open week (week_open, from _spotlight_lock_week), a published
-- one (already_published, so a second publish press still reads as a no-op), a skipped one
-- (week_skipped) and a stale one (week_stale).
CREATE OR REPLACE FUNCTION public._spotlight_lock_pending_week(p_week DATE)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF public._spotlight_lock_week(p_week) IS NOT NULL THEN
        RAISE EXCEPTION 'already_published' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.spotlight_weeks w WHERE w.week_key = p_week AND w.skipped_at IS NOT NULL) THEN
        RAISE EXCEPTION 'week_skipped' USING ERRCODE = 'P0001';
    END IF;
    IF public._spotlight_week_stale(p_week) THEN
        RAISE EXCEPTION 'week_stale' USING ERRCODE = 'P0001';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._spotlight_lock_pending_week(DATE) FROM PUBLIC, anon, authenticated;

-- Skip a closed week: nothing from it is published and it leaves the queue. Owner only, gated in
-- the body. Idempotent (a second press keeps the first skipped_at). Refuses an open week
-- (week_open) and a published one (already_published). Its choices stay on the rows, inert.
CREATE OR REPLACE FUNCTION public.close_spotlight_week(p_week_key DATE)
RETURNS TABLE (week_key DATE, skipped_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_at TIMESTAMPTZ;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner_only' USING ERRCODE = 'P0001';
    END IF;
    IF public._spotlight_lock_week(p_week_key) IS NOT NULL THEN
        RAISE EXCEPTION 'already_published' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.spotlight_weeks w SET skipped_at = COALESCE(w.skipped_at, now())
    WHERE w.week_key = p_week_key
    RETURNING w.skipped_at INTO v_at;
    RETURN QUERY SELECT p_week_key, v_at;
END;
$$;
REVOKE ALL ON FUNCTION public.close_spotlight_week(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_spotlight_week(DATE) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. The tag lock and the caption lock: one predicate for both. A post is locked while its
--    unremoved entry is up in the CURRENT week (the photographer can still take it down), or is
--    chosen in a week that is published, or pending (neither skipped nor stale). An unchosen
--    entry in a closed week does not lock: choose refuses a tagged frame, and a caption changed
--    before choose is the caption the owner chooses. A chosen entry in a skipped or stale week
--    does not lock either: neither can ever be published.
--    Callers serialise on the post row: the tag trigger takes FOR SHARE, an UPDATE of the caption
--    already holds the row, and put_up_for_spotlight and choose_spotlight_entry take FOR NO KEY
--    UPDATE on it before their own checks. Each side reads the other in a statement after its lock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._spotlight_post_locked(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.spotlight_entries e
        LEFT JOIN public.spotlight_weeks w ON w.week_key = e.week_key
        WHERE e.post_id = p_post_id
          AND e.removed_at IS NULL
          AND (e.week_key = public.spotlight_week_key(now())
               OR (e.chosen_at IS NOT NULL
                   AND (w.published_at IS NOT NULL
                        OR (w.skipped_at IS NULL AND NOT public._spotlight_week_stale(e.week_key)))))
    );
$$;
REVOKE ALL ON FUNCTION public._spotlight_post_locked(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refuse_tag_in_spotlight()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM 1 FROM public.posts WHERE id = NEW.post_id FOR SHARE;
    IF public._spotlight_post_locked(NEW.post_id) THEN
        RAISE EXCEPTION 'in_spotlight' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.refuse_tag_in_spotlight() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS refuse_tag_in_spotlight_trigger ON public.post_tags;
CREATE TRIGGER refuse_tag_in_spotlight_trigger
    BEFORE INSERT OR UPDATE OF post_id ON public.post_tags
    FOR EACH ROW EXECUTE FUNCTION public.refuse_tag_in_spotlight();

-- Only a real change is refused: an UPDATE that writes the same caption back goes through.
CREATE OR REPLACE FUNCTION public.refuse_caption_in_spotlight()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF public._spotlight_post_locked(NEW.id) THEN
        RAISE EXCEPTION 'in_spotlight' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.refuse_caption_in_spotlight() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS refuse_caption_in_spotlight_trigger ON public.posts;
CREATE TRIGGER refuse_caption_in_spotlight_trigger
    BEFORE UPDATE OF caption ON public.posts
    FOR EACH ROW
    WHEN (OLD.caption IS DISTINCT FROM NEW.caption)
    EXECUTE FUNCTION public.refuse_caption_in_spotlight();

-- ---------------------------------------------------------------------------
-- 3. The automatic hide. Unchanged for any photo that has never been in Spotlight. For one that
--    has, a reporter counts only when they were in its audience before Spotlight: someone
--    post_visible_to lets see one of its posts (the author, followers, tagged people), or a member
--    of the roll it was shot in. A stranger's report still inserts, still lands in
--    list_photo_reports and still reaches the owner's push; it just cannot hide the frame for
--    everyone. Evaluated at the moment of each report, like the count it replaces.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_hide_reported()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_spotlight BOOLEAN;
BEGIN
    v_spotlight := EXISTS (SELECT 1 FROM public.spotlight_entries e
                           JOIN public.posts po ON po.id = e.post_id
                           WHERE po.photo_id = NEW.photo_id);
    IF (SELECT COUNT(DISTINCT r.reporter_id)
        FROM public.photo_reports r
        WHERE r.photo_id = NEW.photo_id
          AND (NOT v_spotlight
               OR EXISTS (SELECT 1 FROM public.posts po
                          WHERE po.photo_id = NEW.photo_id
                            AND public.post_visible_to(r.reporter_id, po.id, po.user_id))
               OR EXISTS (SELECT 1 FROM public.photos ph
                          JOIN public.roll_members rm ON rm.roll_id = ph.roll_id AND rm.user_id = r.reporter_id
                          WHERE ph.id = NEW.photo_id))) >= 2 THEN
        UPDATE public.photos SET hidden = TRUE WHERE id = NEW.photo_id;
        UPDATE public.posts  SET hidden = TRUE WHERE photo_id = NEW.photo_id;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.auto_hide_reported() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The photographer's withdraw, until publish. This week: as before (unchosen, deleted). A
--    closed week that is still pending: allowed, chosen or not, unless the owner removed it (the
--    owner's choice simply disappears; publish then refuses none_chosen as usual). Published,
--    skipped or stale: week_closed. The week row is locked FOR SHARE before the entry, the same
--    order every owner write takes (week, then entry), so a withdraw and a publish, choose or
--    skip on the same week queue on the row: whichever commits first, the other sees it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.withdraw_from_spotlight(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_uid   UUID := auth.uid();
    v_now   DATE := public.spotlight_week_key(now());
    v_week  DATE;
    v_entry RECORD;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_signed_in' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('spotlight:' || v_uid::text, 0));
    IF NOT EXISTS (SELECT 1 FROM public.posts po WHERE po.id = p_post_id AND po.user_id = v_uid) THEN
        RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
    END IF;
    SELECT e.week_key INTO v_week
    FROM public.spotlight_entries e
    WHERE e.post_id = p_post_id AND e.user_id = v_uid;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    IF v_week < v_now THEN
        INSERT INTO public.spotlight_weeks (week_key) VALUES (v_week) ON CONFLICT (week_key) DO NOTHING;
        PERFORM 1 FROM public.spotlight_weeks w WHERE w.week_key = v_week FOR SHARE;
    END IF;
    SELECT e.id, e.week_key, e.chosen_at, e.removed_at INTO v_entry
    FROM public.spotlight_entries e
    WHERE e.post_id = p_post_id AND e.user_id = v_uid
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    IF v_entry.week_key = v_now THEN
        IF v_entry.chosen_at IS NOT NULL THEN
            RAISE EXCEPTION 'week_closed' USING ERRCODE = 'P0001';
        END IF;
    ELSIF v_entry.week_key <> v_week
          OR v_entry.removed_at IS NOT NULL
          OR NOT public._spotlight_week_pending(v_entry.week_key) THEN
        RAISE EXCEPTION 'week_closed' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM public.spotlight_entries e WHERE e.id = v_entry.id;
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.withdraw_from_spotlight(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_from_spotlight(UUID) TO authenticated;

-- The menu's state. Unchanged columns first, then the caller's entry in their most recent pending
-- week (closed, unpublished, unskipped, not stale, not removed by the owner): the one withdraw can
-- still take down. NULL in all three when there is none. The return shape grows, so DROP first.
DROP FUNCTION IF EXISTS public.own_spotlight_entry();
CREATE FUNCTION public.own_spotlight_entry()
RETURNS TABLE (
    week_key         DATE,
    week_starts_at   TIMESTAMPTZ,
    week_closes_at   TIMESTAMPTZ,
    can_put_up       BOOLEAN,
    post_id          UUID,
    photo_id         UUID,
    post_created_at  TIMESTAMPTZ,
    put_up_at        TIMESTAMPTZ,
    pending_week_key TEXT,
    pending_post_id  UUID,
    pending_photo_id UUID
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH wk AS (SELECT public.spotlight_week_key(now()) AS k),
    pend AS (
        SELECT pe.week_key, pe.post_id, pp.photo_id
        FROM public.spotlight_entries pe
        JOIN public.posts pp ON pp.id = pe.post_id
        WHERE pe.user_id = auth.uid()
          AND pe.removed_at IS NULL
          AND public._spotlight_week_pending(pe.week_key)
        ORDER BY pe.week_key DESC
        LIMIT 1
    )
    SELECT wk.k,
           public._spotlight_week_start(wk.k),
           public._spotlight_week_start(wk.k + 7),
           NOT public.post_is_covered(auth.uid(), now()),
           e.post_id,
           po.photo_id,
           po.created_at,
           e.put_up_at,
           to_char(pend.week_key, 'YYYY-MM-DD'),
           pend.post_id,
           pend.photo_id
    FROM wk
    LEFT JOIN public.spotlight_entries e ON e.user_id = auth.uid() AND e.week_key = wk.k
    LEFT JOIN public.posts po ON po.id = e.post_id
    LEFT JOIN pend ON TRUE
    WHERE auth.uid() IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION public.own_spotlight_entry() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.own_spotlight_entry() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. The owner's queue and writes.
-- ---------------------------------------------------------------------------

-- The queue. With no argument: every entry in every pending week (closed, unpublished, unskipped,
-- not stale), newest week first. With a week: that week, in any state. Same shape as before.
CREATE OR REPLACE FUNCTION public.list_spotlight_queue(p_week_key DATE DEFAULT NULL)
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
    blocked_with_owner    BOOLEAN
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
           public.is_blocked_either_way(auth.uid(), e.user_id)
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

-- Choose a frame (six at most per week). Idempotent on a frame already chosen. Now also refuses
-- a skipped or stale week, and a frame in a block with the owner (blocked).
CREATE OR REPLACE FUNCTION public.choose_spotlight_entry(p_post_id UUID)
RETURNS TABLE (week_key DATE, chosen_count INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_week  DATE;
    v_entry RECORD;
    v_count INT;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner_only' USING ERRCODE = 'P0001';
    END IF;
    SELECT e.week_key INTO v_week FROM public.spotlight_entries e WHERE e.post_id = p_post_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
    END IF;
    PERFORM public._spotlight_lock_pending_week(v_week);
    -- The post row, before the tag check below: a tag insert in flight holds FOR SHARE on it
    -- (refuse_tag_in_spotlight) and a caption update holds it outright, so this waits for either
    -- to commit and the checks then see it; a tag or caption arriving after this lock waits for
    -- the choose to commit and is refused in_spotlight.
    PERFORM 1 FROM public.posts po WHERE po.id = p_post_id FOR NO KEY UPDATE;

    SELECT e.id, e.user_id, e.chosen_at, e.removed_at, po.hidden, po.created_at, po.photo_id,
           po.user_id AS author_id
    INTO v_entry
    FROM public.spotlight_entries e
    JOIN public.posts po ON po.id = e.post_id
    WHERE e.post_id = p_post_id AND e.week_key = v_week
    FOR UPDATE OF e;
    IF NOT FOUND OR v_entry.removed_at IS NOT NULL THEN
        RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = v_entry.photo_id AND ph.user_id = v_entry.user_id) THEN
        RAISE EXCEPTION 'not_photographer' USING ERRCODE = 'P0001';
    END IF;
    IF v_entry.hidden OR EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = v_entry.photo_id AND ph.hidden) THEN
        RAISE EXCEPTION 'hidden' USING ERRCODE = 'P0001';
    END IF;
    IF public.post_is_covered(v_entry.author_id, v_entry.created_at) THEN
        RAISE EXCEPTION 'covered' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.post_tags t WHERE t.post_id = p_post_id) THEN
        RAISE EXCEPTION 'tagged' USING ERRCODE = 'P0001';
    END IF;
    IF public.is_blocked_either_way(auth.uid(), v_entry.user_id) THEN
        RAISE EXCEPTION 'blocked' USING ERRCODE = 'P0001';
    END IF;

    IF v_entry.chosen_at IS NULL THEN
        SELECT count(*) INTO v_count FROM public.spotlight_entries e
        WHERE e.week_key = v_week AND e.chosen_at IS NOT NULL AND e.removed_at IS NULL;
        IF v_count >= 6 THEN
            RAISE EXCEPTION 'limit' USING ERRCODE = 'P0001';
        END IF;
        UPDATE public.spotlight_entries e SET chosen_at = now() WHERE e.id = v_entry.id;
    END IF;

    RETURN QUERY SELECT v_week, (SELECT count(*)::int FROM public.spotlight_entries e
                                 WHERE e.week_key = v_week AND e.chosen_at IS NOT NULL AND e.removed_at IS NULL);
END;
$$;
REVOKE ALL ON FUNCTION public.choose_spotlight_entry(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.choose_spotlight_entry(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.unchoose_spotlight_entry(p_post_id UUID)
RETURNS TABLE (week_key DATE, chosen_count INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_week DATE;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner_only' USING ERRCODE = 'P0001';
    END IF;
    SELECT e.week_key INTO v_week FROM public.spotlight_entries e WHERE e.post_id = p_post_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
    END IF;
    PERFORM public._spotlight_lock_pending_week(v_week);
    UPDATE public.spotlight_entries e SET chosen_at = NULL WHERE e.post_id = p_post_id AND e.week_key = v_week;
    RETURN QUERY SELECT v_week, (SELECT count(*)::int FROM public.spotlight_entries e
                                 WHERE e.week_key = v_week AND e.chosen_at IS NOT NULL AND e.removed_at IS NULL);
END;
$$;
REVOKE ALL ON FUNCTION public.unchoose_spotlight_entry(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unchoose_spotlight_entry(UUID) TO authenticated;

-- Publish. Refuses an open, published, skipped or stale week, and a week with no frame that can
-- go out (none_chosen). A frame goes out, counts and earns the badge only when it is chosen, not
-- removed, not hidden (post or photo) and not covered.
CREATE OR REPLACE FUNCTION public.publish_spotlight_week(p_week_key DATE)
RETURNS TABLE (week_key DATE, published_at TIMESTAMPTZ, frames INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_count INT;
    v_at    TIMESTAMPTZ;
    v_user  UUID;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner_only' USING ERRCODE = 'P0001';
    END IF;
    PERFORM public._spotlight_lock_pending_week(p_week_key);
    SELECT count(*) INTO v_count
    FROM public.spotlight_entries e
    JOIN public.posts po ON po.id = e.post_id
    WHERE e.week_key = p_week_key AND e.chosen_at IS NOT NULL AND e.removed_at IS NULL
      AND NOT po.hidden
      AND NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = po.photo_id AND ph.hidden)
      AND NOT public.post_is_covered(po.user_id, po.created_at);
    IF v_count = 0 THEN
        RAISE EXCEPTION 'none_chosen' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.spotlight_weeks w SET published_at = now()
    WHERE w.week_key = p_week_key AND w.published_at IS NULL
    RETURNING w.published_at INTO v_at;

    FOR v_user IN
        SELECT DISTINCT e.user_id
        FROM public.spotlight_entries e
        JOIN public.posts po ON po.id = e.post_id
        WHERE e.week_key = p_week_key AND e.chosen_at IS NOT NULL AND e.removed_at IS NULL
          AND NOT po.hidden
          AND NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = po.photo_id AND ph.hidden)
          AND NOT public.post_is_covered(po.user_id, po.created_at)
    LOOP
        PERFORM public._ratchet_badges(v_user);
    END LOOP;

    RETURN QUERY SELECT p_week_key, v_at, v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.publish_spotlight_week(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_spotlight_week(DATE) TO authenticated;

-- The public reads (the strip, the sheet of past weeks, a person's shelf) skip a frame whose photo
-- is hidden even when its post row is not, the same rule publish counts by. Every write path keeps
-- the two flags together; this covers a hand edit that does not. Otherwise unchanged.
CREATE OR REPLACE FUNCTION public._spotlight_weeks_for(p_user_id UUID, p_before DATE, p_limit INT)
RETURNS TABLE (week_key DATE, published_at TIMESTAMPTZ, frames JSONB)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT w.week_key, w.published_at, f.frames
    FROM public.spotlight_weeks w
    CROSS JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object(
                   'post_id',         e.post_id,
                   'photo_id',        po.photo_id,
                   'user_id',         e.user_id,
                   'username',        u.username,
                   'display_name',    u.display_name,
                   'avatar_path',     u.avatar_path,
                   'thumb_path',      po.thumb_path,
                   'feed_path',       po.feed_path,
                   'storage_path',    po.storage_path,
                   'post_created_at', po.created_at,
                   'chosen_at',       e.chosen_at
               ) ORDER BY e.chosen_at, e.post_id) AS frames
        FROM public.spotlight_entries e
        JOIN public.posts po ON po.id = e.post_id
        JOIN public.users u ON u.id = e.user_id
        WHERE e.week_key = w.week_key
          AND e.chosen_at IS NOT NULL
          AND e.removed_at IS NULL
          AND (p_user_id IS NULL OR e.user_id = p_user_id)
          AND NOT po.hidden
          AND NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = po.photo_id AND ph.hidden)
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    ) f
    WHERE auth.uid() IS NOT NULL
      AND w.published_at IS NOT NULL
      AND (p_before IS NULL OR w.week_key < p_before)
      AND f.frames IS NOT NULL
    ORDER BY w.week_key DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 52);
$$;
REVOKE ALL ON FUNCTION public._spotlight_weeks_for(UUID, DATE, INT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. The ratchet. Production's definition from 2026-09-25_spotlight.sql (read back from production
--    2026-09-25 and byte-identical to it), with one change: the spotlight predicate also skips a
--    hidden photo and a covered post, the same rule as publish. The loop in publish is not enough
--    on its own: profile_badges runs this for any profile read, so without the predicate change
--    a covered or hidden chosen frame in a published week would award the badge on the next read.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ratchet_badges(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- first_light: their first frame ever, full stop.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'first_light', MIN(p.taken_at)
    FROM public.photos p
    WHERE p.user_id = p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_roll: shot into the roll on both sides of its halfway point, on a
    -- roll that actually developed.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'full_roll', MIN(agg.earned_at)
    FROM (
        SELECT
            BOOL_OR(p.taken_at < r.created_at + INTERVAL '6 hours') AS shot_early,
            MIN(p.taken_at) FILTER (WHERE p.taken_at >= r.created_at + INTERVAL '6 hours') AS earned_at
        FROM public.rolls r
        JOIN public.photos p ON p.roll_id = r.id AND p.user_id = p_user_id
        WHERE public.is_roll_developed(r.id)
        GROUP BY r.id, r.created_at
    ) agg
    WHERE agg.shot_early AND agg.earned_at IS NOT NULL
    HAVING MIN(agg.earned_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- darkroom: had a perfect reveal-opening streak at some point, across
    -- every developed roll they were ever a member of. Frozen the instant
    -- this INSERT first lands -- a later skipped reveal no longer removes it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'darkroom', MAX(v.viewed_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    LEFT JOIN public.roll_reveal_views v
        ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
    WHERE rm.user_id = p_user_id
      AND public.is_roll_developed(r.id)
    HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(v.viewed_at)
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- founding_100: signup_ordinal <= 100. earned_at = the account's own
    -- created_at (the ordinal was decided at signup), never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT u.id, 'founding_100', u.created_at
    FROM public.users u
    WHERE u.id = p_user_id
      -- 2026-09-08: the hundred are the first hundred PEOPLE. An account hidden from
      -- discovery (the App Review login) keeps its ordinal, the ordinal stays immutable,
      -- but it neither earns this nor takes a seat: the rank counted here skips it, so
      -- the 101st ordinal is the 100th founder when one hidden account sits before it.
      AND NOT u.hidden_from_discovery
      AND (SELECT count(*) FROM public.users x
           WHERE NOT x.hidden_from_discovery AND x.signup_ordinal <= u.signup_ordinal) <= 100
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- first_in: first to open a roll's reveal, on a roll with >= 2 MEMBERS
    -- (an empty race beats no one). Ranked with a deterministic tiebreak so
    -- this is stable forever once earned.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    )
    SELECT p_user_id, 'first_in', MIN(r.viewed_at)
    FROM ranked r
    JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
    WHERE r.user_id = p_user_id AND r.rn = 1
    HAVING MIN(r.viewed_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- roll_maker: created a roll that went on to hold at least one photo
    -- from anyone. The photo requirement keeps this from being farmable by
    -- creating and abandoning empty rolls.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'roll_maker', MIN(r.created_at)
    FROM public.rolls r
    WHERE r.created_by = p_user_id
      AND EXISTS (SELECT 1 FROM public.photos p WHERE p.roll_id = r.id)
    HAVING MIN(r.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- brought_someone: someone signed up using this user's invite code.
    -- Records only that it happened and when (u.created_at), never who.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'brought_someone', MIN(u.created_at)
    FROM public.allowed_emails ae
    JOIN public.users u ON lower(u.email) = ae.email
    WHERE ae.note = 'invited_by:' || p_user_id::text
    HAVING MIN(u.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- joined_in: joined a roll (roll_members) that somebody ELSE created.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'joined_in', MIN(rm.joined_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    WHERE rm.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(rm.joined_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chipped_in: shot at least one photo into a roll they did not create.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chipped_in', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.rolls r ON r.id = p.roll_id
    WHERE p.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- shared: posted a frame to the feed, full stop. earned_at is the
    -- honest global first posts.created_at; the covered-post gate is
    -- applied at READ time by profile_badges, not here.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'shared', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- well_met: somebody ELSE reacted to one of their photos. Excludes
    -- self-reactions. Deliberately photo_reactions (not post_reactions) ,
    -- see five_more_badges.sql's header for the full reasoning.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'well_met', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE p.user_id = p_user_id
      AND pr.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_house: a roll reaches >= 5 DISTINCT CONTRIBUTORS, and this user
    -- is one of them. See five_more_badges.sql's own comment for the full
    -- >= vs = reasoning and the shared-earned_at behaviour.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH roll_contributors AS (
        SELECT p.roll_id, p.user_id AS contributor_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        WHERE p.roll_id IS NOT NULL
        GROUP BY p.roll_id, p.user_id
    ), ranked AS (
        SELECT roll_id, contributor_id, first_shot,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY first_shot ASC, contributor_id ASC) AS rn
        FROM roll_contributors
    ), roll_threshold AS (
        SELECT roll_id, first_shot AS threshold_at
        FROM ranked
        WHERE rn = 5
    )
    SELECT p_user_id, 'full_house', MIN(rt.threshold_at)
    FROM roll_threshold rt
    JOIN ranked me ON me.roll_id = rt.roll_id AND me.contributor_id = p_user_id
    HAVING MIN(rt.threshold_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- front_row -- NEW. See PART 1's matching block for the full comment.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    ), my_wins AS (
        SELECT r.roll_id, r.viewed_at,
               ROW_NUMBER() OVER (ORDER BY r.viewed_at ASC, r.roll_id ASC) AS frn
        FROM ranked r
        JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
        WHERE r.user_id = p_user_id AND r.rn = 1
    )
    SELECT p_user_id, 'front_row', viewed_at
    FROM my_wins
    WHERE frn = 5
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- packed_house -- NEW. Identical to full_house above, rn = 10 not 5.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH roll_contributors AS (
        SELECT p.roll_id, p.user_id AS contributor_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        WHERE p.roll_id IS NOT NULL
        GROUP BY p.roll_id, p.user_id
    ), ranked AS (
        SELECT roll_id, contributor_id, first_shot,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY first_shot ASC, contributor_id ASC) AS rn
        FROM roll_contributors
    ), roll_threshold AS (
        SELECT roll_id, first_shot AS threshold_at
        FROM ranked
        WHERE rn = 10
    )
    SELECT p_user_id, 'packed_house', MIN(rt.threshold_at)
    FROM roll_threshold rt
    JOIN ranked me ON me.roll_id = rt.roll_id AND me.contributor_id = p_user_id
    HAVING MIN(rt.threshold_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- patron -- NEW. Identical lineage join to brought_someone above, rn = 5
    -- over this caller's own invitees ordered by their own created_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH invitees AS (
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || p_user_id::text
    ), ranked AS (
        SELECT created_at,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, invitee_id ASC) AS rn
        FROM invitees
    )
    SELECT p_user_id, 'patron', created_at
    FROM ranked
    WHERE rn = 5
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- cover_to_cover: ten rolls you shot into before they developed.
    -- REWRITTEN (2026-08-18_cover_to_cover_ten_rolls.sql). It used to mean
    -- "every developed roll you were ever a member of contains a photo of
    -- yours", which had the floor at ONE roll and turned out to be trivial:
    -- of its first five holders, three earned it by joining a single roll
    -- and shooting into it. It was also unearnable forever after one miss,
    -- because the missed roll counts against you permanently -- easy for a
    -- brand-new account and impossible for an engaged one, which is exactly
    -- backwards. Cumulative counting fixes both: it always progresses, one
    -- skipped roll never poisons it, and ten is real work.
    -- Same rank-the-nth shape as every other threshold badge here, so a
    -- later eleventh roll can never displace the recorded earned_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH mine AS (
        SELECT p.roll_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        JOIN public.rolls r ON r.id = p.roll_id
        WHERE p.user_id = p_user_id
          AND public.is_roll_developed(r.id)
        GROUP BY p.roll_id
    ), ranked AS (
        SELECT first_shot,
               ROW_NUMBER() OVER (ORDER BY first_shot ASC, roll_id ASC) AS rn
        FROM mine
    )
    SELECT p_user_id, 'cover_to_cover', first_shot
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- kept_one -- NEW. See PART 1's matching block for what "developed but
    -- never shared" means here and why develops_at (not is_developed) is
    -- the condition.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH kept AS (
        SELECT p.taken_at, p.id,
               ROW_NUMBER() OVER (ORDER BY p.taken_at ASC, p.id ASC) AS rn
        FROM public.photos p
        WHERE p.user_id = p_user_id
          AND p.develops_at <= now()
          AND NOT EXISTS (SELECT 1 FROM public.posts po WHERE po.photo_id = p.id)
    )
    SELECT p_user_id, 'kept_one', taken_at
    FROM kept
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- regular -- NEW. Seven distinct app_open days. Not retroactive; see
    -- this file's header.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH days AS (
        SELECT DISTINCT day
        FROM public.usage_events
        WHERE user_id = p_user_id AND event = 'app_open'
    ), ranked AS (
        SELECT day, ROW_NUMBER() OVER (ORDER BY day ASC) AS rn
        FROM days
    )
    SELECT p_user_id, 'regular', day::timestamptz
    FROM ranked
    WHERE rn = 7
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- one_year: a year old, AND still shooting.
    -- Was pure tenure: "now() >= created_at + 1 year", nothing else. That made
    -- it the only badge in the catalogue reachable by doing nothing, which is
    -- survivable at silver and wrong at gold -- and 14 of 48 accounts have never
    -- shot a single frame, so the first cohort to reach a passive gold badge
    -- would have been mostly dormant accounts collecting a medal for existing.
    --
    -- Now it needs a frame taken ON OR AFTER the first anniversary. Monotonic
    -- like everything else here: once true it stays true, and it is never
    -- blocked -- miss your anniversary week and any later frame still earns it,
    -- unlike a "shot during month twelve" window which would shut forever.
    -- earned_at is that qualifying frame, the honest instant both halves became
    -- true, never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'one_year', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.users u ON u.id = p.user_id
    WHERE p.user_id = p_user_id
      AND p.taken_at >= u.created_at + INTERVAL '1 year'
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- open_door -- NEW. Same lineage join as patron/brought_someone, rn = 10.
    -- Ten is chosen off real numbers, not a round figure: the top inviter in
    -- production has 24 joined invitees and the next has 9, so ten is held by
    -- exactly one account today with a second one invite away. Twenty would
    -- have sat empty for years.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH invitees AS (
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || p_user_id::text
    ), ranked AS (
        SELECT created_at,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, invitee_id ASC) AS rn
        FROM invitees
    )
    SELECT p_user_id, 'open_door', created_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chimed_in -- NEW. Reacted to SOMEBODY ELSE'S photo. The mirror of
    -- well_met, which fires when someone reacts to yours: one rewards being
    -- seen, this one rewards looking.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chimed_in', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE pr.user_id = p_user_id
      AND p.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- in_frame -- NEW. Somebody tagged you in a photo. Nothing you can do to
    -- cause it, which is the point: it marks being part of someone's roll.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'in_frame', MIN(pt.created_at)
    FROM public.post_tags pt
    WHERE pt.tagged_user_id = p_user_id
    HAVING MIN(pt.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- spotter -- NEW. You tagged someone else in one of your own posts.
    -- Self-tags excluded, or this would fire for anyone who tapped their own
    -- face once.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'spotter', MIN(pt.created_at)
    FROM public.post_tags pt
    JOIN public.posts po ON po.id = pt.post_id
    WHERE po.user_id = p_user_id
      AND pt.tagged_user_id <> p_user_id
    HAVING MIN(pt.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- said_it -- NEW. Wrote a caption. Reads posts.caption, NOT photos.caption:
    -- both columns exist, but a caption is typed when a frame is posted, so
    -- photos.caption holds 0 rows in production against posts.caption's 47.
    -- Written against photos first, which made the badge unearnable by anyone
    -- -- caught because the backfill granted it to nobody at all.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'said_it', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
      AND po.caption IS NOT NULL
      AND btrim(po.caption) <> ''
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- ten_frames -- NEW. The tenth frame ever shot, ranked so earned_at pins to
    -- that frame and a later eleventh can never move it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT p.taken_at,
               ROW_NUMBER() OVER (ORDER BY p.taken_at ASC, p.id ASC) AS rn
        FROM public.photos p
        WHERE p.user_id = p_user_id
    )
    SELECT p_user_id, 'ten_frames', taken_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- good_company: TEN people follow you.
    -- Shipped as "somebody followed you", which the backfill granted to all 48
    -- accounts: every account HAS a follower by construction, because
    -- 2026-08-14_auto_follow_owner_backfill.sql wires one up at signup. A badge
    -- every account holds on arrival is a side effect wearing a pill, and it
    -- dilutes the bronze rung it sits on.
    -- Five was tried first and was still too generous, landing on 35 of 48.
    -- Measured across candidate thresholds -- 5:35, 8:24, 10:22, 12:20, 15:14 --
    -- ten is where the curve flattens, and the last round number before the
    -- badge starts excluding people who genuinely have an audience.
    -- Ranked rather than counted so earned_at pins to the tenth follow and an
    -- eleventh can never move it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked_follows AS (
        SELECT f.created_at,
               ROW_NUMBER() OVER (ORDER BY f.created_at ASC, f.follower_id ASC) AS rn
        FROM public.follows f
        WHERE f.following_id = p_user_id
    )
    SELECT p_user_id, 'good_company', created_at
    FROM ranked_follows
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- spotlight (2026-09-25): a frame of theirs chosen and published in Spotlight. earned_at is
    -- the week's publish time. A frame taken out after publish still counts (the badge stays);
    -- one removed before publish never went out, so it does not. publish_spotlight_week runs
    -- this for each chosen person inside its own transaction.
    -- Hardening (2026-09-25): a hidden photo or a covered post never earns it, the same rule
    -- publish_spotlight_week counts by.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'spotlight', MIN(w.published_at)
    FROM public.spotlight_entries e
    JOIN public.spotlight_weeks w ON w.week_key = e.week_key
    JOIN public.posts po ON po.id = e.post_id
    WHERE e.user_id = p_user_id
      AND e.chosen_at IS NOT NULL
      AND w.published_at IS NOT NULL
      AND (e.removed_at IS NULL OR e.removed_at >= w.published_at)
      AND NOT po.hidden
      AND NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = po.photo_id AND ph.hidden)
      AND NOT public.post_is_covered(po.user_id, po.created_at)
    HAVING MIN(w.published_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_set: TWENTY other badge ids, LAST.
    -- Was ten, which the catalogue outgrew: adding seven badges in one day took
    -- its holders from 3 to 9 without anyone doing anything, because a fixed
    -- count gets easier every time the catalogue grows. Twenty is 80% of the 25
    -- a normal account can actually obtain (the other four are hand-granted or
    -- the closed founding window), so it reads as "you have nearly everything"
    -- rather than "you have a third of it".
    -- Still must run after every predicate above in this same pass: it is the
    -- only one that reads the ledger it writes to. WHERE badge_id NOT IN
    -- ('full_set', 'spotlight') is the explicit cannot-count-itself guarantee, and
    -- keeps the editorial spotlight badge out of a count meant to be reached by effort.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT eb.earned_at,
               ROW_NUMBER() OVER (ORDER BY eb.earned_at ASC, eb.badge_id ASC) AS rn
        FROM public.earned_badges eb
        WHERE eb.user_id = p_user_id AND eb.badge_id NOT IN ('full_set', 'spotlight')
    )
    SELECT p_user_id, 'full_set', earned_at
    FROM ranked
    WHERE rn = 20
    ON CONFLICT (user_id, badge_id) DO NOTHING;
END;
$function$
;

REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. The owner's Monday alert counts pending weeks only (no skipped or stale week). Otherwise
--    unchanged; p_now is still only for tests.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.spotlight_morning_alert(p_now TIMESTAMPTZ DEFAULT now())
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_local  TIMESTAMP := p_now AT TIME ZONE 'America/New_York';
    v_frames INT;
    v_weeks  INT;
    v_newest DATE;
    v_what   TEXT;
BEGIN
    IF extract(isodow FROM v_local) <> 1 OR extract(hour FROM v_local) <> 9 THEN
        RETURN FALSE;
    END IF;
    IF EXISTS (SELECT 1 FROM public.ops_alerts a
               WHERE a.source = 'spotlight' AND a.created_at > p_now - INTERVAL '6 days') THEN
        RETURN FALSE;
    END IF;
    SELECT count(*), count(DISTINCT e.week_key), max(e.week_key)
    INTO v_frames, v_weeks, v_newest
    FROM public.spotlight_entries e
    WHERE e.removed_at IS NULL
      AND public._spotlight_week_pending(e.week_key, p_now);
    IF v_frames = 0 THEN
        RETURN FALSE;
    END IF;
    v_what := v_frames || CASE WHEN v_frames = 1 THEN ' frame' ELSE ' frames' END;
    INSERT INTO public.ops_alerts (source, detail, created_at) VALUES ('spotlight', LEFT(
        CASE WHEN v_weeks = 1
             THEN v_what || ' waiting for the week of ' || to_char(v_newest, 'FMMonth FMDD')
                  || '. Choose and publish in the admin panel.'
             ELSE v_what || ' waiting across ' || v_weeks || ' weeks, the newest the week of '
                  || to_char(v_newest, 'FMMonth FMDD') || '. Choose and publish in the admin panel.'
        END, 500), p_now);
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.spotlight_morning_alert(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

COMMIT;
