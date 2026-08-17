-- ============================================================
-- Migration: five more earned badges, plus a fix for a real defect in how
-- badges get recorded at all. Paste into Supabase Dashboard -> SQL Editor
-- and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER supabase/migrations/2026-08-17_profile_identity.sql
-- AND supabase/migrations/2026-08-17_earned_badges.sql (both already applied
-- to production). This file ALTERS what those two shipped: it widens
-- earned_badges' badge_id CHECK constraint, backfills five new badge ids,
-- and CREATE OR REPLACEs public.profile_badges and public.grant_badge's
-- sibling functions with new bodies. It does not edit either prior file.
--
-- WHY THESE FIVE
-- --------------
-- Measured against production: 48 accounts, 34 have ever shot anything, 15
-- joined a roll, 10 shot into one, 5 created one. Four of the seven existing
-- badges require a roll, so only ~21% of users can reach most of the set.
-- These five mark the rungs people actually fall off, and make the feature
-- non-empty for people who use FLIM as a plain camera:
--   joined_in   - joined a roll someone else started (not one you made)
--   chipped_in  - shot into a roll you did not create
--   shared      - posted a frame to the feed, ever
--   well_met    - somebody else reacted to one of your photos
--   full_house  - a roll you contributed to reached 5+ distinct contributors
--
-- THE SECOND THING THIS FILE FIXES: NOTHING EVER FIRED THE RATCHET
-- -------------------------------------------------------------------
-- public.profile_badges(p_profile_id) is the ONLY thing that has ever
-- written to earned_badges outside a backfill, and the Swift client only
-- calls it from UserPageView -- i.e. when somebody opens A profile. There
-- was no path that fired when the CALLER's own predicates newly became
-- true. Concretely: user earns a badge, nothing records it. No row exists,
-- unseen_badge_count() (a pure read) returns 0, the dot never appears, and
-- the user has no reason to open their own profile to trigger it. The only
-- thing that worked was a DIFFERENT user opening THEIR profile, which fires
-- the ratchet for THAT profile as a side effect -- never for the caller.
--
-- THE FIX: public.refresh_own_badges() -- see PART 4 below. Zero-argument,
-- hard-pinned to auth.uid(), evaluates the CALLER's own predicates, ratchets
-- them into earned_badges (identical shape to what profile_badges already
-- did, same historical earned_at, never now()), and returns the caller's
-- own unseen count so the client gets both in one round trip. The Swift
-- client should call this instead of (or in addition to) unseen_badge_count()
-- at the moments it currently polls that count -- see the "How the app uses
-- this" footer for the exact call.
--
-- REFACTOR, NOT DUPLICATION
-- --------------------------
-- profile_badges and refresh_own_badges both need to run the exact same
-- twelve predicates (seven original, five new below). Copy-pasting them into
-- two functions would create two copies that WILL drift -- the whole reason
-- this system exists is that the first version's predicates (the pre-ledger,
-- live-computed ones) were subtly wrong. So the predicates now live in
-- exactly one place: public._ratchet_badges(p_user_id UUID), an internal,
-- fully un-grantable helper (EXECUTE revoked from PUBLIC, anon, AND
-- authenticated -- nobody calls it directly, only profile_badges and
-- refresh_own_badges call it, and both of those are themselves SECURITY
-- DEFINER, so the call succeeds under the defining role's own privileges on
-- its own function regardless of the REVOKE, the same way one SECURITY
-- DEFINER function in this schema has always been able to call another).
-- profile_badges and refresh_own_badges are now both thin: ratchet, then
-- read back whatever's relevant to that caller.
--
-- COVERED POSTS: WHAT LEAKS AND WHAT DOESN'T
-- ---------------------------------------------
-- shared's earned_at is pinned, forever, to a specific posts.created_at --
-- the first one a user ever made. profile_badges is callable about ANY
-- profile by ANY authenticated caller. If that first post happens to be a
-- COVERED post (2026-08-12_covered_posts.sql: three named accounts, a fixed
-- window, hidden from everyone except the author/the other two/the owner),
-- returning that exact timestamp to an unauthorized viewer would leak that a
-- post existed at that instant even though the post row and its bytes stay
-- hidden -- a real leak this file must not introduce. The fix is a read-time
-- filter, not a write-time one: the ratchet still writes the honest, global
-- earned_at (a fact about the past, true regardless of who's asking, same as
-- every other predicate in this file), but profile_badges' final SELECT now
-- omits the 'shared' row entirely -- not just blanks its date, the whole row
-- -- unless public.covered_post_visible(auth.uid(), p_profile_id, earned_at)
-- says the caller may see a post at that author/timestamp. That function
-- already exists (2026-08-12_covered_posts.sql) and needs no changes: it
-- returns TRUE unconditionally for a non-covered timestamp, for the post's
-- own author, and for the owner, which is exactly "fail closed for everyone
-- else, fully working for everyone who's allowed to know." Verified in
-- PART 5 below with an actual covered post in the harness.
--
-- well_met deliberately does NOT get an equivalent gate, and that is a
-- decision, not an oversight: well_met is computed entirely from
-- photo_reactions joined to photos -- it never touches public.posts or any
-- covered-post machinery at all. photo_reactions' own visibility has always
-- been governed by roll membership (public.photo_reactions' RLS policy,
-- unrelated to posts), and 2026-08-12_covered_posts.sql says explicitly, in
-- its own header, that it deliberately does NOT touch reactions: "a covered
-- post's comments/reactions/tags are NOT separately hidden by this file."
-- A reaction on a raw photo can happen (and, in FLIM, typically does happen)
-- long before that photo is ever posted to the feed at all, so its timestamp
-- carries no reliable correlation to when or whether a post was later made,
-- let alone whether that post fell inside a covered window. This is the same
-- posture the already-shipped first_light and full_roll badges already
-- take -- both reveal roll/photo timing without any covered-post gate, and
-- that was already accepted in production. Reusing post_reactions (which
-- IS keyed off public.posts) for well_met instead would have reintroduced
-- exactly the coupling this paragraph is explaining why to avoid, which is
-- why photo_reactions was chosen over post_reactions for this badge -- see
-- PART 3's well_met block for the query itself.
--
-- THE LAUNCH-DAY TRAP, SECOND OCCURRENCE
-- -----------------------------------------
-- Every one of these five is earned RETROACTIVELY by people who already did
-- the thing. PART 2's backfill stamps seen_at = now() explicitly on every
-- row it writes, exactly as 2026-08-17_earned_badges.sql's own backfill did
-- -- marking them seen is reversible (an owner can NULL a seen_at later to
-- fire the reveal deliberately) where letting them fire on ship is not.
-- Only a badge inserted by _ratchet_badges for something that becomes true
-- STRICTLY AFTER this migration runs -- via profile_badges OR the new
-- refresh_own_badges -- is ever born with seen_at = NULL. _ratchet_badges'
-- own INSERTs never mention seen_at at all, letting the column take its
-- NULL default, precisely so this rule holds no matter which of the two
-- callers happens to trigger a given predicate first.
-- ============================================================


-- ============================================================
-- PART 0: widen the catalog. Verified the exact live shape first (see this
-- file's own header task): earned_badges_badge_id_check currently reads
-- CHECK (badge_id IN ('first_light', 'full_roll', 'darkroom', 'founding_100',
-- 'first_in', 'roll_maker', 'brought_someone', 'founding_crew', 'test_roll')).
-- CHECK constraints have no ADD-VALUE form, so this is drop-then-recreate,
-- same idiom as this schema's DROP POLICY IF EXISTS + CREATE POLICY -- safe
-- to re-run, and the constraint's CONTENTS are what's compared, not whether
-- a create-attempt already ran once.
--
-- earned_badges_grantable_check is UNTOUCHED here on purpose: it stays
-- exactly `granted_by IS NULL OR badge_id IN ('founding_crew', 'test_roll')`.
-- None of the five ids below are added to it, which is what makes
-- "grant_badge can never mint one of these five" a table-level guarantee
-- instead of an application-logic promise -- verified in PART 5.
-- ============================================================
ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_badge_id_check;
ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (
    'first_light', 'full_roll', 'darkroom', 'founding_100',
    'first_in', 'roll_maker', 'brought_someone',
    'founding_crew', 'test_roll',
    'joined_in', 'chipped_in', 'shared', 'well_met', 'full_house'
));


-- ============================================================
-- PART 1: backfill. Set-based twin of PART 3's per-user predicates below --
-- read PART 3 first if any single block here looks unfamiliar. Every INSERT
-- stamps seen_at = now() explicitly; see this file's header for why that is
-- not optional.
-- ============================================================

-- joined_in: joined a roll (roll_members) that somebody ELSE created.
-- Excludes the creator's own roll_members row (a creator very likely has
-- one) by requiring rolls.created_by <> the member. Earned at that
-- membership's own joined_at, earliest qualifying roll.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT rm.user_id, 'joined_in', MIN(rm.joined_at), now()
FROM public.roll_members rm
JOIN public.rolls r ON r.id = rm.roll_id
WHERE r.created_by <> rm.user_id
GROUP BY rm.user_id
HAVING MIN(rm.joined_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- chipped_in: shot at least one photo into a roll they did not create.
-- photos.roll_id is nullable (solo shots aren't in any roll); the JOIN to
-- rolls naturally excludes those rows, no separate IS NOT NULL check needed.
-- Earned at that photo's own taken_at, earliest qualifying.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT p.user_id, 'chipped_in', MIN(p.taken_at), now()
FROM public.photos p
JOIN public.rolls r ON r.id = p.roll_id
WHERE r.created_by <> p.user_id
GROUP BY p.user_id
HAVING MIN(p.taken_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- shared: posted a frame to the feed, full stop. Earned at their first
-- posts.created_at. See this file's header for why this timestamp is
-- deliberately NOT filtered for covered-post status here (backfill records
-- the honest global fact; the covered-post gate lives at READ time in
-- profile_badges, PART 3, so it stays correct even if covered_post_windows
-- changes later).
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT po.user_id, 'shared', MIN(po.created_at), now()
FROM public.posts po
GROUP BY po.user_id
HAVING MIN(po.created_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- well_met: somebody ELSE reacted to one of their photos. Excludes
-- self-reactions (pr.user_id <> p.user_id) -- without that, this would be
-- trivially self-grantable by reacting to your own photo. Earned at the
-- earliest qualifying reaction's own created_at. Deliberately photo_reactions
-- (roll-scoped, unrelated to posts/covered), not post_reactions -- see this
-- file's header for the full reasoning.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT p.user_id, 'well_met', MIN(pr.created_at), now()
FROM public.photo_reactions pr
JOIN public.photos p ON p.id = pr.photo_id
WHERE pr.user_id <> p.user_id
GROUP BY p.user_id
HAVING MIN(pr.created_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- full_house: a roll reaches 5+ DISTINCT CONTRIBUTORS (shot >= 1 photo into
-- it, not merely a roll_members row), and this user is one of them. Uses
-- >= 5, not = 5, on purpose: contributors only ever accumulate as more
-- people shoot into a roll, so a roll that reaches 6 necessarily passed
-- through 5, and an exact-match predicate would delete the badge the moment
-- a sixth person showed up -- that exact bug is why two_up was cut from the
-- original badge set, and this is written to never reproduce its shape.
-- roll_contributors: each (roll, contributor)'s own first photo. ranked:
-- contributors within a roll ordered by that first-photo time (contributor
-- id as a deterministic tiebreak for the vanishingly unlikely exact tie,
-- same shape as first_in's ROW_NUMBER below). roll_threshold: the 5th-ranked
-- contributor's own first-shot time -- this is what "the moment the fifth
-- distinct contributor's first photo landed" is. Fixed forever the instant a
-- roll has 5 contributors: a 6th, 7th, ... contributor's own first-shot time
-- is necessarily later than rank 5's, so it can never move rank 5's own
-- value backward or displace it. EVERY contributor of a roll that clears
-- the threshold earns the SAME earned_at (the roll's own qualifying moment),
-- including someone who joined in as contributor #8 after the roll had
-- already reached 5 -- that is the literal reading of "the user must be one
-- of them," not "the user must be one of the first five."
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
    WHERE rn = 5
)
SELECT me.contributor_id, 'full_house', MIN(rt.threshold_at), now()
FROM roll_threshold rt
JOIN ranked me ON me.roll_id = rt.roll_id
GROUP BY me.contributor_id
HAVING MIN(rt.threshold_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;


-- ============================================================
-- PART 2: public._ratchet_badges(p_user_id) -- the one and only place all
-- twelve predicates (seven original + five new) live. Both profile_badges
-- (PART 3) and refresh_own_badges (PART 4) call this, then each does its own
-- read afterward. RETURNS void: unlike profile_badges/refresh_own_badges,
-- this function declares no OUT variables, so none of the bare `badge_id`
-- references in each ON CONFLICT target below are ambiguous the way they
-- were inside profile_badges' own RETURNS TABLE (badge_id, earned_at) body
-- (2026-08-17_earned_badges.sql's own comment on #variable_conflict
-- use_column explains that collision) -- moving this logic out from under a
-- RETURNS TABLE signature is what makes that pragma unnecessary here.
--
-- INTERNAL ONLY: EXECUTE is revoked from PUBLIC, anon, AND authenticated --
-- nobody calls this directly, ever. profile_badges and refresh_own_badges
-- can still call it because both are themselves SECURITY DEFINER: a
-- SECURITY DEFINER function executes with the privileges of the role that
-- OWNS it, and that owner (whoever runs this file, i.e. the Dashboard SQL
-- editor / service role) owns _ratchet_badges too and so always retains
-- implicit EXECUTE on its own function regardless of the REVOKE below -- the
-- REVOKE only ever stops a DIFFERENT role (anon, authenticated, or any other
-- non-owner) from calling it directly.
--
-- The seven ORIGINAL blocks below are reproduced with IDENTICAL predicates
-- to 2026-08-17_earned_badges.sql's PART 3 -- only the parameter name
-- changed (p_profile_id -> p_user_id, since this is no longer "the profile
-- someone's viewing," it's "whoever's predicates we're evaluating"). Nothing
-- about what makes a badge true, or what earned_at is computed as, is
-- touched. The FIVE NEW blocks follow, matching PART 1's backfill shape
-- exactly except grouped by nothing (parameterized to one user instead of
-- every user at once) and never touching seen_at.
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

    -- joined_in -- NEW. See PART 1's matching block for the full comment.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'joined_in', MIN(rm.joined_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    WHERE rm.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(rm.joined_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chipped_in -- NEW. See PART 1's matching block.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chipped_in', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.rolls r ON r.id = p.roll_id
    WHERE p.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- shared -- NEW. earned_at is the honest global first posts.created_at;
    -- the covered-post gate is applied at READ time by profile_badges
    -- (PART 3), not here. See PART 1's matching block.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'shared', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- well_met -- NEW. Excludes self-reactions. See PART 1's matching block,
    -- and this file's header, for why photo_reactions (not post_reactions)
    -- and why no covered-post gate is needed here.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'well_met', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE p.user_id = p_user_id
      AND pr.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_house -- NEW. See PART 1's matching block for the full comment on
    -- >= 5 vs = 5 and why every contributor of a qualifying roll shares one
    -- earned_at.
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
END;
$$;

REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM anon;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM authenticated;


-- ============================================================
-- PART 3: profile_badges -- now a thin wrapper: ratchet the profile being
-- VIEWED, then read back what's actually there, with one extra guard.
--
-- Same SECURITY DEFINER / callable-about-any-profile / authenticated-only
-- posture as before, unchanged. Signature and return SHAPE are UNCHANGED:
-- still profile_badges(p_profile_id UUID) RETURNS TABLE (badge_id TEXT,
-- earned_at TIMESTAMPTZ). What changed is which ROWS can come back: a
-- 'shared' row is now omitted entirely (not blanked, omitted) for a caller
-- who is not allowed to know a covered post exists at that timestamp -- see
-- this file's header "COVERED POSTS: WHAT LEAKS AND WHAT DOESN'T." Every
-- other badge_id is returned exactly as before.
-- ============================================================
CREATE OR REPLACE FUNCTION public.profile_badges(p_profile_id UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM public._ratchet_badges(p_profile_id);

    RETURN QUERY
    SELECT eb.badge_id, eb.earned_at
    FROM public.earned_badges eb
    WHERE eb.user_id = p_profile_id
      AND (
          eb.badge_id <> 'shared'
          OR public.covered_post_visible(auth.uid(), p_profile_id, eb.earned_at)
      )
    ORDER BY eb.earned_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_badges(UUID) TO authenticated;


-- ============================================================
-- PART 4: refresh_own_badges() -- the fix for "nothing ever recorded a
-- badge for the person who actually earned it." See this file's header for
-- the full defect description.
--
-- Zero arguments, hard-pinned to auth.uid() -- same non-negotiable rule
-- 2026-08-17_earned_badges.sql's PART 5 already established for
-- mark_own_badges_seen/unseen_badge_count/own_unseen_badges: a function that
-- writes or reads "the caller's own" anything must resolve entirely from
-- auth.uid(), never from an argument, or a caller could act on someone
-- else's row. Ratchets via _ratchet_badges(auth.uid()) -- the identical
-- predicates profile_badges uses, so a badge earned by calling this function
-- is indistinguishable in the table from one that would have been earned by
-- someone else opening this user's profile. Returns the caller's own unseen
-- count (BIGINT, matching unseen_badge_count()'s own return type) so the
-- client gets "ratchet, then tell me if anything's new" in one round trip
-- instead of two.
--
-- Badges this records are newly earned, genuinely, right now -- they follow
-- the NORMAL rule (seen_at NULL by default, since _ratchet_badges never
-- mentions that column) rather than the backfill's rule. That is exactly
-- right: unlike the backfill, there is no "this already happened before the
-- feature existed" fact to launder here, so there's nothing to pre-mark
-- seen.
--
-- unseen_badge_count() itself is UNCHANGED -- still STABLE, still a pure
-- read, still exactly what it was in 2026-08-17_earned_badges.sql. It
-- remains the right call for a cheap read with no write side effect (e.g. a
-- tab-bar dot re-check that doesn't want to risk a write on every render);
-- refresh_own_badges() is for the moment the client actually wants to make
-- sure anything newly true gets recorded.
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_own_badges()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM public._ratchet_badges(auth.uid());

    RETURN (
        SELECT COUNT(*)::BIGINT
        FROM public.earned_badges
        WHERE user_id = auth.uid() AND seen_at IS NULL
    );
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_own_badges() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_own_badges() FROM anon;
GRANT EXECUTE ON FUNCTION public.refresh_own_badges() TO authenticated;


-- ---- How the app uses this --------------------------------------------------
--
-- Unchanged call, same return shape (badge_id TEXT, earned_at TIMESTAMPTZ).
-- Automatic catalog is now twelve ids: first_light, full_roll, darkroom,
-- founding_100, first_in, roll_maker, brought_someone, joined_in,
-- chipped_in, shared, well_met, full_house. Grantable catalog UNCHANGED:
-- founding_crew, test_roll.
--   SELECT * FROM profile_badges('<uuid>');
--
-- NEW -- call this instead of (or right before) unseen_badge_count() at the
-- moments the client wants to make sure anything the CALLER just did gets
-- recorded, not just displayed: e.g. right after finishing a roll's reveal,
-- posting to the feed, or on a periodic app-foreground check. Ratchets the
-- caller's own badges, then returns their own unseen count in one call:
--   SELECT refresh_own_badges();
--
-- Own unseen badges, called once when the profile tab / badge strip is
-- actually shown to their owner:
--   SELECT mark_own_badges_seen();
--
-- Dot on the profile tab, own badges only, no argument, cheap, READ ONLY (no
-- write, so it will NOT surface something newly true until something else --
-- refresh_own_badges(), or someone opening this profile -- has ratcheted it
-- in first):
--   SELECT unseen_badge_count();
--
-- WHICH of the caller's own badges are unseen, for the press-in animation at
-- render time, own badges only, no argument:
--   SELECT * FROM own_unseen_badges();
--
-- Owner-only, from the admin dashboard (flim-app.com/admin), not the app:
--   SELECT grant_badge('<uuid>', 'founding_crew');
--   SELECT revoke_badge('<uuid>', 'founding_crew');
