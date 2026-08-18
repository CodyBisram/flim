-- ============================================================
-- Migration: the medal ladder's seven new badges, and Cover to Cover
-- rewritten as ten rolls counted instead of a perfect record.
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER 2026-08-18_nine_more_badges.sql and
-- 2026-08-18_retire_test_roll.sql, both already applied to production.
--
-- THE SEVEN
-- ----------
-- One gold:
--   open_door      - TEN invited people joined (patron is five)
--
-- Six for the bottom rung, the ordinary things a person does in their first
-- fortnight and keeps doing. The catalogue's cheapest badge used to be
-- "shoot your first frame", which left it nothing to say on day three:
--   chimed_in      - reacted to somebody else's photo
--   in_frame       - somebody tagged you in a photo
--   spotter        - you tagged somebody in one of yours
--   said_it        - wrote a caption
--   ten_frames     - shot ten frames
--   good_company   - somebody followed you
--
-- Two of the six (in_frame, good_company) are things you cannot go and do,
-- deliberately: a ladder made only of chores reads like a chore.
--
-- WHY cover_to_cover CHANGED
-- ---------------------------
-- It meant "every developed roll you were ever a member of contains a photo
-- of yours", which put the floor at ONE roll. Measured before this ran, of
-- its five holders three had earned it by joining a single roll and shooting
-- into it (cody 8/8, lele 3/3, then three accounts at 1/1). It was also
-- unearnable forever after a single miss, since the missed roll counts
-- against you permanently. Trivial for a new account, impossible for an
-- active one. It is now ten rolls counted cumulatively: always progressable,
-- never poisoned by one skip, and nobody in production holds ten yet.
--
-- ⚠️ THE FIVE EXISTING cover_to_cover HOLDERS KEEP IT. A ratchet row is never
-- revisited. The reset is the commented block at the bottom of this file,
-- left off by default: deleting an earned badge is the one thing this system
-- promises never to do, and it should be a decision made on purpose.
--
-- HOW THE BACKFILL WORKS
-- -----------------------
-- Rather than restating all seven predicates a second time as backfill
-- statements (the shape every previous badge migration used, and the place
-- they were most likely to drift from the live ones), PART 3 calls
-- _ratchet_badges once per account after the new body is installed. Same
-- code, so the backfill cannot disagree with the predicate. PART 4 then marks
-- those rows seen, so existing accounts do not open the app to five badges at
-- once; anyone earning them from here on still gets the reveal.
-- ============================================================


-- ============================================================
-- PART 1: widen the id constraint by exactly seven.
-- Rebuilt from the CURRENT constraint UNION the new ids, rather than from a
-- hardcoded list, so this is correct regardless of which earlier migrations
-- are applied and stays safe to re-run.
-- ============================================================
DO $$
DECLARE
    v_ids TEXT;
BEGIN
    SELECT string_agg(quote_literal(id), ', ' ORDER BY id)
    INTO v_ids
    FROM (
        SELECT trim(both '''' from split_part(parts.raw, '::', 1)) AS id
        FROM (
            SELECT unnest(regexp_split_to_array(
                       substring(pg_get_constraintdef(oid) FROM 'ARRAY\[(.*)\]'),
                       '\s*,\s*')) AS raw
            FROM pg_constraint
            WHERE conname = 'earned_badges_badge_id_check'
        ) parts
        UNION
        SELECT unnest(ARRAY['open_door','chimed_in','in_frame','spotter',
                            'said_it','ten_frames','good_company'])
    ) all_ids;

    EXECUTE 'ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_badge_id_check';
    EXECUTE 'ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (' || v_ids || '))';
END $$;


-- ============================================================
-- PART 2: _ratchet_badges, 27 predicates. Every pre-existing one reproduced
-- verbatim; cover_to_cover rewritten; the seven new ones appended, all of
-- them BEFORE full_set, which must stay last because it is the only
-- predicate that reads the ledger it writes to.
-- ============================================================
CREATE OR REPLACE FUNCTION public._ratchet_badges(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    WHERE u.id = p_user_id AND u.signup_ordinal <= 100
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
    -- self-reactions. Deliberately photo_reactions (not post_reactions) —
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

    -- one_year -- NEW. Account is >= 1 year old. earned_at is the exact
    -- instant it became true, never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'one_year', u.created_at + INTERVAL '1 year'
    FROM public.users u
    WHERE u.id = p_user_id AND now() >= u.created_at + INTERVAL '1 year'
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

    -- good_company -- NEW. Somebody followed you. Like in_frame, not something
    -- you can go and do.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'good_company', MIN(f.created_at)
    FROM public.follows f
    WHERE f.following_id = p_user_id
    HAVING MIN(f.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_set -- NEW, LAST. Must run after every predicate above in this
    -- same pass -- see this file's header. Ten OTHER distinct badge ids
    -- already recorded for this user; earned_at pins to the 10th one's own
    -- earned_at, ordered ascending. WHERE badge_id <> 'full_set' is the
    -- explicit cannot-count-itself guarantee.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT eb.earned_at,
               ROW_NUMBER() OVER (ORDER BY eb.earned_at ASC, eb.badge_id ASC) AS rn
        FROM public.earned_badges eb
        WHERE eb.user_id = p_user_id AND eb.badge_id <> 'full_set'
    )
    SELECT p_user_id, 'full_set', earned_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM anon;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM authenticated;


-- ============================================================
-- PART 3: backfill, by running the real thing once per account.
-- ============================================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id FROM public.users LOOP
        PERFORM public._ratchet_badges(r.id);
    END LOOP;
END $$;


-- ============================================================
-- PART 4: mark the backfilled rows seen. Scoped to the seven new ids, so
-- anything already waiting to be revealed to its owner stays waiting.
-- ============================================================
UPDATE public.earned_badges
SET seen_at = now()
WHERE seen_at IS NULL
  AND badge_id IN ('open_door','chimed_in','in_frame','spotter','said_it','ten_frames','good_company');


-- ---- Verify -----------------------------------------------------------------
--
--   SELECT badge_id, COUNT(*) AS holders FROM public.earned_badges
--   WHERE badge_id IN ('open_door','chimed_in','in_frame','spotter','said_it','ten_frames','good_company')
--   GROUP BY badge_id ORDER BY holders DESC;


-- ---- OPTIONAL, DESTRUCTIVE: reset cover_to_cover to the new rule -------------
-- Uncomment and run ONLY if the five existing holders should not keep a badge
-- earned under a rule that no longer exists.
--
-- DELETE FROM public.earned_badges WHERE badge_id = 'cover_to_cover';
-- DO $reset$
-- DECLARE r RECORD;
-- BEGIN
--     FOR r IN SELECT id FROM public.users LOOP
--         PERFORM public._ratchet_badges(r.id);
--     END LOOP;
-- END $reset$;
