-- ============================================================
-- Migration: per-user client version (client_versions table,
-- report_client_version RPC, admin_versions dashboard RPC).
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-07_admin_dashboard.sql (public.is_owner()).
-- ⚠️ run this BEFORE releasing the Swift client that calls
--    report_client_version (the client call is try?-swallowed, so nothing
--    breaks either way, but rows only start appearing once this is live).
--
-- WHY: "how many users are on the latest version" was unanswerable on
-- 2026-08-21, the day after 1.4.2 released. The only tables carrying
-- app_version were crash_diagnostics and feedback, both biased slivers.
-- App Store Connect's version analytics cover only the ~third of users who
-- opted into sharing, and lag a day. One row per user, overwritten on every
-- launch, is a census instead of a sample.
--
-- PRIVACY: one current version string per account, no history. Which version
-- someone runs is already collected (linked to identity) by every crash row
-- and feedback row; this adds no new category to the nutrition label
-- (Usage Data > Product Interaction / Diagnostics, already declared).
-- Deliberately NOT an event stream and deliberately no per-day history:
-- the question is "who is behind today", never "when did they update".
-- ============================================================

-- ------------------------------------------------------------
-- 1. The table. One row per user, latest wins. `build` kept beside
--    `version` because TestFlight testers all share a version string and
--    differ only by build, and the dashboard should say so.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.client_versions (
    user_id    UUID NOT NULL PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    version    TEXT NOT NULL,
    build      TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 2. RLS. Same posture as usage_events: owner-read, and deliberately NO
--    insert/update policy for authenticated. The only writer is the
--    SECURITY DEFINER function below, so a client cannot claim a version
--    it is not running (harmless-looking, but a forged "everyone updated"
--    would hide a broken rollout).
-- ------------------------------------------------------------
ALTER TABLE public.client_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "client_versions: owner reads" ON public.client_versions;
CREATE POLICY "client_versions: owner reads"
    ON public.client_versions FOR SELECT TO authenticated
    USING (public.is_owner());

-- ------------------------------------------------------------
-- 3. report_client_version. Same carelessness contract as log_usage_event:
--    no-ops when signed out, fire on every launch, the upsert makes repeats
--    free. Length caps reject junk without ever failing the app (the client
--    call is try?-swallowed anyway).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_client_version(p_version TEXT, p_build TEXT DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN;
    END IF;
    IF p_version IS NULL OR length(p_version) = 0 OR length(p_version) > 32
       OR length(COALESCE(p_build, '')) > 32 THEN
        RETURN;
    END IF;

    INSERT INTO public.client_versions (user_id, version, build, updated_at)
    VALUES (auth.uid(), p_version, p_build, now())
    ON CONFLICT (user_id)
    DO UPDATE SET version = EXCLUDED.version,
                  build   = EXCLUDED.build,
                  updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.report_client_version(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.report_client_version(TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.report_client_version(TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 4. admin_versions, for the dashboard's Versions panel. Owner-gated like
--    every admin_* function: the gate is repeated here, never assumed.
--    `unreported` is the honest bucket: accounts that have not yet opened a
--    build that reports (or have not opened the app at all since this
--    shipped). It stays large at first and drains as people update; reading
--    it as "on an old version" is wrong for the first weeks.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_versions()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH gate AS (SELECT public.is_owner() AS ok)
  SELECT CASE WHEN (SELECT ok FROM gate) THEN jsonb_build_object(
    'accounts', (SELECT count(*) FROM public.users),
    'reported', (SELECT count(*) FROM public.client_versions),
    'unreported', (SELECT count(*) FROM public.users u
                    WHERE NOT EXISTS (SELECT 1 FROM public.client_versions c
                                       WHERE c.user_id = u.id)),
    'versions', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'version', v.version,
               'users', v.users,
               'builds', v.builds,
               'last_seen', v.last_seen
             ) ORDER BY v.users DESC, v.version DESC), '[]'::jsonb)
      FROM (
        SELECT version,
               count(*) AS users,
               string_agg(DISTINCT COALESCE(build, '?'), ', ' ORDER BY COALESCE(build, '?')) AS builds,
               max(updated_at) AS last_seen
        FROM public.client_versions
        GROUP BY version
      ) v
    )
  ) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.admin_versions() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_versions() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_versions() TO authenticated;

-- ------------------------------------------------------------
-- 5. No backfill. Nothing has ever recorded a per-user version, so the
--    table starts empty and fills as reporting clients launch. The first
--    honest read of "who is behind" is roughly a week after the first
--    reporting build reaches the App Store.
-- ------------------------------------------------------------
