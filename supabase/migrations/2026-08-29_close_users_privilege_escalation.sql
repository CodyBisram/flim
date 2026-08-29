-- ============================================================
-- SECURITY FIX: privilege escalation to owner via public.users
-- Paste into Supabase Dashboard -> SQL Editor and run, or apply via the
-- Management API. Safe to re-run (every statement is idempotent).
-- RUN THIS BEFORE THE NEXT APP RELEASE. It needs no client change and closes
-- a hole that is open right now, in production, against 51 real accounts.
--
-- THE HOLE
-- --------
-- information_schema.table_privileges showed `authenticated` AND `anon` both
-- holding TABLE-WIDE UPDATE, INSERT and DELETE on public.users (Supabase's
-- default "grant all on every new table in public" behaviour, never taken
-- back for this table the way it already was for SELECT — see
-- 2026-08-05_profiles_view_read_only.sql and the `GRANT SELECT (...)` line in
-- schema.sql). Column-level UPDATE was therefore open on EVERY column,
-- including `email`, `invite_code`, `invite_uses_remaining` and `id`.
--
-- The RLS policy "users: own row" is
--   FOR ALL USING (auth.uid() = id) WITH CHECK (auth.uid() = id)
-- which is a ROW-level restriction only. It happily permits an authenticated
-- user to update ANY COLUMN of their own row, because it was never asked to
-- restrict columns — that job was supposed to belong to grants, and the
-- grants were wide open.
--
-- public.is_owner() / public.is_owner(uuid) resolved the ENTIRE admin surface
-- (approve_invite_request, list_invite_requests, every admin_* analytics RPC,
-- the report queue, the covered-posts exemption) from `lower(email) =
-- lower('codyysb@gmail.com')` — a column the client could write.
--
-- EXPLOIT, confirmed by the owner against production: any signed-in user
-- issues
--   PATCH /rest/v1/users?id=eq.<self>   { "email": "codyysb@gmail.com" }
-- and is_owner() then returns TRUE for them. That grants approve_invite_request
-- (insert ANY email into allowed_emails — a total bypass of the invite-only
-- gate), list_invite_requests (raw emails of everyone who ever requested
-- access), and the rest of the admin/moderation/analytics surface. Separately,
-- the same table-wide grant let any user set their own invite_uses_remaining
-- to any number, or rewrite their own `id` outright.
--
-- The only BEFORE UPDATE trigger on public.users before this migration was
-- lock_signup_ordinal_trigger (2026-08-17_profile_identity.sql). It protects
-- exactly one column, signup_ordinal. Nothing protected email, invite_code,
-- invite_uses_remaining or id.
--
-- THE FIX — three independent layers, so a mistake in any one does not
-- reopen the hole:
--
--   1. Column-scoped grants replace the table-wide ones. Every client write
--      path to public.users was traced against Flim/Services/AuthService.swift
--      (read-only from this migration's side — no Swift file is touched):
--        UPDATE: username, display_name, bio, avatar_path, cover_path
--          (setUsername's fallback path ~L405, setDisplayName ~L435,
--           setBio ~L448, avatar upload ~L526, cover upload ~L553).
--        INSERT: id, email, username, invite_code, display_name
--          (setUsername's InsertUser struct at signup, ~L396-399; the caller
--           already holds a session at this point, so `anon` never needs
--           INSERT — only `authenticated` does).
--        DELETE: no client write path exists. Account deletion goes through
--          the SECURITY DEFINER public.delete_account() RPC, which deletes
--          the auth.users row; public.users cascades via its
--          `id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE`
--          FK, run with the FUNCTION OWNER's privileges regardless of what
--          `authenticated`/`anon` hold on public.users. DELETE is revoked
--          from both and re-granted to neither.
--      `displayed_badges` goes through the SECURITY DEFINER
--      `set_displayed_badges` RPC only — confirmed no direct client write
--      path exists — so it needs no grant here, same as before this fix.
--      `hidden_from_discovery` has no client write path either (only ever
--      read, e.g. Flim/Models/Social.swift's CodingKey and
--      FeedService.swift's ranking) — confirmed, no grant needed.
--
--   2. is_owner() and is_owner(uuid) are re-pointed at the owner's immutable
--      auth user id (f43287d4-f239-415b-af45-650bbee62e83, signup_ordinal 1,
--      per the owner) instead of a lower(email) comparison. This closes the
--      hole EVEN IF layer 1 above is ever undone: the INSERT path at signup
--      also accepts an arbitrary `email` (see the InsertUser struct above),
--      so column-scoping UPDATE alone still leaves a brand-new account able
--      to claim the owner's email on the way IN, before any UPDATE grant is
--      even relevant. `id` beats `email` here for three reasons `email`
--      never had: id is the PRIMARY KEY: it cannot collide, and after this
--      migration it cannot be changed by anyone, ever (layer 3 below). id is
--      pinned to auth.uid() by the "users: own row" RLS policy, so its
--      identity is exactly the identity Supabase Auth already vouches for.
--      And id is what every foreign key in this schema actually points at —
--      email was always ordinary, mutable, client-suppliable data wearing an
--      admin gate's clothes.
--        NOTE: this reverses the stated rationale in the no-arg is_owner()'s
--      original comment ("resolve against email... rather than pinning a
--      UUID that would go stale if the owner's row is ever recreated"). That
--      concern is real only if the owner's auth.users row is deleted and
--      re-created from scratch (a new signup gets a new id) — an event the
--      owner controls and would need to update this constant for regardless
--      of which column were chosen, whereas the email column being
--      client-writable is a hole ANY of the other 50 accounts can trigger
--      today, unilaterally, with one PATCH request. The trade is deliberate:
--      accept a manual update on the rare, owner-initiated event in exchange
--      for removing a live, universally-reachable escalation.
--
--   3. A new BEFORE UPDATE trigger, lock_users_privileged_columns_trigger,
--      as defence in depth against a FUTURE grant mistake re-opening this
--      exact door (which is precisely how it opened the first time — nobody
--      wrote `GRANT UPDATE ON public.users TO authenticated` on purpose,
--      Supabase's default schema privileges did it silently). It pins id,
--      email and invite_code to their OLD values on every UPDATE,
--      unconditionally — there is no legitimate path anywhere in this
--      codebase that changes any of the three after signup. It also pins
--      invite_uses_remaining, but NOT unconditionally: redeem_invite()
--      (decrement) and credit_invite_earnback() (increment) are live
--      SECURITY DEFINER functions that legitimately mutate it on every
--      redemption / every invitee's first photo. See the function body
--      comment for exactly how current_user distinguishes "a client updated
--      their own row directly" from "a trusted definer function is doing
--      this on the client's behalf" — and why this function must stay
--      SECURITY INVOKER (the default) for that distinction to mean anything.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- LAYER 1: column-scoped grants replace the table-wide ones.
-- REVOKE first: as 2026-08-05_profiles_view_read_only.sql's own note says, a
-- bare GRANT does not remove Supabase's default table-wide privileges — the
-- REVOKE has to run first, every time this file re-runs, to actually mean
-- anything.
-- ------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON public.users FROM anon, authenticated;

-- Signup only (AuthService.setUsername's InsertUser, ~L396-399). The caller
-- already holds a session before this INSERT runs, so `anon` never needs it.
GRANT INSERT (id, email, username, invite_code, display_name)
    ON public.users TO authenticated;

-- Every column the client legitimately updates directly, and nothing else.
-- displayed_badges goes through set_displayed_badges() (SECURITY DEFINER);
-- signup_ordinal, invite_uses_remaining, email, invite_code and id have no
-- direct-UPDATE client path at all, by design, and are not listed here.
GRANT UPDATE (username, display_name, bio, avatar_path, cover_path)
    ON public.users TO authenticated;

-- No DELETE grant to anyone: account deletion runs through the SECURITY
-- DEFINER public.delete_account() RPC (DELETE FROM auth.users), and
-- public.users.id's ON DELETE CASCADE FK removes the profile row with the
-- FUNCTION OWNER's privileges, independent of what authenticated/anon hold
-- on public.users directly.

-- ------------------------------------------------------------
-- LAYER 2: is_owner() / is_owner(uuid), re-pointed at the owner's immutable
-- auth id instead of a client-writable email column. Same signatures, same
-- grants as before (STABLE, SECURITY DEFINER, search_path pinned, anon
-- revoked) — only the body changes, so nothing else that calls either
-- overload needs to change.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() = 'f43287d4-f239-415b-af45-650bbee62e83'::uuid;
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
    SELECT p_user = 'f43287d4-f239-415b-af45-650bbee62e83'::uuid;
$$;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner(uuid) TO authenticated;

-- ------------------------------------------------------------
-- LAYER 3: defence in depth. Pins id/email/invite_code unconditionally
-- (no legitimate UPDATE path exists for any of them anywhere in this
-- codebase) and invite_uses_remaining conditionally (redeem_invite() and
-- credit_invite_earnback() legitimately mutate it).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_users_privileged_columns()
RETURNS TRIGGER
-- Deliberately SECURITY INVOKER (the default — no SECURITY DEFINER clause).
-- Do NOT add SECURITY DEFINER here "for consistency" with
-- lock_signup_ordinal_trigger. See the invite_uses_remaining branch below
-- for exactly why: SECURITY DEFINER would swap current_user to THIS
-- function's own owner for the whole of its execution, permanently masking
-- who actually issued the firing UPDATE, and silently turning that branch
-- into a no-op that never pins invite_uses_remaining again.
LANGUAGE plpgsql
AS $$
BEGIN
    -- id, email, invite_code: no legitimate UPDATE path exists anywhere in
    -- this codebase for any of the three. id is the auth.users-FK'd primary
    -- key. email and invite_code are written exactly once, at signup, by
    -- AuthService.setUsername's INSERT (see LAYER 1's grant above) and never
    -- touched again by any RPC or trigger. Pinned UNCONDITIONALLY —
    -- current_user does not matter for these three, because there is no
    -- role, trusted or not, that has a live reason to change them via a
    -- normal UPDATE statement.
    --
    -- A genuine one-off correction (e.g. a typo'd email, done by hand by the
    -- owner) follows the exact convention lock_signup_ordinal_trigger
    -- already documents for signup_ordinal:
    --   ALTER TABLE public.users DISABLE TRIGGER lock_users_privileged_columns_trigger;
    --   UPDATE public.users SET email = '...' WHERE id = '...';
    --   ALTER TABLE public.users ENABLE TRIGGER lock_users_privileged_columns_trigger;
    NEW.id          := OLD.id;
    NEW.email       := OLD.email;
    NEW.invite_code := OLD.invite_code;

    -- invite_uses_remaining is different: it IS legitimately mutated today,
    -- by two live SECURITY DEFINER functions — redeem_invite() (decrement,
    -- 2026-08-29_invite_quota.sql) and credit_invite_earnback() (increment,
    -- 2026-08-29_invite_earnback.sql) — so it cannot be pinned
    -- unconditionally without breaking both on every call.
    --
    -- current_user is what tells the two cases apart, and it only works
    -- because this function is SECURITY INVOKER (see above):
    --   * A direct PostgREST UPDATE from a signed-in client fires this
    --     trigger as `authenticated` (or, pre-auth, `anon`, though RLS's
    --     own-row check already blocks that case) — current_user during a
    --     SECURITY INVOKER trigger's execution is whatever role is actually
    --     driving the statement that fired it.
    --   * redeem_invite() and credit_invite_earnback() are SECURITY
    --     DEFINER, owned by this schema's function owner like every other
    --     definer function here. For the ENTIRE duration of their
    --     execution — including the `UPDATE public.users` statement inside
    --     their body, and any trigger that statement fires — current_user
    --     is their owner, not `authenticated`/`anon`.
    -- So this check distinguishes "a client updated their own row directly"
    -- from "a trusted server-side function is doing this on the client's
    -- behalf", independent of table/column GRANTs entirely. That
    -- independence is the whole point of this layer: even if some future
    -- migration re-grants table-wide or column-wide UPDATE on
    -- invite_uses_remaining to authenticated/anon by mistake — precisely how
    -- this hole existed the first time — a direct client write is still
    -- caught here and pinned back to OLD, while redeem_invite() and
    -- credit_invite_earnback() keep working completely unmodified.
    IF current_user IN ('anon', 'authenticated') THEN
        NEW.invite_uses_remaining := OLD.invite_uses_remaining;
    END IF;

    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_users_privileged_columns() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lock_users_privileged_columns_trigger ON public.users;
CREATE TRIGGER lock_users_privileged_columns_trigger
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.lock_users_privileged_columns();

COMMIT;

-- ============================================================
-- Verify after running
-- ============================================================
--
-- 1. Grants: authenticated should show only insert/update on the listed
--    columns, nothing on delete; anon should show NOTHING at all.
--
--   SELECT grantee, privilege_type, string_agg(column_name, ',' ORDER BY column_name) AS cols
--   FROM information_schema.column_privileges
--   WHERE table_schema = 'public' AND table_name = 'users'
--     AND grantee IN ('anon','authenticated')
--     AND privilege_type IN ('INSERT','UPDATE')
--   GROUP BY grantee, privilege_type
--   ORDER BY grantee, privilege_type;
--   -- expect: authenticated/INSERT -> display_name,email,id,invite_code,username
--   --         authenticated/UPDATE -> avatar_path,bio,cover_path,display_name,username
--   --         no anon rows at all
--
--   SELECT grantee, privilege_type
--   FROM information_schema.table_privileges
--   WHERE table_schema = 'public' AND table_name = 'users'
--     AND grantee IN ('anon','authenticated')
--     AND privilege_type IN ('INSERT','UPDATE','DELETE');
--   -- expect: zero rows (no bare table-wide grant survives; column-level
--   -- grants above appear in column_privileges, not here)
--
-- 2. is_owner(): should be TRUE only for the owner's own session, and must
--    now be TRUE regardless of what `email` currently holds on that row.
--
--   SELECT public.is_owner('f43287d4-f239-415b-af45-650bbee62e83'::uuid); -- expect TRUE
--   SELECT public.is_owner(gen_random_uuid());                            -- expect FALSE
--
-- 3. Trigger: attempting to move email/invite_code/id/invite_uses_remaining
--    away from OLD as a plain UPDATE (i.e. as `postgres`/service role in the
--    SQL editor, current_user NOT IN ('anon','authenticated')) should show
--    id/email/invite_code hold, and invite_uses_remaining move (proving the
--    conditional branch is not accidentally unconditional):
--
--   SELECT id, email, invite_code, invite_uses_remaining FROM public.users LIMIT 1; -- note the id
--   UPDATE public.users
--     SET email = 'should-not-stick@example.com', invite_uses_remaining = 999
--     WHERE id = '<that id>';
--   SELECT id, email, invite_code, invite_uses_remaining FROM public.users WHERE id = '<that id>';
--   -- expect: email UNCHANGED, invite_uses_remaining = 999 (this session is
--   -- not `anon`/`authenticated`, matching what redeem_invite()/
--   -- credit_invite_earnback() rely on). Revert the 999 by hand afterward.
--
-- 4. Regression: confirm the two live SECURITY DEFINER writers still work
--    after this migration —
--   SELECT public.redeem_invite('<a real, unspent code>', 'someone-new@example.com');
--   -- expect: TRUE, and the inviter's invite_uses_remaining decremented by
--   -- exactly 1 (not blocked by the new trigger).
-- ============================================================
