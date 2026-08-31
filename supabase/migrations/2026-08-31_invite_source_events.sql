-- ============================================================
-- Migration: three source-tagged invite-share usage events.
-- Paste into Supabase Dashboard -> SQL Editor and run once. Idempotent.
--
-- `invite_sent` (activation_events) answers "has this account ever tried to invite
-- someone" — a one-time-per-user funnel milestone. It cannot answer WHICH surface
-- the share came from, because activation_events dedupes on (user_id, event) and
-- keeps only the first. To know whether the reveal's closing invite converts at all
-- against the profile sheet and the feed empty state — the experiment shipped this
-- week — the share needs a repeatable, per-surface signal, which is what
-- usage_events is for.
--
-- usage_events has no source column and its key is (user_id, event, day), so the
-- source lives in the event name: three events rather than one event plus a
-- dimension. Volume per surface is then `sum(occurrences) group by event`.
--
-- Only the CHECK constraint changes; log_usage_event and the RLS posture are
-- untouched. A client that logs one of these before this runs is rejected loudly
-- by the CHECK, exactly as an unknown event should be, so this must be applied
-- before the build that logs them ships.
-- ============================================================

ALTER TABLE public.usage_events DROP CONSTRAINT usage_events_event_check;

ALTER TABLE public.usage_events ADD CONSTRAINT usage_events_event_check CHECK (event IN (
    'app_open',
    'photo_captured',
    'post_shared',
    'feed_viewed',
    'reveal_watched',
    -- The invite share, by the surface it happened on. `invite_sent` still fires
    -- the once-ever funnel milestone alongside these; these carry the volume and
    -- the source the milestone cannot.
    'invite_shared_profile',
    'invite_shared_feed',
    'invite_shared_reveal'
));

-- ---- Verify -----------------------------------------------------------------
--   -- After the client ships and someone shares, which surface do invites come from:
--   select event, sum(occurrences) as shares, count(distinct user_id) as people
--   from public.usage_events
--   where event like 'invite_shared_%'
--   group by event order by shares desc;
