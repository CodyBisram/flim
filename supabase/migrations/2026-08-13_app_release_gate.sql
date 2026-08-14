-- ============================================================
-- App version gate (single-row config table).
--
-- WHY: when 1.4 shipped, a server-side deploy had to be held back because
-- clients still on 1.3 would have received pushes for a feature their build
-- could not display. This table lets the client compare its own version
-- against `minimum_version` (hard block, no dismiss) and `latest_version`
-- (dismissible "update available" nudge), so future backend deploys don't
-- have to wait on every install upgrading first.
--
-- ⚠️⚠️⚠️  DANGER — THIS TABLE CAN BRICK EVERY INSTALL WITH ONE BAD VALUE  ⚠️⚠️⚠️
-- Setting `minimum_version` above a version that is actually running in the
-- wild locks out every user with no in-app recovery, including an App Store
-- reviewer testing a new submission. There is no client-side escape hatch by
-- design (that's what makes the hard block actually hold), so a mistake here
-- is a support fire, not a bug ticket.
--
-- THE RULE: `minimum_version` must never exceed a build that is already
-- APPROVED AND RELEASED on the App Store. Never a build that is merely
-- submitted, merely "In Review", or sitting in TestFlight. Apple's review
-- clock and phased rollout mean "submitted" and "live" can be days apart;
-- raising the floor before every existing install has had a chance to update
-- past it is exactly the bug this table exists to prevent, not commit.
--
-- OPERATIONAL SEQUENCE, always in this order:
--   1. Ship a build (increment `latest_version` once it is live, this is the
--      dismissible nudge and is safe to raise as soon as the build is out,
--      it never locks anyone out).
--   2. Wait for that build to actually be live on the App Store (not
--      "Pending Developer Release", not "In Review") and give installs real
--      time to update.
--   3. Only then, if a build's absence would actually break something
--      (e.g. a backend change the old build can't handle), raise
--      `minimum_version` to that build's version, and never higher than a
--      build you have already completed step 2 for.
--
-- This table starts INERT: both versions seeded at '0.0.0', below every real
-- build, so the gate does nothing until the owner deliberately raises a
-- value by hand. Never ship this pre-armed.
--
-- RLS: SELECT is open to `anon` AND `authenticated`. The gate must be
-- readable before sign-in, a blocked client can't be allowed to reach the
-- auth screen either, or the block is pointless. No policy grants any write;
-- the table is service-role-only for writes (see the explicit REVOKE below,
-- which strips the INSERT/UPDATE/DELETE Supabase's default privileges hand
-- `anon`/`authenticated` on every new `public` table at CREATE time, the
-- same class of hole closed for `public.profiles` on 2026-08-05 and
-- documented there).
--
-- Single-row-ness is structural, not conventional: `id BOOLEAN PRIMARY KEY
-- DEFAULT TRUE CHECK (id)` means `id` can only ever be TRUE, and TRUE is
-- already the primary key, so a second row is impossible, not just
-- discouraged. Same pattern as `redeem_invite_rate` / `invite_request_rate`.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.app_release_gate (
    id               BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),  -- single-row table
    minimum_version  TEXT NOT NULL DEFAULT '0.0.0',   -- below this: hard block
    latest_version   TEXT NOT NULL DEFAULT '0.0.0',   -- below this: dismissible nudge
    message          TEXT,                             -- optional custom line, NULL uses the app's default copy
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the single row INERT: both versions at '0.0.0', below any shipped build,
-- so a fresh apply of this file does nothing until the owner arms it by hand.
-- ON CONFLICT DO NOTHING so re-running this migration never stomps a value the
-- owner has since raised in production.
INSERT INTO public.app_release_gate (id, minimum_version, latest_version)
VALUES (TRUE, '0.0.0', '0.0.0')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.app_release_gate ENABLE ROW LEVEL SECURITY;

-- Readable pre-sign-in: a client must be able to fetch this row before it has
-- a session, so a build that's been hard-blocked never even reaches the auth
-- screen. TO anon, authenticated (not USING (true) with no role list) so the
-- grant is legible from the policy alone.
DROP POLICY IF EXISTS "app_release_gate: readable by anyone" ON public.app_release_gate;
CREATE POLICY "app_release_gate: readable by anyone"
    ON public.app_release_gate FOR SELECT
    TO anon, authenticated
    USING (true);

-- No INSERT/UPDATE/DELETE policy of any kind, on purpose: this table is
-- writable only by the service role (owner via the SQL editor, or a
-- service-role edge function), never by a client holding the publishable key.
--
-- The REVOKE is the load-bearing line, not the absence of a write policy.
-- Supabase's default privileges grant INSERT/UPDATE/DELETE (and SELECT) to
-- `anon`/`authenticated` on every new table in `public` at CREATE time, and a
-- bare `GRANT SELECT` does not take those away, RLS with no write policy
-- would still leave the grant sitting underneath, blocked only by RLS
-- evaluating to false on every row for those roles, one bad policy away from
-- being wide open. This project has hit that exact hole three times already
-- (see the `public.profiles` view comment in schema.sql for the production
-- instance of it). Verified in Docker below: explicitly REVOKE ALL first,
-- then GRANT only SELECT.
REVOKE ALL ON public.app_release_gate FROM anon, authenticated, PUBLIC;
GRANT SELECT ON public.app_release_gate TO anon, authenticated;

-- Keep `updated_at` honest without relying on every future manual UPDATE to
-- remember it, so the owner can always tell when the gate was last touched.
CREATE OR REPLACE FUNCTION public.app_release_gate_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;
-- Trigger functions are never client-callable directly (only fired by the
-- trigger machinery), strip EXECUTE the same way every other internal
-- function in this project does.
REVOKE ALL ON FUNCTION public.app_release_gate_touch_updated_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS app_release_gate_touch_updated_at ON public.app_release_gate;
CREATE TRIGGER app_release_gate_touch_updated_at
    BEFORE UPDATE ON public.app_release_gate
    FOR EACH ROW EXECUTE FUNCTION public.app_release_gate_touch_updated_at();
