-- The four inputs of the weekly tripwire's arithmetic (scripts/tripwire_check.sh), callable by
-- service role only, the same shape as r2_watch_numbers(): the check runs from a script with the
-- long-lived service key, so the /tripwire skill judges the numbers instead of computing them.
--
--   pg_net_bytes          size of net._http_response; over 20 MB means the cleanup cron stopped
--   crons                 every cron.job with its schedule and active flag, for cadence drift
--   push_backlog_over_1h  rows the push crons poll that are still unsent an hour after they were
--                         written (every push_sent table send-social-push reads, plus developed
--                         roll photos), which the poll should never leave behind
--   db_bytes              pg_database_size, compared against the last logged week
create or replace function public.tripwire_numbers()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'pg_net_bytes', (select pg_total_relation_size('net._http_response')),
    'crons', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'jobname', j.jobname, 'schedule', j.schedule, 'active', j.active
             ) order by j.jobname), '[]'::jsonb)
      from cron.job j
    ),
    'push_backlog_over_1h', (
      -- Every table send-social-push polls on push_sent (plus the develop push's photos),
      -- counting only rows older than an hour so a row the next two-minute run will take
      -- is not a backlog. earned_badges is polled too but has no created_at; it is left out.
      (select count(*) from public.post_comments          where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.post_reactions         where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.posts                  where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.post_tags              where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.comment_likes          where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.photo_comments         where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.photo_reactions        where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.follows                where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.photo_reports          where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.user_reports           where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.ops_alerts             where not push_sent and created_at < now() - interval '1 hour')
    + (select count(*) from public.roll_follow_up_invites where not push_sent and created_at < now() - interval '1 hour')
    + (select count(distinct roll_id) from public.photos
        where roll_id is not null and push_sent = false and develops_at < now() - interval '1 hour')
    ),
    'db_bytes', (select pg_database_size(current_database()))
  );
$$;
revoke all on function public.tripwire_numbers() from public, anon, authenticated;
-- Revoking PUBLIC strips the default grant service_role rode in on; it needs its own.
grant execute on function public.tripwire_numbers() to service_role;
