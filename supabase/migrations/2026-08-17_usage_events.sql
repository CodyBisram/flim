-- ============================================================
-- Migration: repeated-event instrumentation (usage_events table,
-- log_usage_event RPC, plus a one-time backfill from existing tables).
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-07_admin_dashboard.sql (public.is_owner()).
-- ⚠️ run this BEFORE pushing the Swift client that calls log_usage_event.
--
-- activation_events (2026-08-08) answers "did this person ever do X". It
-- structurally cannot answer the three questions that decide whether FLIM is
-- worth opening the invite list:
--
--   1. Does anyone come back?          (week-N retention, cohorted by signup)
--   2. How often do they open it?      (active days per week)
--   3. Do they shoot, or just lurk?    (captures vs feed views on the same day)
--
-- ------------------------------------------------------------
-- THE DESIGN DECISION: day buckets with counters, not an event stream.
-- ------------------------------------------------------------
-- The obvious shape is one row per event with a timestamp. That is rejected
-- here for three reasons, in order of how much they matter:
--
-- (a) PRIVACY. A timestamped stream reconstructs a behavioural timeline: this
--     person opened FLIM at 02:14, again at 02:19, was awake at 4am, stopped
--     opening it the week they stopped talking to someone. FLIM's own App
--     Store listing promises "no algorithm, no strangers", and that timeline
--     is exactly the artifact the promise is about. A daily counter answers
--     every question above and cannot reconstruct any of it.
--
-- (b) IDEMPOTENCE. The unique index on activation_events (user_id, event) is
--     what lets Activation.log() be fire-and-forget: a retried capture, a
--     double-tap, a reinstall all collapse to one row, and the CLIENT never
--     has to track "did I already send this". Dropping to a plain event
--     stream throws that away and makes every retry a real duplicate.
--     (user_id, event, day) restores it: ON CONFLICT DO UPDATE increments
--     instead of inserting, so the client keeps firing carelessly and the
--     database stays the thing that makes it correct.
--
-- (c) COST. Bounded at users x events x days. At today's ~40 accounts and the
--     5 events below that is at most 73,000 rows/year, and realistically far
--     less because nobody fires all 5 every day. Postgres does not notice
--     this. For scale: an analytics bucket does not start being the right
--     destination until roughly 5,000 active users, which would be ~9M
--     rows/year. Until then this table is cheaper AND joinable against
--     users/posts/photos in a single query, which a bucket is not.
--
-- What the day bucket gives up: session-level analysis. You get "photos on
-- days when they shot", not "photos per session", and no session length. For
-- a camera opened a few times a day that is arguably the more meaningful
-- number anyway, and it is the entire cost of (a).
--
-- ------------------------------------------------------------
-- NUTRITION LABEL: unchanged.
-- ------------------------------------------------------------
-- FLIM already declares Usage Data > Product Interaction, linked to identity,
-- for activation_events. Daily counts of the same in-app actions are the same
-- category, linked the same way. No new disclosure, no new consent prompt.
-- Verify against docs/PRIVACY.md before shipping; do not assume.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The table. Separate from activation_events on purpose: that table's
--    unique (user_id, event) IS its contract, and widening it to carry
--    repeats would break the guarantee ten call sites already rely on.
--
--    `day` is a DATE in UTC. Not the user's local day: FLIM has no timezone
--    column, and inventing one to make buckets prettier would collect
--    location-adjacent data to improve a chart. Retention over weeks is
--    unaffected by a few hours of boundary skew.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.usage_events (
    user_id     UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    event       TEXT NOT NULL,
    day         DATE NOT NULL DEFAULT (now() AT TIME ZONE 'utc')::date,
    -- Not called `count`: that is a function name, and a column sharing it makes
    -- every later query ambiguous to read even where it parses.
    occurrences INT  NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, event, day),
    CONSTRAINT usage_events_event_check CHECK (event IN (
        -- The retention backbone. Everything in question 1 and 2 comes from
        -- this one event; the rest are here to make the answer actionable.
        'app_open',
        -- Volume. Separates "opens it" from "uses it".
        'photo_captured',
        -- Conversion. A capture that never reaches the feed is a different
        -- product problem from never capturing.
        'post_shared',
        -- The lurker signal: opened the feed, shot nothing. This is the one
        -- that tells you whether the 20-upload cap or the camera is the
        -- friction, and activation_events cannot see it at all.
        'feed_viewed',
        -- Is the reveal actually the hook the product bets on? Fires on every
        -- reveal, not just the first, which is the whole point.
        'reveal_watched'
    ))
);

-- Cohort/retention queries filter by day across all users, so day leads.
CREATE INDEX IF NOT EXISTS usage_events_day_event_idx ON public.usage_events (day, event);

-- ------------------------------------------------------------
-- 2. RLS. Same posture as activation_events: append-only, owner-read.
--    No UPDATE policy is granted to anyone, so the increment in section 3
--    is only reachable through the SECURITY DEFINER function, never by a
--    client crafting its own UPDATE to inflate or zero its numbers.
-- ------------------------------------------------------------
ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "usage_events: owner reads" ON public.usage_events;
CREATE POLICY "usage_events: owner reads"
    ON public.usage_events FOR SELECT TO authenticated
    USING (public.is_owner());

-- Note there is deliberately NO insert policy for `authenticated`. Unlike
-- activation_events, nothing writes here except log_usage_event() below, which
-- is SECURITY DEFINER and therefore bypasses RLS. Granting a direct insert
-- would let a client write any count it liked. Verified directly against a
-- non-superuser role holding Supabase's stock default table grants (SELECT/
-- INSERT/UPDATE/DELETE): a forged INSERT of occurrences = 999999 is rejected
-- outright by RLS ("new row violates row-level security policy"), and a
-- forged UPDATE against an existing row affects 0 rows. Only log_usage_event()
-- can move this table.

-- ------------------------------------------------------------
-- 3. log_usage_event. Same carelessness contract as log_activation_event:
--    no-ops when signed out, rejects an unknown event loudly via CHECK, and
--    is safe to call on every single occurrence.
--
--    The ON CONFLICT increment is what makes "fire on every app open" cost one
--    row per user per day instead of one row per open.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_usage_event(p_event TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN;
    END IF;

    -- The existing row is referenced as `usage_events`, unqualified: ON CONFLICT
    -- DO UPDATE binds the target by the name used in the INSERT, and schema-
    -- qualifying it here is a syntax error.
    INSERT INTO public.usage_events (user_id, event, occurrences)
    VALUES (auth.uid(), p_event, 1)
    ON CONFLICT (user_id, event, day)
    DO UPDATE SET occurrences = usage_events.occurrences + 1;
END;
$$;

-- ------------------------------------------------------------
-- 4. Grants. Same as activation_events: this project carries the stock
--    Supabase default privileges, which GRANT EXECUTE on new FUNCTIONS to
--    anon and authenticated at creation time, and REVOKE FROM PUBLIC alone
--    does not remove anon's own named grant. authenticated-only, never anon.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.log_usage_event(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_usage_event(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_usage_event(TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 5. Backfill, from evidence that already exists. Same discipline as the
--    activation backfill: real historical dates, never now(), and nothing
--    invented where no evidence exists.
--
--    DERIVED (months of real history, available immediately):
--      photo_captured <- public.photos, one row per user per day, counted
--      post_shared    <- public.posts,  same
--      reveal_watched <- public.roll_reveal_views, same
--
--    NOT DERIVED, because nothing has ever recorded either:
--      app_open    <- no launch or session has ever been written down. This
--                     is the retention backbone, so RETENTION CURVES START
--                     EMPTY and need ~4 weeks of real traffic before the
--                     week-2 column means anything. Volume history is
--                     immediate; retention history is not. Do not read the
--                     first fortnight's curve as a finding.
--      feed_viewed <- likewise. A post's existence proves someone wrote, never
--                     that anyone read.
-- ------------------------------------------------------------
INSERT INTO public.usage_events (user_id, event, day, occurrences)
SELECT user_id, 'photo_captured', (taken_at AT TIME ZONE 'utc')::date, COUNT(*)
FROM public.photos
GROUP BY user_id, (taken_at AT TIME ZONE 'utc')::date
ON CONFLICT (user_id, event, day) DO NOTHING;

INSERT INTO public.usage_events (user_id, event, day, occurrences)
SELECT user_id, 'post_shared', (created_at AT TIME ZONE 'utc')::date, COUNT(*)
FROM public.posts
GROUP BY user_id, (created_at AT TIME ZONE 'utc')::date
ON CONFLICT (user_id, event, day) DO NOTHING;

INSERT INTO public.usage_events (user_id, event, day, occurrences)
SELECT user_id, 'reveal_watched', (viewed_at AT TIME ZONE 'utc')::date, COUNT(*)
FROM public.roll_reveal_views
GROUP BY user_id, (viewed_at AT TIME ZONE 'utc')::date
ON CONFLICT (user_id, event, day) DO NOTHING;


-- ============================================================
-- THE QUERIES THIS BUYS. Paste into the SQL editor as the owner.
-- Cohort-scoped throughout: docs/METRICS.md already records that an
-- uncohorted funnel is invalid, because someone who signed up yesterday
-- has not had the chance to fail week 2 yet.
-- ============================================================

-- ---- Q1. Week-N retention by signup cohort ---------------------------------
-- The number that decides whether to open the invite list. Read DOWN a column
-- (does week 2 hold across cohorts), not across a row.
WITH cohorts AS (
    SELECT id, date_trunc('week', created_at)::date AS cohort_week
    FROM public.users
),
activity AS (
    SELECT DISTINCT c.id, c.cohort_week,
           FLOOR((u.day - c.cohort_week) / 7)::int AS week_n
    FROM public.usage_events u
    JOIN cohorts c ON c.id = u.user_id
    WHERE u.event = 'app_open' AND u.day >= c.cohort_week
)
SELECT c.cohort_week,
       COUNT(DISTINCT c.id) AS cohort_size,
       COUNT(DISTINCT a.id) FILTER (WHERE a.week_n = 1) AS wk1,
       COUNT(DISTINCT a.id) FILTER (WHERE a.week_n = 2) AS wk2,
       COUNT(DISTINCT a.id) FILTER (WHERE a.week_n = 3) AS wk3,
       COUNT(DISTINCT a.id) FILTER (WHERE a.week_n = 4) AS wk4
FROM cohorts c
LEFT JOIN activity a ON a.id = c.id
GROUP BY c.cohort_week
ORDER BY c.cohort_week;

-- ---- Q2. How often, for people who came back at all -------------------------
-- Active days out of 7. Median, not mean: one heavy user drags a mean and
-- METRICS.md already records that trap for storage.
SELECT t.wk::date AS week,
       COUNT(DISTINCT t.user_id) AS active_users,
       ROUND(AVG(t.days), 1) AS mean_active_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.days) AS median_active_days
FROM (
    SELECT user_id, date_trunc('week', day) AS wk, COUNT(DISTINCT day) AS days
    FROM public.usage_events WHERE event = 'app_open'
    GROUP BY user_id, date_trunc('week', day)
) t
GROUP BY t.wk
ORDER BY week DESC;

-- ---- Q3. Shooters vs lurkers -----------------------------------------------
-- Of the people who opened FLIM this week, how many pressed the shutter, and
-- how many of those actually shared. The two drop-offs are different problems:
-- opened-but-never-shot is a camera or friction problem, shot-but-never-shared
-- is a confidence or reveal problem.
SELECT date_trunc('week', day)::date AS week,
       COUNT(DISTINCT user_id) FILTER (WHERE event = 'app_open')       AS opened,
       COUNT(DISTINCT user_id) FILTER (WHERE event = 'photo_captured') AS shot,
       COUNT(DISTINCT user_id) FILTER (WHERE event = 'post_shared')    AS shared
FROM public.usage_events
GROUP BY date_trunc('week', day)
ORDER BY week DESC;

-- ---- How the app uses this --------------------------------------------------
--
-- App (signed-in user, fire-and-forget, safe to call every time):
--   SELECT log_usage_event('app_open');
--
-- There is no analogue of activation_funnel() here: the three queries above
-- are ad hoc SQL editor queries, not an RPC, because they take arguments
-- (cohort window, week count) that don't have one obviously right default.
