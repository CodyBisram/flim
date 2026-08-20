-- The three inputs of the R2 tripwire (see scripts/r2_trigger_check.sh), callable by service
-- role only: the weekly watch job authenticates with the service key because management tokens
-- rotate daily and a months-long watch cannot depend on one.
create or replace function public.r2_watch_numbers()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'storage_bytes', (select coalesce(sum((metadata->>'size')::bigint),0)
                        from storage.objects where bucket_id='photos'),
    'storage_bytes_14d', (select coalesce(sum((metadata->>'size')::bigint),0)
                            from storage.objects
                           where bucket_id='photos' and created_at > now() - interval '14 days'),
    'app_opens_7d', (select coalesce(sum(occurrences),0) from public.usage_events
                      where event='app_open' and day > current_date - 7)
  );
$$;
revoke all on function public.r2_watch_numbers() from public, anon, authenticated;
-- Revoking PUBLIC strips the default grant service_role rode in on; it needs its own.
grant execute on function public.r2_watch_numbers() to service_role;
