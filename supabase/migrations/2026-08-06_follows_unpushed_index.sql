-- ============================================================
-- Missing partial index on follows.push_sent
-- Paste into Supabase Dashboard -> SQL Editor. Safe to re-run, safe any time.
--
-- Every other table the push scanner reads already has this index:
--   post_comments, post_reactions, photo_comments, photo_reactions,
--   photo_reports, user_reports  -> <table>_unpushed_idx
--
-- follows was added on 2026-08-05 with the column and the scan but not the index,
-- so `select ... from follows where push_sent = false`, which send-social-push runs
-- every sixty seconds forever, is a sequential scan.
--
-- Harmless today at ~130 rows. It is worth fixing now anyway because `follows` is the
-- table that grows fastest with the user base — n users can produce up to n² edges —
-- while the rows the scan actually wants stay near zero, since each is flipped to true
-- within a minute of being written. That combination, a huge table and a tiny hot set,
-- is exactly what a partial index is for.
--
-- CONCURRENTLY is deliberately NOT used: it cannot run inside a transaction block, and
-- at this table size the plain form locks for microseconds. Revisit if follows ever
-- reaches millions of rows.
-- ============================================================

CREATE INDEX IF NOT EXISTS follows_unpushed_idx
    ON public.follows (push_sent) WHERE (push_sent = false);

-- Verify: should list follows_unpushed_idx alongside its six siblings.
--
--   select tablename, indexname from pg_indexes
--   where schemaname = 'public' and indexdef ilike '%push_sent%'
--   order by tablename;
