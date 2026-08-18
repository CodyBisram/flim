-- ============================================================
-- Migration: let a user find out WHICH of their own badges a stranger
-- actually sees on their profile right now, not just the rule that decides
-- it. Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER supabase/migrations/2026-08-17_profile_identity.sql,
-- 2026-08-17_earned_badges.sql, 2026-08-17_five_more_badges.sql, AND
-- 2026-08-17_displayed_badges.sql — all four are already applied to
-- production as of this file (2026-08-17_displayed_badges.sql's
-- rarest-four default has been confirmed resolving correctly for a real
-- account). This file does not edit any of those four; it layers on top of
-- 2026-08-17_displayed_badges.sql's public.profile_badges via
-- CREATE OR REPLACE.
--
-- THE GAP THIS CLOSES
-- --------------------
-- profile_badges(p_profile_id) correctly returns EVERY earned badge when
-- the caller asks about themselves — hiding a badge is a statement about
-- what OTHERS see, never about hiding it from the person who earned it,
-- and that must not change. But that means there has never been a read
-- path, even for the owner, that returns the RESOLVED set a stranger would
-- actually see. A profile owner can be told "only four of these show to
-- other people, picked automatically," but not WHICH four — rarity can't
-- be derived client-side, it needs COUNT(DISTINCT user_id) per badge_id
-- across every account, which the client has no business touching
-- directly. That gap is the exact complaint that started this whole
-- feature (a user had no idea only their four rarest showed to others);
-- stating the rule without the outcome only half-answers it.
--
-- THE FIX, IN THREE PARTS
-- ------------------------
--   1. public._resolve_effective_displayed_badges(p_profile_id, p_viewer) —
--      the non-owner branch of profile_badges (2026-08-17_displayed_badges
--      .sql PART 2), extracted verbatim and parameterized by viewer instead
--      of reading auth.uid() directly. This is the ONE place "stored
--      selection, else rarest-four, gated on covered-shared" now lives —
--      see the note below on why sharing it, not re-deriving it twice, is
--      the whole point.
--   2. profile_badges' non-owner branch becomes a two-line delegation to
--      that helper, called with p_viewer = auth.uid() — the real caller,
--      exactly as before. Signature, return shape, the _ratchet_badges
--      call, the owner-sees-all branch, and the covered-post gate are all
--      unchanged; only WHERE the non-owner branch's logic lives moves.
--   3. public.own_effective_displayed_badges() — zero-argument, hard-pinned
--      to auth.uid(), the new self-serve read. Calls the same helper with
--      p_profile_id = auth.uid() but p_viewer = NULL, which is what makes
--      this "what a STRANGER sees" rather than "what I see of myself" —
--      see PART 3 below for exactly why NULL is the right stand-in.
--
-- WHY FACTOR RATHER THAN RE-DERIVE
-- -----------------------------------
-- Two hand-maintained copies of "stored selection, else rarest four,
-- ordered the same way, gated on covered-shared the same way" is precisely
-- the kind of divergence this feature has already been bitten by once
-- (2026-08-17_five_more_badges.sql's own header describes profile_badges
-- and refresh_own_badges needing the same twelve predicates, and factors
-- them into _ratchet_badges for exactly this reason). Both callers here
-- share the identical query text, not a re-typed variant of it — a badge
-- reported as "what shows to a stranger" via own_effective_displayed_
-- badges() and a badge actually shown to a real stranger via
-- profile_badges() can never disagree, because they run the same code.
--
-- WHY p_viewer = NULL MEANS "A STRANGER," NOT "NOBODY"
-- --------------------------------------------------------
-- public.covered_post_visible(p_viewer, p_author, p_created_at)
-- (2026-08-12_covered_posts.sql) is:
--     NOT post_is_covered(p_author, p_created_at)
--     OR is_owner(p_viewer)
--     OR EXISTS (covered_post_windows w WHERE w.user_id = p_viewer AND w.active)
-- Calling own_effective_displayed_badges() with p_viewer = auth.uid() (the
-- caller looking at THEIR OWN profile) would be wrong here: is_owner(v) is
-- irrelevant to that question, but the third clause fires whenever
-- p_viewer = p_profile_id and that profile was ever covered — covered_
-- post_visible is TRUE for a covered account looking at their OWN 'shared'
-- badge unconditionally (see 2026-08-17_displayed_badges.sql PART 2's own
-- comment on why that's correct for THAT function — the owner must always
-- see their own full badge list). Reusing that same call here would answer
-- "can I see my own badge," which is always yes, not "would a stranger see
-- it," which is the actual question this function exists to answer.
-- p_viewer = NULL sidesteps this cleanly: is_owner(NULL) is FALSE (no user
-- row has id = NULL), and EXISTS (... w.user_id = NULL ...) is FALSE for
-- the same reason (NULL never equals any user_id), so covered_post_visible
-- (NULL, author, t) reduces to exactly NOT post_is_covered(author, t) — a
-- generic viewer who is neither the site owner nor one of the three
-- covered accounts. That IS the definition of "a stranger" this whole
-- feature is answering "what does a stranger see" about, and it is the
-- strictest (fail-closed) simulation available: it can only ever omit a
-- row a real stranger would also have had omitted, never the reverse.
-- ============================================================


-- ============================================================
-- PART 1: public._resolve_effective_displayed_badges(p_profile_id, p_viewer)
-- — the shared non-owner resolution logic. Byte-identical query text to
-- 2026-08-17_displayed_badges.sql PART 2's non-owner branch, with auth.uid()
-- replaced by the p_viewer parameter everywhere it appeared. Does NOT call
-- _ratchet_badges — this is a pure read over whatever earned_badges already
-- holds, same posture as own_unseen_badges/unseen_badge_count
-- (2026-08-17_earned_badges.sql PART 5): ratcheting is profile_badges' and
-- refresh_own_badges' job, not every reader's.
--
-- INTERNAL ONLY, same shape as _ratchet_badges — EXECUTE is revoked from
-- PUBLIC, anon, AND authenticated. Nobody calls this directly: profile_
-- badges (PART 2) and own_effective_displayed_badges (PART 3) can still
-- call it because both are themselves SECURITY DEFINER, and a SECURITY
-- DEFINER function always retains implicit EXECUTE on another function
-- owned by the same role regardless of a REVOKE aimed at other roles. This
-- is deliberate, not incidental: p_viewer is a trusted argument only
-- because both callers pin it themselves (auth.uid() in one case, NULL in
-- the other) — a directly-callable two-argument version would let any
-- authenticated caller pass an arbitrary (p_profile_id, p_viewer) pair and
-- probe covered-post visibility for combinations they have no business
-- constructing themselves.
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
    -- Fully qualified column references throughout (eb.badge_id, rarity.badge_id,
    -- sel.badge_id) for the same reason 2026-08-17_displayed_badges.sql's
    -- profile_badges gives: RETURNS TABLE (badge_id, earned_at) implicitly
    -- declares plpgsql OUT variables of those same names.
    SELECT u.displayed_badges INTO v_selection
    FROM public.users u
    WHERE u.id = p_profile_id;

    IF v_selection IS NULL THEN
        -- Default: rarest four first. Identical predicate, JOIN, and
        -- ORDER BY/LIMIT to 2026-08-17_displayed_badges.sql PART 2's own
        -- default branch — see that file for the full reasoning on rarity
        -- ranking and the tie-break chain. The covered-post gate sits in
        -- the SAME WHERE that feeds the ORDER BY/LIMIT below it, for the
        -- identical reason that file documents: filtering after the LIMIT
        -- instead of inside the candidate WHERE could let an invisible
        -- 'shared' row crowd out a visible badge that should have taken
        -- one of the four slots.
        RETURN QUERY
        SELECT eb.badge_id, eb.earned_at
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
        ORDER BY rarity.holder_count ASC, eb.earned_at ASC, eb.badge_id ASC
        LIMIT 4;
        RETURN;
    END IF;

    -- Explicit selection, possibly '{}' (show none). unnest(...) WITH
    -- ORDINALITY preserves the profile owner's own chosen order — see
    -- 2026-08-17_displayed_badges.sql PART 2 for why the JOIN back to
    -- earned_badges and the repeated covered-post gate are both still
    -- required here even though set_displayed_badges already validates
    -- ownership at write time.
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


-- ============================================================
-- PART 2: profile_badges(p_profile_id) — unchanged signature, return shape
-- (badge_id TEXT, earned_at TIMESTAMPTZ), _ratchet_badges call, and
-- owner-sees-all branch (still gated on covered-shared, still a no-op for
-- a self-view — see 2026-08-17_displayed_badges.sql PART 2 for why). The
-- ONLY change: the non-owner branch's body is replaced by a call into
-- PART 1's shared helper with p_viewer = auth.uid() — the real caller,
-- exactly the value the inlined query used before. Every behaviour is
-- preserved: same stored-selection-or-rarest-four resolution, same
-- ordering, same covered-post gate, same result for every input this
-- function has ever been asked before this migration ran.
-- ============================================================
CREATE OR REPLACE FUNCTION public.profile_badges(p_profile_id UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM public._ratchet_badges(p_profile_id);

    -- ------------------------------------------------------------
    -- The owner sees EVERYTHING they've earned (still covered-post gated on
    -- 'shared' — always a no-op for a self-view, see
    -- 2026-08-17_displayed_badges.sql PART 2 for the full proof). Hiding a
    -- badge is a statement about what OTHERS see; it must never also hide
    -- it from the person who earned it.
    -- ------------------------------------------------------------
    IF p_profile_id = auth.uid() THEN
        RETURN QUERY
        SELECT eb.badge_id, eb.earned_at
        FROM public.earned_badges eb
        WHERE eb.user_id = p_profile_id
          AND (
              eb.badge_id <> 'shared'
              OR public.covered_post_visible(auth.uid(), p_profile_id, eb.earned_at)
          )
        ORDER BY eb.earned_at ASC;
        RETURN;
    END IF;

    -- ------------------------------------------------------------
    -- Everyone else: delegate to the shared resolver (PART 1 above), viewed
    -- as the real caller (auth.uid()) — identical to what this branch
    -- computed inline before this migration.
    -- ------------------------------------------------------------
    RETURN QUERY
    SELECT r.badge_id, r.earned_at
    FROM public._resolve_effective_displayed_badges(p_profile_id, auth.uid()) r;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_badges(UUID) TO authenticated;


-- ============================================================
-- PART 3: public.own_effective_displayed_badges() — the new self-serve
-- read this migration exists to add.
--
-- Zero arguments, hard-pinned to auth.uid() — same non-negotiable rule
-- own_unseen_badges/unseen_badge_count/mark_own_badges_seen/refresh_own_
-- badges already establish (2026-08-17_earned_badges.sql PART 5,
-- 2026-08-17_five_more_badges.sql PART 4): a function answering "what does
-- MY OWN profile show" must resolve entirely from auth.uid(), never from
-- an argument, or a caller could probe another user's resolved list.
-- There is no p_profile_id parameter to spoof.
--
-- STABLE, not VOLATILE: this is a pure read, same posture as own_unseen_
-- badges and unseen_badge_count. It deliberately does NOT call
-- _ratchet_badges — profile_badges and refresh_own_badges already own
-- recording; this function only ever reads what's already in earned_
-- badges. A badge that hasn't been ratcheted in yet for the caller simply
-- won't appear here yet either, exactly as it wouldn't appear via
-- profile_badges called by someone else who also hasn't triggered the
-- ratchet — same staleness window that already exists everywhere else in
-- this feature, not a new one.
--
-- Calls PART 1's helper with p_profile_id = auth.uid() (whose profile) and
-- p_viewer = NULL (a stranger — see this file's header for exactly why
-- NULL, not auth.uid() again, is what makes this "what a stranger sees"
-- rather than "what I see of my own profile," which is always the full
-- unfiltered answer profile_badges' owner branch already gives).
--
-- WITH ORDINALITY on the function call, plus an explicit ORDER BY on that
-- ordinal, is what guarantees the returned badge_id order matches the
-- helper's own emission order byte-for-byte rather than relying on
-- Postgres not happening to reorder a plain function-scan pass-through —
-- the one thing this function's whole reason for existing depends on
-- being exactly right.
-- ============================================================
CREATE OR REPLACE FUNCTION public.own_effective_displayed_badges()
RETURNS TABLE (badge_id TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT r.badge_id
    FROM public._resolve_effective_displayed_badges(auth.uid(), NULL::uuid) WITH ORDINALITY
        AS r(badge_id, earned_at, ord)
    ORDER BY r.ord ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.own_effective_displayed_badges() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.own_effective_displayed_badges() FROM anon;
GRANT EXECUTE ON FUNCTION public.own_effective_displayed_badges() TO authenticated;


-- ---- How the app uses this --------------------------------------------------
--
-- profile_badges, set_displayed_badges, own_unseen_badges,
-- mark_own_badges_seen, refresh_own_badges, unseen_badge_count: ALL
-- UNCHANGED calls and return shapes — see 2026-08-17_earned_badges.sql,
-- 2026-08-17_five_more_badges.sql, and 2026-08-17_displayed_badges.sql's
-- own footers for the full list.
--
-- NEW — the caller's own resolved "what a stranger sees on my profile
-- right now" list, in display order, own profile only, no argument:
--   SELECT * FROM own_effective_displayed_badges();
-- Use this to answer "which four" once profile_badges/get_own_profile has
-- already told the caller a rarest-four default is in effect (i.e.
-- displayed_badges is NULL) or to show exactly what an explicit selection
-- resolves to (e.g. confirming a 'shared' badge is in the chosen list but
-- won't actually show while covered).
