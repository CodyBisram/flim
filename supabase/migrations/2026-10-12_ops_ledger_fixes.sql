-- Two findings from the nightly review (2026-10-12). NOT YET APPLIED. The owner applies it.
-- Idempotent: safe to re-run.
--
-- 1. copy_edge_failures (2026-09-15) copied only ids above the ledger's MAX(id). net._http_response
--    ids are handed out when a request starts, not when its reply lands, so a slow failure that
--    finished after a faster, higher-id failure had already been copied was skipped for good.
--    pg_net keeps six hours of replies (a few hundred rows), so the hourly copy now reads all of
--    them and lets the primary key drop what it already has. A ledger row deleted at 14 days
--    cannot come back: its pg_net row was gone long before.
--
-- 2. The flim-daily-digest schedule this file creates on a fresh database was still the old
--    hourly one ('0 14-23,0-1 * * *'); production has run once a day at 16:00 UTC since
--    2026-10-10. A bootstrap would have quietly gone back to hourly. Aligned here; production
--    already has this schedule, so applying it there changes nothing.

CREATE OR REPLACE FUNCTION public.copy_edge_failures()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n INT;
BEGIN
    INSERT INTO public.edge_response_log (id, created, status_code, error_msg, content)
    SELECT r.id, r.created, r.status_code, r.error_msg, LEFT(r.content::text, 300)
    FROM net._http_response r
    WHERE r.status_code IS NULL OR r.status_code NOT IN (200, 204)
    ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM public.edge_response_log WHERE created < NOW() - INTERVAL '14 days';
    RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.copy_edge_failures() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flim-daily-digest') THEN
        PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'flim-daily-digest'),
                               schedule := '0 16 * * *');
    END IF;
END;
$$;
