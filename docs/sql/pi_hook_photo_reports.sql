-- Adds photo_reports to the Pi's real-time hooks (docs/ROUTINES.md, 2026-09-21).
-- supabase/migrations/2026-09-15_pi_hooks.sql wired crash_diagnostics, ops_alerts, user_reports,
-- users and activation_events; photo_reports was left out, so a reported photograph never
-- reaches the receiver. The receiver already handles the table (owner, reporter, roll or page,
-- a drafted call). Same function, same secret row, one more trigger.
--
-- Not applied from the Pi. Run in the SQL editor against production, then mirror into
-- supabase/schema.sql and a dated migration by the owner's hand.

drop trigger if exists pi_hook_photo_reports on public.photo_reports;
create trigger pi_hook_photo_reports
    after insert on public.photo_reports
    for each row execute function public.pi_hook_notify();

-- Verify: select tgname, tgrelid::regclass from pg_trigger where tgname like 'pi_hook_%';   -- 6 rows
