-- ============================================================
-- Migration: blocking severs BOTH follow edges (follower-count asymmetry fix)
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
-- No client changes depend on this — the app's optimistic unfollow in
-- FeedService.block() still runs (now redundant server-side but harmless), so
-- there is NO run-before-push gate here. Run it whenever.
--
-- Bug: when A blocks B, the client deletes A→B (unfollow), but the follows
-- DELETE policy is `follower_id = auth.uid()`, so A can't delete B's B→A row.
-- B→A survived every block: the blocker dropped out of the blocked user's
-- follower LIST (client filters blockedIds) but the follower COUNT stayed put
-- (counts count raw rows), while the following count fell correctly. Observed
-- live after Sabirah blocked Cody — looked broken.
--
-- Fix: an AFTER INSERT trigger on blocks deletes both edges between the pair,
-- either direction. SECURITY DEFINER so it bypasses the follows DELETE policy
-- (the client role could only ever delete its own follower_id row). Plus a
-- one-time backfill to clean the Sabirah↔Cody leftover and any other stale
-- edges that predate the trigger.
-- Statements are in dependency order (function -> trigger -> backfill).
-- ============================================================

-- 1. Trigger function: nuke both follow edges between blocker and blocked.
--    Trigger functions are invoked by the trigger mechanism, not by a client
--    role via RPC, so no role needs EXECUTE — revoke from PUBLIC/anon/
--    authenticated to match the auto_hide_reported convention in schema.sql.
CREATE OR REPLACE FUNCTION public.block_severs_follows()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.follows
    WHERE (follower_id = NEW.blocker_id AND following_id = NEW.blocked_id)
       OR (follower_id = NEW.blocked_id AND following_id = NEW.blocker_id);
    RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.block_severs_follows() FROM PUBLIC, anon, authenticated;

-- 2. Wire it up (AFTER INSERT on blocks). All blocks come from the client table
--    INSERT (FeedService.block); no RPC/edge function creates blocks, so this
--    covers every path by construction.
DROP TRIGGER IF EXISTS block_severs_follows_trigger ON public.blocks;
CREATE TRIGGER block_severs_follows_trigger
    AFTER INSERT ON public.blocks
    FOR EACH ROW EXECUTE FUNCTION public.block_severs_follows();

-- 3. One-time backfill: delete any surviving follow edge between a pair that
--    CURRENTLY has a block row in either direction (cleans the Sabirah↔Cody
--    leftover). Idempotent — re-running finds nothing after the first pass.
DELETE FROM public.follows f
WHERE EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = f.follower_id  AND b.blocked_id = f.following_id)
       OR (b.blocker_id = f.following_id AND b.blocked_id = f.follower_id)
);
