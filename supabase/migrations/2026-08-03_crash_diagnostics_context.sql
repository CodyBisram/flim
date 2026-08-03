-- ============================================================
-- Crash diagnostics: the context needed to actually act on a row.
--
-- The table already captured what crashed and the call stack. What it could not answer:
--
--   WHICH BUILD.  `app_version` is "1.2", but every CI build of 1.2 has its own dSYM, and a
--   MetricKit stack is raw binary offsets that only the exact matching dSYM can resolve. Without
--   the build number you cannot tell which artifact to symbolicate against. (It is technically
--   recoverable from the binary UUID inside call_stack_tree; this makes it a column instead of
--   an excavation.)
--
--   WHEN.  `created_at` is when the row was UPLOADED. MetricKit only hands diagnostics over on a
--   later launch, so six rows arriving at 19:48 look like six crashes at 19:48 when they are
--   really a flush at app start. `occurred_at` is the diagnostic window's own end timestamp, so
--   crashes can finally be placed in time and correlated with a release.
--
--   WHO.  os_version + device_model separate "everyone" from "one person on one old phone",
--   which is the first question worth asking about any crash.
--
-- All nullable: existing rows predate the fields, and a diagnostic retried from a pre-update
-- on-device queue legitimately has none of them. Missing means unknown, never a dropped row.
-- ============================================================
ALTER TABLE public.crash_diagnostics
    ADD COLUMN IF NOT EXISTS app_build    text,
    ADD COLUMN IF NOT EXISTS os_version   text,
    ADD COLUMN IF NOT EXISTS device_model text,
    ADD COLUMN IF NOT EXISTS occurred_at  timestamptz;

-- Triage reads newest-first by when the crash HAPPENED, and almost always filters to one build.
CREATE INDEX IF NOT EXISTS crash_diagnostics_occurred_at_idx
    ON public.crash_diagnostics (occurred_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS crash_diagnostics_build_idx
    ON public.crash_diagnostics (app_version, app_build);
