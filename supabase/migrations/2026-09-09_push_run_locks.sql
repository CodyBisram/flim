-- One run of each push sender at a time. The senders poll unsent rows, send, then mark them
-- sent; with pg_cron firing every two minutes and a run occasionally taking longer, two runs
-- could read the same unsent rows and both send. A short lease, taken at the start of a run and
-- released at the end (or expired by the clock if the run dies), makes overlap impossible.
CREATE TABLE IF NOT EXISTS public.push_run_locks (
    name         TEXT PRIMARY KEY,
    locked_until TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE public.push_run_locks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_run_locks FROM PUBLIC, anon, authenticated;

-- TRUE when the lease was taken; FALSE when another run holds it. Service role only.
CREATE OR REPLACE FUNCTION public.acquire_push_lock(p_name TEXT, p_seconds INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_taken BOOLEAN := FALSE;
BEGIN
    INSERT INTO public.push_run_locks (name, locked_until) VALUES (p_name, NOW() - INTERVAL '1 second')
    ON CONFLICT (name) DO NOTHING;
    UPDATE public.push_run_locks
    SET locked_until = NOW() + make_interval(secs => p_seconds)
    WHERE name = p_name AND locked_until < NOW()
    RETURNING TRUE INTO v_taken;
    RETURN COALESCE(v_taken, FALSE);
END;
$$;
CREATE OR REPLACE FUNCTION public.release_push_lock(p_name TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.push_run_locks SET locked_until = NOW() - INTERVAL '1 second' WHERE name = p_name;
$$;
REVOKE ALL ON FUNCTION public.acquire_push_lock(TEXT, INT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_push_lock(TEXT) FROM PUBLIC, anon, authenticated;
