-- ============================================================
-- Migration: get_own_invites_sent() -- the caller's own invite history, for
-- the invite screen to show "you invited @handle, sent Aug 3, not joined yet"
-- style rows instead of a bare spent-count.
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Also folded into schema.sql in this same change,
-- immediately after get_own_invite_quota(), the RPC it is the natural sibling
-- of.
--
-- THE JOIN, REUSED, NOT REINVENTED
-- ----------------------------------------------------------------------
-- redeem_invite() (2026-07-15, rewritten 2026-08-29_invite_quota.sql) stamps
-- allowed_emails.note = 'invited_by:' || <inviter uuid> the moment a code is
-- redeemed, timestamped by allowed_emails.added_at. That note is the ONLY
-- durable link from an invitee's email back to who invited them anywhere in
-- this schema. 2026-08-18_good_company_ten.sql's badge predicate and
-- 2026-08-29_invite_earnback.sql's trigger both walk it; this RPC walks it a
-- third time, in the direction good_company already uses (given an inviter,
-- find their invitees), not the direction invite_earnback's trigger uses
-- (given an invitee, find their inviter).
--
-- Row source is `public.allowed_emails`, not `public.users`: an invite that
-- was redeemed but never followed by a signup must still show up (as a row
-- with handle = NULL), and allowed_emails is the only table with a row for
-- that email at all. `public.users` is then LEFT JOINed on, by email exactly
-- like 2026-08-18_good_company_ten.sql's canonical join
-- (`lower(u.email) = ae.email`; allowed_emails.email is already stored
-- lower-cased, see its table comment).
--
-- WHY EXACT-MATCH, NOT JUST "note ~ invited_by:<any uuid>"
-- ----------------------------------------------------------------------
-- credit_invite_earnback()'s regex, '^invited_by:<uuid-shape>$', exists there
-- because that trigger is handed a note and must extract WHICH uuid is
-- inside it without knowing it in advance. Here we already know exactly
-- which uuid we're looking for -- auth.uid(), the caller -- so the filter is
-- built by splicing that concrete value into the same anchored shape:
-- `ae.note ~ ('^invited_by:' || auth.uid()::text || '$')`. A uuid's text
-- form contains no regex metacharacters, so this is exact-string equality
-- anchored start-to-end, not a loose substring match; it cannot be tricked
-- by a hand-written note that merely CONTAINS the caller's uuid somewhere,
-- and it can never match a note belonging to a DIFFERENT inviter. This is
-- the same strict shape credit_invite_earnback() relies on, just pinned to
-- one concrete uuid instead of parsing an unknown one out.
--
-- NEVER RETURN AN EMAIL -- THIS IS THE WHOLE POINT OF allowed_emails HAVING
-- NO CLIENT POLICIES AT ALL
-- ----------------------------------------------------------------------
-- allowed_emails is reachable by clients ONLY through is_email_allowed() and
-- redeem_invite(), both of which return a bare boolean. This RPC is a new,
-- THIRD door into that table, and the one hard rule it must never break is
-- that `email` never crosses it in any form -- not raw, not lower-cased, not
-- masked, not hashed, nothing derived from it. The SELECT list below reads
-- only `u.username`, `ae.added_at`, and a boolean derived from `public.photos`;
-- `ae.email` is used solely in the JOIN and WHERE clauses, never projected.
-- An invitee who redeemed a code but has not yet created an account (no
-- matching `users` row) surfaces as `handle = NULL` -- their email is not
-- substituted, masked, or hinted at in any way; the row is otherwise
-- indistinguishable from "no invitee has this slot" to anything reading the
-- RPC's output.
--
-- ZERO PARAMETERS, PINNED TO auth.uid() -- NO SESSION MEANS ZERO ROWS
-- ----------------------------------------------------------------------
-- Same shape as get_own_profile() / get_own_invite_quota() /
-- account_inventory(): no argument exists that could ask for anyone else's
-- invite history. If auth.uid() is NULL (no session -- shouldn't happen
-- given the `authenticated`-only grant below, but PostgREST does not
-- guarantee that invariant against every possible caller), the regex splice
-- above evaluates to `ae.note ~ NULL`, which is NULL, which the WHERE clause
-- treats as false for every row -- zero rows back, no error. The explicit
-- `auth.uid() IS NOT NULL` guard below is redundant with that NULL
-- propagation but is spelled out anyway so the "no session -> zero rows, not
-- an error" contract does not silently depend on operator-precedence trivia
-- surviving a future edit.
--
-- ACCOUNT-DELETED AND WHY THAT'S FINE
-- ----------------------------------------------------------------------
-- If an invitee's account is later deleted, their `public.users` row is gone
-- (ON DELETE CASCADE from auth.users) but their `allowed_emails` row is not
-- -- that table has no FK to users, by design (same shape as
-- invite_earnbacks.inviter_id: a later deletion elsewhere can never cascade
-- away this audit trail). The LEFT JOIN on email simply stops matching, so
-- the row reverts to looking exactly like an invite that was redeemed but
-- never resulted in a signup: handle = NULL, activated = false. This is a
-- deliberate simplification, not a bug: it is impossible to show a deleted
-- account's handle without inventing a "ghost username" concept that exists
-- nowhere else in this schema, and showing "not joined yet" for someone who
-- joined-then-left is a defensible reading of the caller's current invite
-- roster (that invite slot is not delivering an active user right now).
--
-- BLOCKING -- MY READ: A BLOCKED/BLOCKING INVITEE'S HANDLE SHOULD STILL
-- SHOW, AND THIS FUNCTION DELIBERATELY DOES NOT CALL is_blocked_either_way()
-- ----------------------------------------------------------------------
-- Every existing is_blocked_either_way() call site in schema.sql gates an
-- ONGOING SOCIAL SURFACE: posts, comments, reactions, tags, roll photos, the
-- following list -- content or relationships another person can currently
-- see or act through. This RPC is neither: it is the caller's own,
-- backward-looking receipt of a completed transaction (a code they
-- generated, that someone else redeemed, at a specific past instant), scoped
-- so tightly that no argument can even point it at anyone but auth.uid().
-- Suppressing a row here would not hide the caller FROM the invitee or
-- protect the invitee's privacy -- it would falsify the caller's own invite
-- history, understating a real invite they sent and (if activated) a real
-- earn-back their account may have received, for a fact that has nothing to
-- do with whatever came between them later. The closest existing precedent,
-- invite_earnbacks.inviter_id, is likewise never filtered or unwound by a
-- later block, deletion, or any other subsequent event -- once true, it
-- stays true. Implemented as: no blocks/is_blocked_either_way reference
-- anywhere in this function. If this reasoning is wrong, the fix is one
-- added predicate (`AND NOT public.is_blocked_either_way(auth.uid(), u.id)`,
-- guarded for u.id IS NULL) -- not a rewrite.
--
-- PERFORMANCE
-- ----------------------------------------------------------------------
-- Called when the invite sheet opens, not in a loop, so this optimizes for
-- an obviously-correct query over a micro-optimized one -- but the one part
-- of it that scales with the caller's OWN invite count still avoids a scan:
-- `activated` is `EXISTS (SELECT 1 FROM public.photos p WHERE p.user_id =
-- u.id)`, a single index probe against `photos_user_idx (user_id, taken_at
-- DESC)` per invitee, not a count() or a join fan-out. For an invitee with
-- no `users` row yet, u.id is NULL, the EXISTS correlated subquery can never
-- match, and Postgres short-circuits it to false without touching the
-- `photos` table at all.
-- The outer scan, `allowed_emails` filtered by `note ~ ...`, is unindexed by
-- note (allowed_emails has no index on that column, same as
-- credit_invite_earnback()'s header already documents for the opposite
-- direction) -- accepted here for the same reason 2026-08-18's
-- good_company badge predicate accepts it: this runs once per caller
-- interaction, not once per photo insert forever.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_own_invites_sent()
RETURNS TABLE (
    handle    TEXT,
    sent_at   TIMESTAMPTZ,
    activated BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT
        u.username AS handle,
        ae.added_at AS sent_at,
        EXISTS (
            SELECT 1 FROM public.photos p WHERE p.user_id = u.id
        ) AS activated
    FROM public.allowed_emails ae
    LEFT JOIN public.users u ON lower(u.email) = ae.email
    WHERE auth.uid() IS NOT NULL
      AND ae.note ~ ('^invited_by:' || auth.uid()::text || '$')
    ORDER BY ae.added_at ASC;
$$;

REVOKE ALL ON FUNCTION public.get_own_invites_sent() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_invites_sent() TO authenticated;

-- ---- Verify -----------------------------------------------------------------
--
--   -- As a signed-in caller, via the RPC path (run through PostgREST /
--   -- Supabase client in the app, or `select * from get_own_invites_sent();`
--   -- against a session in the SQL editor's "Run as" if available):
--   SELECT * FROM public.get_own_invites_sent();
--
--   -- Sanity check server-side (service role; DOES bypass RLS, do not treat
--   -- this as what a client can see) that no email ever appears in the
--   -- function's own source or output shape:
--   SELECT prosrc FROM pg_proc WHERE proname = 'get_own_invites_sent';
