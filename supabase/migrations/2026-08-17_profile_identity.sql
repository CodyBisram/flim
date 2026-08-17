-- ============================================================
-- Migration: profile identity (signup_ordinal, profile_badges RPC,
-- profile_film_stats RPC). Paste into Supabase Dashboard -> SQL Editor and
-- run. Safe to re-run.
-- ⚠️ run this BEFORE pushing the Swift client that reads signup_ordinal,
-- calls profile_badges, or calls profile_film_stats.
--
-- UI for this is being designed in parallel. This file owns schema, ordinal
-- assignment, and the two read RPCs only — no Swift is touched here.
--
-- Three independent pieces:
--   1. users.signup_ordinal   — a permanent "you are the Nth member" number.
--   2. profile_badges(uuid)   — earned-only achievement list, ritual not volume.
--   3. profile_film_stats(uuid) — frames shot / rolls developed / shooting since,
--      replacing follower/following counts on the profile.
-- ============================================================


-- ============================================================
-- PART 1: signup_ordinal
-- ============================================================
--
-- THE TENSION, STATED AND RESOLVED
-- ---------------------------------
-- Two race-free ways to hand out "you are the Nth member":
--
--   (a) A Postgres SEQUENCE (nextval()). Genuinely race-free — nextval() is
--       atomic and never blocks concurrent callers. Its defect: nextval() is
--       NOT transactional. If the INSERT that consumed a sequence value later
--       rolls back (a unique_violation on username, a constraint failure, a
--       client abort), that number is gone forever. The 9th person to ever
--       sign up could end up wearing "#11" because #9 and #10 were burned on
--       failed attempts. For a feature whose entire point is "this number
--       is you, permanently, unfakeably," a gap is a silent lie: the person
--       wearing #11 is not actually the 11th member.
--
--   (b) Serialize assignment behind a lock, scoped to the SAME transaction as
--       the row INSERT, and derive the next number from what is ACTUALLY
--       PERSISTED (MAX(signup_ordinal)+1) rather than from an external
--       generator. If that transaction rolls back, the row was never
--       created, so nobody ever "used" that number in the first place —
--       there is nothing to roll back, because the number was never handed
--       out independently of the row. Zero gaps, by construction, forever.
--       Its cost: every signup now serializes against a single lock, i.e.
--       concurrent signups queue instead of running in parallel.
--
-- DECISION: (b). FLIM is invite-only, has ~40 accounts total months into
-- existence, and a signup is a human doing onboarding, not a bulk import —
-- there has never been, and is not going to be, meaningful concurrent signup
-- load. The cost of (b) (a single global lock serializing INSERTs into
-- `users`) is invisible at this scale and remains cheap even after invites
-- open up. The cost of (a) — a low number that turns out not to actually
-- mean "the Nth member" — directly destroys the one property this feature
-- exists to sell. Permanence and correctness win over throughput that isn't
-- needed. Implemented below as a BEFORE INSERT trigger holding a single
-- pg_advisory_xact_lock for the duration of the inserting transaction.
--
-- A secondary, unprompted benefit of NOT using a raw SEQUENCE: there is no
-- separate sequence object to `setval()` past the backfilled max, which is
-- itself a classic footgun with SERIAL/IDENTITY backfills (forget the
-- setval and the very next signup collides with a backfilled row). Deriving
-- the next value from MAX(signup_ordinal) makes the backfill and the
-- trigger read from the same source of truth by construction.
--
-- READABILITY: signup_ordinal is meant to be public identity, the same way
-- username/avatar/bio already are. It is added to the exact two places the
-- app already exposes safe profile columns through — see
-- 2026-08-05_profiles_view_read_only.sql for why `public.profiles` runs with
-- the view owner's rights (NOT security_invoker, that would break every
-- profile read — do not "fix" that here) and why `users` carries a parallel
-- column-level SELECT grant for authenticated. signup_ordinal joins both
-- lists. It is NOT added to get_own_profile()'s column list because that
-- function already does `SELECT * FROM public.users`, so the new column
-- appears there automatically with no edit needed.
--
-- WRITABILITY: no client write path exists, or ever should. Assignment is
-- exclusively the BEFORE INSERT trigger below. The harder question is
-- UPDATE: `users: own row` is `FOR ALL ... USING/WITH CHECK (auth.uid() =
-- id)`, i.e. row-level, not column-level — Supabase's default privileges
-- grant table-level UPDATE on `users` to `authenticated` (only SELECT was
-- ever cut down to column-level, in the 2026-08-05 fix), and the app's own
-- AuthService already does plain `.update()` calls against this table for
-- bio/display_name/avatar_path/cover_path. Nothing stops a client from also
-- PATCHing `signup_ordinal` in that same request today. A second trigger
-- (BEFORE UPDATE) pins the column to its OLD value on every UPDATE,
-- unconditionally, regardless of what NEW carries or which role fired it —
-- this is what actually makes the number unfakeable, not just
-- "unassigned-by-the-client-normally." See its own comment below for the
-- documented manual-override escape hatch.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The column. Nullable at first ON PURPOSE: the backfill immediately
--    below needs to run against the real, currently-NULL rows before NOT
--    NULL is enforced. Both the backfill and the NOT NULL/UNIQUE step that
--    follows are safe to re-run — the backfill only ever touches rows still
--    missing a value, so a second run of this whole file is a no-op here.
-- ------------------------------------------------------------
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS signup_ordinal INT;

-- ------------------------------------------------------------
-- 2. Backfill EXISTING users, created_at ascending, id as a deterministic
--    tiebreaker for any exact-same-timestamp rows (ORDER BY created_at alone
--    is not guaranteed stable if two rows share a timestamp). Starts at 1.
--    Must run BEFORE the trigger in step 4 exists: the trigger derives the
--    next number from MAX(signup_ordinal), so if it started assigning
--    numbers to brand-new signups while older rows were still NULL, a new
--    signup could grab "#1" out from under the actual first member. Running
--    the backfill first, in the same transaction as everything else in this
--    file, closes that ordering hazard entirely.
-- ------------------------------------------------------------
WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
    FROM public.users
    WHERE signup_ordinal IS NULL
)
UPDATE public.users u
SET signup_ordinal = ranked.rn
FROM ranked
WHERE u.id = ranked.id;

-- ------------------------------------------------------------
-- 3. Lock it down: every row now has a value (the backfill above guarantees
--    it for a from-scratch run; a re-run finds zero NULLs and both
--    statements below are harmless no-ops). Enforced as a UNIQUE INDEX
--    rather than an ADD CONSTRAINT, matching this codebase's existing
--    idempotent-DDL convention (see activation_events_user_event_idx) —
--    Postgres has no ADD CONSTRAINT IF NOT EXISTS, and a unique index is the
--    same guarantee a UNIQUE constraint would give.
-- ------------------------------------------------------------
ALTER TABLE public.users ALTER COLUMN signup_ordinal SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_signup_ordinal_unique_idx ON public.users (signup_ordinal);

-- ------------------------------------------------------------
-- 4. Assignment, BEFORE INSERT. Overwrites NEW.signup_ordinal unconditionally
--    — even if a caller supplied one — so the server is the only source of
--    truth regardless of what a crafted INSERT body contains.
--
--    pg_advisory_xact_lock is transaction-scoped: it is acquired here and
--    released automatically at COMMIT or ROLLBACK of the inserting
--    transaction, so it can never deadlock or leak across requests. Because
--    it is held for the transaction's full lifetime, a second concurrent
--    signup's trigger blocks on the SAME lock until the first one finishes
--    (commit OR rollback) before it can read MAX(signup_ordinal) — that is
--    what makes two simultaneous signups structurally unable to observe the
--    same MAX and hand out the same number. hashtext() turns a fixed,
--    readable string into the lock's 32-bit key so this isn't a magic
--    unexplained integer.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_signup_ordinal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_next INT;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('public.users.signup_ordinal'));
    SELECT COALESCE(MAX(signup_ordinal), 0) + 1 INTO v_next FROM public.users;
    NEW.signup_ordinal := v_next;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.assign_signup_ordinal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS assign_signup_ordinal_trigger ON public.users;
CREATE TRIGGER assign_signup_ordinal_trigger
    BEFORE INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.assign_signup_ordinal();

-- ------------------------------------------------------------
-- 5. Immutability, BEFORE UPDATE. Pins signup_ordinal to its OLD value on
--    every UPDATE, unconditionally — this is what closes the client-PATCH
--    hole described in the header (table-level UPDATE on `users` is granted
--    to `authenticated`, and RLS is row-level, not column-level, so nothing
--    else in this schema stops a user from rewriting their own number).
--
--    This also blocks a legitimate manual correction from the SQL editor
--    (e.g. fixing a data-entry mistake), since triggers fire for every role,
--    including the dashboard's own connection. The documented escape hatch:
--        ALTER TABLE public.users DISABLE TRIGGER lock_signup_ordinal_trigger;
--        -- do the manual UPDATE
--        ALTER TABLE public.users ENABLE TRIGGER lock_signup_ordinal_trigger;
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lock_signup_ordinal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.signup_ordinal := OLD.signup_ordinal;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_signup_ordinal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lock_signup_ordinal_trigger ON public.users;
CREATE TRIGGER lock_signup_ordinal_trigger
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.lock_signup_ordinal();

-- ------------------------------------------------------------
-- 6. Expose it exactly where username/avatar/bio/etc. already are.
--
--    public.profiles: single-table view, columns appended at the END
--    (Postgres cannot reorder/rename existing view columns via CREATE OR
--    REPLACE VIEW; decode is by name in the app, so append-only order is
--    fine). Re-states REVOKE ALL / GRANT SELECT right after so this file is
--    a complete, standalone, correct redefinition — CREATE OR REPLACE VIEW
--    does not itself reset an existing view's grants (the view's OID is
--    unchanged), but restating them costs nothing and removes any
--    dependency on this file running after schema.sql rather than before it.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.profiles AS
    SELECT id, username, avatar_path, bio, created_at, display_name, cover_path,
           hidden_from_discovery, signup_ordinal
    FROM public.users;

REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated, anon;

-- public.users column-level grant (authenticated only — anon has never had
-- direct table access to `users`, only to the `profiles` view above, and
-- that is unchanged here).
GRANT SELECT (signup_ordinal) ON public.users TO authenticated;


-- ============================================================
-- PART 2 & 3: profile_badges / profile_film_stats
-- ============================================================
--
-- CROSS-CUTTING DECISIONS, made once here and applying to both functions:
--
-- * SECURITY DEFINER, callable about ANY profile by any authenticated
--   caller — this is the explicit design brief ("badges... callable by any
--   authenticated user about any profile"), and it deliberately bypasses the
--   normal roll-membership RLS boundary (rolls/roll_members/photos are
--   otherwise readable only by fellow members). That is a real, intentional
--   trade: a caller with no connection to a private roll can learn "this
--   profile earned two_up on 2026-08-03" even though they could never read
--   that roll's row directly. This is the same shape as signup_ordinal and
--   film stats: identity elements deliberately made public on the profile.
--   Flagged, not hidden.
--
-- * Covered posts (2026-08-12_covered_posts.sql) restrict who can see a
--   bounded set of POSTS. Neither function below reads public.posts at all
--   — every predicate is built from public.photos / public.rolls /
--   public.roll_members / public.roll_reveal_views only — so there is no
--   path by which either function can reveal a covered post's existence,
--   content, or timing to someone who cannot already see it. Verified by
--   inspection: grep the function bodies below for "posts" and find none.
--
-- * Blocks (public.blocks / is_blocked_either_way) gate POSTS, comments,
--   reactions and tags, never profile fields or roll data — `users:
--   profiles readable` is `USING (true)`, unconditionally, and rolls/
--   roll_members carry no block check either. hidden_from_discovery is a
--   Discover-suggestion filter the CLIENT applies; it does not restrict any
--   read path at the database layer. Both functions below match that
--   existing posture exactly: no block gate, no hidden_from_discovery gate.
--   This is parity with how the rest of the profile already behaves, not a
--   new hole — a blocked user's username/avatar/bio/signup_ordinal are
--   already fully readable today, and badges/stats join that same list.
--
-- * Counts never leak. profile_badges returns ONLY rows for badges actually
--   earned (never a row for an unearned badge, never the underlying count
--   that would let a caller back out "how close" someone is). Every SELECT
--   below is structured so a badge that isn't earned simply produces zero
--   rows, not a row with a null/zero earned_at.
--
-- * No volume badges. None of the four predicates below reward "did X N
--   times" for any N; each is a ritual/pattern check that is true or false
--   regardless of how many total photos the person has ever taken. This
--   matters concretely: FLIM caps uploads at 20/day and every photo costs
--   real Storage egress, so a badge that rewards raw count would be a
--   standing incentive to farm uploads against both limits.
-- ============================================================

-- ------------------------------------------------------------
-- Supporting index. photos_user_idx (user_id, taken_at DESC) and
-- photos_roll_idx (roll_id, develops_at DESC) already exist; neither serves
-- "this user's photos within this specific roll" well, which is the shape
-- both full_roll and two_up query below (and which profile_badges will now
-- run on every profile view, a genuinely new hot path). Partial on roll_id
-- IS NOT NULL since that's the only case either query ever hits.
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS photos_roll_user_idx
    ON public.photos (roll_id, user_id)
    WHERE roll_id IS NOT NULL;

-- ------------------------------------------------------------
-- profile_badges(p_profile_id): the list of EARNED badges only, each a
-- stable text id and the timestamp it was earned. Four badges, each with
-- its exact predicate and the judgment call behind it — the ones marked
-- "SANITY-CHECK THIS" are the ones with no single obvious definition and
-- need Cody's read before shipping.
--
-- Badges are computed LIVE from current data on every call, not written to
-- a persisted ledger. Three of the four (first_light, full_roll, two_up)
-- are checks against a specific past event and can never stop being true
-- once true — they are permanent by construction, exactly like
-- signup_ordinal. The fourth (darkroom) is defined cumulatively across
-- every roll the profile has ever been part of, which means it CAN
-- currently stop being true (join a new roll, skip that one reveal, and it
-- disappears until watched) — see that badge's own comment; this is called
-- out explicitly because a losable achievement is a real product decision,
-- not an oversight.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.profile_badges(p_profile_id UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- first_light: their first frame ever, full stop. Earned date = the
    -- date of that frame. Includes photos later hidden by moderation — this
    -- is a factual "you took a photo on this date" milestone, and moderation
    -- state governs whether OTHERS can see a photo, not whether it happened.
    RETURN QUERY
    SELECT 'first_light'::TEXT, MIN(p.taken_at)
    FROM public.photos p
    WHERE p.user_id = p_profile_id
    HAVING MIN(p.taken_at) IS NOT NULL;

    -- full_roll — SANITY-CHECK THIS. FLIM rolls have no fixed exposure count
    -- (unlike a physical 24/36-shot roll): a roll simply develops 12h after
    -- creation, whether it holds one photo or fifty. "Shot a roll through to
    -- completion rather than abandoning it" therefore has no photo-count
    -- definition that isn't an arbitrary, invented threshold — exactly the
    -- volume-proxy this feature is supposed to avoid.
    --
    -- Chosen instead: a WHEN-based definition. A roll they contributed to
    -- (1) actually reached its natural development (is_roll_developed), and
    -- (2) they shot into it on BOTH sides of its halfway point — at least
    -- once before roll.created_at + 6h, and at least once at or after it.
    -- This rewards staying with a roll across its whole life instead of
    -- dumping several shots in the first few minutes and never returning
    -- (the "abandoning" the badge name is contrasted against), and it costs
    -- nothing extra to satisfy with more photos — two photos, one on each
    -- side of the midpoint, qualifies exactly as much as twenty would.
    -- Earned date = the first of their photos taken at/after the midpoint
    -- (the moment the "didn't abandon it" condition became true), taking
    -- the EARLIEST such roll if they've done this more than once.
    RETURN QUERY
    SELECT 'full_roll'::TEXT, MIN(agg.earned_at)
    FROM (
        SELECT
            BOOL_OR(p.taken_at < r.created_at + INTERVAL '6 hours') AS shot_early,
            MIN(p.taken_at) FILTER (WHERE p.taken_at >= r.created_at + INTERVAL '6 hours') AS earned_at
        FROM public.rolls r
        JOIN public.photos p ON p.roll_id = r.id AND p.user_id = p_profile_id
        WHERE public.is_roll_developed(r.id)
        GROUP BY r.id, r.created_at
    ) agg
    WHERE agg.shot_early AND agg.earned_at IS NOT NULL
    -- The outer HAVING is load-bearing, not decorative: an aggregate query
    -- with no GROUP BY always returns exactly one row, even when the WHERE
    -- above filters `agg` down to zero rows (MIN() over an empty set is
    -- NULL, but it is still a row). Without this, an unearned full_roll
    -- would come back as (full_roll, NULL) instead of no row at all —
    -- caught by the Docker verification pass, see the completion report.
    HAVING MIN(agg.earned_at) IS NOT NULL;

    -- darkroom — SANITY-CHECK THIS, and read the whole comment before
    -- trusting the name. "Watched every reveal in a roll" cannot be built
    -- as a within-one-roll, percent-of-photos-seen predicate: RollService
    -- .recordRevealView() writes roll_reveal_views the moment the reveal
    -- OPENS (RollRevealViewModel.loadDeck), not when every photo in it has
    -- actually been viewed — this schema has no per-photo reveal-progress
    -- signal at all, in any table. Inventing a proxy for "watched to the
    -- end" (e.g. "stayed past N seconds") would be exactly that: invented,
    -- not derived, which the task brief says not to do.
    --
    -- What IS soundly provable: whether they ever skipped OPENING a reveal.
    -- Redefined at the cross-roll level: for every roll they were ever a
    -- MEMBER of that has since developed, do they have a matching
    -- roll_reveal_views row — i.e. across their whole roll history, they
    -- never skipped one. Requires at least one developed roll to exist at
    -- all (an account with zero rolls does not trivially earn this).
    -- Earned date = the most recent reveal they opened, i.e. "as of now,
    -- the streak is intact through this date" rather than a single fixed
    -- moment — see the function-level comment on why this one, alone among
    -- the four, can currently un-earn itself.
    RETURN QUERY
    SELECT 'darkroom'::TEXT, MAX(v.viewed_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    LEFT JOIN public.roll_reveal_views v
        ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
    WHERE rm.user_id = p_profile_id
      AND public.is_roll_developed(r.id)
    HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(v.viewed_at);

    -- two_up: was in a roll with exactly one other CONTRIBUTOR. Read
    -- "contributor" as "shot at least one photo into it," not "is a
    -- roll_member of it" — a roll can pick up silent members who never
    -- shoot, and the badge is about an intimate two-PERSON-SHOOTING roll,
    -- not a two-person invite list. Earned date = the moment the second
    -- distinct contributor's first photo landed (the instant the roll
    -- became a two-up rather than a solo roll), earliest such roll if more
    -- than one qualifies. Does not require the roll to have developed —
    -- "was in a roll with exactly one other contributor" is about who
    -- showed up, not whether the clock finished.
    RETURN QUERY
    SELECT 'two_up'::TEXT, MIN(t.earned_at)
    FROM (
        SELECT prc.roll_id, MAX(prc2.first_shot) AS earned_at
        FROM (
            SELECT roll_id, user_id, MIN(taken_at) AS first_shot
            FROM public.photos
            WHERE roll_id IS NOT NULL
            GROUP BY roll_id, user_id
        ) prc
        JOIN (
            SELECT roll_id, user_id, MIN(taken_at) AS first_shot
            FROM public.photos
            WHERE roll_id IS NOT NULL
            GROUP BY roll_id, user_id
        ) prc2 ON prc2.roll_id = prc.roll_id
        WHERE prc.user_id = p_profile_id
        GROUP BY prc.roll_id
        HAVING COUNT(*) = 2
    ) t
    -- Same reason as full_roll's outer HAVING above: without it, a profile
    -- with zero qualifying rolls gets one (two_up, NULL) row instead of none.
    HAVING MIN(t.earned_at) IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_badges(UUID) TO authenticated;

-- ------------------------------------------------------------
-- profile_film_stats(p_profile_id): frames shot, rolls developed, first
-- frame ever ("shooting since"). Replaces follower/following counts on the
-- profile by design — those can only ever look like failure on a new
-- account; these three numbers only ever go up (well: shooting_since never
-- moves once set, frames_shot and rolls_developed are monotonic).
--
-- frames_shot counts every photo the profile has ever taken, moderation-
-- hidden or not — same reasoning as first_light above: this is a private
-- fact about what they did, not a claim about what's currently visible to
-- others, and it reveals a count, never which photos.
-- rolls_developed counts DISTINCT rolls they personally shot into that have
-- since developed (not every roll they were merely a member of — this is
-- "rolls of film you shot," matching the badge's own reading of
-- "contributor" above for internal consistency).
-- shooting_since is NULL for an account with zero photos; the client should
-- simply not render the line rather than treating NULL as an error.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.profile_film_stats(p_profile_id UUID)
RETURNS TABLE (
    frames_shot     BIGINT,
    rolls_developed BIGINT,
    shooting_since  TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        COUNT(*)::BIGINT AS frames_shot,
        COUNT(DISTINCT p.roll_id) FILTER (
            WHERE p.roll_id IS NOT NULL AND public.is_roll_developed(p.roll_id)
        )::BIGINT AS rolls_developed,
        MIN(p.taken_at) AS shooting_since
    FROM public.photos p
    WHERE p.user_id = p_profile_id;
$$;

REVOKE ALL ON FUNCTION public.profile_film_stats(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_film_stats(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_film_stats(UUID) TO authenticated;


-- ---- How the app uses this --------------------------------------------------
--
-- Own or anyone's profile number, via the profiles view (anon+authenticated)
-- or the users column grant (authenticated), same as username/avatar/bio:
--   SELECT signup_ordinal FROM profiles WHERE id = '<uuid>';
-- Own full row (unchanged call, new column arrives automatically):
--   SELECT get_own_profile();
--
-- Earned badges for any profile (authenticated only):
--   SELECT * FROM profile_badges('<uuid>');
--   -- badge_id | earned_at
--
-- Film stats for any profile (authenticated only):
--   SELECT * FROM profile_film_stats('<uuid>');
--   -- frames_shot | rolls_developed | shooting_since
--
-- Manual signup_ordinal correction (owner only, SQL editor):
--   ALTER TABLE public.users DISABLE TRIGGER lock_signup_ordinal_trigger;
--   UPDATE public.users SET signup_ordinal = <n> WHERE id = '<uuid>';
--   ALTER TABLE public.users ENABLE TRIGGER lock_signup_ordinal_trigger;
