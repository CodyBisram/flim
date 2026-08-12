-- ============================================================
-- Comment-like push notifications: schema for public.comment_likes.
-- Paste into Supabase Dashboard -> SQL Editor and run ONCE, before deploying
-- the updated send-social-push Edge Function.
--
-- public.comment_likes predates this feature (schema.sql, "Likes on comments").
-- It ships with a composite primary key (comment_id, user_id) and no id or
-- push_sent column, unlike every other table send-social-push polls.
--
-- Two additions, both idempotent (IF NOT EXISTS) and safe to re-run:
--
--   1. id UUID NOT NULL DEFAULT gen_random_uuid()
--      A surrogate id, added ALONGSIDE the existing composite primary key,
--      which is UNCHANGED and still (comment_id, user_id). Every other
--      push_sent table here (post_comments, post_reactions, photo_comments,
--      photo_reactions) is marked done with a single `.in("id", ids)` after a
--      batch send; comment_likes has no such column to key on, which would
--      force send-social-push to update one row at a time by
--      (comment_id, user_id) pairs instead (the same shape `follows` already
--      needs, since it also has no surrogate id). For a table that groups
--      MULTIPLE likes per comment into one push, batching the mark-done step
--      with the other push_sent tables' shape is simpler and cheaper than a
--      per-row round trip for every like in the group. gen_random_uuid() as
--      the default is volatile, so this ALTER TABLE assigns a genuinely
--      distinct id to every existing row (not one shared value), the same way
--      gen_random_uuid() already behaves as the id default on every other
--      table in this file.
--   2. push_sent BOOLEAN NOT NULL DEFAULT FALSE
--      Same poll + push_sent-flag pattern as every other table
--      send-social-push scans.
--
-- Both are mirrored into supabase/schema.sql (the canonical, idempotent
-- source of truth) so a from-scratch schema.sql apply produces the same
-- shape. schema.sql intentionally does NOT carry the backfill below, for the
-- same reason the follows/photo_reactions backfills were split into their own
-- one-time files: push_sent = FALSE is the normal, recurring, correct state
-- for a comment like that is currently mid-flight to the every-1-minute
-- send-social-push poll, not a one-time migration artifact, and schema.sql is
-- re-run in production as the standing workflow here.
--
-- CRITICAL, read before running: comment_likes has real rows dating back
-- months, from before this feature existed. Without the backfill below, the
-- column would be added with every existing like defaulting to
-- push_sent = FALSE, and the very next scheduled run of send-social-push
-- would read every historical comment like on the table as "new" and fire a
-- real push, to a real person, for a like that happened weeks or months ago.
-- This project has already shipped one notification that pointed at
-- something the app could not show; this migration exists specifically so
-- that mistake is not repeated for comment likes. The UPDATE below runs in
-- the SAME script as the ALTER TABLE, before send-social-push is ever
-- redeployed against this column, so there is no gap where a poll could see
-- push_sent = FALSE on a historical row.
--
-- Idempotency: the two ALTER TABLEs and both CREATE INDEXes are IF NOT EXISTS
-- and re-run cleanly. The backfill is the one statement that is NOT purely
-- idempotent, on purpose. See the note above it for the reasoning: it marks
-- everything that exists at run time, so it stays correct however long after
-- authoring you run it, at the cost of a re-run suppressing up to one poll
-- cycle of pending pushes. Run it once.
--
-- ORDER MATTERS: run this BEFORE deploying the updated send-social-push
-- function (the one with the new "Comment likes" section), or the poll could
-- fire on historical rows in the gap between the two steps.
-- ============================================================

ALTER TABLE public.comment_likes ADD COLUMN IF NOT EXISTS id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.comment_likes ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- Uniqueness on the surrogate id, so `.in("id", ids)` from the Edge Function can never
-- collide across rows. A unique INDEX (not a table constraint) so this stays
-- expressible with IF NOT EXISTS and is safe to re-run.
CREATE UNIQUE INDEX IF NOT EXISTS comment_likes_id_idx ON public.comment_likes (id);

-- The same partial index every push_sent table in this file has: the scan send-social-push
-- runs every sixty seconds wants only the (normally near-zero) unsent rows, not a sequential
-- scan of the whole table.
CREATE INDEX IF NOT EXISTS comment_likes_unpushed_idx ON public.comment_likes (push_sent) WHERE push_sent = FALSE;

-- CRITICAL backfill: every comment like that exists WHEN THIS RUNS is marked as already
-- notified, so the first send-social-push poll after deploy does not blast a push for the
-- entire historical table at once. See the CRITICAL note above for why this matters.
--
-- Deliberately NOT filtered by a fixed created_at cutoff. A cutoff dated when this file was
-- written is only correct if the file is run the same day, and deploys here are manual and
-- have sat for days before. Run this a week late with a cutoff and every like made in that
-- week is still FALSE, so they all fire at once: exactly the blast this backfill exists to
-- prevent, just delayed. "Everything that exists right now" is correct whenever it runs.
--
-- The tradeoff is re-running. A second run would also flip any genuinely new like that had
-- not been pushed yet, suppressing its notification. That window is at most one poll cycle,
-- about sixty seconds of likes, and a handful of missed pushes is a far smaller harm than a
-- mass send to real people. Run it once; if you do run it twice, this is what you lose.
UPDATE public.comment_likes
SET push_sent = TRUE
WHERE push_sent = FALSE;

-- Verify after running: this should return 0.
--   SELECT COUNT(*) FROM public.comment_likes WHERE push_sent = FALSE;
-- (A small non-zero count is expected only if someone liked a comment in the seconds between
-- the backfill and this query. Those rows are correct to still be FALSE: they are new likes
-- and should push. A LARGE count means the backfill did not run, so stop and check before
-- deploying the function.)
