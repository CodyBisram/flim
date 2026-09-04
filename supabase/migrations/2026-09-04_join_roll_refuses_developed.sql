-- ============================================================
-- Migration: join_roll refuses a roll that has already developed.
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run (CREATE OR REPLACE FUNCTION). Already mirrored
-- in schema.sql.
--
-- Context: join_roll (2026-07-?? original, most recently redefined in
-- schema.sql) only ever checked that the roll existed and the 50-member cap.
-- A code texted after the roll's reveal already happened still joined the
-- new member, and the client then shows an invite promising a reveal that
-- is already in the past and auto-plays it. The 2026-08-26 confirmations
-- redesign settled the product rule the other direction: invites end when a
-- roll develops. The client already hides the invite UI once a roll is
-- developed; this migration makes join_roll agree server-side so a code
-- shared/received late can't be used to slip in after the fact.
--
-- Placement of the new check matters: it runs BEFORE the already-member
-- lookup, not after, so a developed roll refuses EVERYONE it does not
-- already contain -- including a brand-new join attempt -- while an
-- existing member's repeat call is untouched (see below). It reuses
-- is_roll_developed(uuid), the same SECURITY DEFINER helper the photos
-- INSERT policy already calls, so the notion of "developed" cannot drift
-- between the invite gate and the upload gate.
--
-- Idempotent re-join is preserved on purpose: an existing member who calls
-- join_roll again (e.g. tapping a link they already used) still returns
-- the roll uneventfully. That path is a no-op read plus an
-- ON CONFLICT DO NOTHING insert; it never depended on the roll being
-- undeveloped and still doesn't. Only a genuinely NEW member is blocked
-- once the roll has developed.
--
-- Error convention matches the function's existing style exactly:
-- 'roll_not_found' (P0002) and 'roll_full' (P0001) are both plain
-- RAISE EXCEPTION with a bare message the client string-matches on. This
-- adds 'roll_developed' the same way, no custom ERRCODE, so
-- RollService.mapJoinRollError can add a case with no other changes.
-- Older, unmapped clients will surface the raw Postgres error text instead
-- of friendly copy; that gap is accepted and the Swift side is being
-- updated in parallel to close it.
-- ============================================================

CREATE OR REPLACE FUNCTION public.join_roll(p_code TEXT)
RETURNS public.rolls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r public.rolls;
    member_count INT;
    already_member BOOLEAN;
BEGIN
    SELECT * INTO r FROM public.rolls WHERE invite_code = UPPER(p_code) LIMIT 1;
    IF r.id IS NULL THEN
        RAISE EXCEPTION 'roll_not_found' USING ERRCODE = 'P0002';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.roll_members WHERE roll_id = r.id AND user_id = auth.uid()
    ) INTO already_member;

    -- Invites end when a roll develops (2026-08-26 confirmations redesign).
    -- Checked before the insert path below, and only enforced for a caller
    -- who is not already a member, so re-fetching a roll you already joined
    -- keeps working after it develops.
    IF NOT already_member AND public.is_roll_developed(r.id) THEN
        RAISE EXCEPTION 'roll_developed' USING ERRCODE = 'P0004';
    END IF;

    IF NOT already_member THEN
        SELECT COUNT(*) INTO member_count FROM public.roll_members WHERE roll_id = r.id;
        IF member_count >= 50 THEN
            RAISE EXCEPTION 'roll_full' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.roll_members (roll_id, user_id)
        VALUES (r.id, auth.uid())
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN r;
END;
$$;

-- Grants: explicit REVOKE-then-GRANT-to-authenticated, restated even though
-- the signature didn't change, same reasoning as every other fold in this
-- file -- CREATE OR REPLACE does not touch privileges, so they must be
-- reasserted whenever a function body is redefined outside schema.sql's own
-- single top-to-bottom run.
REVOKE ALL ON FUNCTION public.join_roll(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_roll(TEXT) TO authenticated;
