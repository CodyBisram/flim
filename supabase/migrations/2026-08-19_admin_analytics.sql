-- Analytics for the owner dashboard.
--
-- These exist because docs/METRICS.md exists: eleven tested queries that have to be pasted into
-- the SQL editor by hand, one at a time, which means in practice they get run when something is
-- already going wrong. Behind an RPC they are a page you look at.
--
-- Every function here is SECURITY DEFINER and starts with the same is_owner() gate. That gate is
-- the ONLY thing standing between these and the whole userbase's activity, so it is repeated in
-- each function rather than assumed from a wrapper: a function added later that forgets it would
-- be a silent, total exposure.
--
-- All read-only. None of them write, and none takes an id that could be used to reach a single
-- named person's content: the named lists return handles and counts, which is what a nudge needs
-- and no more.

-- ---------------------------------------------------------------------------
-- 1. Activation funnel, cohort-scoped, with the caveat carried in the payload.
--
-- The trap this closes: every activation event started logging on a different day, so raw counts
-- across them are meaningless (first_launch is not everyone who ever launched, it is however many
-- days it has existed). docs/METRICS.md handles that with a hardcoded date and the instruction
-- "move it forward whenever a new event is added", which is exactly the kind of thing nobody
-- does. Two events were added on 2026-08-19 and the doc's date was already four days stale.
--
-- The obvious fix, deriving the cohort from the newest event, was tried and is WORSE. Adding an
-- event then pins the cohort to that instant and every step reads zero until a week of signups
-- accumulates: the funnel breaks precisely when instrumentation improves, which is the moment you
-- most want to look at it.
--
-- So the default is the newest event that has been live at least a week, which moves on its own
-- but never to a date that empties the cohort. Each step also reports whether it is COMPARABLE:
-- a step whose logging began after the cohort date cannot be read against the others, and saying
-- so beside the number is worth more than silently omitting it.
create or replace function public.admin_funnel(p_since timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok),
  starts as (
    select event, min(created_at) as first_seen
    from public.activation_events group by event
  ),
  since as (
    select coalesce(
      p_since,
      (select max(first_seen) from starts where first_seen <= now() - interval '7 days'),
      (select min(first_seen) from starts)
    ) as d
  ),
  cohort as (
    select id from auth.users where created_at >= (select d from since)
  ),
  steps(step, ord) as (values
    ('first_launch',1),('onboarding_finished',2),('camera_authorized',3),
    ('camera_ready',4),('shutter_tapped',5),('first_shot',6),
    ('notifications_authorized',7),('roll_joined',8),('post_shared',9),('reveal_watched',10))
  select case when (select ok from gate) then jsonb_build_object(
    'since', (select d from since),
    'cohort_size', (select count(*) from cohort),
    'derived', p_since is null,
    'steps', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'step', s.step, 'ord', s.ord,
               'reached', (select count(distinct a.user_id) from public.activation_events a
                            where a.event = s.step and a.user_id in (select id from cohort)),
               'logging_since', (select first_seen from starts where starts.event = s.step),
               -- False when this step began logging after the cohort started, or has never
               -- logged at all. Its number is then a floor, not a measurement.
               'comparable', coalesce(
                 (select first_seen from starts where starts.event = s.step) <= (select d from since),
                 false)
             ) order by s.ord), '[]'::jsonb)
      from steps s
    )
  ) else null end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Push reach.
--
-- The question this was built for: 42 accounts had camera_authorized and 25 held a device token,
-- and nothing said whether the other 17 refused or were never asked. Those want opposite
-- responses, so the three states are reported separately and "never asked" is computed as the
-- absence of both permission events rather than as a state anyone records.
create or replace function public.admin_reach()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok),
  people as (
    select u.id,
           exists(select 1 from public.device_tokens d where d.user_id = u.id) as has_token,
           exists(select 1 from public.activation_events a
                   where a.user_id = u.id and a.event = 'notifications_authorized') as said_yes,
           exists(select 1 from public.activation_events a
                   where a.user_id = u.id and a.event = 'notifications_denied') as said_no
    from auth.users u
  )
  select case when (select ok from gate) then jsonb_build_object(
    'accounts', (select count(*) from people),
    'with_token', (select count(*) from people where has_token),
    'authorized', (select count(*) from people where said_yes),
    'denied', (select count(*) from people where said_no and not said_yes),
    -- The actionable bucket. Not a recorded state: it is everyone the prompt never reached.
    'never_asked', (select count(*) from people where not said_yes and not said_no),
    'tokens', (select count(*) from public.device_tokens),
    'newest_token', (select max(updated_at) from public.device_tokens)
  ) else null end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Who is stuck, by name.
--
-- The three cohorts worth a nudge, each defined by the step they have not taken. Returns handles
-- and counts because that is what deciding on a campaign needs; no photo ids, no paths, nothing
-- that reaches content.
--
-- "Never shot" is zero rows in photos, NOT zero posts: somebody with frames sitting unsorted has
-- taken a photograph and belongs in the third list, where the ask is different.
create or replace function public.admin_stuck()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok),
  p as (
    select pr.id, pr.username, pr.created_at,
           (select count(*) from public.photos x where x.user_id = pr.id) as photos,
           (select count(*) from public.photos x where x.user_id = pr.id and not x.is_sorted) as to_sort,
           (select min(x.taken_at) from public.photos x where x.user_id = pr.id and not x.is_sorted) as oldest_unsorted,
           (select count(*) from public.posts po where po.user_id = pr.id) as posts,
           exists(select 1 from public.device_tokens d where d.user_id = pr.id) as reachable
    from public.profiles pr
  )
  select case when (select ok from gate) then jsonb_build_object(
    'never_shot', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'username', username, 'joined', created_at::date, 'reachable', reachable
      ) order by created_at), '[]'::jsonb) from p where photos = 0),
    'shot_never_posted', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'username', username, 'photos', photos, 'to_sort', to_sort, 'reachable', reachable
      ) order by photos desc), '[]'::jsonb) from p where photos > 0 and posts = 0),
    -- Two days, and the floor is the point: somebody actively shooting today has a deck because
    -- they are using the app, and telling them it is waiting describes their afternoon back.
    'deck_sitting', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'username', username, 'to_sort', to_sort,
        'oldest', oldest_unsorted::date, 'reachable', reachable
      ) order by to_sort desc), '[]'::jsonb)
      from p where to_sort > 0 and oldest_unsorted < now() - interval '48 hours')
  ) else null end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Daily pulse.
--
-- Is the app alive this week. Signups, shots, posts and reactions per day, zero-filled so a dead
-- day is a visible gap rather than a missing row that closes up and hides itself in a chart.
create or replace function public.admin_pulse(p_days int default 21)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok),
  days as (
    select generate_series(
      (current_date - (least(greatest(p_days, 1), 90) - 1))::date, current_date, '1 day'
    )::date as d
  )
  select case when (select ok from gate) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'day', days.d,
      'signups', (select count(*) from auth.users u where u.created_at::date = days.d),
      'shots', (select count(*) from public.photos x where x.taken_at::date = days.d),
      'posts', (select count(*) from public.posts po where po.created_at::date = days.d),
      'reactions', (select count(*) from public.post_reactions r where r.created_at::date = days.d),
      'shooters', (select count(distinct x.user_id) from public.photos x where x.taken_at::date = days.d)
    ) order by days.d) from days
  ), '[]'::jsonb) else null end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Retention by signup week.
--
-- Whether people come back, measured by activity rather than by opening the app: a launch is not
-- instrumented per-day, but a shot, a post or a reaction is, and any of the three is a return.
create or replace function public.admin_retention()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok),
  cohorts as (
    select u.id, date_trunc('week', u.created_at)::date as wk, u.created_at
    from auth.users u
  ),
  acts as (
    select user_id, taken_at as at from public.photos
    union all select user_id, created_at from public.posts
    union all select user_id, created_at from public.post_reactions
  )
  select case when (select ok from gate) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'week', wk,
      'size', size,
      'd1', d1, 'd7', d7, 'd14', d14
    ) order by wk) from (
      select c.wk,
             count(distinct c.id) as size,
             count(distinct c.id) filter (where exists (
               select 1 from acts a where a.user_id = c.id
                 and a.at >= c.created_at + interval '1 day'
                 and a.at <  c.created_at + interval '2 days')) as d1,
             count(distinct c.id) filter (where exists (
               select 1 from acts a where a.user_id = c.id
                 and a.at >= c.created_at + interval '7 days'
                 and a.at <  c.created_at + interval '8 days')) as d7,
             count(distinct c.id) filter (where exists (
               select 1 from acts a where a.user_id = c.id
                 and a.at >= c.created_at + interval '14 days'
                 and a.at <  c.created_at + interval '15 days')) as d14
      from cohorts c group by c.wk
    ) t
  ), '[]'::jsonb) else null end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Storage, and the egress proxy.
--
-- The one that decides whether this is affordable. Storage grows with shooting and is bounded by
-- it; egress grows with LOOKING and is not bounded by anything, which is why the second number
-- matters more than the first even though the first is the one that has a bill attached today.
--
-- Renditions missing is in here because it is a direct multiplier on egress: a photo with no
-- thumbnail falls back to the full master everywhere it appears, forever.
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
                          where created_at + interval '12 hours' > now())
  ) else null end;
$$;

-- ---------------------------------------------------------------------------
-- 7. One-off campaigns that have been sent.
--
-- So a campaign is a thing with a record rather than a thing somebody remembers doing.
create or replace function public.admin_campaigns()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with gate as (select public.is_owner() as ok)
  select case when (select ok from gate) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'campaign', campaign,
      'claimed', claimed,
      'delivered', delivered,
      'first_sent', first_sent,
      -- Did it work: how many of the people contacted have shot since being contacted.
      'shot_after', shot_after
    ) order by first_sent desc)
    from (
      select o.campaign,
             count(*) as claimed,
             count(*) filter (where o.sent_at is not null) as delivered,
             min(o.sent_at) as first_sent,
             count(*) filter (where exists (
               select 1 from public.photos x
                where x.user_id = o.user_id and x.taken_at > o.sent_at)) as shot_after
      from public.one_shot_push o group by o.campaign
    ) t
  ), '[]'::jsonb) else null end;
$$;

-- Owner-gated inside each function, but revoke the blanket grant anyway: a function that is only
-- safe because of a line in its own body is one refactor away from not being.
revoke all on function public.admin_funnel(timestamptz) from public, anon;
revoke all on function public.admin_reach() from public, anon;
revoke all on function public.admin_stuck() from public, anon;
revoke all on function public.admin_pulse(int) from public, anon;
revoke all on function public.admin_retention() from public, anon;
revoke all on function public.admin_storage() from public, anon;
revoke all on function public.admin_campaigns() from public, anon;

grant execute on function public.admin_funnel(timestamptz) to authenticated;
grant execute on function public.admin_reach() to authenticated;
grant execute on function public.admin_stuck() to authenticated;
grant execute on function public.admin_pulse(int) to authenticated;
grant execute on function public.admin_retention() to authenticated;
grant execute on function public.admin_storage() to authenticated;
grant execute on function public.admin_campaigns() to authenticated;
