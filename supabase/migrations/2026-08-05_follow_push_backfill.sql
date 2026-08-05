-- ============================================================
-- Migration: one-time backfill for follows.push_sent
-- Paste into Supabase Dashboard -> SQL Editor and run ONCE, after schema.sql
-- has added public.follows.push_sent (ALTER TABLE ... ADD COLUMN IF NOT EXISTS
-- push_sent, already in schema.sql).
--
-- Run this AFTER schema.sql, and only the first time this feature is deployed.
--
-- Why this can't live in schema.sql: push_sent = FALSE is the normal, recurring
-- state for a follow that is currently waiting on the every-1-minute
-- send-social-push poll, not a one-time migration artifact. schema.sql is
-- re-run in production as the standing workflow here, so an unconditional
-- `UPDATE public.follows SET push_sent = TRUE WHERE push_sent = FALSE` sitting
-- in schema.sql would silently re-fire on every re-run and permanently swallow
-- the notification for every follow that happens to be mid-flight at that
-- moment, with no way to recover it. This file exists so that backfill only
-- ever runs once.
--
-- What it does: every follow in the table predates follow notifications
-- entirely, so mark them push_sent = TRUE up front. Without this, the first
-- send-social-push poll after deploy would push a "started following you" for
-- the ENTIRE follow graph at once, to everyone, for relationships that in some
-- cases are weeks old. That is the failure worth being careful about here: it
-- cannot be recalled, and it would land on every user simultaneously.
--
-- Idempotency: the cutoff is a fixed point in time (when this migration is
-- authored/first run), not a relative "now()". Re-running this file is safe:
-- every follow created before the cutoff was already flipped to TRUE on the
-- first run, so the WHERE clause matches nothing on subsequent runs. Any follow
-- created at/after the cutoff is a genuinely NEW follow that should still get
-- its push and is deliberately left untouched by this file, both the first time
-- and on any re-run.
--
-- ORDER MATTERS: run this BEFORE deploying the updated send-social-push
-- function, or the poll may fire on the historical rows in the gap between the
-- two steps. schema.sql adds the column defaulting to FALSE, which is exactly
-- the state the scanner acts on.
--
-- No client changes depend on this, push_sent is not read or written by the
-- app; only the send-social-push Edge Function touches it (service role,
-- bypasses RLS).
-- ============================================================

UPDATE public.follows
SET push_sent = TRUE
WHERE push_sent = FALSE
  AND created_at < TIMESTAMPTZ '2026-08-06 00:00:00+00';

-- A follow row predating the created_at column default would have a NULL date
-- and be missed by the comparison above, leaving it to push. There should be
-- none (created_at has defaulted to NOW() since the table was created), but a
-- stray NULL here costs a wrong push to a real person.
UPDATE public.follows
SET push_sent = TRUE
WHERE push_sent = FALSE
  AND created_at IS NULL;
