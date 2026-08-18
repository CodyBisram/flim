-- ============================================================
-- Migration: give earned_badges a push_sent column, so a badge can finally
-- tell its owner it happened.
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run AFTER 2026-08-18_one_year_still_shooting.sql (applied), and
-- BEFORE deploying the send-social-push change that reads this column.
--
-- WHY
-- ----
-- Badges were built with an in-app dot and nothing else. Every other notifiable
-- event in this schema carries push_sent and gets picked up by the
-- send-social-push poll: posts, post_tags, post_comments, comment_likes,
-- photo_reactions, follows. earned_badges did not, so there was no way to be
-- told you had earned something. The dot only lives on the Feed tab's avatar
-- button, only refreshes when that tab reappears, and the ratchet that decides
-- you earned anything only runs once per launch, so in practice the news
-- arrived at least one cold start after the fact and only if you happened to
-- look at the right corner of the right tab.
--
-- ⚠️ BACKFILLED TO TRUE, WHICH IS THE WHOLE POINT OF DOING IT IN THIS ORDER.
-- There are 272 rows in earned_badges right now. A column defaulting to FALSE
-- with no backfill would mean the very first poll after deploy sends every one
-- of them: 22 pushes to one account, 17 to another, in a burst, for badges
-- earned days ago. The same trap 2026-08-17_post_tags_push_sent.sql documents
-- for tags, and the same fix. Only badges earned AFTER this runs will notify.
--
-- No index is added. The poll filters `push_sent = false`, which after this
-- backfill matches almost nothing, and the table is a few hundred rows on a
-- primary key of (user_id, badge_id). A partial index here would cost more to
-- maintain than the sequential scan it saves.
-- ============================================================

ALTER TABLE public.earned_badges
    ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- Everything that already exists is old news. Scoped to FALSE rather than
-- unconditional so re-running this file cannot un-send anything queued in
-- between.
UPDATE public.earned_badges SET push_sent = TRUE WHERE push_sent = FALSE;


-- ---- Verify -----------------------------------------------------------------
--
--   -- Expect 0 immediately after running, and 272 total.
--   SELECT COUNT(*) FILTER (WHERE NOT push_sent) AS will_notify,
--          COUNT(*)                              AS total
--   FROM public.earned_badges;
--
--   -- To test the push end to end, un-flag ONE row for yourself and wait for
--   -- the next send-social-push run:
--   -- UPDATE public.earned_badges SET push_sent = FALSE
--   -- WHERE user_id = '<your uuid>' AND badge_id = 'kept_one';
