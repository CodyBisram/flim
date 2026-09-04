-- ============================================================
-- Migration: chapter_stats() -- the data half of a Chapters "month in
-- numbers" card -- plus the per-user visibility pick that controls who
-- sees which stat when someone other than the profile owner asks.
-- Paste into Supabase Dashboard -> SQL Editor and run, or deploy via the
-- Management API. Safe to re-run throughout (CREATE OR REPLACE, IF NOT
-- EXISTS, DROP CONSTRAINT/POLICY IF EXISTS before recreation).
--
-- SCOPE: this ships the SUPERSET of stats the card could ever show; the
-- app picks which of these rows it actually renders. It does not touch
-- profile_chapters or chapter_photos (2026-09-03_chapters.sql,
-- 2026-09-04_chapters_posted_only.sql), it only adds a third function
-- that reads the same posted-only source those two already agreed on.
--
-- VISIBILITY OF THE UNDERLYING PHOTOS: every stat here is computed ONLY
-- over the exact same posted photos chapter_photos(p_profile_id,
-- p_month_start) would return to THIS caller for THIS month -- the
-- "source" CTE below is a byte-for-byte copy of chapter_photos' own
-- source CTE (posted-only, not hidden, not blocked either way, not
-- covered -- the same predicate "posts: readable by authenticated"
-- already enforces), narrowed to the one month. A stat can never
-- reference a photo the caller could not already see in that profile's
-- grid or Chapters playback. SECURITY DEFINER remains necessary for the
-- same reason as chapter_photos: reading public.photos for roll_id, for
-- a viewer who is not that photo's owner or roll member, needs elevated
-- rights (public.photos' own RLS would otherwise hide it); every row this
-- function can ever return has already separately passed the
-- posts-visibility predicate in the query body, so there is nothing for
-- those elevated rights to leak beyond what that predicate already
-- allowed through.
--
-- MONTH BOUNDARY: identical convention to profile_chapters/chapter_photos
-- -- taken_at shifted back 4 hours (FeedUnit.dayBoundaryHour) before
-- truncating to month or day, fixed at UTC (FLIM stores no per-user
-- timezone column; see 2026-09-03_chapters.sql's header for the full
-- reasoning). busiest_day and streak_days reuse the same 4-hour-shifted
-- day boundary for internal consistency with the rest of Chapters.
--
-- REACTIONS/COMMENTS SOURCE: chapter_photos deals only in POSTED photos,
-- each of which has exactly one row in public.posts (posts.photo_id is
-- UNIQUE per (user_id, photo_id) and every source row here comes from a
-- join against posts). The feed's own reaction/comment batching
-- (FeedService.batchReactions / batchComments) counts a shared post via
-- public.post_reactions / public.post_comments keyed on post_id -- NOT
-- public.photo_reactions / public.photo_comments, which back the
-- separate roll-photo-thread UI FeedService.loadRollActivity reads from
-- and are never joined into a feed card's own counts. This function
-- counts post_reactions / post_comments for the same reason: a chapter
-- stat about "reactions received" must match what the feed itself would
-- have shown on that same shared post, not a different, roll-scoped
-- thread the card never displays.
--
-- NIGHT_SHOTS TIMEZONE ASSUMPTION: "22:00-04:00" is evaluated in
-- America/New_York, FLIM's current user base, not a per-user zone (FLIM
-- has none -- see above). A user shooting outside the US Eastern time
-- zone gets a night_shots count bucketed to New York local time, not
-- their own. Documented known gap, not an oversight; a per-user timezone
-- column is out of scope here.
--
-- OMISSION RULE: a stat row is omitted entirely, never returned as a
-- zero, whenever there is nothing to say for it that month (no reactions
-- means no most_reacted/most_commented/top_reaction/reactions_received/
-- comments_received row; no shared roll among the month's posted shots
-- means no rolls_count/people_shot_with row). shots/first_shot/last_shot/
-- streak_days are the only rows guaranteed present whenever the month has
-- any posted shots at all (which chapter_stats' own caller already knows,
-- since profile_chapters would not have listed the month otherwise).
--
-- VISIBILITY PICK: users.chapter_public_stats is the profile owner's own
-- allow-list of which stat_key values everyone ELSE may see on their
-- card. The EMPTY array (the default, and every existing account's
-- current value) means "everything public" -- so shipping this migration
-- changes nothing for anyone who has never opened the picker, and the
-- picker's first save is an explicit OPT-OUT list, never an opt-in one
-- nobody has populated yet. The profile owner always sees every row
-- regardless of their own pick (the picker previews rows that are about
-- to become hidden from others, never from themselves). The CHECK
-- constraint on the column and the validation inside
-- set_chapter_public_stats both enforce the SAME fixed key list, so a
-- typo can neither silently hide a real stat (rejected outright) nor
-- silently grant visibility to a key chapter_stats does not know how to
-- filter by (also rejected outright).
-- ============================================================

-- users.chapter_public_stats: added here (not beside hidden_from_discovery/
-- signup_ordinal above) because it is exclusively a Chapters concern; the
-- authenticated column-level SELECT grant list further below is still the
-- single place that decides whether a client can read it directly.
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS chapter_public_stats TEXT[] NOT NULL DEFAULT '{}';

ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_chapter_public_stats_keys_check,
    ADD CONSTRAINT users_chapter_public_stats_keys_check
        CHECK (chapter_public_stats <@ ARRAY[
            'most_reacted', 'most_commented', 'reactions_received', 'comments_received',
            'top_reaction', 'busiest_day', 'night_shots', 'streak_days', 'rolls_count',
            'people_shot_with', 'first_shot', 'last_shot', 'shots'
        ]::text[]);

-- chapter_public_stats joins the same authenticated column-level SELECT grant
-- hidden_from_discovery and signup_ordinal already sit in (schema.sql, "users:
-- any signed-in user may read rows but ONLY the safe profile columns"). This is
-- REVOKE-then-GRANT already in schema.sql, so re-running that block after this
-- migration picks the new column up automatically; nothing to change there for
-- a from-scratch load. Deliberately NOT added to the `profiles` view: no client
-- surface needs another profile's pick list, only the settings screen reading
-- its OWN row needs this column, and profiles is read-only by design.
GRANT SELECT (chapter_public_stats) ON public.users TO authenticated;

-- chapter_stats(p_profile_id, p_month_start): the "month in numbers" superset.
-- See header above for the full visibility/omission/timezone contract.
CREATE OR REPLACE FUNCTION public.chapter_stats(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    stat_key         TEXT,
    value_int        INTEGER,
    value_text       TEXT,
    photo_id         UUID,
    photo_thumb_path TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Byte-for-byte the same predicate as chapter_photos' own source CTE,
        -- narrowed to the one month up front so every CTE below it is already
        -- scoped correctly.
        SELECT po.id AS post_id, p.id AS photo_id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
          AND date_trunc('month', (po.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ),
    reaction_counts AS (
        SELECT s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY s.photo_id, s.display_path, s.taken_at
    ),
    comment_counts AS (
        SELECT s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_comments pc ON pc.post_id = s.post_id
        GROUP BY s.photo_id, s.display_path, s.taken_at
    ),
    reaction_emoji AS (
        SELECT pr.emoji, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY pr.emoji
    ),
    day_bucketed AS (
        SELECT date_trunc('day', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS shot_day
        FROM source s
    ),
    day_counts AS (
        SELECT shot_day, count(*) AS cnt FROM day_bucketed GROUP BY shot_day
    ),
    streaks AS (
        -- Classic gaps-and-islands: within a sequence of distinct days, a run of
        -- CONSECUTIVE days shares the same (day - row_number()) value.
        SELECT shot_day, shot_day - (row_number() OVER (ORDER BY shot_day))::int AS grp
        FROM (SELECT DISTINCT shot_day FROM day_bucketed) d
    ),
    streak_lengths AS (
        SELECT grp, count(*) AS len FROM streaks GROUP BY grp
    ),
    roll_ids AS (
        SELECT DISTINCT roll_id FROM source WHERE roll_id IS NOT NULL
    ),
    stats (stat_key, value_int, value_text, photo_id, photo_thumb_path) AS (
        (SELECT 'shots'::text, count(*)::int, NULL::text, NULL::uuid, NULL::text
         FROM source
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'reactions_received', count(*)::int, NULL, NULL, NULL
         FROM source s JOIN public.post_reactions pr ON pr.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'comments_received', count(*)::int, NULL, NULL, NULL
         FROM source s JOIN public.post_comments pc ON pc.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'most_reacted', rc.cnt::int, NULL, rc.photo_id, rc.display_path
         FROM reaction_counts rc
         ORDER BY rc.cnt DESC, rc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'most_commented', cc.cnt::int, NULL, cc.photo_id, cc.display_path
         FROM comment_counts cc
         ORDER BY cc.cnt DESC, cc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_reaction', re.cnt::int, re.emoji, NULL, NULL
         FROM reaction_emoji re
         ORDER BY re.cnt DESC, re.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'busiest_day', dc.cnt::int, to_char(dc.shot_day, 'YYYY-MM-DD'), NULL, NULL
         FROM day_counts dc
         ORDER BY dc.cnt DESC, dc.shot_day DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'night_shots', count(*)::int, NULL, NULL, NULL
         FROM source s
         WHERE EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) >= 22
            OR EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) < 4
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'streak_days', max(len)::int, NULL, NULL, NULL
         FROM streak_lengths)

        UNION ALL
        (SELECT 'rolls_count', count(*)::int, NULL, NULL, NULL
         FROM roll_ids
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'people_shot_with', count(DISTINCT rm.user_id)::int, NULL, NULL, NULL
         FROM public.roll_members rm
         WHERE rm.roll_id IN (SELECT roll_id FROM roll_ids)
           AND rm.user_id <> p_profile_id
         HAVING count(DISTINCT rm.user_id) > 0)

        UNION ALL
        (SELECT 'first_shot', NULL, NULL, s.photo_id, s.display_path
         FROM source s
         ORDER BY s.taken_at ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'last_shot', NULL, NULL, s.photo_id, s.display_path
         FROM source s
         ORDER BY s.taken_at DESC
         LIMIT 1)
    ),
    owner_pick AS (
        SELECT chapter_public_stats FROM public.users WHERE id = p_profile_id
    )
    SELECT st.stat_key, st.value_int, st.value_text, st.photo_id, st.photo_thumb_path
    FROM stats st
    WHERE auth.uid() = p_profile_id
       OR EXISTS (
            SELECT 1 FROM owner_pick op
            WHERE COALESCE(array_length(op.chapter_public_stats, 1), 0) = 0
               OR st.stat_key = ANY(op.chapter_public_stats)
          );
$$;

REVOKE ALL ON FUNCTION public.chapter_stats(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_stats(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_stats(UUID, DATE) TO authenticated;

-- set_chapter_public_stats(p_keys): the only write path for a user's own
-- chapter_public_stats pick. Pattern after set_displayed_badges (schema.sql):
-- zero-trust on input, pinned to auth.uid() (no p_user_id argument, nothing to
-- spoof), NULL treated the same as '{}' (both mean "show everything" per the
-- empty-array convention above), every element validated against the exact
-- same fixed key list the table CHECK constraint enforces, idempotent, and the
-- saved array is returned so the caller can confirm what stuck without a
-- second round trip.
CREATE OR REPLACE FUNCTION public.set_chapter_public_stats(p_keys TEXT[])
RETURNS TEXT[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keys TEXT[] := COALESCE(p_keys, ARRAY[]::text[]);
BEGIN
    IF array_position(v_keys, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'chapter_public_stats: key cannot be null';
    END IF;

    IF NOT (v_keys <@ ARRAY[
        'most_reacted', 'most_commented', 'reactions_received', 'comments_received',
        'top_reaction', 'busiest_day', 'night_shots', 'streak_days', 'rolls_count',
        'people_shot_with', 'first_shot', 'last_shot', 'shots'
    ]::text[]) THEN
        RAISE EXCEPTION 'chapter_public_stats: unknown stat key';
    END IF;

    UPDATE public.users SET chapter_public_stats = v_keys WHERE id = auth.uid();

    RETURN v_keys;
END;
$$;
REVOKE ALL ON FUNCTION public.set_chapter_public_stats(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_chapter_public_stats(TEXT[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_chapter_public_stats(TEXT[]) TO authenticated;
