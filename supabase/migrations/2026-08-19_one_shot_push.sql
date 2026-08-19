-- A ledger of one-off pushes, so a campaign can never reach the same person twice.
--
-- Every other push in FLIM is reactive: something happened, the person it happened to is told.
-- A one-off nudge has no such trigger, so nothing stops a second invocation of the same job from
-- buzzing everybody again. A push cannot be unsent, so the guard is a table rather than care.
--
-- Claimed BEFORE the send, not after. If the function dies mid-run the claimed row stays and that
-- person is skipped on a re-run: one missed nudge is a far better failure than a second one.
create table if not exists public.one_shot_push (
  campaign   text        not null,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  claimed_at timestamptz not null default now(),
  -- Null until APNs accepts it, so a run can be audited for what actually went out rather than
  -- what was attempted.
  sent_at    timestamptz,
  primary key (campaign, user_id)
);

-- Service role only. No client ever reads or writes this: it exists for edge functions, and RLS
-- with no policy denies everyone else by default.
alter table public.one_shot_push enable row level security;

comment on table public.one_shot_push is
  'One row per (campaign, person) for one-off push campaigns. Claimed before sending so a rerun cannot double-send.';
