-- ============================================================
-- Migration: profile_chapters() + chapter_photos() go posted-only, on both
-- branches, for every viewer including the profile's own owner.
--
-- OWNER DECISION 2026-09-04: a chapter is what you shared. The two-branch
-- rule shipped by 2026-09-03_chapters.sql (own page counted every
-- DEVELOPED photo -- unposted and private roll shots included -- while
-- someone else's page counted only POSTED photos under the profile grid's
-- visibility) is retired. There is now exactly one rule, applied
-- identically regardless of who is asking: posted photos only, gated by
-- the exact same predicate "posts: readable by authenticated" already
-- enforces (not hidden, not blocked either way, not covered) -- the same
-- predicate FeedService.fetchUserPosts (the profile grid's own query)
-- relies on RLS to apply. shot_count now means posted shots for that
-- month; roll_count means distinct rolls among those posted shots
-- (previously it also picked up roll_id from private, never-posted roll
-- shots on the own-page branch).
--
-- SELF CASE, CONFIRMED NOT SPECIAL-CASED: covered_post_visible(viewer,
-- author, created_at) (schema.sql) is
--   NOT post_is_covered(author, created_at)
--   OR is_owner(viewer)
--   OR EXISTS (covered_post_windows WHERE user_id = viewer AND active)
-- When viewer = author and the post IS covered, post_is_covered(author,
-- ...) being true means an active covered_post_windows row exists with
-- user_id = author; the third disjunct's EXISTS clause, with viewer =
-- author, is checking that exact same row, so it is also true. The
-- predicate is TRUE for every covered post whose author is the viewer,
-- with no dependency on is_owner. is_blocked_either_way(viewer, author)
-- with viewer = author is always FALSE: public.blocks carries
-- CHECK (blocker_id <> blocked_id), so no row with blocker_id = blocked_id
-- can ever exist, let alone one matching a caller's own id on both sides.
-- A caller viewing their own page therefore always passes both checks
-- without any explicit self-case in the query body below -- confirmed,
-- not assumed.
--
-- WHAT STAYS THE SAME: return shapes (profile_chapters:
-- month_start/shot_count/roll_count/cover_paths/first_shot_at/
-- last_shot_at; chapter_photos: id/taken_at/thumb_path/feed_path/
-- storage_path/roll_id/roll_name), ordering (profile_chapters DESC by
-- month, chapter_photos ASC by taken_at within a month), cover selection
-- (up to 4 thumb paths, most recent first, COALESCE(thumb_path,
-- storage_path) fallback), the month boundary (taken_at shifted back 4
-- hours / FeedUnit.dayBoundaryHour before truncating to month, fixed at
-- UTC -- see 2026-09-03_chapters.sql's header for the full reasoning,
-- unchanged here), the 1000-row cap on chapter_photos, both functions'
-- grants (authenticated only; anon and PUBLIC revoked), SECURITY DEFINER,
-- and SET search_path = public. roll_id/roll_name on chapter_photos rows
-- still come from the photo joined by the post (posts does not
-- denormalize roll_id).
--
-- SECURITY DEFINER remains necessary: reading public.photos for roll_id,
-- for a viewer who is not that photo's owner or roll member, still needs
-- elevated rights (public.photos' own RLS would otherwise hide it). There
-- is no more an own-page branch whose elevated rights need a separate
-- auth.uid() = p_profile_id gate -- the query only ever reads rows that
-- already passed the exact same posts-visibility predicate RLS enforces
-- for every caller, so there is nothing left for elevated rights to leak.
-- ============================================================

CREATE OR REPLACE FUNCTION public.profile_chapters(p_profile_id UUID)
RETURNS TABLE (
    month_start   DATE,
    shot_count    INTEGER,
    roll_count    INTEGER,
    cover_paths   TEXT[],
    first_shot_at TIMESTAMPTZ,
    last_shot_at  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        -- Posted photos only, one rule for every viewer including the
        -- profile's own owner -- see header for why the self case needs
        -- no special handling. Joined to photos only for roll_id, which
        -- posts does not denormalize; the join is safe because the row is
        -- only reachable once the post itself has passed the visibility
        -- gate below.
        SELECT p.id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    ),
    bucketed AS (
        SELECT
            date_trunc('month', (taken_at - interval '4 hours') AT TIME ZONE 'utc')::date AS bucket_month,
            taken_at, roll_id, display_path
        FROM source
    ),
    ranked_covers AS (
        SELECT bucket_month, display_path,
               row_number() OVER (PARTITION BY bucket_month ORDER BY taken_at DESC) AS rn
        FROM bucketed
    )
    SELECT
        b.bucket_month,
        count(*)::integer,
        count(DISTINCT b.roll_id) FILTER (WHERE b.roll_id IS NOT NULL)::integer,
        COALESCE(
            (SELECT array_agg(rc.display_path ORDER BY rc.rn)
             FROM ranked_covers rc
             WHERE rc.bucket_month = b.bucket_month AND rc.rn <= 4),
            ARRAY[]::text[]
        ),
        min(b.taken_at),
        max(b.taken_at)
    FROM bucketed b
    GROUP BY b.bucket_month
    ORDER BY b.bucket_month DESC;
$$;

REVOKE ALL ON FUNCTION public.profile_chapters(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_chapters(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_chapters(UUID) TO authenticated;

-- chapter_photos(p_profile_id, p_month_start): same posted-only rule as
-- profile_chapters above, same month convention, ordered oldest-first so
-- a reveal-style player can step straight through the result set.
-- feed_path is the card-size rendition column; roll_name is resolved via
-- a LEFT JOIN on public.rolls so a personal (non-roll) shot returns NULL
-- rather than being excluded.
CREATE OR REPLACE FUNCTION public.chapter_photos(p_profile_id UUID, p_month_start DATE)
RETURNS TABLE (
    id           UUID,
    taken_at     TIMESTAMPTZ,
    thumb_path   TEXT,
    feed_path    TEXT,
    storage_path TEXT,
    roll_id      UUID,
    roll_name    TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH source AS (
        SELECT p.id, po.taken_at, po.thumb_path, po.feed_path, po.storage_path, p.roll_id
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE po.user_id = p_profile_id
          AND NOT po.hidden
          AND NOT public.is_blocked_either_way(auth.uid(), po.user_id)
          AND public.covered_post_visible(auth.uid(), po.user_id, po.created_at)
    )
    SELECT s.id, s.taken_at, s.thumb_path, s.feed_path, s.storage_path, s.roll_id, r.name
    FROM source s
    LEFT JOIN public.rolls r ON r.id = s.roll_id
    WHERE date_trunc('month', (s.taken_at - interval '4 hours') AT TIME ZONE 'utc')::date = p_month_start
    ORDER BY s.taken_at ASC
    LIMIT 1000;
$$;

REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chapter_photos(UUID, DATE) FROM anon;
GRANT EXECUTE ON FUNCTION public.chapter_photos(UUID, DATE) TO authenticated;

-- posts_user_taken_idx (2026-09-03_chapters.sql) already covers user_id +
-- taken_at for both functions above; nothing new needed here.
