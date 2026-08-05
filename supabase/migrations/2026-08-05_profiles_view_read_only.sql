-- ============================================================
-- SECURITY FIX: public.profiles was writable by anyone
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- RUN THIS BEFORE THE NEXT APP RELEASE. It needs no client change and fixes a
-- hole that is open right now.
--
-- What was wrong
-- --------------
-- public.profiles is a view over public.users exposing only the safe columns
-- (id, username, avatar_path, bio, created_at, display_name, cover_path,
-- hidden_from_discovery). It exists because RLS is row-level and cannot hide
-- the email and invite_code COLUMNS, so `users` withholds SELECT from anon and
-- authenticated and the view is the door instead.
--
-- A view runs as its OWNER unless declared with security_invoker, so reads
-- through it bypass RLS on `users`. That is intended and load-bearing here.
--
-- The problem is that a single-table view like this is AUTO-UPDATABLE, so
-- WRITES through it also run as the owner and also bypass RLS. Supabase's
-- default privileges grant INSERT/UPDATE/DELETE to anon and authenticated on
-- every new object in the public schema, and the existing `GRANT SELECT ON
-- public.profiles` did not take those away.
--
-- Net effect: anyone holding the publishable key, which ships inside the app
-- binary and is trivially extractable, could
--
--     PATCH /rest/v1/profiles?id=eq.<any user id>
--
-- and rewrite that person's username, display name, bio, avatar or cover, or
-- DELETE their row outright (cascading to their photos, rolls and follows).
-- No login required. The "users: own row" policy never came into it, because
-- the view's owner is not subject to it.
--
-- Verified against production on 2026-08-05 with an unauthenticated PATCH
-- aimed at a UUID that does not exist: it returned 200 with an empty result,
-- not 403. The write was accepted and executed; it simply matched no row.
--
-- What this does
-- --------------
-- Takes the view back down to SELECT. Nothing in the app or the Edge Functions
-- has ever written through it: profile edits go to public.users, where the
-- "users: own row" policy (auth.uid() = id) correctly restricts them. So this
-- costs no functionality.
--
-- What this deliberately does NOT do
-- ----------------------------------
-- It does not add `security_invoker = true`, which is what Supabase's linter
-- asks for. That would break every profile read in the app, because the caller
-- has no SELECT privilege on public.users. Satisfying the linter properly means
-- granting column-level SELECT on users to authenticated and then flipping the
-- view, which is a larger change that needs testing, and which would also cut
-- anon off from profiles entirely. The linter finding stays, with this as the
-- mitigation: the property it flags is safe for reads and is now unreachable
-- for writes.
-- ============================================================

BEGIN;

-- Read only. REVOKE first: a bare GRANT SELECT does not remove the default
-- privileges that Supabase hands out on objects in the public schema.
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated, anon;

-- TRUNCATE is not subject to row level security, so "users: own row" does not
-- contain it. PostgREST cannot issue one, which is the only reason this was not
-- reachable, and that is too thin a thing to rely on.
REVOKE TRUNCATE ON public.users FROM anon, authenticated;

COMMIT;

-- Verify: profiles should show SELECT only for anon and authenticated.
--
--   select table_name, grantee,
--          string_agg(privilege_type, ',' order by privilege_type) as privs
--   from information_schema.role_table_grants
--   where table_schema = 'public'
--     and table_name in ('users','profiles')
--     and grantee in ('anon','authenticated')
--   group by table_name, grantee
--   order by table_name, grantee;
