-- ============================================================
-- Finish the owner-identity fix: the three remaining lower(email) comparisons
-- Paste into Supabase Dashboard -> SQL Editor and run, or apply via the
-- Management API. Safe to re-run (every statement is idempotent).
--
-- BACKGROUND
-- ----------
-- 2026-08-29_close_users_privilege_escalation.sql re-pointed is_owner() /
-- is_owner(uuid) at the owner's immutable auth id
-- (f43287d4-f239-415b-af45-650bbee62e83) instead of
-- lower(email) = lower('codyysb@gmail.com'), because `email` was, at the
-- time, a client-writable column: any signed-in user could PATCH their own
-- row's email to the owner's and have is_owner() return TRUE for them. That
-- migration deliberately left three OTHER call sites resolving "the owner"
-- the same email-comparison way, on the reasoning that none of the three
-- grants privilege (worst case is a wrong push recipient or a wrong
-- auto-follow target, not an escalation), and an urgent security fix should
-- stay minimal. This migration is that documented follow-up
-- (docs/PENDING.md, "other places that resolve the owner by email"):
--
--   1. public.auto_follow_owner() (this file, schema.sql): resolves the
--      owner to build every new signup's auto-follow row.
--   2. supabase/functions/send-social-push/index.ts: resolves the owner to
--      find their push tokens (report notifications) and, separately, to
--      build the covered-posts allowed-viewer set.
--   3. supabase/functions/send-daily-digest/index.ts: resolves the owner
--      for the same covered-posts allowed-viewer set.
--
-- Layer 1's column-scoped grants (2026-08-29) already stop `email` from
-- being client-writable going forward, which independently narrows all
-- three of the above. This migration removes the assumption itself instead
-- of relying on that narrowing holding forever: three copies of "trust
-- email" already proved to be one too many.
--
-- WHY A NEW public.owner_user_id() RATHER THAN CALLING is_owner(uuid)
-- --------------------------------------------------------------------
-- is_owner(uuid) answers "is this the owner", not "who is the owner": it
-- has no return value to resolve a token or a viewer-set from. It is also
-- GRANTed to `authenticated` only (anon revoked, by design, since it gates
-- admin RPCs). send-social-push and send-daily-digest run under the
-- SERVICE ROLE key (supabase-js against PostgREST as the `service_role`
-- Postgres role, not `authenticated`), so calling is_owner(uuid) from them
-- would require widening its grant to a role that has no business touching
-- an authenticated-only admin gate, for a function that isn't even the
-- right shape for what they need.
--
-- Rather than paste the pinned UUID a fourth, fifth and sixth time (once
-- more in this file's trigger, once in each edge function), this migration
-- adds ONE new function, public.owner_user_id(), that returns the same
-- constant is_owner()/is_owner(uuid) already compare against, and rewrites
-- is_owner()/is_owner(uuid) themselves to call it instead of repeating the
-- literal. That leaves exactly one place in the whole codebase spelling out
-- f43287d4-f239-415b-af45-650bbee62e83: this function's body. Every other
-- caller (is_owner(), is_owner(uuid), the auto-follow trigger, and both edge
-- functions via RPC) reads it from there.
--
-- owner_user_id() carries no privilege by itself (it returns an identifier,
-- not a boolean gate), and that identifier is already trivially discoverable
-- by any authenticated client today: every account auto-follows the owner
-- at signup (see auto_follow_owner below), and "follows: readable by
-- authenticated" already lets any signed-in user read every row of
-- public.follows, owner's following_id included. Even so, nothing actually
-- needs `anon` to call it (no unauthenticated Swift call path exists, and
-- both edge functions run as `service_role`), so anon is revoked here the
-- same as every other signed-in-only RPC in this schema, on general
-- least-privilege grounds rather than because holding it back was load
-- bearing. It is plain SECURITY INVOKER SQL (no DEFINER clause, no
-- search_path pin needed): it touches no table and dereferences nothing
-- that depends on the caller's privileges.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- The single pinned owner constant. Same UUID 2026-08-29 pinned into
-- is_owner()/is_owner(uuid); f43287d4-f239-415b-af45-650bbee62e83,
-- signup_ordinal 1, per the owner. See that migration's LAYER 2 comment for
-- why id beats email here.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
    SELECT 'f43287d4-f239-415b-af45-650bbee62e83'::uuid;
$$;
REVOKE ALL ON FUNCTION public.owner_user_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.owner_user_id() FROM anon;
GRANT EXECUTE ON FUNCTION public.owner_user_id() TO authenticated, service_role;

-- ------------------------------------------------------------
-- is_owner() / is_owner(uuid): same signatures, same grants as
-- 2026-08-29 (STABLE, SECURITY DEFINER, search_path pinned, anon revoked);
-- only the body changes, to read the constant from owner_user_id() instead
-- of repeating the literal.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() = public.owner_user_id();
$$;
REVOKE ALL ON FUNCTION public.is_owner() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner() TO authenticated;

CREATE OR REPLACE FUNCTION public.is_owner(p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_user = public.owner_user_id();
$$;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner(uuid) TO authenticated;

-- ------------------------------------------------------------
-- auto_follow_owner(): resolve the owner from owner_user_id() instead of
-- lower(email). Behaviour preserved exactly, including the two early-return
-- guards documented in schema.sql's "Auto-follow the owner at signup" block:
--   * no owner row on this environment yet -> RETURN NEW before attempting
--     the INSERT (now an explicit EXISTS check, since owner_user_id() always
--     returns the constant whether or not that row exists here, unlike the
--     old SELECT ... LIMIT 1 which naturally returned NULL in that case);
--   * the row being inserted IS the owner's own account -> RETURN NEW before
--     attempting the INSERT, same as before.
-- The EXCEPTION WHEN OTHERS backstop is unchanged and would still catch this
-- FK case if the EXISTS check above were ever removed, but the check is kept
-- explicit rather than relying on that backstop, matching this function's
-- existing style of failing early rather than failing loud.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_follow_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner_id UUID := public.owner_user_id();
BEGIN
    IF NEW.id = v_owner_id THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_owner_id) THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.follows (follower_id, following_id)
    VALUES (NEW.id, v_owner_id)
    ON CONFLICT (follower_id, following_id) DO NOTHING;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.auto_follow_owner() FROM PUBLIC, anon, authenticated;

-- Trigger definition itself is unchanged (same function name, same table,
-- same timing), re-stated here only so this file fully replaces the old
-- trigger function body; DROP + CREATE keeps this idempotent the same way
-- every other trigger migration in this repo does it.
DROP TRIGGER IF EXISTS auto_follow_owner_trigger ON public.users;
CREATE TRIGGER auto_follow_owner_trigger
    AFTER INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.auto_follow_owner();

COMMIT;

-- ============================================================
-- Verify after running
-- ============================================================
--
-- 1. owner_user_id() resolves and matches is_owner()'s constant:
--
--   SELECT public.owner_user_id(); -- expect f43287d4-f239-415b-af45-650bbee62e83
--   SELECT public.is_owner(public.owner_user_id()); -- expect TRUE
--
-- 2. Grants: service_role and authenticated can call owner_user_id(); anon
--    cannot. Only authenticated can call is_owner()/is_owner(uuid):
--
--   SELECT grantee, privilege_type
--   FROM information_schema.routine_privileges
--   WHERE routine_schema = 'public' AND routine_name = 'owner_user_id';
--   -- expect: authenticated, service_role EXECUTE; no anon row
--
-- 3. auto_follow_owner unchanged behaviour: a fresh signup still gets a
--    follows row to the owner, and the owner's own signup does not try to
--    follow themselves:
--
--   -- (in a project where the owner row already exists)
--   SELECT following_id FROM public.follows WHERE follower_id = '<a recent signup id>';
--   -- expect: includes f43287d4-f239-415b-af45-650bbee62e83
-- ============================================================
