-- ============================================================
-- Migration: persist profile badges instead of recomputing them live, add
-- three more earned badges, and track whether their owner has SEEN each one.
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
--
-- ⚠️ ORDER: run supabase/migrations/2026-08-17_profile_identity.sql FIRST
-- (this file reads signup_ordinal, is_roll_developed, and reuses
-- photos_roll_user_idx, all defined there), THEN this file, BEFORE pushing
-- any Swift client that expects a badge to stay put once seen, reads
-- unseen_badge_count, calls mark_own_badges_seen, or calls
-- grant_badge/revoke_badge. Neither file has been applied to production
-- yet — this whole migration is still pre-deploy, so it is safe to keep
-- amending this ONE file in place rather than layering a second one on top.
--
-- AMENDS supabase/migrations/2026-08-17_profile_identity.sql. That file is
-- left untouched; this one is additive on top of it (new table, new
-- function bodies via CREATE OR REPLACE, no destructive changes to
-- anything it already created).
--
-- THE PROBLEM THIS FIXES
-- -----------------------
-- profile_badges(uuid) was STABLE and computed every badge fresh from
-- current data on every call. first_light and full_roll are checks
-- against a specific past event and were WRITTEN as permanent-by-
-- construction, but because nothing ever recorded the answer, "permanent"
-- only held as long as the underlying rows never changed shape: a
-- predicate that recounts a live aggregate at query time (rather than
-- pinning the specific instant it first became true) can retroactively
-- flip back to false as more data arrives, silently un-earning something
-- that genuinely already happened. Separately, even for a predicate that
-- stays true forever, "earned_at" drifted with the query (e.g. darkroom's
-- MAX(viewed_at) legitimately moves as more reveals get watched), so the
-- SAME badge could show a different date on two different days even
-- though nothing about whether it was earned changed.
--
-- THE FIX, IN THREE PARTS
-- ------------------------
--   1. A ledger table, earned_badges, that is only ever appended to for a
--      given (user_id, badge_id) once. profile_badges becomes a ratchet:
--      evaluate the predicates as before, INSERT ... ON CONFLICT DO NOTHING
--      any that are newly true using the PREDICATE's own computed
--      earned_at (never now()), then return what's actually in the table.
--      A predicate going false later has no effect, because nothing ever
--      re-reads or deletes an existing row on the strength of a predicate.
--   2. Every predicate below is written to be correct on a single, LAZY
--      evaluation — stable no matter how much more data accumulates after
--      the moment it became true. A ratchet only freezes what a predicate
--      happens to observe; it cannot repair a predicate that was never
--      correct to begin with, so first_in and roll_maker below use a
--      rank-by-time-then-tiebreak shape specifically so each is pinned to
--      the instant it became true, not to whatever the data looks like at
--      whatever moment someone happens to call this function.
--   3. earned_badges carries a seen_at column: NULL means "earned but never
--      shown to its owner." Every row this migration BACKFILLS gets
--      seen_at stamped at backfill time (see PART 2's own note on why this
--      is not optional — the auto-follow-owner backfill hit the identical
--      trap and the fix is the same shape). Only a badge earned genuinely
--      AFTER this migration ships is ever born with seen_at = NULL, which
--      is what lets the client show "new" only for the real thing.
--      mark_own_badges_seen() (PART 5) is the only way seen_at ever moves,
--      and it is hard-pinned to auth.uid() — see that function's own
--      comment for why p_profile_id can never be involved in that decision.
--
-- WHAT A BADGE RECORDS, ON PURPOSE, AND WHAT IT NEVER DOES
-- -----------------------------------------------------------
-- No badge below, and no badge added later to this table, should ever
-- record WHO it was earned with or WHO it involved — no roll reference, no
-- other user's id, nothing an explanation string could turn into "with
-- @someone." The ratchet makes every row here permanent by construction;
-- a second person's handle written into a permanent row would be that
-- person's name living on someone else's profile forever, with no way for
-- either of them to later dissociate from it. earned_badges' columns
-- (user_id, badge_id, earned_at, granted_by, seen_at) are deliberately the
-- complete set — badge_id plus a timestamp is the only shape a badge is
-- allowed to take. brought_someone (PART 2/3) is the sharpest case: it
-- records only that the caller successfully brought someone in, and when —
-- never who.
-- ============================================================


-- ============================================================
-- PART 1: earned_badges — the ledger.
-- ============================================================
--
-- PRIMARY KEY (user_id, badge_id) is what makes the ratchet an ON CONFLICT
-- DO NOTHING target: a row existing at all IS "earned," there is no other
-- status to track.
--
-- badge_id is TEXT, not an enum, gated by the FIRST check constraint below
-- instead — matches this schema's existing convention of TEXT + CHECK for
-- small closed catalogs (see e.g. activation_events.event). Adding a new
-- badge id later is a one-line change to that constraint's list, nothing
-- else about the table shape moves.
--
-- granted_by distinguishes an owner-granted badge from a predicate-earned
-- one for BOOKKEEPING (NULL = earned by the predicates in PART 3 below,
-- a uuid = granted by that owner). It must never surface to any other
-- reader: profile_badges (PART 3) selects only (badge_id, earned_at), and
-- earned_badges itself carries no policies at all — see the RLS note below.
--
-- The SECOND check constraint is the actual enforcement the task asked
-- for: "grantable ids come from a small fixed catalog." It says a granted
-- row (granted_by IS NOT NULL) may only ever carry one of the two seeded
-- grantable ids. This is deliberately a table constraint, not application
-- logic inside grant_badge — even a future buggy rewrite of that function
-- physically cannot INSERT a granted row that impersonates first_light,
-- full_roll, darkroom, founding_100, first_in, roll_maker, or
-- brought_someone, because Postgres itself rejects it. Adding a third
-- grantable badge later means widening this one list (and the first one,
-- so the id is valid at all) — still a one-line migration, no new table,
-- no new column.
--
-- seen_at is nullable ON PURPOSE, and defaults to NULL: that default is
-- exactly right for a badge earned genuinely after this migration ships
-- (nobody has shown it to its owner yet). It is wrong for the BACKFILL in
-- PART 2, which is why every backfill INSERT below stamps seen_at
-- explicitly at insert time instead of taking the column default — see
-- that part's own comment for the launch-day trap this avoids.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.earned_badges (
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    badge_id   TEXT NOT NULL,
    earned_at  TIMESTAMPTZ NOT NULL,
    granted_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    seen_at    TIMESTAMPTZ,
    PRIMARY KEY (user_id, badge_id),
    CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (
        'first_light', 'full_roll', 'darkroom', 'founding_100',
        'first_in', 'roll_maker', 'brought_someone',
        'founding_crew', 'test_roll'
    )),
    CONSTRAINT earned_badges_grantable_check CHECK (
        granted_by IS NULL OR badge_id IN ('founding_crew', 'test_roll')
    )
);

-- granted_by is the one foreign key here without index coverage from the
-- primary key (user_id, badge_id) — partial, since it's only ever non-NULL
-- for the small minority of rows an owner explicitly granted.
CREATE INDEX IF NOT EXISTS earned_badges_granted_by_idx
    ON public.earned_badges (granted_by)
    WHERE granted_by IS NOT NULL;

-- RLS ON, deliberately NO policies — same shape as allowed_emails,
-- redeem_invite_rate, and digest_state elsewhere in this schema: a table
-- that must never be readable or writable directly by any client role,
-- only through the SECURITY DEFINER functions below. This is what makes
-- "granted_by never leaks to other users reading a profile" true by
-- construction rather than by careful column selection alone: even a typo
-- in profile_badges' SELECT list could not leak it, because there is no
-- direct grant to fall back on.
ALTER TABLE public.earned_badges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.earned_badges FROM PUBLIC, anon, authenticated;


-- ============================================================
-- PART 2: backfill. Runs the same predicates PART 3 will run per-profile,
-- but once, for every user at once, so nobody who already earned a badge
-- under the old live-computed function loses it the moment this ships.
-- Each INSERT here is the set-based twin of the matching block in
-- profile_badges below — same predicate, same earned_at expression, just
-- grouped by user instead of parameterized by one. Read PART 3 first if
-- the shape of any single one of these looks unfamiliar.
--
-- EVERY INSERT BELOW STAMPS seen_at = now() EXPLICITLY. This is not
-- optional. Without it, every row here takes the column's NULL default,
-- and the first person to open the app after this ships would be met with
-- up to seven badges at once, every one of them animating as "new" — the
-- exact trap 2026-08-14_auto_follow_owner_backfill.sql already hit and
-- documented for follows.push_sent (see that file's own comment on why
-- push_sent is set TRUE at backfill-insert time, not left at its default).
-- Same shape here: a backfilled row is a fact about the PAST becoming
-- newly recorded, not a new achievement happening right now, so its
-- "shown to owner" state should reflect that it's not actually new. Only a
-- badge inserted by profile_badges' own ratchet (PART 3), for something
-- that becomes true strictly AFTER this migration runs, is allowed to be
-- born with seen_at = NULL.
-- ============================================================

-- first_light: everyone's first frame ever.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT p.user_id, 'first_light', MIN(p.taken_at), now()
FROM public.photos p
GROUP BY p.user_id
HAVING MIN(p.taken_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- full_roll: see profile_badges' comment on this predicate below for the
-- "shot on both sides of the midpoint" reasoning; this is that same check
-- run for every (user, roll) pair instead of one user at a time.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT agg.user_id, 'full_roll', MIN(agg.earned_at), now()
FROM (
    SELECT
        p.user_id,
        r.id AS roll_id,
        BOOL_OR(p.taken_at < r.created_at + INTERVAL '6 hours') AS shot_early,
        MIN(p.taken_at) FILTER (WHERE p.taken_at >= r.created_at + INTERVAL '6 hours') AS earned_at
    FROM public.rolls r
    JOIN public.photos p ON p.roll_id = r.id
    WHERE public.is_roll_developed(r.id)
    GROUP BY p.user_id, r.id, r.created_at
) agg
WHERE agg.shot_early AND agg.earned_at IS NOT NULL
GROUP BY agg.user_id
HAVING MIN(agg.earned_at) IS NOT NULL
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- darkroom: everyone who, as of THIS BACKFILL MOMENT, had opened every
-- reveal for every developed roll they were ever a member of. This is the
-- exact "had a perfect streak at some point" freeze the ratchet now means
-- for this badge going forward — see profile_badges' comment on darkroom
-- below for the full explanation of why the meaning changed.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT rm.user_id, 'darkroom', MAX(v.viewed_at), now()
FROM public.roll_members rm
JOIN public.rolls r ON r.id = rm.roll_id
LEFT JOIN public.roll_reveal_views v
    ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
WHERE public.is_roll_developed(r.id)
GROUP BY rm.user_id
HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(v.viewed_at)
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- founding_100: every account already inside the first 100 signups.
-- Currently every single account (FLIM has ~40 total) — that is expected,
-- not a bug; see PART 3 below for why.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT u.id, 'founding_100', u.created_at, now()
FROM public.users u
WHERE u.signup_ordinal <= 100
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- first_in: everyone who was ranked 1st to open the reveal on some roll
-- that had at least two MEMBERS (not contributors — see profile_badges'
-- comment on this predicate below for why that distinction is the right
-- one here). Ranked by time with a deterministic tiebreak, which is what
-- makes this stable forever once computed: it can never be displaced by
-- who opens the reveal next.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
WITH ranked AS (
    SELECT roll_id, user_id, viewed_at,
           ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
    FROM public.roll_reveal_views
), qualifying_rolls AS (
    SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
)
SELECT r.user_id, 'first_in', MIN(r.viewed_at), now()
FROM ranked r
JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
WHERE r.rn = 1
GROUP BY r.user_id
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- roll_maker: everyone who created a roll that went on to hold at least one
-- photo (from anyone, not just the creator — "created and it got shot
-- into," not "created and shot into it yourself"; full_roll already covers
-- the creator's own shooting behavior).
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT r.created_by, 'roll_maker', MIN(r.created_at), now()
FROM public.rolls r
WHERE EXISTS (SELECT 1 FROM public.photos p WHERE p.roll_id = r.id)
GROUP BY r.created_by
ON CONFLICT (user_id, badge_id) DO NOTHING;

-- brought_someone: the invite-lineage join from
-- 2026-08-08_activation_events.sql's invite_redeemed backfill, reused
-- here — allowed_emails.note = 'invited_by:<uuid>' is written by
-- redeem_invite() the moment a code is used, and joining back to
-- public.users by (lower-cased) email finds who actually went on to sign
-- up with it. DELIBERATELY DIFFERENT from that backfill's own dating: this
-- one uses u.created_at (when the invitee actually JOINED), not
-- ae.added_at (when the code was redeemed) — those two moments can be far
-- apart, and the day someone actually showed up is the one worth
-- stamping. The extra JOIN to `inv` (rather than grouping by the raw
-- extracted uuid) is a safety net, not decoration: if an inviter's account
-- were ever deleted, split_part(ae.note, ':', 2) would still parse to a
-- uuid, but INSERTing it as user_id would violate earned_badges' own
-- foreign key — this join simply excludes that case instead of erroring
-- the whole backfill.
--
-- Records only that it happened and when — MIN(u.created_at), nothing
-- about which invitee it was. See this file's header note on why no badge
-- here is ever allowed to carry another person's identity.
--
-- This badge becomes structurally unearnable the day FLIM ever removes
-- invite codes — there would be no new allowed_emails rows with this note
-- shape to find. That is intended, not a gap to fix: it turns
-- brought_someone into a permanent artifact of the invite era rather than
-- a badge nobody can explain anymore, exactly like a real "beta tester"
-- stamp outlives the beta.
INSERT INTO public.earned_badges (user_id, badge_id, earned_at, seen_at)
SELECT inv.id, 'brought_someone', MIN(u.created_at), now()
FROM public.allowed_emails ae
JOIN public.users u ON lower(u.email) = ae.email
JOIN public.users inv ON inv.id = split_part(ae.note, ':', 2)::uuid
WHERE ae.note LIKE 'invited_by:%'
GROUP BY inv.id
ON CONFLICT (user_id, badge_id) DO NOTHING;


-- ============================================================
-- PART 3: profile_badges(p_profile_id) — now a ratchet, not a pure read.
--
-- No longer STABLE: it writes (INSERT ... ON CONFLICT DO NOTHING) before
-- it reads. Volatility is left at the default (VOLATILE) rather than
-- explicitly stated, matching how every other writing function in this
-- schema is declared.
--
-- Same SECURITY DEFINER / callable-about-any-profile / authenticated-only
-- posture as before — see the original migration's header comment for the
-- full reasoning, unchanged here. The one new consequence worth flagging:
-- because this function is callable about ANY profile by ANY authenticated
-- caller, and it now writes, simply viewing someone else's profile can
-- cause a row to be inserted into earned_badges FOR THEM. That is fine —
-- the insert is derived entirely from that profile's own real data, never
-- from anything the calling client supplies, so no caller can forge or
-- influence what gets written for someone else, only trigger the same
-- write that profile's own client would eventually trigger anyway. It
-- must NOT, however, mark anything seen — see PART 5's header comment for
-- why that is a completely separate, auth.uid()-only path.
--
-- Each block below follows the same shape: INSERT INTO earned_badges
-- SELECT <the predicate, unchanged from the original read-only version
-- unless noted> ... ON CONFLICT (user_id, badge_id) DO NOTHING. The final
-- RETURN QUERY reads back from the table, never from the predicates
-- directly, which is what makes a later false predicate harmless: nothing
-- downstream of the INSERTs ever looks at the predicates again.
-- ============================================================
CREATE OR REPLACE FUNCTION public.profile_badges(p_profile_id UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
    -- The pragma above is load-bearing, not decorative: RETURNS TABLE (badge_id, earned_at)
    -- implicitly declares plpgsql OUT variables named badge_id and earned_at, which collide
    -- with earned_badges' own columns of the same names. Every `ON CONFLICT (user_id,
    -- badge_id)` below is a bare identifier that PL/pgSQL would otherwise refuse to resolve
    -- (ambiguous: the OUT variable or the table column?) — this function never reads or
    -- assigns those OUT variables directly (RETURN QUERY fills them positionally instead), so
    -- forcing every such reference to mean the table column is exactly what's wanted here.

    -- first_light: their first frame ever, full stop. Earned date = the
    -- date of that frame. Unchanged from the original migration.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_profile_id, 'first_light', MIN(p.taken_at)
    FROM public.photos p
    WHERE p.user_id = p_profile_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_roll: unchanged predicate from the original migration — shot
    -- into the roll on both sides of its halfway point, on a roll that
    -- actually developed. The ratchet is what's new: previously this
    -- could show a different "earliest qualifying roll" on different
    -- calls if is_roll_developed's answer for some roll changed between
    -- them; now the first roll observed to qualify is the one that sticks.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_profile_id, 'full_roll', MIN(agg.earned_at)
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
    HAVING MIN(agg.earned_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- darkroom: predicate UNCHANGED from the original migration ("never
    -- skipped opening a reveal, across every developed roll you were ever
    -- a member of"). What changes is what the ratchet makes it MEAN. The
    -- original comment flagged this as the one badge that "can currently
    -- stop being true" — join a new roll, skip its reveal, and the live
    -- computation would go false. The ratchet removes that: once this
    -- INSERT lands once, it is never revisited on the strength of the
    -- predicate again. So as of this migration, darkroom no longer means
    -- "your streak is intact as of right now" — it means "you had a
    -- perfect streak at some point," frozen at whichever call first
    -- observed it true. A later skipped reveal no longer removes it.
    --
    -- Flim/Models/ProfileIdentity.swift's copy for this badge currently
    -- reads "You've opened every reveal so far, across every roll you've
    -- been part of," which still describes the OLD live-losable meaning
    -- ("so far" implies it could stop being true). That copy needs a
    -- follow-up edit once this ships — flagging it here rather than
    -- editing Swift myself, per this agent's ownership boundary.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_profile_id, 'darkroom', MAX(v.viewed_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    LEFT JOIN public.roll_reveal_views v
        ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
    WHERE rm.user_id = p_profile_id
      AND public.is_roll_developed(r.id)
    HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(v.viewed_at)
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- founding_100 — NEW. Earned the instant an account's signup_ordinal
    -- (permanent, unfakeable, immutable via the trigger in
    -- 2026-08-17_profile_identity.sql) is 100 or below. earned_at is the
    -- account's created_at, not now() — the ordinal was decided at signup,
    -- so that's when this was actually earned, discovery of it by this
    -- function is incidental. Can never un-earn by construction: nothing
    -- can ever change an existing row's signup_ordinal after insert (see
    -- lock_signup_ordinal_trigger).
    --
    -- This is currently UNIVERSAL — FLIM has roughly 40 accounts total, so
    -- every existing account qualifies. That is intended, not a bug to
    -- special-case away: the badge is defined against a fixed threshold,
    -- and it only becomes a meaningful scarcity signal ("one of the first
    -- 100 ever") once the app has grown past that line. Shipping it early,
    -- while it's still universal, costs nothing and means there's no later
    -- migration needed to "turn it on."
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT u.id, 'founding_100', u.created_at
    FROM public.users u
    WHERE u.id = p_profile_id AND u.signup_ordinal <= 100
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- first_in — NEW. You were the first person to open a roll's reveal,
    -- on a roll that had at least two MEMBERS. The member-count floor is
    -- deliberate: this badge is about beating other people TO the reveal,
    -- and being first to open your own solo reveal beats no one — a badge
    -- that fires on an empty race would cheapen the ones that involved an
    -- actual race. Ranked by ROW_NUMBER() over viewed_at (user_id as a
    -- deterministic tiebreak for the vanishingly unlikely exact-timestamp
    -- tie), which is what makes this stable forever once earned: a second
    -- person opening the reveal later can only ever rank 2nd or worse, so
    -- it can never bump the person who already ranked 1st. Earned date =
    -- the caller's own viewed_at on the earliest such qualifying roll.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    )
    SELECT p_profile_id, 'first_in', MIN(r.viewed_at)
    FROM ranked r
    JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
    WHERE r.user_id = p_profile_id AND r.rn = 1
    HAVING MIN(r.viewed_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- roll_maker — NEW. You created a roll (rolls.created_by), and it went
    -- on to hold at least one photo from anyone. The photo requirement is
    -- load-bearing: without it, creating and abandoning ten empty rolls in
    -- a row would earn this for free, making it the one farmable badge in
    -- the whole set — creating a roll costs nothing and has no upload-limit
    -- interaction the way shooting a photo does. Earned date = the
    -- earliest such qualifying roll's created_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_profile_id, 'roll_maker', MIN(r.created_at)
    FROM public.rolls r
    WHERE r.created_by = p_profile_id
      AND EXISTS (SELECT 1 FROM public.photos p WHERE p.roll_id = r.id)
    HAVING MIN(r.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- brought_someone — NEW. Mirrors the backfill block above exactly, just
    -- scoped to this one caller as the inviter instead of every inviter at
    -- once — see that block's comment for the full reasoning (note format,
    -- why u.created_at and not ae.added_at, why this records only that it
    -- happened and when rather than who, and why this badge is meant to
    -- become permanently unearnable once invites go away). note is an
    -- exact match here, not a LIKE prefix, because p_profile_id pins the
    -- entire suffix, not just the 'invited_by:' prefix.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_profile_id, 'brought_someone', MIN(u.created_at)
    FROM public.allowed_emails ae
    JOIN public.users u ON lower(u.email) = ae.email
    WHERE ae.note = 'invited_by:' || p_profile_id::text
    HAVING MIN(u.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    RETURN QUERY
    SELECT eb.badge_id, eb.earned_at
    FROM public.earned_badges eb
    WHERE eb.user_id = p_profile_id
    ORDER BY eb.earned_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.profile_badges(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.profile_badges(UUID) TO authenticated;


-- ============================================================
-- PART 4: owner-granted badges.
--
-- Same owner gate as list_feedback/activation_funnel: `IF NOT
-- public.is_owner() THEN RAISE EXCEPTION`, not a REVOKE — EXECUTE stays
-- granted to `authenticated` so a non-owner's call fails with a clean
-- error rather than a permission-denied at the transport layer, matching
-- every other admin RPC in this schema.
--
-- grant_badge is intentionally NOT a general-purpose "insert any row into
-- earned_badges" — it can only ever produce a row for one of the two
-- catalog ids seeded below (founding_crew, test_roll), and that is
-- enforced twice: once here as an explicit early check with a clear error
-- message, and unconditionally by earned_badges_grantable_check on the
-- table itself (PART 1) as the real backstop, so it holds even against a
-- future rewrite of this function that forgets the early check.
--
-- earned_at is now() — a grant, unlike a predicate, has no earlier real
-- moment to backdate to; it happened when the owner clicked it.
--
-- ON CONFLICT DO NOTHING here on purpose: re-granting an already-granted
-- (or already-earned) badge is a no-op, not an error — an owner re-running
-- a grant should never see a failure.
-- ============================================================
CREATE OR REPLACE FUNCTION public.grant_badge(p_user_id UUID, p_badge_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    IF p_badge_id NOT IN ('founding_crew', 'test_roll') THEN
        RAISE EXCEPTION 'badge % is not grantable', p_badge_id;
    END IF;

    INSERT INTO public.earned_badges (user_id, badge_id, earned_at, granted_by)
    VALUES (p_user_id, p_badge_id, now(), auth.uid())
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    RETURN TRUE;
END;
$$;

-- revoke_badge is the mis-grant undo the task asked for. Deliberately
-- scoped to `granted_by IS NOT NULL` in the DELETE's WHERE clause: this
-- cannot be used to strip a badge someone actually earned through the
-- predicates in PART 3, only to undo something an owner granted. That
-- keeps the "a badge, once earned, is never removed" guarantee intact even
-- in the presence of an admin undo tool.
CREATE OR REPLACE FUNCTION public.revoke_badge(p_user_id UUID, p_badge_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    DELETE FROM public.earned_badges
    WHERE user_id = p_user_id
      AND badge_id = p_badge_id
      AND granted_by IS NOT NULL;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_badge(UUID, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.revoke_badge(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_badge(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.revoke_badge(UUID, TEXT) TO authenticated;


-- ============================================================
-- PART 5: seen-state — marking badges seen, the caller's own unseen count
-- for a profile-tab dot, and which specific badges are unseen so the right
-- stamps get the press-in animation at render time.
--
-- ALL THREE functions below take NO p_profile_id argument at all, on
-- purpose, and resolve everything from auth.uid(). This is the one rule in
-- this whole file that must never bend: profile_badges (PART 3) is
-- callable about ANY profile by any authenticated caller and WRITES as a
-- side effect of that (already true before this part existed), which means
-- someone else opening my profile can be the thing that inserts my own
-- earned_badges row. If any of these three took a p_profile_id parameter
-- instead of trusting auth.uid(), a caller could either mark ANOTHER
-- user's reveal-moment as already-seen before that user ever saw it
-- themselves (silently stealing it), or read another user's unseen state
-- outright. None of the three below has any code path where the row being
-- touched or returned depends on anything the caller supplies — only on
-- who they're authenticated as. All three are also deliberately absent
-- from profile_badges' own return columns (still just badge_id,
-- earned_at): whether someone HAS seen their own badge is that person's
-- private state, the same category of thing granted_by already is, not
-- something a caller browsing their profile has any business reading.
-- ============================================================

-- Marks every one of the CALLER's own unseen badges as seen, in one call —
-- the client fires this once when the profile tab / badge strip is
-- actually shown, not per-badge. Idempotent: a badge with seen_at already
-- set is simply not matched by the WHERE clause on a second call, so
-- calling this repeatedly (e.g. every time the tab is opened) is always
-- safe and never overwrites an earlier seen_at with a later one.
CREATE OR REPLACE FUNCTION public.mark_own_badges_seen()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.earned_badges
    SET seen_at = now()
    WHERE user_id = auth.uid() AND seen_at IS NULL;
$$;

-- The caller's own count of earned-but-never-shown badges, for a profile
-- tab dot. Returns 0 for a logged-out/no-match caller (auth.uid() is NULL
-- pre-auth, which matches no row) rather than erroring, same posture as
-- every other read RPC in this schema degrading quietly.
CREATE OR REPLACE FUNCTION public.unseen_badge_count()
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COUNT(*)::BIGINT
    FROM public.earned_badges
    WHERE user_id = auth.uid() AND seen_at IS NULL;
$$;

-- WHICH of the caller's own badges are unseen, for deciding which stamps
-- get the press-in animation at render time. Deliberately a separate call
-- from unseen_badge_count() above, not a replacement for it: the tab dot
-- only ever needs a cheap count without loading a whole profile, this one
-- is for the moment the badge strip actually renders. badge_id ONLY — no
-- earned_at, no seen_at, nothing else — because the one thing this exists
-- to answer is "which ids animate," and profile_badges (PART 3) is still
-- the only place earned_at is served from. Do not use earned_at ordering
-- as a proxy for "which are new": it is the date the thing HAPPENED, not
-- when the ratchet recorded it, so a badge inserted today can carry an old
-- earned_at and sort into the middle of an otherwise-seen list — this
-- function exists specifically so nothing has to infer that from dates.
CREATE OR REPLACE FUNCTION public.own_unseen_badges()
RETURNS TABLE (badge_id TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT eb.badge_id
    FROM public.earned_badges eb
    WHERE eb.user_id = auth.uid() AND eb.seen_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.mark_own_badges_seen() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_own_badges_seen() FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_own_badges_seen() TO authenticated;

REVOKE ALL ON FUNCTION public.unseen_badge_count() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unseen_badge_count() FROM anon;
GRANT EXECUTE ON FUNCTION public.unseen_badge_count() TO authenticated;

REVOKE ALL ON FUNCTION public.own_unseen_badges() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.own_unseen_badges() FROM anon;
GRANT EXECUTE ON FUNCTION public.own_unseen_badges() TO authenticated;


-- ---- How the app uses this --------------------------------------------------
--
-- Unchanged call, same return shape (badge_id TEXT, earned_at TIMESTAMPTZ),
-- rows now backed by earned_badges instead of computed inline. Automatic
-- catalog: first_light, full_roll, darkroom, founding_100, first_in,
-- roll_maker, brought_someone. Grantable catalog: founding_crew, test_roll.
--   SELECT * FROM profile_badges('<uuid>');
--
-- Own unseen badges, called once when the profile tab / badge strip is
-- actually shown to their owner:
--   SELECT mark_own_badges_seen();
--
-- Dot on the profile tab, own badges only, no argument, cheap (no profile
-- load required):
--   SELECT unseen_badge_count();
--
-- WHICH of the caller's own badges are unseen, for the press-in animation
-- at render time, own badges only, no argument:
--   SELECT * FROM own_unseen_badges();
--
-- Owner-only, from the admin dashboard (flim-app.com/admin), not the app:
--   SELECT grant_badge('<uuid>', 'founding_crew');
--   SELECT revoke_badge('<uuid>', 'founding_crew');
