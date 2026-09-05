-- ============================================================
-- Migration: five more chapter_stats() keys -- biggest_fan, top_given_reaction,
-- golden_hour, roll_mvp, longest_gap.
--
-- Last-changed baseline: supabase/migrations/2026-09-05_chapter_photos_post_id.sql,
-- which added post_id to chapter_stats' return shape. Everything that file
-- documented (posted-only source CTE, month boundary at the 04:00 shift,
-- covered_post_visible + is_blocked_either_way on the source predicate, the
-- omission rule, the chapter_public_stats visibility pick) is unchanged and not
-- re-explained below except where a new key departs from it.
--
-- RETURN TYPE CHANGE: same DROP FUNCTION IF EXISTS + CREATE + re-grant dance as
-- every prior chapter_stats change, because Postgres refuses to let CREATE OR
-- REPLACE FUNCTION change a RETURNS TABLE column list. Safe to re-run: a second
-- pass drops the already-updated function and recreates the identical shape.
-- Same SECURITY DEFINER, same authenticated-only grant (anon and PUBLIC
-- revoked) -- nothing else to restore.
--
-- NEW COLUMN: user_id UUID, appended at the end of the RETURNS TABLE, nullable,
-- NULL on every existing stat_key. Only biggest_fan and roll_mvp set it, so the
-- app can open that person's profile directly instead of resolving a username
-- back to an id. Adding a column to a RETURNS TABLE is additive: a client that
-- only decodes the keys it already knows ignores user_id entirely.
--
-- THE FIVE NEW KEYS
--
-- 1. biggest_fan: who reacted to the profile owner's posted shots the most
--    that month, EXCLUDING the owner reacting to their own posts. Grouped over
--    the same `source` CTE joined to post_reactions (same reactions the
--    reactions_received/most_reacted keys already count), by reactor. This is
--    the one key with an extra visibility gate beyond the usual source
--    predicate: `source` already guarantees the CALLING user is allowed to see
--    the profile owner's posts at all (is_blocked_either_way(caller, owner) +
--    covered_post_visible), but says nothing about whether the caller is
--    allowed to see the REACTOR specifically. A biggest_fan the caller has
--    blocked (or who has blocked the caller) is skipped in favor of the next
--    highest reactor by the same is_blocked_either_way(auth.uid(), reactor)
--    check every other surface uses; if every reactor is blocked either way
--    with the caller, the key is omitted, same omission rule as everything
--    else. The profile OWNER's own view is unaffected (auth.uid() = p_profile_id
--    bypasses the final visibility-pick filter entirely, same as always, and
--    is_blocked_either_way(x, x) is always FALSE so the owner never
--    self-filters). Tie-break: count desc, then most recent reaction desc, for
--    a deterministic pick.
--
-- 2. top_given_reaction: the emoji the PROFILE OWNER gave out most that month,
--    across every post they reacted to (not just their own posts -- this is
--    about the owner's behaviour, not what happened to their posts, so the
--    `source` CTE, which is scoped to the owner's OWN posted shots, does not
--    apply here at all). Bounded on the reaction's own created_at with the
--    same 04:00 shift every other month boundary in this function uses. The
--    only visibility rule that applies is a block check: a reaction the owner
--    made on a post by someone blocked either way with the CALLER is excluded,
--    so a viewer can never learn "the owner reacted to something" about a
--    relationship they cannot see. covered_post_visible and post.hidden are
--    deliberately NOT layered on top here -- this key describes an action the
--    owner took, not a post's current visibility, and the task scope for this
--    key is exactly the block check, nothing broader.
--
-- 3. golden_hour: the America/New_York hour (0-23) with the most posted shots
--    that month, over `source` exactly like night_shots already does (same
--    TIMEZONE ASSUMPTION night_shots documents: America/New_York, FLIM's
--    current user base, not a per-user zone -- FLIM has none). value_int is
--    the hour; value_text is that hour's shot count as text, so the app can
--    show "6 shots at 5pm" without a second query. Omitted when the month has
--    fewer than 3 posted shots total, regardless of how those shots are
--    distributed across hours -- a "golden hour" computed from 1-2 shots is
--    noise, not a stat. Tie-break: count desc, then hour asc.
--
-- 4. roll_mvp: among the rolls the profile owner posted into that month
--    (the same roll_ids CTE rolls_count/people_shot_with already use), the
--    other member who shot the most photos into those specific rolls, keyed
--    off public.photos directly (every shot into the roll, not only posted
--    ones -- this is about who is filling the roll, not who is posting).
--    ROLL VISIBILITY: restricted to rolls the CALLER can see, using the exact
--    same predicate as the "photos: roll members can read shared" storage
--    policy (NOT p.hidden AND public.is_roll_member(p.roll_id) AND NOT
--    public.is_blocked_either_way(auth.uid(), p.user_id)) rather than
--    people_shot_with's simpler unfiltered roll_members count -- that
--    predicate exists precisely because roll membership does not itself imply
--    the caller may see a specific member's shots (blocking never touches
--    roll_members; see that policy's own comment). Reusing it here means a
--    caller who is not in one of the owner's rolls, or who is blocked either
--    way with the top shooter, never learns who that shooter is. Omitted when
--    there are no such rolls, or no other member shot into them. Tie-break:
--    count desc, then username asc.
--
-- 5. longest_gap: the largest number of days between two consecutive DISTINCT
--    posted-shot days that month (day boundary via the same 04:00 shift
--    day_bucketed already computes), using the standard LAG-over-distinct-days
--    gap calculation. value_int is the gap length in days; photo_id /
--    photo_thumb_path / post_id identify the EARLIEST shot on the day that
--    ENDED the gap (the first shot back after the drought), so the app can
--    show that photo. Omitted when the month has fewer than 2 distinct
--    posted-shot days (no gap exists to measure) or the largest gap is under
--    3 days (not surprising enough to be a stat).
--
-- CHECK CONSTRAINT: users_chapter_public_stats_keys_check and
-- set_chapter_public_stats()'s validation list both gain the same five new
-- keys, kept byte-for-byte identical to each other as before (that identity is
-- what a typo-fails-loud instead of typo-silently-hides-or-leaks).
-- ============================================================

ALTER TABLE public.users
    DROP CONSTRAINT IF EXISTS users_chapter_public_stats_keys_check,
    ADD CONSTRAINT users_chapter_public_stats_keys_check
        CHECK (chapter_public_stats <@ ARRAY[
            'most_reacted', 'most_commented', 'reactions_received', 'comments_received',
            'top_reaction', 'busiest_day', 'night_shots', 'streak_days', 'rolls_count',
            'people_shot_with', 'first_shot', 'last_shot', 'shots',
            'biggest_fan', 'top_given_reaction', 'golden_hour', 'roll_mvp', 'longest_gap'
        ]::text[]);

-- Hot path for top_given_reaction (filters post_reactions directly by
-- reactor, with no post_id to lean on the existing post_reactions_post_idx).
CREATE INDEX IF NOT EXISTS post_reactions_user_idx ON public.post_reactions (user_id);

DROP FUNCTION IF EXISTS public.chapter_stats(UUID, DATE);

CREATE FUNCTION public.chapter_stats(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    stat_key         TEXT,
    value_int        INTEGER,
    value_text       TEXT,
    photo_id         UUID,
    photo_thumb_path TEXT,
    post_id          UUID,
    user_id          UUID
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
        SELECT s.post_id, s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY s.post_id, s.photo_id, s.display_path, s.taken_at
    ),
    comment_counts AS (
        SELECT s.post_id, s.photo_id, s.display_path, s.taken_at, count(*) AS cnt
        FROM source s
        JOIN public.post_comments pc ON pc.post_id = s.post_id
        GROUP BY s.post_id, s.photo_id, s.display_path, s.taken_at
    ),
    reaction_emoji AS (
        SELECT pr.emoji, count(*) AS cnt
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        GROUP BY pr.emoji
    ),
    day_bucketed AS (
        SELECT s.photo_id, s.post_id, s.display_path, s.taken_at,
               date_trunc('day', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS shot_day
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
    -- ---- biggest_fan ----
    fan_counts AS (
        SELECT pr.user_id AS reactor_id, count(*) AS cnt, max(pr.created_at) AS last_reacted_at
        FROM source s
        JOIN public.post_reactions pr ON pr.post_id = s.post_id
        WHERE pr.user_id <> p_profile_id
        GROUP BY pr.user_id
    ),
    -- ---- top_given_reaction (owner's own behaviour, source CTE does not apply) ----
    given_reactions AS (
        SELECT pr.emoji, count(*) AS cnt
        FROM public.post_reactions pr
        JOIN public.posts po ON po.id = pr.post_id
        WHERE pr.user_id = p_profile_id
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND date_trunc('month', (pr.created_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
        GROUP BY pr.emoji
    ),
    -- ---- golden_hour ----
    hour_counts AS (
        SELECT EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York'))::int AS hr, count(*) AS cnt
        FROM source s
        GROUP BY hr
    ),
    -- ---- roll_mvp: same visibility predicate as the "photos: roll members can
    -- read shared" storage policy, not the simpler unfiltered people_shot_with
    -- count -- see the header comment above for why. ----
    roll_mvp_counts AS (
        SELECT p.user_id AS shooter_id, count(*) AS cnt
        FROM public.photos p
        WHERE p.roll_id IN (SELECT roll_id FROM roll_ids)
          AND p.user_id <> p_profile_id
          AND NOT p.hidden
          AND public.is_roll_member(p.roll_id)
          AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
        GROUP BY p.user_id
    ),
    -- ---- longest_gap ----
    distinct_days AS (
        SELECT DISTINCT shot_day FROM day_bucketed
    ),
    day_gaps AS (
        SELECT shot_day, shot_day - LAG(shot_day) OVER (ORDER BY shot_day) AS gap_days
        FROM distinct_days
    ),
    gap_pick AS (
        SELECT shot_day, gap_days
        FROM day_gaps
        WHERE gap_days IS NOT NULL
        ORDER BY gap_days DESC, shot_day ASC
        LIMIT 1
    ),
    gap_ending_photo AS (
        -- The earliest shot on the day that ended the gap (first shot back
        -- after the drought), matched back to day_bucketed rather than
        -- re-deriving shot_day from taken_at a second time.
        SELECT db.photo_id, db.display_path, db.post_id, gp.gap_days
        FROM gap_pick gp
        JOIN day_bucketed db ON db.shot_day = gp.shot_day
        ORDER BY db.taken_at ASC
        LIMIT 1
    ),
    stats (stat_key, value_int, value_text, photo_id, photo_thumb_path, post_id, user_id) AS (
        (SELECT 'shots'::text, count(*)::int, NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::uuid
         FROM source
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'reactions_received', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM source s JOIN public.post_reactions pr ON pr.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'comments_received', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM source s JOIN public.post_comments pc ON pc.post_id = s.post_id
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'most_reacted', rc.cnt::int, NULL, rc.photo_id, rc.display_path, rc.post_id, NULL
         FROM reaction_counts rc
         ORDER BY rc.cnt DESC, rc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'most_commented', cc.cnt::int, NULL, cc.photo_id, cc.display_path, cc.post_id, NULL
         FROM comment_counts cc
         ORDER BY cc.cnt DESC, cc.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_reaction', re.cnt::int, re.emoji, NULL, NULL, NULL, NULL
         FROM reaction_emoji re
         ORDER BY re.cnt DESC, re.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'busiest_day', dc.cnt::int, to_char(dc.shot_day, 'YYYY-MM-DD'), NULL, NULL, NULL, NULL
         FROM day_counts dc
         ORDER BY dc.cnt DESC, dc.shot_day DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'night_shots', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM source s
         WHERE EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) >= 22
            OR EXTRACT(HOUR FROM (s.taken_at AT TIME ZONE 'America/New_York')) < 4
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'streak_days', max(len)::int, NULL, NULL, NULL, NULL, NULL
         FROM streak_lengths)

        UNION ALL
        (SELECT 'rolls_count', count(*)::int, NULL, NULL, NULL, NULL, NULL
         FROM roll_ids
         HAVING count(*) > 0)

        UNION ALL
        (SELECT 'people_shot_with', count(DISTINCT rm.user_id)::int, NULL, NULL, NULL, NULL, NULL
         FROM public.roll_members rm
         WHERE rm.roll_id IN (SELECT roll_id FROM roll_ids)
           AND rm.user_id <> p_profile_id
         HAVING count(DISTINCT rm.user_id) > 0)

        UNION ALL
        (SELECT 'first_shot', NULL, NULL, s.photo_id, s.display_path, s.post_id, NULL
         FROM source s
         ORDER BY s.taken_at ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'last_shot', NULL, NULL, s.photo_id, s.display_path, s.post_id, NULL
         FROM source s
         ORDER BY s.taken_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'biggest_fan', fc.cnt::int, u.username, NULL, NULL, NULL, fc.reactor_id
         FROM fan_counts fc
         JOIN public.users u ON u.id = fc.reactor_id
         WHERE NOT public.is_blocked_either_way(auth.uid(), fc.reactor_id)
         ORDER BY fc.cnt DESC, fc.last_reacted_at DESC
         LIMIT 1)

        UNION ALL
        (SELECT 'top_given_reaction', gr.cnt::int, gr.emoji, NULL, NULL, NULL, NULL
         FROM given_reactions gr
         ORDER BY gr.cnt DESC, gr.emoji ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'golden_hour', hc.hr::int, hc.cnt::text, NULL, NULL, NULL, NULL
         FROM hour_counts hc
         WHERE (SELECT count(*) FROM source) >= 3
         ORDER BY hc.cnt DESC, hc.hr ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'roll_mvp', rmc.cnt::int, u.username, NULL, NULL, NULL, rmc.shooter_id
         FROM roll_mvp_counts rmc
         JOIN public.users u ON u.id = rmc.shooter_id
         ORDER BY rmc.cnt DESC, u.username ASC
         LIMIT 1)

        UNION ALL
        (SELECT 'longest_gap', gep.gap_days::int, NULL, gep.photo_id, gep.display_path, gep.post_id, NULL
         FROM gap_ending_photo gep
         WHERE gep.gap_days >= 3)
    ),
    owner_pick AS (
        SELECT chapter_public_stats FROM public.users WHERE id = p_profile_id
    )
    SELECT st.stat_key, st.value_int, st.value_text, st.photo_id, st.photo_thumb_path, st.post_id, st.user_id
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
        'people_shot_with', 'first_shot', 'last_shot', 'shots',
        'biggest_fan', 'top_given_reaction', 'golden_hour', 'roll_mvp', 'longest_gap'
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
