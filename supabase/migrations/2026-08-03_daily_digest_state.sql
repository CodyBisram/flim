-- ============================================================
-- Daily digest state: one row per user, recording the last time they were sent a
-- "your friends posted" digest.
--
-- Exists so the digest is idempotent. The function is scheduled hourly rather than daily (a
-- once-a-day cron that misses its window sends nothing that day), so it needs to know whether a
-- given user has already had today's digest. Storing the timestamp rather than a date also makes
-- the "posts since" window exact: a digest covers everything since the last one actually sent,
-- so a missed run rolls into the next one instead of dropping those posts on the floor.
--
-- Deliberately NOT a column on users: this is delivery bookkeeping, written by the service role
-- on a schedule, and it has no business sitting next to profile data that the client reads and
-- writes. Nobody but the function ever touches it, hence no client-facing policy.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.digest_state (
    user_id      uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    last_sent_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.digest_state ENABLE ROW LEVEL SECURITY;

-- No policies on purpose. RLS is on with zero policies, so authenticated clients can neither read
-- nor write it; the edge function uses the service role, which bypasses RLS entirely.
