-- ============================================================
-- Migration: retire test_roll into founding_crew, and put the two
-- hand-granted badges ahead of founding_100 in the automatic default.
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER supabase/migrations/2026-08-18_nine_more_badges.sql.
-- That file's PART 0 rewrites earned_badges_badge_id_check to a list that
-- still contains 'test_roll', and its PART 3 installs a slot_rank that only
-- knows about founding_100. Running this file second replaces both. If the
-- two are run in the wrong order, re-run THIS file — it is idempotent and
-- reads the CURRENT constraint rather than assuming which list is live, so
-- a second pass repairs the ordering with no data effect.
--
-- WHY test_roll GOES AWAY
-- ------------------------
-- "Tester" and "Founding Crew" were the same honour told twice. Being here
-- while FLIM was still being tested IS being part of the crew that got it
-- off the ground, and splitting that across two gold pills spent two of a
-- profile's four slots saying one thing. Measured before this ran:
-- test_roll had 6 holders, founding_crew had 0 — the thinner of the two
-- names had taken the whole population and the better one had never been
-- granted at all.
--
-- Nobody loses a stamp. Every test_roll holder gets founding_crew carrying
-- their ORIGINAL earned_at and granted_by, not now() and not this
-- migration's author — the ledger's whole promise is that a date on a
-- profile is the date the thing actually happened. Anyone who somehow held
-- both keeps the earlier of the two dates.
--
-- WHY founder AND founding_crew OUTRANK founding_100
-- ---------------------------------------------------
-- 2026-08-18_nine_more_badges.sql pinned founding_100 to slot 1 on the
-- reasoning that it is the one thing that could never happen again. True,
-- but it is also currently held by all 48 accounts, so as a lead badge it
-- says nothing about the specific person whose profile you are reading. The
-- two hand-granted badges are the opposite: they exist precisely because
-- someone decided this particular account mattered. So the pin becomes a
-- three-step ladder — founder, then founding_crew, then founding_100 —
-- ahead of the rarity sort that fills the remaining slots.
--
-- This changes the DEFAULT only. An explicit selection is still returned
-- exactly as chosen, in the chosen order, unchanged from
-- 2026-08-17_own_effective_displayed_badges.sql onward.
-- ============================================================


-- ============================================================
-- PART 1: migrate the holders, then drop the rows.
-- Runs BEFORE the constraint is narrowed, so the old rows are still legal
-- while being read.
-- ============================================================

-- Every test_roll holder gains founding_crew at their original timestamp.
-- ON CONFLICT DO NOTHING covers anyone already holding both; LEAST() is not
-- needed there because the conflicting row is simply kept as-is, and the
-- UPDATE below is what pulls an existing row back to the earlier date.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, granted_by, seen_at)
SELECT eb.user_id, 'founding_crew', eb.earned_at, eb.granted_by, eb.seen_at
FROM public.earned_badges eb
WHERE eb.badge_id = 'test_roll'
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- If someone held both already, keep the EARLIER date: the honour started
-- whenever the first of the two was granted.
UPDATE public.earned_badges fc
SET earned_at = tr.earned_at
FROM public.earned_badges tr
WHERE fc.user_id = tr.user_id
  AND fc.badge_id = 'founding_crew'
  AND tr.badge_id = 'test_roll'
  AND tr.earned_at < fc.earned_at;

DELETE FROM public.earned_badges WHERE badge_id = 'test_roll';

-- Strip 'test_roll' out of any explicit display selection. Without this a
-- selection array keeps a dangling id: harmless at read time (the resolver
-- INNER JOINs earned_badges, so it silently yields nothing) but it would
-- cost that account a visible slot for a badge that no longer exists.
-- array_remove on a NULL selection returns NULL, so the "automatic" state
-- is preserved rather than being turned into an empty explicit choice.
UPDATE public.users
SET displayed_badges = array_remove(displayed_badges, 'test_roll')
WHERE displayed_badges IS NOT NULL
  AND 'test_roll' = ANY(displayed_badges);


-- ============================================================
-- PART 2: narrow both CHECK constraints.
-- Rebuilt from the CURRENT constraint minus 'test_roll' rather than from a
-- hardcoded list, so this produces the right result whether or not
-- 2026-08-18_nine_more_badges.sql has been applied yet.
-- ============================================================
DO $$
DECLARE
    v_ids TEXT;
BEGIN
    -- Pull the id list out of whatever earned_badges_badge_id_check currently
    -- says, drop 'test_roll', and rebuild. If the constraint is missing
    -- entirely (fresh database, migrations run out of order), fall back to the
    -- full post-nine_more catalog.
    SELECT string_agg(quote_literal(id), ', ' ORDER BY id)
    INTO v_ids
    FROM (
        SELECT unnest(regexp_split_to_array(
                   substring(pg_get_constraintdef(oid) FROM 'ARRAY\[(.*)\]'),
                   '\s*,\s*')) AS raw
        FROM pg_constraint
        WHERE conname = 'earned_badges_badge_id_check'
    ) parts
    CROSS JOIN LATERAL (SELECT trim(both '''' from split_part(parts.raw, '::', 1)) AS id) x
    WHERE x.id <> 'test_roll';

    IF v_ids IS NULL THEN
        v_ids := '''first_light'', ''full_roll'', ''darkroom'', ''founding_100'', '
              || '''first_in'', ''roll_maker'', ''brought_someone'', ''founding_crew'', '
              || '''joined_in'', ''chipped_in'', ''shared'', ''well_met'', ''full_house'', '
              || '''front_row'', ''packed_house'', ''patron'', ''cover_to_cover'', '
              || '''kept_one'', ''regular'', ''one_year'', ''full_set'', ''founder''';
    END IF;

    EXECUTE 'ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_badge_id_check';
    EXECUTE 'ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (' || v_ids || '))';
END $$;

-- The grantable allow-list, now two ids. This is the table-level guarantee
-- that grant_badge can never mint an automatic badge, so it is narrowed in
-- lockstep with the function below rather than trusting the function alone.
ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_grantable_check;
ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_grantable_check CHECK (
    granted_by IS NULL OR badge_id IN ('founding_crew', 'founder')
);


-- ============================================================
-- PART 3: grant_badge — same body, one id shorter.
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

    IF p_badge_id NOT IN ('founding_crew', 'founder') THEN
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

-- revoke_badge needs no edit: it already deletes any row with granted_by IS
-- NOT NULL regardless of badge_id, so it covers both remaining grantables.


-- ============================================================
-- PART 4: _resolve_effective_displayed_badges — the pin becomes a ladder.
-- Signature, STABLE/SECURITY DEFINER, internal-only REVOKEs, the covered-post
-- gate, and the explicit-selection branch are all UNCHANGED. The only change
-- is slot_rank: 0/1/2 for founder/founding_crew/founding_100, 3 for the rest,
-- still sorted ahead of the untouched holder_count/earned_at/badge_id chain.
--
-- When none of the three is held, every row gets slot_rank 3 and the ORDER BY
-- reduces to exactly the original rarity sort, so this stays a superset of the
-- previous behaviour rather than a divergent rewrite — same property
-- 2026-08-18_nine_more_badges.sql's own header claims for the founding_100 pin.
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
        RETURN QUERY
        SELECT c.badge_id, c.earned_at
        FROM (
            SELECT eb.badge_id, eb.earned_at,
                   CASE eb.badge_id
                       WHEN 'founder'       THEN 0
                       WHEN 'founding_crew' THEN 1
                       WHEN 'founding_100'  THEN 2
                       ELSE 3
                   END AS slot_rank,
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

    -- Explicit selection, possibly '{}'. Never reordered.
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
-- PART 5: _ratchet_badges — no edit needed, and here is why.
-- No predicate in it ever mentioned test_roll (it was hand-granted only, so
-- it never had one), and nothing in it references founding_crew either. The
-- function is left exactly as 2026-08-18_nine_more_badges.sql leaves it.
-- ============================================================


-- ---- Verify -----------------------------------------------------------------
--
--   -- Should be 0.
--   SELECT COUNT(*) FROM public.earned_badges WHERE badge_id = 'test_roll';
--
--   -- Should be 6, all with granted_by set and their ORIGINAL dates.
--   SELECT COUNT(*) AS holders, MIN(earned_at) AS earliest
--   FROM public.earned_badges WHERE badge_id = 'founding_crew';
--
--   -- Should not contain test_roll.
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname = 'earned_badges_badge_id_check';
--
--   -- Should raise 'badge test_roll is not grantable'.
--   SELECT grant_badge('<uuid>', 'test_roll');
--
--   -- A founding_crew holder should now lead with it, not founding_100.
--   SELECT * FROM public.profile_badges('<uuid of a former tester>');
