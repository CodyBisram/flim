-- ============================================================
-- Close the covered-posts gap in public.get_suggested_emoji(uuid[]).
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- THE GAP
-- -------
-- get_suggested_emoji is SECURITY DEFINER, so it bypasses posts' RLS by
-- construction. Its third branch (the "reveal gate" comment above it in
-- schema.sql) independently re-implements "is there a visible post sharing
-- this photo" as its own EXISTS over public.posts, testing po.hidden and
-- is_blocked_either_way, but it was written before covered posts existed
-- (supabase/migrations/2026-08-12_covered_posts.sql) and was never taught
-- about them. "posts: readable by authenticated" and "photos: readable when
-- shared to a post" both gained a public.covered_post_visible(...) clause on
-- 2026-08-12; this function did not, and was flagged as a known gap in that
-- file's own header at the time ("This is flagged, not fixed"). Net effect:
-- a caller who already holds a covered post's photo_id (e.g. cached from
-- before the post was covered, or guessed) could still call
-- get_suggested_emoji([that id]) and get back its suggested-emoji array,
-- even though the post row and the photo bytes are hidden from them by both
-- RLS policies.
--
-- THE FIX
-- -------
-- One added clause, AND-ed onto the existing EXISTS in the third
-- (post-sharing) branch only: public.covered_post_visible(auth.uid(),
-- po.user_id, po.created_at) — the exact predicate the posts/storage
-- policies already use, keyed off the POST's author and created_at (a
-- covered post is defined by ITS author and timestamp, not the underlying
-- photo's owner, which can differ when a roll-mate re-shares someone else's
-- shot). Calling the existing helper rather than re-deriving the covered-
-- post rule a third time is deliberate: a third independent copy of the
-- same logic is exactly how this drifted the first time.
--
-- The other two branches (photo-owner, roll-member) are byte-for-byte
-- unchanged. Covered posts do not restrict what a photo's own owner can see
-- of their own photo, and the roll-member branch is not about posts at all
-- (see 2026-08-12_covered_posts.sql's header, "ONE EXCEPTION, and it is not
-- a hole": roll membership already grants photo visibility independent of
-- any post, and that exception is unaffected here on purpose).
--
-- Function signature, security context (SECURITY DEFINER), STABLE marking,
-- search_path, and grants are all unchanged.
--
-- PER-ROW, NOT ALL-OR-NOTHING
-- ---------------------------
-- p_photo_ids is an array; the WHERE clause (including this new predicate)
-- runs once per candidate row of the s/p join, same as every other
-- condition already in this function. A mixed array containing one covered
-- photo's id and one ordinary photo's id returns exactly one row (the
-- ordinary photo's), not zero rows and not an error: the covered photo's
-- row simply fails its own WHERE evaluation and is silently absent, exactly
-- like every other "not visible" case this function already produces
-- (wrong id, undeveloped roll-mate's photo, blocked party, hidden photo).
--
-- auth.uid() INSIDE SECURITY DEFINER
-- -----------------------------------
-- SECURITY DEFINER changes whose privileges the function body runs with
-- (bypassing RLS as the function owner), not which session is asking.
-- auth.uid() reads the calling request's JWT claim regardless of the
-- function's security context; that is what already made the photo-owner
-- and roll-member branches correct, and covered_post_visible(auth.uid(),
-- ...) here composes exactly the same way the posts/storage policies use
-- it. Verified directly in the Docker harness below (the outsider,
-- covered-author, and owner cases all pivot correctly on auth.uid()).
--
-- PERFORMANCE
-- -----------
-- Added cost per candidate row: one call to covered_post_visible(uuid, uuid,
-- timestamptz), which is itself STABLE, SECURITY DEFINER, and does at most
-- one indexed lookup on covered_post_windows (PK on user_id) via
-- post_is_covered, short-circuited entirely (post_is_covered/is_owner never
-- evaluated) by the OR when the viewer is already one of the covered
-- authors — cheap in the common case where covered_post_windows has three
-- rows total. This runs only inside the third branch's EXISTS, i.e. only
-- for photo ids that already matched a post row on photo_id, not for every
-- id in p_photo_ids and not for ids resolved by the cheaper photo-owner
-- branch first (SQL OR short-circuiting means the EXISTS subquery is not
-- even evaluated once the photo-owner branch already matched). On the
-- feed's hot path, where the overwhelming majority of requested ids belong
-- to non-covered posts, the added predicate is one extra cheap boolean
-- function call per row already being evaluated, not a new join, no new
-- index required.
--
-- OTHER SECURITY DEFINER FUNCTIONS CHECKED FOR THE SAME GAP
-- -----------------------------------------------------------
-- Enumerated every SECURITY DEFINER function in schema.sql and checked
-- whether it re-implements post or photo visibility:
--   * is_email_allowed, redeem_invite: allowlist/invite gate, no post/photo
--     visibility logic.
--   * is_roll_member, is_roll_developed: roll membership/timing only, no
--     post visibility.
--   * auto_hide_reported (trigger): writes photos.hidden/posts.hidden on
--     report threshold, does not read/return post or photo rows to a client.
--   * delete_account: cascades a delete, does not return content.
--   * get_own_profile: returns the caller's own users row only, no
--     post/photo join.
--   * is_owner(), is_owner(uuid): membership check only.
--   * post_is_covered, covered_post_visible: these ARE the covered-post
--     primitives; correct by definition.
--   * is_blocked_either_way: boolean relationship check, no post/photo
--     content returned.
--   * block_severs_follows (trigger): follows only.
--   * register_device_token, request_invite, log_activation_event: no
--     post/photo visibility involved.
--   * list_invite_requests, approve_invite_request, decline_invite_request,
--     list_photo_reports, list_user_reports, set_photo_hidden,
--     dismiss_photo_report, dismiss_user_report, list_feedback,
--     dismiss_feedback, activation_funnel (both overloads): every one of
--     these opens with `IF NOT public.is_owner() THEN RETURN/RAISE`, i.e.
--     gated to the owner only. covered_post_visible already exempts the
--     owner unconditionally (is_owner(p_viewer) short-circuits it to TRUE),
--     so even list_photo_reports surfacing a covered post's photo_id and
--     reason to the owner is not a gap: the owner is allowed to see every
--     covered post already, by the same rule these RPCs would need to add.
--   * list_orphaned_photos_objects: revoked from anon AND authenticated,
--     callable only by service_role (the storage sweep), not reachable by
--     any signed-in client at all.
--   * set_photo_suggested_emoji: write path, restricted to
--     `WHERE id = p_photo_id AND user_id = auth.uid()`, i.e. you can only
--     set suggestions on your own photo; not a visibility read of anyone
--     else's content.
--   * mark_developed_photos, app_release_gate_touch_updated_at: not
--     SECURITY DEFINER, not relevant.
-- get_suggested_emoji was the only one with the gap. No other instance
-- found.
--
-- VERIFICATION: run against a scratch Postgres 15 in Docker (trimmed mocks
-- of auth.uid()/public.users/public.photos/public.posts/
-- public.photo_suggested_emoji/public.covered_post_windows from this
-- repo's schema.sql, plus is_roll_member, is_blocked_either_way,
-- post_is_covered, covered_post_visible reproduced unedited). Confirmed:
-- an ordinary (non-covered) post's photo still returns its suggestion to an
-- outsider exactly as before; a covered post's photo returns nothing to an
-- outsider; the same covered photo returns the suggestion to each of the
-- three covered authors (not just its own author) and to the owner; a
-- mixed array of one covered id + one ordinary id returns exactly the one
-- permitted row, not zero rows and not an error. See the completion report
-- for the exact transcript.
--
-- ROLLBACK: re-run 2026-08-14's prior CREATE OR REPLACE (this file again
-- with the added AND clause removed) or drop the whole function back to the
-- 2026-08-12 body; no data was written by this change, only a function
-- definition.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_suggested_emoji(p_photo_ids UUID[])
RETURNS TABLE (photo_id UUID, suggested_emoji TEXT[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT s.photo_id, s.suggested_emoji
    FROM public.photo_suggested_emoji s
    JOIN public.photos p ON p.id = s.photo_id
    WHERE s.photo_id = ANY(p_photo_ids)
      AND NOT p.hidden
      AND (
            p.user_id = auth.uid()
            OR (
                p.roll_id IS NOT NULL
                AND public.is_roll_member(p.roll_id)
                AND NOT public.is_blocked_either_way(auth.uid(), p.user_id)
                AND p.develops_at <= now()
              )
            OR EXISTS (
                SELECT 1 FROM public.posts po
                WHERE po.photo_id = p.id
                  AND NOT po.hidden
                  AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
                  AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
              )
          );
$$;

-- Grants unchanged; restated because CREATE OR REPLACE FUNCTION does not
-- reset an existing function's grants, but this keeps the file a complete,
-- standalone redefinition independent of what already ran.
REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_suggested_emoji(UUID[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_suggested_emoji(UUID[]) TO authenticated;
