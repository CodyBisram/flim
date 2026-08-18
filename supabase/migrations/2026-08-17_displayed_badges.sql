-- ============================================================
-- Migration: let users choose which of their earned badges appear on their
-- profile, capped at four, ordered, defaulting to their rarest four when
-- nobody has chosen. Paste into Supabase Dashboard -> SQL Editor and run.
-- Safe to re-run.
--
-- ⚠️ ORDER: run AFTER supabase/migrations/2026-08-17_profile_identity.sql,
-- 2026-08-17_earned_badges.sql, AND 2026-08-17_five_more_badges.sql — ALL
-- THREE are already applied to production as of this file. This file's
-- CREATE OR REPLACE FUNCTION public.profile_badges is written directly on
-- top of five_more_badges.sql's version: it still calls that file's
-- public._ratchet_badges(p_user_id) to ratchet (never reproduces the
-- twelve predicates itself — that would create a second, driftable copy of
-- logic that already lives in one place), and it still applies that file's
-- covered-post gate on the 'shared' badge_id specifically, unconditionally,
-- in every branch below — see PART 2's own comment on why that gate has to
-- be evaluated before this file's own selection/default logic, not after.
-- Run this BEFORE pushing any Swift client that reads displayed_badges or
-- calls set_displayed_badges.
--
-- WHAT THIS ADDS, IN TWO PARTS
-- ------------------------------
--   1. users.displayed_badges — an ORDERED, nullable, capped-at-4 array of
--      badge ids the profile owner has chosen to lead with. NULL ("no
--      choice made") and '{}' ("chose to show nothing") are kept distinct
--      on purpose — see PART 1's own comment.
--   2. profile_badges(p_profile_id) changes ONLY what it returns to a
--      caller who is not p_profile_id itself — the owner still always sees
--      every earned badge (still gated by covered-post visibility on
--      'shared', exactly as five_more_badges.sql already has it — see PART
--      2 for why that gate is a no-op for a self-view regardless). A
--      non-owner caller now sees either the profile's stored selection (in
--      stored order) or, if nothing has been chosen, that profile's rarest
--      four badges (rarity = fewest distinct holders across earned_badges,
--      ascending; tied by the profile's own earned_at ascending, then
--      badge_id for full determinism) — both still subject to the same
--      covered-post gate on 'shared'. set_displayed_badges(TEXT[]) is the
--      new RPC that lets a signed-in user set their own selection,
--      zero-trust on input, validated against earned_badges directly so it
--      never needs to know the badge catalog.
--
-- WHY AN ARRAY IS SAFE HERE WITHOUT RECONCILIATION
-- ---------------------------------------------------
-- earned_badges is a ratchet (2026-08-17_earned_badges.sql PART 1/3): a row
-- once inserted is never deleted, and no predicate re-evaluation can ever
-- make an already-earned badge un-earned. That is exactly what makes
-- storing a plain array of chosen ids safe rather than requiring some
-- separate reconciliation step every time a badge's underlying data
-- changes — a badge_id present in displayed_badges today is GUARANTEED to
-- still be present in earned_badges tomorrow, forever, so there is no
-- "stale selection" case to detect or repair. set_displayed_badges (PART 3)
-- still checks ownership at write time regardless, both because zero-trust
-- input validation is cheap and because it is the thing that actually
-- proves the caller may show it, not merely that it will remain true later.
-- ============================================================


-- ============================================================
-- PART 1: users.displayed_badges — the stored selection.
-- ============================================================
--
-- NULL is the default for every existing and future row (no explicit
-- DEFAULT needed — that's what an added nullable column with no DEFAULT
-- clause already gives every existing row, and every future INSERT that
-- doesn't mention this column) and means "no choice made, fall back to the
-- rarest-four default computed in profile_badges (PART 2)." An EMPTY array
-- is a deliberately different, deliberately chosen state: "show none." Both
-- are legitimate, persisted states — see set_displayed_badges (PART 3) for
-- how a caller moves between all three states (NULL / '{}' / a real list).
--
-- The CHECK enforces the cap independently of set_displayed_badges, so the
-- 4-badge limit holds even against a future direct UPDATE that bypasses the
-- RPC entirely (e.g. from the SQL editor, or a rewritten RPC that forgets
-- its own check) — same "constraint as the real backstop, not just the
-- function's own early check" posture earned_badges_grantable_check already
-- uses for grant_badge. array_length(x, 1) returns NULL (not 0) for an
-- empty array in Postgres, which is why the empty-array case is wrapped in
-- COALESCE(..., 0) below rather than compared to array_length directly —
-- without it, a 5-element array with a NULL hazard aside, an explicit `= 4`
-- boundary check on a NULL comparison would silently pass (NULL <= 4 is
-- NULL, not true, but also not false — CHECK only fails on an explicit
-- FALSE, so an ungated NULL would let anything through). Duplicate ids and
-- unearned ids are NOT checked here — those require reading earned_badges,
-- which only set_displayed_badges (a function, not a constraint) can do
-- with the caller's own auth.uid() in scope; see PART 3.
-- ============================================================
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS displayed_badges TEXT[];

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_displayed_badges_check;
ALTER TABLE public.users ADD CONSTRAINT users_displayed_badges_check
    CHECK (displayed_badges IS NULL OR COALESCE(array_length(displayed_badges, 1), 0) <= 4);

-- Readable through the same path signup_ordinal uses for the CALLER'S OWN
-- row: get_own_profile() already does `SELECT * FROM public.users`, so this
-- column arrives there automatically, no edit needed. Deliberately NOT
-- added to public.profiles or to a column-level grant on users for OTHER
-- people's rows — a non-owner has no legitimate reason to read the raw
-- selection directly; profile_badges (PART 2) is the only sanctioned way
-- anyone else ever learns what it resolves to (including the NULL ->
-- rarest-four fallback, which a raw column read could never reproduce
-- correctly anyway).


-- ============================================================
-- PART 2: profile_badges(p_profile_id) — unchanged signature and return
-- shape (badge_id TEXT, earned_at TIMESTAMPTZ). Ratchets via
-- public._ratchet_badges(p_profile_id) (five_more_badges.sql PART 2) rather
-- than reproducing any predicate here — this file has no idea how many
-- badge ids exist and must not need to.
--
-- THE COVERED-POST GATE, AND WHY IT IS APPLIED BEFORE SELECTION/DEFAULT,
-- NOT AFTER
-- --------------------------------------------------------------------------
-- five_more_badges.sql's profile_badges filters out a 'shared' row the
-- caller isn't allowed to know about with:
--     eb.badge_id <> 'shared' OR public.covered_post_visible(auth.uid(), p_profile_id, eb.earned_at)
-- That expression is repeated as-is in EVERY branch below (owner, default,
-- explicit selection) — never dropped, never applied only "after" some
-- other filter runs. Concretely, it is written inside the WHERE clause of
-- each branch's own SELECT, which means it is evaluated, and can remove a
-- 'shared' row, BEFORE that branch's ORDER BY/LIMIT ever runs. This
-- ordering is load-bearing for the default (rarest-four) branch
-- specifically: if the gate ran AFTER the LIMIT 4 instead of inside the
-- WHERE that produces the candidate rows, an outsider who cannot see a
-- covered 'shared' badge could still have it silently occupy one of the
-- four slots (crowding out a badge they COULD have seen) instead of the
-- next-rarest visible badge taking that slot. Filtering first, inside the
-- same WHERE the rarity ranking reads from, is what makes "not visible" and
-- "doesn't count toward the four" the same guarantee.
--
-- It is also applied, unconditionally, in the owner branch — not because it
-- ever removes anything there (see below), but because leaving it out of
-- that one branch as a "safe to skip, they're the owner" shortcut is
-- exactly the kind of asymmetry a later edit could get wrong. It provably
-- never changes the owner's own result: public.covered_post_visible(v, a, t)
-- is TRUE whenever v = a, for either reason the function checks —
-- NOT post_is_covered(...) is TRUE when this account was never one of the
-- three covered accounts in the first place, and if it WAS, the EXISTS
-- against covered_post_windows matches on w.user_id = p_viewer = p_profile_id
-- directly. Either way, a covered account's own 'shared' badge is always
-- visible to itself. Keeping the same expression in all three branches
-- means that guarantee is proven by the code being identical, not by three
-- separately-reasoned-about copies staying in sync by hand.
-- ============================================================
CREATE OR REPLACE FUNCTION public.profile_badges(p_profile_id UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_selection TEXT[];
BEGIN
    -- RETURNS TABLE (badge_id, earned_at) implicitly declares plpgsql OUT variables
    -- named badge_id and earned_at, which collide with earned_badges' own columns of
    -- the same names (this bit both earned_badges.sql's original ratchet and this
    -- file's first draft, caught in Docker verification — see the completion report).
    -- Rather than lean on the #variable_conflict pragma, every column reference below
    -- is written fully qualified (eb.badge_id, rarity.badge_id, sel.badge_id, and the
    -- rarity subquery's own eb2.badge_id) so there is never a bare `badge_id` for
    -- Postgres to have to disambiguate in the first place.
    PERFORM public._ratchet_badges(p_profile_id);

    -- ------------------------------------------------------------
    -- The owner sees EVERYTHING they've earned (still covered-post gated on
    -- 'shared', see header — always a no-op for a self-view). Hiding a
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
    -- Everyone else: the profile's own stored choice, or the rarest-four
    -- default when nothing has been chosen. NULL vs '{}' is read here, not
    -- collapsed — see PART 1's comment for why they're kept distinct.
    -- ------------------------------------------------------------
    SELECT u.displayed_badges INTO v_selection
    FROM public.users u
    WHERE u.id = p_profile_id;

    IF v_selection IS NULL THEN
        -- Default: rarest four first. Rarity = COUNT(DISTINCT user_id) per
        -- badge_id across the WHOLE earned_badges ledger (every profile,
        -- not just this one) — ascending, so the badge fewer people hold
        -- sorts first. Tie-break by this profile's own earned_at ascending
        -- (the task's own tie-break), then badge_id ascending as a final,
        -- purely mechanical tiebreak so the result is fully deterministic
        -- even in the vanishingly unlikely case of an exact earned_at tie
        -- too — nothing here should ever depend on scan order. The
        -- covered-post clause sits in the SAME WHERE that feeds the
        -- ORDER BY/LIMIT below it — see header for why that ordering matters.
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
              OR public.covered_post_visible(auth.uid(), p_profile_id, eb.earned_at)
          )
        ORDER BY rarity.holder_count ASC, eb.earned_at ASC, eb.badge_id ASC
        LIMIT 4;
        RETURN;
    END IF;

    -- Explicit selection, possibly '{}' (show none). unnest(...) WITH
    -- ORDINALITY is what preserves the caller's OWN chosen order — a plain
    -- JOIN has no inherent order to fall back on, and this is an ORDERED
    -- list by design (task brief: "people will want to lead with their
    -- rarest"). The JOIN back to earned_badges (rather than trusting the
    -- array's contents outright) is defensive, not load-bearing for
    -- OWNERSHIP today: set_displayed_badges (PART 3) already refuses to
    -- store an id the caller doesn't hold, and badges never un-earn, so
    -- every id in a validly-written array is guaranteed to still match a
    -- row here. It IS load-bearing for the covered-post gate, though — this
    -- is the one branch where a caller's own explicit choice could
    -- otherwise smuggle a 'shared' row past an outsider (see header,
    -- "the case where a careless rewrite leaks"), which is exactly why the
    -- same WHERE clause is repeated here too rather than assumed safe
    -- because "the array only ever contains ids they're allowed to show."
    -- Being ALLOWED to show it (ownership) and being visible to THIS
    -- particular viewer (covered-post state) are two different questions,
    -- and only the second one can change per-viewer, per-call.
    RETURN QUERY
    SELECT eb.badge_id, eb.earned_at
    FROM unnest(v_selection) WITH ORDINALITY AS sel(badge_id, ord)
    JOIN public.earned_badges eb
        ON eb.user_id = p_profile_id AND eb.badge_id = sel.badge_id
    WHERE eb.badge_id <> 'shared'
       OR public.covered_post_visible(auth.uid(), p_profile_id, eb.earned_at)
    ORDER BY sel.ord ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_badges(UUID) TO authenticated;

-- Supports the rarity subquery's GROUP BY badge_id above. earned_badges'
-- own PRIMARY KEY (user_id, badge_id) leads with user_id, so it does not
-- serve a "group by badge_id" scan — this is a genuinely new hot path
-- (profile_badges now runs it on every non-owner profile view with no
-- selection set, which is every profile until someone opens the picker).
CREATE INDEX IF NOT EXISTS earned_badges_badge_id_idx
    ON public.earned_badges (badge_id);


-- ============================================================
-- PART 3: set_displayed_badges(p_badge_ids TEXT[]) — the only write path
-- for a user's own selection.
--
-- Zero-trust on input, same posture as redeem_invite/join_roll elsewhere in
-- this schema:
--   * pinned to auth.uid() — no p_user_id argument exists, so there is no
--     argument to spoof; a caller can only ever write their own row.
--   * NULL is accepted and means "clear the selection, revert to the
--     rarest-four default" — handled as its own early branch so it never
--     has to pass through the length/duplicate/ownership checks below,
--     which are meaningless for "no selection."
--   * an EMPTY array ('{}') is accepted and means "show none" — a
--     deliberately different, deliberately stored state from NULL. It
--     falls through the normal validation path below rather than an early
--     return: every check on an empty array is vacuously satisfied (0 <= 4,
--     0 distinct ids, 0 ids to prove ownership of), so it reaches the final
--     UPDATE and is stored as '{}', not coerced to NULL.
--   * more than 4 ids: rejected.
--   * a NULL element inside a non-NULL array: rejected outright, before the
--     length/duplicate/ownership checks even run — an ARRAY[..., NULL, ...]
--     would otherwise make `badge_id = ANY(p_badge_ids)` evaluate to NULL
--     (not FALSE) for any id that doesn't match a real element, which could
--     silently mis-count the ownership check below rather than cleanly
--     fail it.
--   * duplicate ids: rejected.
--   * an id the caller does not actually hold in earned_badges: rejected.
--     Deliberately validated against earned_badges, NOT against any badge
--     catalog or the CHECK constraint on the table (which enforces length
--     only) — ownership is the stricter test (an unheld id is always also
--     an invalid one, but a held id might belong to a catalog this file
--     knows nothing about), and it is the one test that lets this migration
--     stay completely ignorant of which badge ids exist at all. See this
--     file's header for why that matters right now.
--   * the caller's own given order is preserved exactly as provided — this
--     function does not sort, dedupe, or reorder anything it accepts.
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_displayed_badges(p_badge_ids TEXT[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_len   INT;
    v_distinct_count INT;
    v_held_count     INT;
BEGIN
    IF p_badge_ids IS NULL THEN
        UPDATE public.users SET displayed_badges = NULL WHERE id = auth.uid();
        RETURN;
    END IF;

    IF array_position(p_badge_ids, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'displayed_badges: badge id cannot be null';
    END IF;

    -- array_length(x, 1) is NULL (not 0) for an empty array — COALESCE
    -- keeps the cap check meaningful for '{}' instead of comparing NULL <= 4.
    v_len := COALESCE(array_length(p_badge_ids, 1), 0);

    IF v_len > 4 THEN
        RAISE EXCEPTION 'displayed_badges: at most 4 badges, got %', v_len;
    END IF;

    SELECT COUNT(DISTINCT x) INTO v_distinct_count FROM unnest(p_badge_ids) AS x;
    IF v_distinct_count <> v_len THEN
        RAISE EXCEPTION 'displayed_badges: duplicate badge id';
    END IF;

    SELECT COUNT(*) INTO v_held_count
    FROM public.earned_badges eb
    WHERE eb.user_id = auth.uid() AND eb.badge_id = ANY(p_badge_ids);
    IF v_held_count <> v_len THEN
        RAISE EXCEPTION 'displayed_badges: caller has not earned every selected badge';
    END IF;

    UPDATE public.users SET displayed_badges = p_badge_ids WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public.set_displayed_badges(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_displayed_badges(TEXT[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_displayed_badges(TEXT[]) TO authenticated;


-- ---- How the app uses this --------------------------------------------------
--
-- Unchanged call, unchanged return shape (badge_id TEXT, earned_at
-- TIMESTAMPTZ). About your own profile: every earned badge, unfiltered.
-- About anyone else: their chosen selection in their chosen order, or their
-- rarest four if they've never chosen:
--   SELECT * FROM profile_badges('<uuid>');
--
-- Own current raw selection (NULL / '{}' / a list), for pre-populating the
-- picker — arrives automatically via the existing call:
--   SELECT displayed_badges FROM get_own_profile();
--
-- Set/replace/clear the caller's own selection (authenticated only, own row
-- only):
--   SELECT set_displayed_badges(ARRAY['darkroom','first_in']);  -- choose
--   SELECT set_displayed_badges('{}');                          -- show none
--   SELECT set_displayed_badges(NULL);                          -- revert to default
