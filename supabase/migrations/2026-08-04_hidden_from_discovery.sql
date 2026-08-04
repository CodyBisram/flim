-- ============================================================
-- Keep an account out of "people you might know".
--
-- Added for the App Store Review account, which has to be a fully functional real account (a
-- reviewer must be able to do everything a user can) while not being offered to actual users as
-- someone to follow. It is a general flag rather than a hardcoded id, so a support or demo
-- account later needs no code change.
--
-- What this DOES: removes the account from Discover's suggestions, across all three of its tiers
-- (roll mates, mutual follows, recency), which is the only place FLIM proposes people to follow.
--
-- What this does NOT do, deliberately:
--   * It stays visible to anyone who already interacts with it. If it follows you, it appears in
--     your followers; if it shares a roll, it appears in the member list. Hiding it there would
--     mean lying about who is in a roll, which is worse than the account being visible.
--   * Its profile remains reachable by anyone who knows the username. `users: profiles readable`
--     is `USING (true)` on purpose: it is what makes @mentions resolve, photo tags render names,
--     and profiles open from a post. Restricting THAT is a real authorization change and has no
--     business in a stability release.
--
-- In other words this is a suggestion filter, not a privacy boundary, and should not be described
-- as one.
-- ============================================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS hidden_from_discovery boolean NOT NULL DEFAULT false;

-- `profiles` is the read-only view every social surface reads; the flag has to surface there for
-- the client to filter on it.
CREATE OR REPLACE VIEW public.profiles AS
    SELECT id,
           username,
           avatar_path,
           bio,
           created_at,
           display_name,
           cover_path,
           hidden_from_discovery
    FROM public.users;

-- The App Store Review account.
UPDATE public.users
   SET hidden_from_discovery = true
 WHERE id = 'f36a70a6-b35d-48d6-acce-bef562863d4d';

-- Partial index: the flag is true for a handful of rows at most, so only those are worth indexing.
CREATE INDEX IF NOT EXISTS users_hidden_from_discovery_idx
    ON public.users (id) WHERE hidden_from_discovery;
