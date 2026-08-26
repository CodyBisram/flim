-- ============================================================
-- Migration: cron hygiene, from the 2026-08-26 Dashboard cron audit.
-- Two items. Both idempotent; safe to re-run. Owner pastes by hand.
--
-- THE CRON RECORD (what the Dashboard showed on 2026-08-26, written down
-- here because none of it lives in the repo otherwise):
--   flim-social-push    */2 * * * *        edge fn send-social-push
--   flim-develop-push   */5 * * * *        edge fn send-develop-push
--   flim-daily-digest   0 14-23,0-1 * * *  edge fn send-daily-digest
--   flim-storage-sweep  17 9 * * *         edge fn sweep-orphaned-storage
--   flim-cron-cleanup   20 8 * * *         DELETE old cron.job_run_details
--   one-shot-vacuum-2   * * * * *          VACUUM FULL cron.job_run_details  <- removed below
--
-- 1. mark_developed_photos() WAS NEVER SCHEDULED. The audit that went
--    looking for its cadence found there is none: no cron job runs it, and
--    no edge function calls it (send-develop-push reads develops_at and
--    flips push_sent only). The function has sat in the schema since its
--    migration with two later migrations describing is_developed as "a
--    cron-maintained cache", which was aspiration, not fact. In practice
--    the only writer has been the CLIENT (PhotoService.markDevelopedIfReady
--    over the darkroom's loaded page), so is_developed lags until each
--    user next opens their darkroom, and anything server-side that trusts
--    it (badge counts) undercounts in the meantime. This schedules it at
--    the develop-push cadence; the partial index photos_undeveloped_idx
--    (2026-08-26_index_hygiene.sql) exists precisely to make this scan
--    cheap. cron.schedule() with an existing jobname replaces that job's
--    schedule/command in place, so re-pasting cannot create duplicates.
--
-- 2. one-shot-vacuum-2 REMOVAL. Leftover from the 2026-08-24 disk IO
--    incident: a VACUUM FULL of cron.job_run_details intended as a
--    one-shot compaction, but scheduled '* * * * *', so it has been
--    running EVERY MINUTE since, taking an ACCESS EXCLUSIVE lock and
--    rewriting the whole table each time. Retention is already handled by
--    the daily flim-cron-cleanup DELETE; the every-minute rewrite is pure
--    IO burn of exactly the kind the incident's own tripwire watches for.
--    The unschedule below is a no-op if the job is already gone.
-- ============================================================

-- 1. Give is_developed its actual cron.
SELECT cron.schedule(
    'flim-mark-developed',
    '*/5 * * * *',
    'SELECT public.mark_developed_photos()'
);

-- 2. Retire the runaway one-shot.
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'one-shot-vacuum-2';
