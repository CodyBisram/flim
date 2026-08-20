-- NOT YET APPLIED. Ships with the R2 cutover; written now so the Worker and its authority land
-- as one reviewed unit. Apply alongside deploying cloudflare/worker/.
--
-- The one question the R2 Worker asks Postgres: may the CALLING user see this photo's bytes?
-- SECURITY INVOKER on purpose, the entire point is that the photos policies answer, so this can
-- never drift from RLS: a covered post, a block, a follower gate all apply automatically because
-- they already apply to the SELECT this runs.
create or replace function public.can_view_photo(p_path text)
returns boolean
language sql
security invoker
stable
as $$
  select exists (
    select 1 from public.photos
    where p_path in (storage_path, thumb_path, feed_path)
  );
$$;

revoke all on function public.can_view_photo(text) from public, anon;
grant execute on function public.can_view_photo(text) to authenticated;

-- Which photos have their objects in R2 yet. Null means Supabase Storage is still the only home;
-- the app reads through the Worker only when this is set (and the client flag is on), so the
-- backfill can run for days without any reader noticing a thing.
alter table public.photos add column if not exists r2_migrated_at timestamptz;
