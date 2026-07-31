-- ============================================================
-- Migration: one-time backfill for photo_reactions.push_sent
-- Paste into Supabase Dashboard -> SQL Editor and run ONCE, after schema.sql
-- has added public.photo_reactions.push_sent (ALTER TABLE ... ADD COLUMN IF
-- NOT EXISTS push_sent, already in schema.sql).
--
-- Run this AFTER schema.sql, and only the first time this feature is deployed.
--
-- Why this can't live in schema.sql: push_sent = FALSE is the normal, recurring
-- state for a reaction that is currently waiting on the every-1-minute
-- send-social-push poll, not a one-time migration artifact. schema.sql is
-- re-run in production as the standing workflow here, so an unconditional
-- `UPDATE public.photo_reactions SET push_sent = TRUE WHERE push_sent =
-- FALSE` sitting in schema.sql would silently re-fire on every re-run and
-- permanently swallow the notification for every reaction that happens to be
-- mid-flight at that moment, with no way to recover it. This file exists so
-- that backfill only ever runs once.
--
-- What it does: reactions that already existed before this feature shipped
-- predate the notification entirely, so mark them push_sent = TRUE up front;
-- otherwise the first send-social-push poll after deploy would blast a push
-- for every historical reaction on the table. Only reactions created before
-- the cutoff below are touched.
--
-- Idempotency: the cutoff is a fixed point in time (when this migration is
-- authored/first run), not a relative "now()". Re-running this file is safe:
-- every reaction created before the cutoff was already flipped to TRUE on the
-- first run, so the WHERE clause matches nothing on subsequent runs. Any
-- reaction created at/after the cutoff is a genuinely NEW reaction that
-- should still get its push and is deliberately left untouched by this file,
-- both the first time and on any re-run.
--
-- No client changes depend on this, push_sent is not read or written by the
-- app; only the send-social-push Edge Function touches it (service role,
-- bypasses RLS). There is NO run-before-push gate here, run it whenever,
-- but only once, and only after schema.sql has been applied.
-- ============================================================

UPDATE public.photo_reactions
SET push_sent = TRUE
WHERE push_sent = FALSE
  AND created_at < TIMESTAMPTZ '2026-07-31 00:00:00+00';
