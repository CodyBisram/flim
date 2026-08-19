-- Two activation events for the notification permission decision.
--
-- The funnel could not answer a question it was asked on 2026-08-19: 42 accounts have
-- `camera_authorized` and only 25 hold a device token, so 17 people reached a working camera and
-- have no push channel. Whether they DECLINED or were NEVER ASKED is the difference between a
-- lost cause and 17 reachable people, and nothing server-side could tell them apart.
--
-- Three states, read off these two events:
--   notifications_authorized present            -> said yes
--   notifications_denied present, no authorized -> said no
--   NEITHER present                             -> never reached the prompt
--
-- That last one is why nothing is logged for `notDetermined`: the absence is the signal. The
-- prompt only fires from four places in the app (post-capture, an undeveloped roll, the settings
-- toggle, the primer), so a path that misses all four never asks at all.
--
-- Both can exist for one account. The unique index is on (user_id, event), so somebody who
-- declines and later turns notifications on in Settings ends up with both, and the timestamps say
-- which came first. That is a recovery worth being able to count.
alter table public.activation_events
  drop constraint if exists activation_events_event_check;

alter table public.activation_events
  add constraint activation_events_event_check check (event = any (array[
    'first_launch',
    'onboarding_finished',
    'camera_authorized',
    'camera_ready',
    'shutter_tapped',
    'first_shot',
    'notifications_authorized',
    'notifications_denied',
    'roll_created',
    'roll_joined',
    'invite_sent',
    'invite_redeemed',
    'post_shared',
    'reveal_watched'
  ]));
