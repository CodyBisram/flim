-- ============================================================
-- Migration: undo the earn-back BACKFILL, keep the mechanism.
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run (see section 1's guard).
--
-- Context: 2026-08-29_invite_earnback.sql shipped with its optional backfill
-- section left in, and it ran. Measured immediately after, against production:
-- 29 ledger rows, every one of them backfilled (credited_at holds the
-- invitee's real first-photo taken_at, ranging 2026-07-25 to 2026-08-26), and
-- ZERO rows credited by the live trigger yet. Four accounts gained invites:
-- tristan +5, ricky +3, alyssa +1, sabs +1. The owner's 19 ledger rows
-- correctly produced no numeric change, because their allowance is NULL and
-- the backfill's UPDATE is guarded by invite_uses_remaining IS NOT NULL.
--
-- The owner then chose to start clean: no retroactive credits, only activity
-- from here earns an invite back.
--
-- ============================================================
-- WHAT "CLEAN" MEANS HERE, AND THE TRAP IT AVOIDS
-- ============================================================
--
-- The obvious reading is "delete the 29 ledger rows and take the 10 invites
-- back". DO NOT DO THAT. The ledger row is what tells the trigger an invitee
-- has already been accounted for. Delete it and the next photo that invitee
-- takes finds no row, so the trigger credits their inviter then. That is not
-- a clean slate, it is the SAME retroactive credit arriving later and at
-- random, spread over whenever twenty-nine people next open the camera.
--
-- So this migration removes the invites and KEEPS the ledger. Those 29
-- activations stay marked as decided, and are never credited. Only invitees
-- who activate from now on earn anything.
--
-- The ledger row therefore means "we have already made a decision about this
-- invitee", not "this invitee paid out". That is what it has to mean for
-- exactly-once to hold, and it is why credited_at is left pointing at the
-- real historical instant rather than being rewritten.
--
-- ============================================================
-- WHY THIS IS COMPUTED, NOT A LIST OF FOUR NUMBERS
-- ============================================================
--
-- Subtracting a hardcoded 5/3/1/1 would be wrong the moment anyone spends or
-- earns an invite between the measurement above and this file being run. The
-- UPDATE below derives each inviter's delta from the ledger itself, so it
-- stays correct however the numbers have moved.
--
-- The cutoff is what keeps it honest. Backfilled rows carry a historical
-- credited_at (newest 2026-08-26); anything the LIVE trigger credits carries
-- now(). Scoping to rows before the migration date reverses only what the
-- backfill did, and can never claw back an invite somebody genuinely earned
-- by bringing someone in who then shot a photo.
--
-- GREATEST(0, ...) because the column has a >= 0 CHECK: if one of these four
-- has spent invites since the backfill, their current value already nets both
-- effects and a blind subtraction could go negative.
--
-- IS NOT NULL for the same reason the backfill had it, in the opposite
-- direction: an unlimited account was never credited, so it must not be
-- decremented into a finite number here.
-- ============================================================

-- 1. Take back exactly what the backfill gave, from whoever still has it.
--
--    The `changed` marker column makes this idempotent: after this runs once,
--    invite_earnback_reversed is TRUE for those rows and they are excluded
--    from the delta on any re-run, so running this file twice cannot charge
--    anybody twice.
ALTER TABLE public.invite_earnbacks
    ADD COLUMN IF NOT EXISTS reversed BOOLEAN NOT NULL DEFAULT FALSE;

WITH backfilled AS (
    SELECT inviter_id, COUNT(*) AS n
    FROM public.invite_earnbacks
    WHERE credited_at < TIMESTAMPTZ '2026-08-29 00:00:00+00'
      AND reversed IS FALSE
    GROUP BY inviter_id
)
UPDATE public.users u
SET invite_uses_remaining = GREATEST(0, u.invite_uses_remaining - backfilled.n)
FROM backfilled
WHERE u.id = backfilled.inviter_id
  AND u.invite_uses_remaining IS NOT NULL;

UPDATE public.invite_earnbacks
SET reversed = TRUE
WHERE credited_at < TIMESTAMPTZ '2026-08-29 00:00:00+00'
  AND reversed IS FALSE;

-- ---- Verify -----------------------------------------------------------------
--
--   -- Expect 50 rows at 3 and one NULL (signup_ordinal 1). Nobody above 3.
--   SELECT invite_uses_remaining, COUNT(*) FROM public.users GROUP BY 1 ORDER BY 1 NULLS FIRST;
--
--   -- Expect 29, all reversed. The ledger is intact, which is the point:
--   -- these invitees can never be credited again.
--   SELECT reversed, COUNT(*) FROM public.invite_earnbacks GROUP BY 1;
--
--   -- Expect zero. The CHECK would have rejected it, but confirm anyway.
--   SELECT COUNT(*) FROM public.users WHERE invite_uses_remaining < 0;
--
--   -- The mechanism is still armed: this must still exist.
--   SELECT tgname FROM pg_trigger WHERE tgname = 'credit_invite_earnback_trigger';
