-- Real-time event hooks to the owner's Raspberry Pi (see docs/ROUTINES.md).
-- On INSERT into a few tables, POST the row to https://hooks.flim-app.com/supabase via pg_net.
-- The shared secret is NOT in this file: it lives in one row of private.pi_hook_settings, inserted by
-- hand in the SQL editor (see the bottom). With no secret row, the triggers are no-ops.
--
-- Idempotent. Mirrors what was first applied by hand on 2026-09-14 (which put the secret inline in
-- the function body); this version replaces that function.

create extension if not exists pg_net;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.pi_hook_settings (
    key   text primary key,
    value text not null
);
revoke all on private.pi_hook_settings from public, anon, authenticated;
alter table private.pi_hook_settings enable row level security;   -- belt and braces; the schema is not API-exposed

create or replace function public.pi_hook_notify()
returns trigger
language plpgsql
security definer
set search_path = public, private, net
as $$
declare
  secret text;
  target text;
begin
  select value into secret from private.pi_hook_settings where key = 'secret';
  select value into target from private.pi_hook_settings where key = 'url';
  if secret is null then
    return NEW;   -- not configured on this database (e.g. the bootstrap test schema)
  end if;
  perform net.http_post(
    url     := coalesce(target, 'https://hooks.flim-app.com/supabase'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Hook-Secret', secret),
    body    := jsonb_build_object(
                 'type', TG_OP, 'table', TG_TABLE_NAME, 'schema', TG_TABLE_SCHEMA,
                 'record', to_jsonb(NEW), 'old_record', null),
    timeout_milliseconds := 5000);
  return NEW;
end $$;

revoke all on function public.pi_hook_notify() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['crash_diagnostics','ops_alerts','user_reports','users','activation_events'] loop
    execute format('drop trigger if exists pi_hook_%1$s on public.%1$s', t);
    execute format('create trigger pi_hook_%1$s after insert on public.%1$s for each row execute function public.pi_hook_notify()', t);
  end loop;
end $$;

-- One-time, by hand, production only (NOT in this file, NOT in the repo):
--   insert into private.pi_hook_settings (key, value) values ('secret', '<from ~/.ssh/pi-hooks-secret on the Mac>')
--     on conflict (key) do update set value = excluded.value;
-- Verify: select tgname, tgrelid::regclass from pg_trigger where tgname like 'pi_hook_%';   -- 5 rows
