-- ============================================================
-- Migration: nine more badges (three scaled-up versions of proven
-- predicates, five new predicates, one owner-grantable id), plus pinning
-- founding_100 to slot 1 of the automatic default. Paste into Supabase
-- Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER supabase/migrations/2026-08-17_profile_identity.sql,
-- 2026-08-17_earned_badges.sql, 2026-08-17_five_more_badges.sql, AND
-- 2026-08-17_displayed_badges.sql, AND 2026-08-17_own_effective_displayed_
-- badges.sql — all five are already applied to production. This file does
-- not edit any of those five; it layers CREATE OR REPLACE on top of
-- 2026-08-17_five_more_badges.sql's public._ratchet_badges and
-- public.grant_badge, and on top of 2026-08-17_own_effective_displayed_
-- badges.sql's public._resolve_effective_displayed_badges. Run this BEFORE
-- pushing any Swift client that expects front_row, packed_house, patron,
-- cover_to_cover, kept_one, regular, one_year, full_set, or founder to
-- exist, or that expects founding_100 to lead the automatic default.
--
-- THE NINE
-- --------
-- Three are the same predicate shape as an existing badge, bar raised:
--   front_row      - first to open the reveal on FIVE rolls (first_in: one)
--   packed_house   - in a roll with >=10 distinct contributors (full_house: >=5)
--   patron         - FIVE invitees went on to join (brought_someone: one)
--
-- Five are new predicates:
--   cover_to_cover - shot into EVERY developed roll ever a member of (>=1 such roll)
--   kept_one       - let TEN photos develop and shared none of them
--   regular        - active on SEVEN distinct days (usage_events, event='app_open')
--   one_year       - the account is a year old
--   full_set       - holds TEN OTHER badges (meta; evaluated last, excludes itself)
--
-- One is owner-grantable, no predicate at all:
--   founder
--
-- WHY packed_house REUSES full_house'S >= (NOT =) SHAPE
-- --------------------------------------------------------
-- Contributors to a roll only ever accumulate — nobody is ever removed from
-- "shot at least one photo into this roll" once true. An exact-count
-- predicate (`= 10`) would delete itself the instant an 11th contributor
-- showed up, because the live-computed count would no longer equal 10. That
-- exact bug is why two_up was cut from the original badge set (see
-- 2026-08-17_five_more_badges.sql's full_house comment), and packed_house is
-- written to the identical `>= 10`, rank-the-10th-contributor shape so it
-- can never reproduce it. Verified in the harness below by adding an
-- eleventh contributor after packed_house has already fired.
--
-- WHY cover_to_cover GETS HARDER TO HOLD, AND WHY THAT'S FINE
-- ----------------------------------------------------------------
-- Once earned (the ratchet freezes it the instant _ratchet_badges first
-- observes "every developed roll I've ever been a member of, I shot into"),
-- joining a new roll and never shooting into it has no effect on the badge
-- itself — a ratchet row, once inserted, is never revisited. What it DOES
-- affect is whether the badge could be earned for the FIRST time by someone
-- who keeps joining rolls without shooting: the more rolls you're in, the
-- more of them you have to have shot into before this predicate is ever
-- observed true. That is the intended shape of the badge (the task's own
-- framing: "this gets harder to hold as someone joins more rolls, which is
-- the point"), not a defect to work around.
--
-- kept_one: WHAT "DEVELOPED BUT NEVER SHARED" MEANS HERE
-- -----------------------------------------------------------
-- A photo is "developed" when its own develop timer has elapsed —
-- p.develops_at <= now(), the same condition every other read path in this
-- schema checks directly (see e.g. schema.sql's "posts: readable when shared
-- to a post" storage policy) rather than trusting photos.is_developed, which
-- is a cron-maintained cache of that same fact (public.mark_developed_photos,
-- schema.sql) that can lag behind the real deadline between cron runs. It is
-- "never shared" when no row in public.posts references it
-- (NOT EXISTS ... posts.photo_id = photos.id) — posts.photo_id is the only
-- place a photo ever gets attached to the feed, and posts_photo_idx already
-- indexes that lookup (schema.sql). No covered-post gate is needed here: a
-- KEPT photo, by definition, was never posted, so it can never be a covered
-- post in the first place (post_is_covered only ever applies to a row in
-- public.posts).
--
-- regular: NOT RETROACTIVE, ON PURPOSE
-- ----------------------------------------
-- usage_events.event = 'app_open' only began collecting as of
-- 2026-08-17_usage_events.sql, and that file's own header says explicitly
-- there is no backfill for it ("no launch or session has ever been written
-- down"). regular's own backfill below is therefore written honestly against
-- whatever real app_open rows already exist (almost certainly zero, or very
-- few, today) rather than inventing history — the same "real evidence or
-- nothing" discipline every other backfill in this feature already follows.
-- Nobody is expected to hold this badge on the day this migration ships;
-- that is expected, not a bug.
--
-- full_set: WHY IT RUNS LAST, AND WHY IT CANNOT COUNT ITSELF
-- ----------------------------------------------------------------
-- full_set is the one predicate in this whole feature that reads
-- earned_badges instead of some other table — it counts how many OTHER
-- badge ids a user already holds. That makes evaluation order load-bearing
-- in a way no other predicate here is: if it ran before, say, front_row's
-- own INSERT in the same _ratchet_badges call, a user who crosses both
-- thresholds in the same call could be short-counted by one and wrongly
-- miss full_set that pass (it would simply catch it the NEXT pass instead,
-- which is not a correctness bug — earned_badges never lies, it would just
-- be needlessly delayed by one call). It is placed as the LAST statement in
-- both _ratchet_badges (this file, PART 2) and the backfill (PART 1) so it
-- always sees every other predicate's result from the SAME pass, including
-- the eight other new ones below it. `WHERE eb.badge_id <> 'full_set'` in
-- its own query is the actual guarantee against counting itself — belt and
-- suspenders on top of the ordering, not a substitute for it: even if a
-- future edit moved full_set earlier by mistake, this clause alone still
-- stops it from ever counting a full_set row it just inserted a moment ago
-- (which cannot happen today, since nothing above it in the file writes
-- badge_id = 'full_set', but there is no reason to leave that safety
-- implicit when one WHERE clause makes it explicit).
--
-- PINNING founding_100 TO SLOT 1
-- --------------------------------
-- Requested explicitly, knowingly: it costs a slot for everyone until FLIM
-- passes 100 accounts (today, that is everyone), because founding_100 is
-- becoming a status marker rather than an information signal, and status
-- markers are supposed to look the same on everyone who has them. This is a
-- rarity-independent guarantee (badge_id = 'founding_100' always sorts
-- first when held, never based on its own current holder_count) implemented
-- entirely inside PART 3's rewrite of
-- _resolve_effective_displayed_badges — the ONE place profile_badges' and
-- own_effective_displayed_badges' non-owner path share (2026-08-17_own_
-- effective_displayed_badges.sql), so both callers move together and cannot
-- drift. It touches ONLY the NULL-selection (no explicit choice made)
-- branch. The explicit-selection branch and the owner-sees-everything
-- branch are byte-for-byte unchanged from
-- 2026-08-17_own_effective_displayed_badges.sql — someone who chose their
-- own four keeps exactly what they chose, in their own order, founding_100
-- or not.
--
-- founder: GRANTABLE, NOT AUTOMATIC
-- -------------------------------------
-- No predicate anywhere in this file mentions 'founder'. It is added to the
-- grantable catalog (earned_badges_grantable_check, PART 0) and to
-- grant_badge's own allow-list (PART 4) exactly the same way founding_crew
-- and test_roll already are, and to NOTHING else — no backfill entry, no
-- _ratchet_badges block. The table constraint is the real backstop (as it
-- already was for the first two grantable ids): even a future rewrite of
-- grant_badge that forgot its own early check could not mint a 'founder' row
-- through any path other than one the constraint allows, and the constraint
-- only allows it via granted_by IS NOT NULL, i.e. only ever through
-- grant_badge itself.
--
-- THE LAUNCH-DAY TRAP, THIRD OCCURRENCE
-- -----------------------------------------
-- Every backfill INSERT below (all eight predicate-backed ids; founder has
-- none) stamps seen_at = now() explicitly, including full_set's — a user who
-- crosses ten distinct badges purely from THIS backfill (the seven other new
-- ones landing on top of whatever they already held) must not also get a
-- brand new "unseen" full_set the moment they next open the app. Only a
-- badge inserted by _ratchet_badges (PART 2) for something that becomes true
-- STRICTLY AFTER this migration runs is ever born with seen_at = NULL.
-- ============================================================


-- ============================================================
-- PART 0: widen both catalogs.
--
-- earned_badges_badge_id_check: verified the exact live shape first (five_
-- more_badges.sql's own PART 0 already established this drop-then-recreate
-- idiom, since CHECK constraints have no ADD-VALUE form) — adds the nine new
-- ids to the closed catalog.
--
-- earned_badges_grantable_check: adds ONLY 'founder' — none of the eight
-- predicate-backed ids join this list, which is what makes "grant_badge can
-- never mint front_row/packed_house/patron/cover_to_cover/kept_one/regular/
-- one_year/full_set" a table-level guarantee rather than an
-- application-logic promise, verified in the harness below.
-- ============================================================
ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_badge_id_check;
ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (
    'first_light', 'full_roll', 'darkroom', 'founding_100',
    'first_in', 'roll_maker', 'brought_someone',
    'founding_crew', 'test_roll',
    'joined_in', 'chipped_in', 'shared', 'well_met', 'full_house',
    'front_row', 'packed_house', 'patron', 'cover_to_cover', 'kept_one',
    'regular', 'one_year', 'full_set', 'founder'
));

ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_grantable_check;
ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_grantable_check CHECK (
    granted_by IS NULL OR badge_id IN ('founding_crew', 'test_roll', 'founder')
);


-- ============================================================
-- PART 1: backfill. Set-based twin of PART 2's per-user predicates below —
-- read PART 2 first if any single block here looks unfamiliar. Every INSERT
-- stamps seen_at = now() explicitly; see this file's header for why that is
-- not optional. full_set's backfill runs LAST, after all eight others, for
-- the identical ordering reason PART 2 documents for the ratchet itself.
-- ============================================================

-- front_row: first to open the reveal (on a roll with >= 2 members) on FIVE
-- different rolls. Same ranked/qualifying_rolls shape as first_in, plus a
-- second rank layer over the caller's own qualifying wins ordered by
-- viewed_at — rn = 5 pins earned_at to the 5th such win's own viewed_at,
-- stable forever once observed: a 6th win can only ever have a LATER
-- viewed_at than one already recorded, so it can never displace rank 5.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
WITH ranked AS (
    SELECT roll_id, user_id, viewed_at,
           ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
    FROM public.roll_reveal_views
), qualifying_rolls AS (
    SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
), my_wins AS (
    SELECT r.user_id, r.roll_id, r.viewed_at,
           ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY r.viewed_at ASC, r.roll_id ASC) AS frn
    FROM ranked r
    JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
    WHERE r.rn = 1
)
SELECT user_id, 'front_row', viewed_at, now()
FROM my_wins
WHERE frn = 5
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- packed_house: identical shape to full_house (five_more_badges.sql), just
-- rn = 10 instead of rn = 5 for "the moment the tenth distinct contributor's
-- first photo landed." See full_house's own comment for the full reasoning
-- on why >= (not =) is the only safe shape, and why every contributor of a
-- qualifying roll shares the SAME earned_at.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
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
SELECT me.contributor_id, 'packed_house', MIN(rt.threshold_at), now()
FROM roll_threshold rt
JOIN ranked me ON me.roll_id = rt.roll_id
GROUP BY me.contributor_id
HAVING MIN(rt.threshold_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- patron: identical lineage join to brought_someone, ranking each inviter's
-- own invitees by the invitee's created_at — rn = 5 pins earned_at to the
-- 5th invitee's own join moment. Records only that it happened and when,
-- same as brought_someone; see that badge's own comment (2026-08-17_earned_
-- badges.sql) for why no invitee identity is ever recorded.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
WITH invitees AS (
    SELECT inv.id AS inviter_id, u.id AS invitee_id, u.created_at
    FROM public.allowed_emails ae
    JOIN public.users u ON lower(u.email) = ae.email
    JOIN public.users inv ON inv.id = split_part(ae.note, ':', 2)::uuid
    WHERE ae.note LIKE 'invited_by:%'
), ranked AS (
    SELECT inviter_id, created_at,
           ROW_NUMBER() OVER (PARTITION BY inviter_id ORDER BY created_at ASC, invitee_id ASC) AS rn
    FROM invitees
)
SELECT inviter_id, 'patron', created_at, now()
FROM ranked
WHERE rn = 5
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- cover_to_cover: for every developed roll a user was ever a member of, did
-- they shoot at least one photo into it. LEFT JOIN LATERAL finds each
-- roll's own first-shot-by-this-user (NULL if never shot); the HAVING
-- clause requires the developed-roll count to equal the shot count (shot
-- into every one) AND to be > 0 (a zero-roll account does not qualify).
-- earned_at = MAX(first_shot) — the moment the LAST missing roll got its
-- first shot, i.e. the instant the streak actually completed. Same
-- freeze-on-first-observation posture as darkroom: joining a new developed
-- roll later without shooting into it does not un-earn an already-inserted
-- row, it only means someone who hasn't earned it yet has to clear a higher
-- bar going forward — see this file's header.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT rm.user_id, 'cover_to_cover', MAX(first_shot.taken_at), now()
FROM public.roll_members rm
JOIN public.rolls r ON r.id = rm.roll_id
LEFT JOIN LATERAL (
    SELECT MIN(p.taken_at) AS taken_at
    FROM public.photos p
    WHERE p.roll_id = rm.roll_id AND p.user_id = rm.user_id
) first_shot ON true
WHERE public.is_roll_developed(r.id)
GROUP BY rm.user_id
HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(first_shot.taken_at)
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- kept_one: ten of the user's OWN photos that have developed
-- (develops_at <= now(), the same live condition every other read path in
-- this schema checks rather than trusting the cron-cached is_developed flag)
-- with no row in posts referencing them. rn = 10 over ascending taken_at
-- pins earned_at to the 10th such photo's own taken_at.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
WITH kept AS (
    SELECT p.user_id, p.taken_at,
           ROW_NUMBER() OVER (PARTITION BY p.user_id ORDER BY p.taken_at ASC, p.id ASC) AS rn
    FROM public.photos p
    WHERE p.develops_at <= now()
      AND NOT EXISTS (SELECT 1 FROM public.posts po WHERE po.photo_id = p.id)
)
SELECT user_id, 'kept_one', taken_at, now()
FROM kept
WHERE rn = 10
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- regular: active (event = 'app_open') on seven DISTINCT days. rn = 7 over
-- ascending day pins earned_at to that 7th day (midnight UTC, matching this
-- table's own UTC day-bucket convention). See this file's header for why
-- this is expected to insert few or zero rows today.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
WITH days AS (
    SELECT DISTINCT user_id, day
    FROM public.usage_events
    WHERE event = 'app_open'
), ranked AS (
    SELECT user_id, day,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY day ASC) AS rn
    FROM days
)
SELECT user_id, 'regular', day::timestamptz, now()
FROM ranked
WHERE rn = 7
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- one_year: the account's created_at is at least a year in the past.
-- earned_at is the exact instant it became true (created_at + 1 year), never
-- now() — same posture as founding_100's own earned_at.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT u.id, 'one_year', u.created_at + INTERVAL '1 year', now()
FROM public.users u
WHERE now() >= u.created_at + INTERVAL '1 year'
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- full_set: LAST. Ten OTHER distinct badge ids already in earned_badges (as
-- of everything inserted by this file so far, in this same transaction).
-- rn = 10 over each user's own badges ordered by that badge's own earned_at
-- pins full_set's earned_at to the 10th badge's own earned_at — the moment
-- the set actually became complete, not the moment this backfill happened
-- to notice. WHERE badge_id <> 'full_set' is the explicit
-- cannot-count-itself guarantee; see this file's header for why that's
-- belt-and-suspenders on top of running last, not a substitute for it.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
WITH ranked AS (
    SELECT eb.user_id, eb.earned_at,
           ROW_NUMBER() OVER (PARTITION BY eb.user_id ORDER BY eb.earned_at ASC, eb.badge_id ASC) AS rn
    FROM public.earned_badges eb
    WHERE eb.badge_id <> 'full_set'
)
SELECT user_id, 'full_set', earned_at, now()
FROM ranked
WHERE rn = 10
ON CONFLICT (user_id, badge_id) DO NOTHING;


-- ============================================================
-- PART 2: public._ratchet_badges(p_user_id) — CREATE OR REPLACE on top of
-- 2026-08-17_five_more_badges.sql's version. Reproduces all twelve existing
-- predicates VERBATIM (nothing about what makes any of them true, or what
-- their earned_at is computed as, changes here), then appends the eight new
-- ones, with full_set LAST — see this file's header for why that ordering
-- is load-bearing. Still internal-only: REVOKE ALL FROM PUBLIC, anon, AND
-- authenticated below, unchanged posture from five_more_badges.sql. Callers
-- (profile_badges, refresh_own_badges) are untouched by this file — they
-- call this function by name, so replacing its body here is all either of
-- them needs to pick up the nine new predicates on their very next call.
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

    -- cover_to_cover -- NEW. See PART 1's matching block for the full
    -- comment on the LATERAL shape and why it gets harder to hold on
    -- purpose.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'cover_to_cover', MAX(first_shot.taken_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    LEFT JOIN LATERAL (
        SELECT MIN(p.taken_at) AS taken_at
        FROM public.photos p
        WHERE p.roll_id = rm.roll_id AND p.user_id = rm.user_id
    ) first_shot ON true
    WHERE rm.user_id = p_user_id
      AND public.is_roll_developed(r.id)
    HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(first_shot.taken_at)
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
-- PART 3: public._resolve_effective_displayed_badges(p_profile_id, p_viewer)
-- -- CREATE OR REPLACE on top of 2026-08-17_own_effective_displayed_
-- badges.sql's version. Signature, STABLE/SECURITY DEFINER, internal-only
-- REVOKEs, the explicit-selection branch, and the covered-post gate are all
-- UNCHANGED. The ONLY change is the NULL-selection (rarest-four default)
-- branch: founding_100, when held, now always occupies the first output
-- row, and the remaining (up to) three rows are the rarest of everything
-- else -- see this file's header for the full reasoning.
--
-- IMPLEMENTATION: a single `slot_rank` column, 0 for badge_id =
-- 'founding_100' and 1 for everything else, added as the PRIMARY sort key
-- ahead of the existing rarity/earned_at/badge_id tiebreak chain, then
-- LIMIT 4 as before. This is a superset of the old behaviour, not a special
-- case bolted on: when founding_100 is absent from the candidate set
-- entirely, slot_rank is 1 for every row, so the ORDER BY reduces to
-- exactly rarity.holder_count ASC, eb.earned_at ASC, eb.badge_id ASC -- the
-- untouched original ordering -- and the result is byte-for-byte identical
-- to what 2026-08-17_own_effective_displayed_badges.sql already produced.
-- When founding_100 IS present, slot_rank = 0 sorts it ahead of every other
-- row regardless of its OWN holder_count, guaranteeing slot 1 unconditionally
-- rather than "usually, because it happens to be rare" -- which is the whole
-- point: this is meant to hold even after FLIM passes 100 accounts and
-- founding_100 is no longer the rarest thing on the list by holder count
-- alone.
-- ============================================================
CREATE OR REPLACE FUNCTION public._resolve_effective_displayed_badges(p_profile_id UUID, p_viewer UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_selection TEXT[];
BEGIN
    SELECT u.displayed_badges INTO v_selection
    FROM public.users u
    WHERE u.id = p_profile_id;

    IF v_selection IS NULL THEN
        -- Default: founding_100 first if held (slot_rank 0), then the
        -- rarest of everything else. See this file's header for why a
        -- single slot_rank column, sorted ahead of the existing
        -- rarity/earned_at/badge_id chain, is a superset of (not a
        -- divergent rewrite of) 2026-08-17_own_effective_displayed_badges
        -- .sql's own ordering. The covered-post gate sits in the SAME WHERE
        -- that feeds the ORDER BY/LIMIT below it, unchanged reasoning from
        -- that file.
        RETURN QUERY
        SELECT c.badge_id, c.earned_at
        FROM (
            SELECT eb.badge_id, eb.earned_at,
                   CASE WHEN eb.badge_id = 'founding_100' THEN 0 ELSE 1 END AS slot_rank,
                   rarity.holder_count
            FROM public.earned_badges eb
            JOIN (
                SELECT eb2.badge_id, COUNT(DISTINCT eb2.user_id) AS holder_count
                FROM public.earned_badges eb2
                GROUP BY eb2.badge_id
            ) rarity ON rarity.badge_id = eb.badge_id
            WHERE eb.user_id = p_profile_id
              AND (
                  eb.badge_id <> 'shared'
                  OR public.covered_post_visible(p_viewer, p_profile_id, eb.earned_at)
              )
        ) c
        ORDER BY c.slot_rank ASC, c.holder_count ASC, c.earned_at ASC, c.badge_id ASC
        LIMIT 4;
        RETURN;
    END IF;

    -- Explicit selection, possibly '{}' (show none). UNCHANGED from
    -- 2026-08-17_own_effective_displayed_badges.sql: an explicit choice is
    -- never reordered to put founding_100 first -- "someone who chose their
    -- own four keeps exactly what they chose, in their order."
    RETURN QUERY
    SELECT eb.badge_id, eb.earned_at
    FROM unnest(v_selection) WITH ORDINALITY AS sel(badge_id, ord)
    JOIN public.earned_badges eb
        ON eb.user_id = p_profile_id AND eb.badge_id = sel.badge_id
    WHERE eb.badge_id <> 'shared'
       OR public.covered_post_visible(p_viewer, p_profile_id, eb.earned_at)
    ORDER BY sel.ord ASC;
END;
$$;

REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM authenticated;

-- profile_badges (2026-08-17_own_effective_displayed_badges.sql) and
-- own_effective_displayed_badges (same file) both call this function BY
-- NAME, not inline -- neither needs a CREATE OR REPLACE here to pick up the
-- founding_100 pin. Both are otherwise completely untouched by this file.


-- ============================================================
-- PART 4: grant_badge -- CREATE OR REPLACE on top of 2026-08-17_earned_
-- badges.sql's version, widening the allow-list by exactly one id:
-- 'founder'. Everything else (owner gate, ON CONFLICT DO NOTHING, earned_at
-- = now() for a grant, the table CHECK backstop from PART 0 above) is
-- unchanged. revoke_badge needs no edit -- it already deletes any row with
-- granted_by IS NOT NULL regardless of badge_id, so it already works for
-- 'founder' with no change.
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_badge(p_user_id UUID, p_badge_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    IF p_badge_id NOT IN ('founding_crew', 'test_roll', 'founder') THEN
        RAISE EXCEPTION 'badge % is not grantable', p_badge_id;
    END IF;

    INSERT INTO public.earned_badges (user_id, badge_id, earned_at, granted_by)
    VALUES (p_user_id, p_badge_id, now(), auth.uid())
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_badge(UUID, TEXT) TO authenticated;


-- ---- How the app uses this --------------------------------------------------
--
-- profile_badges, refresh_own_badges, set_displayed_badges,
-- own_unseen_badges, mark_own_badges_seen, unseen_badge_count,
-- own_effective_displayed_badges: ALL UNCHANGED calls and return shapes --
-- see 2026-08-17_earned_badges.sql, 2026-08-17_five_more_badges.sql,
-- 2026-08-17_displayed_badges.sql, and 2026-08-17_own_effective_displayed_
-- badges.sql's own footers for the full list.
--
-- Automatic catalog is now twenty ids: first_light, full_roll, darkroom,
-- founding_100, first_in, roll_maker, brought_someone, joined_in,
-- chipped_in, shared, well_met, full_house, front_row, packed_house,
-- patron, cover_to_cover, kept_one, regular, one_year, full_set.
-- Grantable catalog is now three ids: founding_crew, test_roll, founder.
--   SELECT * FROM profile_badges('<uuid>');
--
-- own_effective_displayed_badges() and profile_badges' non-owner branch now
-- both lead with founding_100 (when held) before the rarest-of-the-rest --
-- unchanged call, same return shape, only the DEFAULT ordering moved:
--   SELECT * FROM own_effective_displayed_badges();
--
-- Owner-only, from the admin dashboard (flim-app.com/admin), not the app:
--   SELECT grant_badge('<uuid>', 'founder');
