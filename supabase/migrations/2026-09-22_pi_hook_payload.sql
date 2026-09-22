-- The Pi hook relays the full inserted row to hooks.flim-app.com (2026-09-15_pi_hooks.sql). For
-- public.users that row carries email and invite_code, two columns no client is ever granted
-- and that the receiver drops at the door anyway. Strip them before the request leaves the
-- database, so the relay carries nothing the receiver does not use (audit, 2026-09-22).
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
                 'record', to_jsonb(NEW) - 'email' - 'invite_code', 'old_record', null),
    timeout_milliseconds := 5000);
  return NEW;
end $$;

revoke all on function public.pi_hook_notify() from public, anon, authenticated;
