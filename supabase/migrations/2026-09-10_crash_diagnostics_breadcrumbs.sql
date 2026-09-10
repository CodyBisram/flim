-- Two things found while reading share-flow breadcrumbs back from the owner's phone (2026-09-10).
--
-- 1. The kind check only allowed MetricKit's three kinds, so the app's "breadcrumb" rows (see
--    ShareBreadcrumbs.swift) were rejected silently. Widened.
-- 2. Supabase's default privileges had granted anon and authenticated UPDATE, DELETE, TRUNCATE,
--    REFERENCES and TRIGGER on this table. RLS covers UPDATE and DELETE (no policy, so nothing is
--    reachable), but TRUNCATE is not subject to RLS: anyone holding the publishable key could
--    have emptied the table. Only INSERT (own row, by policy) is a thing a client needs.
ALTER TABLE public.crash_diagnostics DROP CONSTRAINT IF EXISTS crash_diagnostics_kind_check;
ALTER TABLE public.crash_diagnostics ADD CONSTRAINT crash_diagnostics_kind_check
    CHECK (kind = ANY (ARRAY['crash', 'hang', 'cpuException', 'breadcrumb']));
REVOKE SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.crash_diagnostics FROM anon, authenticated;
GRANT INSERT ON public.crash_diagnostics TO anon, authenticated;
