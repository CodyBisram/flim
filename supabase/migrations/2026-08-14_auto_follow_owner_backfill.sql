-- ============================================================
-- One-time backfill: every existing account follows the owner
-- Paste into Supabase Dashboard -> SQL Editor and run ONCE, after schema.sql
-- has added public.auto_follow_owner() / auto_follow_owner_trigger and the
-- follows.push_sent column (all already in schema.sql).
--
-- Run this AFTER schema.sql, and only the first time this feature is
-- deployed. It is deliberately NOT mirrored into schema.sql, the way
-- 2026-08-05_follow_push_backfill.sql and 2026-07-31_photo_reactions_push_backfill.sql
-- also aren't: schema.sql is re-run in production as the standing workflow, and
-- "make everyone follow the owner" re-running on every unrelated future
-- schema.sql change would silently re-subscribe anyone who deliberately
-- unfollowed the owner afterward. That has to be a one-time act, not a
-- standing rule the file re-asserts forever.
--
-- What it does: every user who is not the owner, does not already follow
-- the owner, and has no block with the owner in either direction (so this
-- can never resurrect a relationship someone deliberately severed) gets a
-- new follows row. The trigger added alongside this (public.auto_follow_owner,
-- in schema.sql) only covers NEW signups going forward; this file is what
-- covers everyone who already existed when the feature shipped.
--
-- push_sent is set TRUE at INSERT time (not left at the FALSE default): a
-- single backfill can create one row per existing account all at once, and
-- without this, send-social-push's every-minute poll would fire a "started
-- following you" push at the owner once per row within the next minute — a
-- burst notification for something he asked for himself, not organic
-- activity. Contrast with the auto_follow_owner TRIGGER (schema.sql), whose
-- rows are deliberately left push_sent = FALSE: those happen one at a time,
-- at signup volume, and read the same as a real user tapping Follow.
--
-- created_at is set to a fixed, hardcoded sentinel instant rather than the
-- column's own now() default, on purpose: it makes every row this backfill
-- creates permanently and unambiguously identifiable later (see the DELETE
-- at the bottom of this file), with no risk of an organic follow of the
-- owner ever coincidentally sharing that exact literal timestamp.
--
-- Idempotent: the NOT EXISTS guard means a second run finds nothing left to
-- insert (every row it would have created already exists), and
-- ON CONFLICT DO NOTHING is a second safety net under that.
-- ============================================================

INSERT INTO public.follows (follower_id, following_id, push_sent, created_at)
SELECT
    u.id,
    o.id,
    TRUE,
    TIMESTAMPTZ '2026-08-14 00:00:00+00'
FROM public.users u
CROSS JOIN (
    SELECT id
    FROM public.users
    WHERE lower(email) = lower('codyysb@gmail.com')
    LIMIT 1
) o
WHERE u.id <> o.id
  AND NOT public.is_blocked_either_way(u.id, o.id)
  AND NOT EXISTS (
      SELECT 1 FROM public.follows f
      WHERE f.follower_id = u.id AND f.following_id = o.id
  )
ON CONFLICT (follower_id, following_id) DO NOTHING;

-- If the owner's row does not exist yet in this environment, the CROSS JOIN
-- subquery returns zero rows and this INSERT ... SELECT silently affects
-- nothing. Re-run it after the owner has an account.

-- Verify after running:
--
--   -- how many were just backfilled
--   SELECT count(*) FROM public.follows
--   WHERE created_at = TIMESTAMPTZ '2026-08-14 00:00:00+00';
--
--   -- none of them should still be waiting on a push
--   SELECT count(*) FROM public.follows
--   WHERE created_at = TIMESTAMPTZ '2026-08-14 00:00:00+00' AND push_sent = FALSE;
--   -- expect 0
--
-- To undo just the backfill (pair with dropping the trigger in schema.sql,
-- see the "To undo" note next to auto_follow_owner_trigger there — together
-- these are the two statements that fully reverse this change):
--
--   DELETE FROM public.follows
--   WHERE created_at = TIMESTAMPTZ '2026-08-14 00:00:00+00'
--     AND following_id = (
--         SELECT id FROM public.users WHERE lower(email) = lower('codyysb@gmail.com')
--     );
