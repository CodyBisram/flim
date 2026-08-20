-- The ceilings gauge: how fast FLIM is approaching the two numbers that end the free ride.
--
-- Storage is MEASURED (bytes in the bucket, and the last fortnight's growth, straight from
-- storage.objects). Egress cannot be measured from Postgres at all: bytes served live in
-- Supabase's own logs and no management API exposes them, so the dashboard MODELS it from app
-- opens times an assumed session payload, and labels it modelled. The owner decision this gauge
-- serves: migrate photo bytes to R2 before growth, or wait on a tripwire. Growth trips storage
-- and egress in the same few weeks, so the gauge's job is showing the pace while it is boring.
create or replace function public.admin_storage()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok)
  select case when (select ok from gate) then jsonb_build_object(
    'photos', (select count(*) from public.photos),
    'photos_7d', (select count(*) from public.photos where taken_at > now() - interval '7 days'),
    'missing_thumb', (select count(*) from public.photos where thumb_path is null),
    'missing_feed', (select count(*) from public.photos where feed_path is null),
    'posts', (select count(*) from public.posts),
    'reactions', (select count(*) from public.post_reactions),
    'comments', (select count(*) from public.post_comments),
    'rolls', (select count(*) from public.rolls),
    'rolls_developing', (select count(*) from public.rolls
                          where created_at + interval '12 hours' > now()),
    'storage_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0)
                        from storage.objects where bucket_id = 'photos'),
    'storage_bytes_14d', (select coalesce(sum((metadata->>'size')::bigint), 0)
                            from storage.objects
                           where bucket_id = 'photos'
                             and created_at > now() - interval '14 days'),
    'app_opens_7d', (select coalesce(sum(occurrences), 0) from public.usage_events
                      where event = 'app_open' and day > current_date - 7)
  ) else null end;
$$;
