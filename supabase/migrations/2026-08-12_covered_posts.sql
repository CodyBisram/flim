-- ============================================================
-- COVERED POSTS: a bounded set of posts hidden from everyone except their
-- authors and the owner. Paste into Supabase Dashboard -> SQL Editor and run.
-- Safe to re-run.
--
-- This is deliberately NOT a mutual seal between the three named accounts
-- and everyone else. It does not touch accounts, follows, comments,
-- reactions, Discover, or search, and it does not seal the three authors off
-- from anything: their own feeds, who they can see, and who can see them
-- (outside the covered posts themselves) are completely unaffected. It
-- restricts exactly one thing: who can SEE a bounded set of POSTS.
--
-- WHAT THIS DOES
-- --------------
-- Three named accounts (seeded by USERNAME at the bottom of this file, not
-- hardcoded into any function or policy body): alyssa, ashley, day.
-- A "covered post" is a post authored by one of the three with
-- created_at inside a stored [window_start, window_end) range for that
-- author (seeded below as 2026-08-12 00:00:00 through 2026-08-19 23:59:59.999
-- America/New_York). A covered post is readable ONLY by:
--   * its author,
--   * either of the other two named accounts (symmetric: each of the three
--     can see all three's covered posts, not merely their own), or
--   * the owner (public.is_owner, tested by uuid so it composes inside a
--     two-argument visibility predicate the same way is_blocked_either_way(a, b)
--     already does elsewhere in this schema).
-- Everyone else gets nothing back for a covered post: not the row, and not
-- the photo bytes in Storage.
--
-- ONE EXCEPTION, and it is not a hole. If a covered post's photo came from a
-- SHARED ROLL, the roll's other members can still see that photo, because
-- "photos: roll members can see" grants it on roll membership alone and knows
-- nothing about posts. That is the roll working as designed: those people were
-- already looking at that photograph in the roll before it was ever posted, so
-- hiding the POST takes nothing away from them and reveals nothing new. What
-- they lose is its placement in the feed and on the author's profile, which is
-- what this rule is for. Anyone NOT in that roll still gets nothing.
--
-- Checked against production when this was written: none of the covered posts
-- came from a roll, and none of the three authors shared a roll with anyone
-- outside the allowed set, so the exception was not reachable at all.
--
-- Posts by the same three authors OUTSIDE the
-- window are completely unaffected (still public to every signed-in user,
-- same as today). Posts by anyone else are completely unaffected.
--
-- THIS IS NOT AN EXPIRY. The window selects WHICH posts are covered by
-- comparing each post's own created_at against fixed, stored bounds; nothing
-- in this file compares the window to now(). A covered post found today
-- stays covered a year from now, five years from now, forever, until the
-- `active` flag below is explicitly turned off. Do not "fix" this later by
-- adding a `window_end < now()` clause anywhere; that would silently
-- republish a week of these three people's posts on a timer, which is
-- exactly the failure mode this file exists to avoid.
--
-- THIS DOES NOT SEAL THE THREE ACCOUNTS. Nothing here touches
-- is_blocked_either_way, public.profiles, "users: profiles readable", or any
-- table besides public.posts and storage.objects. The three authors'
-- Discover, search, follow graph, and everyone else's ability to see THEIR
-- non-covered posts are all exactly as before. Do not extend this file to
-- restrict what the three can see (a mutual seal, where the three also stop
-- seeing everyone outside the three); that is a different, explicitly
-- unrequested feature and was deliberately not built here.
--
-- HOW
-- ---
-- 1. public.covered_post_windows (user_id PK, window_start, window_end,
--    active): membership AND the window are DATA, not literals baked into a
--    policy body. RLS is ON with NO policies, deny-all to every client role,
--    same shape as allowed_emails. The only doors in are the SECURITY
--    DEFINER helpers below; the only door out (for you) is the Dashboard SQL
--    editor / service role.
-- 2. public.is_owner(p_user UUID): created here defensively with
--    CREATE OR REPLACE rather than assumed to already exist, so this file
--    has no ordering dependency on any other migration having run first and
--    stays fully standalone. If some other migration has already created an
--    identically-defined overload, this CREATE OR REPLACE is a no-op on an
--    identical body; if the body ever diverges, this is the definition that
--    wins the moment this file runs.
-- 3. public.post_is_covered(p_author UUID, p_created_at TIMESTAMPTZ): TRUE
--    only when p_author has an ACTIVE row in covered_post_windows whose
--    window contains p_created_at. STABLE, SECURITY DEFINER (must bypass
--    covered_post_windows' own deny-all RLS to be callable from the posts/
--    storage policies at all, same reason is_blocked_either_way and
--    is_roll_member are definer functions). With every row's active = FALSE,
--    or an empty table, this always returns FALSE.
-- 4. public.covered_post_visible(p_viewer UUID, p_author UUID,
--    p_created_at TIMESTAMPTZ): the one predicate both policies below add.
--    TRUE when the post isn't covered at all, OR the viewer is the owner, OR
--    the viewer is themselves one of the three (any active row in
--    covered_post_windows, regardless of whose post it is — this is what
--    makes visibility symmetric among the three rather than each only
--    seeing their own). STABLE, SECURITY DEFINER, same reasoning.
-- 5. "posts: readable by authenticated" (public.posts) and "photos: readable
--    when shared to a post" (storage.objects) each get ONE new clause,
--    AND-ed onto their existing body: "AND public.covered_post_visible(...)".
--    Everything else in both policies (NOT hidden, NOT
--    is_blocked_either_way(...)) is reproduced byte-for-byte from current
--    production (schema.sql:1317-1319 and schema.sql:1387-1396) so this file
--    is a complete, correct standalone redefinition, not a diff that assumes
--    some other migration already ran.
--
-- WHY BOTH POLICIES, NOT JUST posts
-- ----------------------------------
-- Verified in a scratch Postgres 15 in Docker (see the completion report):
-- because "photos: readable when shared to a post" is a plain EXISTS
-- subquery against public.posts, NOT a SECURITY DEFINER function call, it is
-- already subject to public.posts' own RLS for the querying role — a hidden
-- covered post's row already fails to match that subquery even before this
-- file's clause is added. That means there is NOT a leak strictly requiring
-- a fix here. This file adds the same clause to the storage policy anyway,
-- for two reasons: (1) it is the existing convention in this exact policy,
-- which already re-derives NOT hidden and NOT is_blocked_either_way
-- explicitly instead of relying on that same implicit RLS propagation
-- (schema.sql:1384-1386 says so directly: "mirrors 'posts: readable by
-- authenticated' above"); (2) relying solely on implicit subquery RLS
-- propagation is a load-bearing assumption about how Postgres composes
-- policies across tables, correct today and verified in Docker, but a single
-- future change to how that subquery is written (e.g. moved behind a
-- SECURITY DEFINER helper for performance, as several other photo-read
-- policies in this schema already are) would silently reopen the bytes
-- without touching this file at all. Being explicit here costs one clause
-- and removes that dependency entirely.
--
-- WHAT THIS DELIBERATELY DOES NOT TOUCH
-- --------------------------------------
-- * post_comments, post_reactions, post_tags, comment_likes: a covered
--   post's comments/reactions/tags are NOT separately hidden by this file.
--   The task scope is posts only ("comments and reactions elsewhere stay
--   visible"). A covered post is hidden as a row, so its own comment thread
--   is unreachable through the app's normal navigation (you can't open a
--   post you can't see), but a comment_id/photo_id held or guessed
--   independently is a separate surface this file does not touch.
-- * public.get_suggested_emoji(uuid[]) (schema.sql, "the reveal gate"): this
--   SECURITY DEFINER function independently re-implements the same "EXISTS a
--   post row ... NOT hidden ... NOT is_blocked_either_way" shape this file
--   edits, but bypasses posts' RLS by construction (SECURITY DEFINER) and
--   is NOT edited here. A caller who already knows a covered post's photo_id
--   can still retrieve that photo's suggested-emoji array through this RPC
--   even though the post row and its bytes are hidden. This is flagged, not
--   fixed: the task's explicit scope was "posts... photos: readable when
--   shared to a post... and the storage.objects photo-read policies," and
--   silently expanding into a third, unrelated RPC was judged out of scope
--   for this change. Worth a follow-up if the three's covered posts should
--   not leak even their suggested emoji.
--
-- ROLLBACK: switches off with exactly one statement, no other change needed.
-- Every predicate this file added evaluates back to its pre-migration value
-- (TRUE, unconditionally) the instant no row in covered_post_windows has
-- active = TRUE, because post_is_covered short-circuits to FALSE:
--
--     UPDATE public.covered_post_windows SET active = FALSE;
--
-- VERIFICATION: run against a scratch Postgres 15 in Docker (trimmed mocks
-- of auth.uid()/public.users/public.blocks/public.posts/storage.objects from
-- this repo's schema.sql, plus is_blocked_either_way reproduced unedited).
-- Confirmed: clean apply from empty, clean re-apply (idempotent DDL,
-- ON CONFLICT DO UPDATE that refreshes the window but does not clobber a
-- manually-flipped `active`), the full visibility matrix (outsider, each of
-- the three authors, the owner) crossed with (before-window / in-window /
-- after-window post by the same covered author), a non-covered author's
-- posts completely unaffected in every case, the active = FALSE rollback
-- restoring every case to its pre-migration result, and — the one this file
-- most needed to prove — moving the harness clock to 2027 and 2030 and
-- confirming an in-window covered post from 2026-08-12 stays hidden from an
-- outsider at both dates (it is not an expiry). See the completion report
-- for the exact transcript.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Owner exemption, created defensively; see header point 2.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_owner(p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users
        WHERE id = p_user
          AND lower(email) = lower('codyysb@gmail.com')
    );
$$;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner(uuid) TO authenticated;

-- ------------------------------------------------------------
-- Membership + window, as data. One row per covered author. `active` is the
-- single-statement kill switch (see ROLLBACK above); `window_start`/
-- `window_end` are fixed timestamps compared only against a POST's own
-- created_at, never against now() — see the header's "THIS IS NOT AN EXPIRY".
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.covered_post_windows (
    user_id      UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    window_start TIMESTAMPTZ NOT NULL,
    window_end   TIMESTAMPTZ NOT NULL,
    active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    CHECK (window_end > window_start)
);

ALTER TABLE public.covered_post_windows ENABLE ROW LEVEL SECURITY;
-- No policies -> deny-all to every client role (anon, authenticated), same
-- shape as allowed_emails. Readable only through the SECURITY DEFINER
-- helpers below; writable only via the SQL editor / service role.

-- ------------------------------------------------------------
-- TRUE only when p_author has an ACTIVE covered_post_windows row whose
-- [window_start, window_end) contains p_created_at.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_is_covered(p_author UUID, p_created_at TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.covered_post_windows w
        WHERE w.user_id = p_author
          AND w.active
          AND p_created_at >= w.window_start
          AND p_created_at <  w.window_end
    );
$$;
REVOKE ALL ON FUNCTION public.post_is_covered(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_is_covered(uuid, timestamptz) TO authenticated;

-- ------------------------------------------------------------
-- The one predicate both read policies below add. FALSE only when the post
-- IS covered AND the viewer is neither the owner nor one of the three
-- (symmetric: presence in covered_post_windows with active = TRUE is enough,
-- regardless of which of the three authored THIS particular post).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.covered_post_visible(p_viewer UUID, p_author UUID, p_created_at TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        NOT public.post_is_covered(p_author, p_created_at)
        OR public.is_owner(p_viewer)
        OR EXISTS (
            SELECT 1 FROM public.covered_post_windows w
            WHERE w.user_id = p_viewer AND w.active
        );
$$;
REVOKE ALL ON FUNCTION public.covered_post_visible(uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.covered_post_visible(uuid, uuid, timestamptz) TO authenticated;

-- ------------------------------------------------------------
-- posts: readable by authenticated. Byte-for-byte the current production
-- body (schema.sql:1317-1319: NOT hidden AND NOT is_blocked_either_way(...))
-- plus one AND-ed clause.
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "posts: readable by authenticated" ON public.posts;
CREATE POLICY "posts: readable by authenticated"
    ON public.posts FOR SELECT TO authenticated
    USING (
        NOT hidden
        AND NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND public.covered_post_visible(auth.uid(), user_id, created_at)
    );

-- ------------------------------------------------------------
-- photos: readable when shared to a post (storage.objects). Byte-for-byte
-- the current production body (schema.sql:1387-1396) plus the same clause,
-- keyed off the POST's author/created_at (po.user_id, po.created_at), not
-- the underlying photo row's. See header "WHY BOTH POLICIES".
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "photos: readable when shared to a post" ON storage.objects;
CREATE POLICY "photos: readable when shared to a post"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'photos'
        AND EXISTS (SELECT 1 FROM public.posts po
                    WHERE storage.objects.name IN (po.storage_path, po.thumb_path, po.feed_path)
                      AND NOT po.hidden
                      AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
                      AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at))
    );

-- ------------------------------------------------------------
-- Seed: by USERNAME, case-insensitive, FAILS LOUD (aborts this entire
-- transaction, including every DDL statement above) unless it resolves
-- EXACTLY three distinct accounts. Re-running this file is safe: the window
-- bounds are refreshed on conflict, but `active` is left alone on conflict
-- so re-running this file after you've manually flipped the kill switch off
-- does not silently turn covered posts back on.
-- ------------------------------------------------------------
DO $$
DECLARE
    v_ids UUID[];
    v_row RECORD;
BEGIN
    SELECT array_agg(id ORDER BY id) INTO v_ids
    FROM public.users
    WHERE lower(username) IN (lower('alyssa'), lower('ashley'), lower('day'));

    IF v_ids IS NULL OR array_length(v_ids, 1) IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION
            'covered-post seed aborted: expected exactly 3 distinct users for usernames alyssa/ashley/day, resolved %. Nothing in this migration was committed.',
            COALESCE(array_length(v_ids, 1), 0)
            USING ERRCODE = 'P0001';
    END IF;

    RAISE NOTICE 'covered-post seed: resolved % distinct member(s), review before trusting this run:', array_length(v_ids, 1);
    FOR v_row IN
        SELECT id, username FROM public.users WHERE id = ANY(v_ids) ORDER BY username
    LOOP
        RAISE NOTICE '  % -> %', v_row.username, v_row.id;
    END LOOP;

    INSERT INTO public.covered_post_windows (user_id, window_start, window_end, active)
    SELECT unnest(v_ids),
           TIMESTAMPTZ '2026-08-12 00:00:00-04',
           TIMESTAMPTZ '2026-08-20 00:00:00-04',
           TRUE
    ON CONFLICT (user_id) DO UPDATE
        SET window_start = EXCLUDED.window_start,
            window_end   = EXCLUDED.window_end;
        -- `active` intentionally NOT in the SET list: preserves a manual
        -- rollback (UPDATE ... SET active = FALSE) across re-runs of this file.
END $$;

COMMIT;

-- Preview query: run this FIRST, before the file above, to eyeball the exact
-- three accounts it will resolve without writing anything:
--   SELECT id, username, email FROM public.users
--   WHERE lower(username) IN ('alyssa','ashley','day') ORDER BY username;
--
-- Post-run verification:
--   SELECT u.username, w.window_start, w.window_end, w.active
--   FROM public.covered_post_windows w
--   JOIN public.users u ON u.id = w.user_id
--   ORDER BY u.username;
--
-- Spot-check which posts are actually covered right now:
--   SELECT p.id, u.username, p.created_at
--   FROM public.posts p
--   JOIN public.users u ON u.id = p.user_id
--   WHERE public.post_is_covered(p.user_id, p.created_at)
--   ORDER BY u.username, p.created_at;
--
-- Rollback (switch off, restores exactly prior behavior, no other change):
--   UPDATE public.covered_post_windows SET active = FALSE;
