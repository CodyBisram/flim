-- ============================================================
-- Migration: report notifications (App Store Guideline 1.2 — the developer must
-- be able to act on UGC reports within 24h)
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
--
-- No client changes depend on this — clients already INSERT into photo_reports /
-- user_reports, and the new push_sent columns default FALSE and are read only by
-- the scheduled send-social-push Edge Function. There is NO run-before-push gate
-- here; run it whenever.
--
-- Mechanism: reuses the existing "scheduled poll + push_sent flag" pattern (the
-- same one device_tokens.sql / send-social-push already use for comments, tags,
-- and reactions) — NOT a pg_net trigger, which this repo deliberately avoids
-- (it would require the service key + function URL embedded in the DB). The
-- every-1-minute send-social-push function now also scans photo_reports and
-- user_reports for push_sent = FALSE and sends an APNs push to the OWNER's
-- registered devices, then flips the flag. Every report notifies (not just the
-- >=2-reporter auto-hide threshold in auto_hide_reported). No new secrets,
-- tables, triggers, or pg_net calls.
--
-- ⚠️ After running this, redeploy the function so it starts scanning reports:
--     supabase functions deploy send-social-push --no-verify-jwt
--
-- Daily-check backstop — if the owner's device has no registered push token, the
-- report still lands in these tables; run this to see everything from the last
-- day (uses created_at, not push_sent, so it catches reports pushed with no
-- device on file):
--     SELECT 'photo' AS kind, id, photo_id AS subject, reason, created_at
--       FROM public.photo_reports WHERE created_at > now() - interval '1 day'
--     UNION ALL
--     SELECT 'user' AS kind, id, reported_id AS subject, reason, created_at
--       FROM public.user_reports  WHERE created_at > now() - interval '1 day'
--     ORDER BY created_at DESC;
-- ============================================================

-- push_sent flag: marks a report the owner has already been notified about, so
-- the scheduled scan doesn't re-push it (identical role to posts/comments.push_sent).
ALTER TABLE public.photo_reports ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.user_reports  ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT FALSE;

-- Partial indexes on the unpushed rows only (tiny, keeps the every-minute scan
-- index-backed) — same shape as post_comments_unpushed_idx in device_tokens.sql.
CREATE INDEX IF NOT EXISTS photo_reports_unpushed_idx ON public.photo_reports (push_sent) WHERE push_sent = FALSE;
CREATE INDEX IF NOT EXISTS user_reports_unpushed_idx  ON public.user_reports  (push_sent) WHERE push_sent = FALSE;
