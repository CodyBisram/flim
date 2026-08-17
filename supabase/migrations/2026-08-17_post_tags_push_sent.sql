-- ============================================================
-- Tag-added-after-publishing push notifications: schema for public.post_tags.
-- Paste into Supabase Dashboard -> SQL Editor and run ONCE, before deploying
-- the updated send-social-push Edge Function.
--
-- Bug this closes: FeedService.setTags (Flim/Services/FeedService.swift) lets
-- a post's owner add tags at any time via "Edit tags", not just at share
-- time. send-social-push's existing "New posts" block only announces tags on
-- posts where posts.push_sent = FALSE; once a post's own push_sent flips
-- TRUE, any tag added to it afterward was silently never announced. The row
-- saved, the UI reported success, and the tagged person was never told.
--
-- public.post_tags predates this feature (schema.sql, "POST TAGS"). Unlike
-- comment_likes (2026-08-12_comment_likes_push_sent.sql), it already has a
-- real, non-composite `id UUID PRIMARY KEY`, so this migration only needs to
-- add push_sent, no surrogate id column.
--
-- One addition, idempotent (IF NOT EXISTS) and safe to re-run:
--
--   push_sent BOOLEAN NOT NULL DEFAULT FALSE
--   Same poll + push_sent-flag pattern as every other table send-social-push
--   scans. Also mirrored into supabase/schema.sql (the canonical, idempotent
--   source of truth) so a from-scratch schema.sql apply produces the same
--   shape. schema.sql intentionally does NOT carry the backfill below, for
--   the same reason the comment_likes/follows/photo_reactions backfills were
--   split into their own one-time files: push_sent = FALSE is the normal,
--   recurring, correct state for a tag that is currently mid-flight to the
--   every-1-minute send-social-push poll, not a one-time migration artifact,
--   and schema.sql is re-run in production as the standing workflow here.
--
-- CRITICAL, read before running: post_tags has real rows dating back months,
-- from every post ever shared with a tagged person, not just tags added after
-- the fact. Without the backfill below, the column would be added with every
-- existing tag defaulting to push_sent = FALSE, and the very next scheduled
-- run of send-social-push's new post_tags-scanning block would read every
-- historical tag on the table as "new" and fire a real "tagged you" push, to
-- a real person, for a tag that was set weeks or months ago. This project has
-- already shipped notifications that pointed at something the app could not
-- show (the hidden-post gap send-social-push's other blocks were just
-- patched for); this migration exists so a second, different mistake, an
-- avalanche of stale tag pushes, is not made instead. The UPDATE below runs
-- in the SAME script as the ALTER TABLE, before send-social-push is ever
-- redeployed against this column, so there is no gap where a poll could see
-- push_sent = FALSE on a historical row.
--
-- Idempotency: the ALTER TABLE and the CREATE INDEX are IF NOT EXISTS and
-- re-run cleanly. The backfill is the one statement that is NOT purely
-- idempotent, on purpose. See the note above it for the reasoning: it marks
-- everything that exists at run time, so it stays correct however long after
-- authoring you run it, at the cost of a re-run suppressing up to one poll
-- cycle of pending pushes. Run it once.
--
-- ORDER MATTERS: run this BEFORE deploying the updated send-social-push
-- function (the one with the new "Tags added AFTER publishing" block), or
-- the poll could fire on historical rows in the gap between the two steps.
-- ============================================================

ALTER TABLE public.post_tags ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- The same partial index every push_sent table here has: the scan send-social-push runs every
-- sixty seconds wants only the (normally near-zero) unsent rows, not a sequential scan of the
-- whole table.
CREATE INDEX IF NOT EXISTS post_tags_unpushed_idx ON public.post_tags (push_sent) WHERE push_sent = FALSE;

-- CRITICAL backfill: every tag that exists WHEN THIS RUNS is marked as already notified, so the
-- first send-social-push poll after deploy does not blast a "tagged you" push for the entire
-- historical table at once.
--
-- Deliberately NOT filtered by a fixed created_at cutoff. A cutoff dated when this file was
-- written is only correct if the file is run the same day, and deploys here are manual and have
-- sat for days before. Run this a week late with a cutoff and every tag made in that week is
-- still FALSE, so they all fire at once: exactly the blast this backfill exists to prevent, just
-- delayed. "Everything that exists right now" is correct whenever it runs.
--
-- The tradeoff is re-running. A second run would also flip any genuinely new tag that had not
-- been pushed yet, suppressing its notification. That window is at most one poll cycle, about
-- sixty seconds of tags, and a handful of missed pushes is a far smaller harm than a mass send to
-- real people. Run it once; if you do run it twice, this is what you lose.
UPDATE public.post_tags
SET push_sent = TRUE
WHERE push_sent = FALSE;

-- Verify after running: this should return 0.
--   SELECT COUNT(*) FROM public.post_tags WHERE push_sent = FALSE;
-- (A small non-zero count is expected only if someone was tagged in the seconds between the
-- backfill and this query. Those rows are correct to still be FALSE: they are new tags and should
-- push. A LARGE count means the backfill did not run, so stop and check before deploying the
-- function.)
