-- ============================================================
-- Migration: profile_chapters() + chapter_photos(), the data half of
-- Chapters (the profile's monthly recap: a shelf of month covers on the
-- profile, design 3a, and a per-month reveal-style playback, design 3b).
-- Paste into Supabase Dashboard -> SQL Editor and run, or deploy via the
-- Management API. Safe to re-run (CREATE OR REPLACE throughout).
--
-- MONTHS ARE COMPUTED, NOT STORED: a month "exists" for a profile purely
-- because photos.taken_at (own page) or posts.taken_at (someone else's
-- page) fall in it. There is no backfill table and no migration of
-- existing data -- every account that already has photos gets a shelf the
-- moment this function is live, and the current, still-running month is
-- included (LIVE AND GROWING, not gated on the month ending), all the way
-- back to a person's first shot (no cutoff).
--
-- VISIBILITY, the part that must be exactly right
-- ------------------------------------------------
-- Own page (p_profile_id = auth.uid()): every DEVELOPED photo the caller
-- shot that month, private roll shots included, undeveloped roll shots
-- excluded even from their own shooter. "Developed" is develops_at <=
-- now(), the same time-derived predicate the app uses everywhere else
-- (RollService.loadCovers's own comment: "Developed = develops_at has
-- passed, independent of the is_developed flag sync"; darkroom_month_summary
-- above computes developing_count the same way). is_sorted is
-- DELIBERATELY NOT checked: that flag only distinguishes whether a
-- personal instant has been swiped out of the Darkroom sort deck yet
-- (schema.sql's own comment: "Roll shots skip the deck (inserted
-- sorted)"), not whether it was shot or developed. A recap of "everything
-- you shot this month" should not omit a photo just because you have not
-- yet triaged it into Darkroom/Feed, and should not retroactively change
-- a past month's tally once you eventually do triage it either.
-- photos.hidden is also NOT checked on the own-page branch, matching
-- "photos: own photos" (schema.sql): a caller always sees their own
-- photos regardless of moderation state, hiding is about who ELSE sees a
-- post, never about the poster's own view of it.
--
-- Someone else's page: only what that person POSTED, with EXACTLY the
-- visibility "posts: readable by authenticated" already grants (schema.sql,
-- defined in the "Block enforcement" section): not hidden, not blocked
-- either way, not covered. That RLS policy is confirmed live as the
-- profile grid's actual server-side gate -- FeedService.fetchUserPosts
-- (the profile grid's own query) selects straight from `posts` filtered
-- only by user_id and hidden, relying on RLS for the blocked/covered
-- clauses -- so this reuses covered_post_visible(...) and
-- is_blocked_either_way(...), the SAME helper functions that policy
-- calls, rather than re-deriving the rule by hand. VISIBILITY SOURCE:
-- the "posts: readable by authenticated" RLS policy on public.posts.
--
-- Both functions run SECURITY DEFINER (needed for the someone-else branch,
-- which must read public.photos to pick up roll_id -- posts does not
-- denormalize it -- for a viewer who is not that photo's owner or roll
-- member, and public.photos' own RLS would otherwise hide it) and
-- reproduce the exact posts-visibility predicate in the query body rather
-- than depending on RLS being bypassed and re-applied implicitly. The
-- own-page branch is additionally gated by `auth.uid() = p_profile_id` in
-- its WHERE clause, so a definer's elevated rights can never be used to
-- read another account's private, un-posted photos; only their own.
-- auth.uid() IS NULL (no session) makes both UNION branches' WHERE
-- clauses evaluate to NULL/false, so an unauthenticated call (impossible
-- anyway once anon is revoked below) returns zero rows rather than
-- erroring.
--
-- MONTH BOUNDARY CONVENTION
-- -------------------------
-- Mirrors darkroom_month_summary's own bucketing rule as closely as this
-- function's fixed, already-agreed signature allows: taken_at shifted
-- back 4 hours (FeedUnit.dayBoundaryHour, the app's 04:00 local day
-- boundary) before truncating to month. It deviates on ONE axis:
-- darkroom_month_summary takes a client-supplied p_timezone and buckets
-- in the caller's own local zone; profile_chapters/chapter_photos take
-- only p_profile_id (the agreed Swift contract) and FLIM stores no
-- per-user timezone column by design (see schema.sql's usage_events
-- comment: "FLIM has no timezone column, and inventing one to make
-- buckets prettier would collect location-adjacent data"). Without a zone
-- to bucket in, both functions here fix the zone at UTC. For a user whose
-- local zone is far from UTC, a shot taken within a few hours of local
-- midnight near a month boundary can therefore land in a different month
-- on the profile shelf than it would in the Darkroom's own, locally-zoned
-- month view. This is a known, accepted deviation, not an oversight --
-- closing it for real would mean adding a timezone parameter to this
-- signature, which is out of scope for a change that must not move the
-- Swift contract already being built against.
--
-- COVER SELECTION
-- ---------------
-- Deliberately NOT mirroring darkroom_month_summary's rank/oldest-first
-- filmstrip: the Chapters contract is explicit that cover_paths is "up to
-- 4 thumb_path values, most recent first" (the shelf tile is a preview of
-- the month's latest activity, not a chronological filmstrip). Ties are
-- broken by taken_at DESC only; COALESCE(thumb_path, storage_path) is
-- used for the actual path (same fallback every other cover path in this
-- schema uses, for photos that predate the thumb_path column), even
-- though the contract calls the column "thumb_path values" -- an older
-- row's storage_path fallback beats returning a NULL array element.
--
-- CAP: chapter_photos is capped at 1000 rows (PostgREST would cap a
-- SETOF result anyway; this makes the cap explicit and independent of
-- PostgREST's default). No month is expected to approach that under
-- FLIM's roll/personal-instant volume; a client that ever needs more
-- pages from a single month.
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
        -- Own page: every developed photo the caller shot, private roll shots
        -- included, undeveloped roll shots excluded. See header for why
        -- is_sorted and photos.hidden are not checked here.
        SELECT p.id, p.taken_at, p.roll_id,
               COALESCE(p.thumb_path, p.storage_path) AS display_path
        FROM public.photos p
        WHERE auth.uid() = p_profile_id
          AND p.user_id = p_profile_id
          AND p.develops_at <= now()

        UNION ALL

        -- Someone else's page: only what they posted, gated by the exact same
        -- predicate as "posts: readable by authenticated" (schema.sql). Joined
        -- to photos only to pick up roll_id, which posts does not denormalize;
        -- the join is safe because the row is only reachable once the post
        -- itself has already passed the visibility gate below.
        SELECT p.id, po.taken_at, p.roll_id,
               COALESCE(po.thumb_path, po.storage_path) AS display_path
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE auth.uid() <> p_profile_id
          AND po.user_id = p_profile_id
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

-- chapter_photos(p_profile_id, p_month_start): one month's photos for
-- playback (design 3b), ordered oldest-first so a reveal-style player can
-- step straight through the result set. Same visibility split, same month
-- convention, as profile_chapters above -- see that function's header for
-- both. feed_path is the card-size rendition column (the same "mid-size
-- feed rendition" column already denormalized onto both photos and posts
-- elsewhere in this schema); there is no other candidate column for that
-- purpose. roll_name is resolved via a LEFT JOIN on public.rolls so a
-- personal (non-roll) shot returns NULL rather than being excluded.
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
        SELECT p.id, p.taken_at, p.thumb_path, p.feed_path, p.storage_path, p.roll_id
        FROM public.photos p
        WHERE auth.uid() = p_profile_id
          AND p.user_id = p_profile_id
          AND p.develops_at <= now()

        UNION ALL

        SELECT p.id, po.taken_at, po.thumb_path, po.feed_path, po.storage_path, p.roll_id
        FROM public.posts po
        JOIN public.photos p ON p.id = po.photo_id
        WHERE auth.uid() <> p_profile_id
          AND po.user_id = p_profile_id
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

-- New hot-path index: both functions above filter posts by user_id and
-- bucket/order by taken_at. posts_user_created_idx (schema.sql) covers
-- user_id + created_at, a different column, so this is a genuinely new
-- index rather than a duplicate.
CREATE INDEX IF NOT EXISTS posts_user_taken_idx ON public.posts (user_id, taken_at DESC);
