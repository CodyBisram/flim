-- ============================================================
-- Migration: invite earn-back -- an invitee's first photo gives their
-- inviter one invite back.
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: safe to re-run. Already mirrored in schema.sql.
-- Statements are in dependency order: the ledger table first (the trigger
-- function references it), then the trigger function + trigger, then grants,
-- then the labeled backfill last so it can be deleted independently of
-- everything the live mechanism needs going forward.
--
-- ⚠️ ORDER: run AFTER 2026-08-29_invite_quota.sql, already applied. This
-- migration reads and increments users.invite_uses_remaining, which that
-- migration is what makes real (default 3, floor >= 0, NULL = unlimited).
--
-- WHAT "ACTIVE" MEANS HERE, AND WHY IT IS NOT "SHOOTS THEIR FIRST ROLL"
-- ----------------------------------------------------------------------
-- The design doc's copy is "shoots their first roll." A roll in FLIM is a
-- shared container anyone in it can shoot into, so "the invitee shot their
-- first roll" is ambiguous about whose activity actually happened: someone
-- can be a member of a roll, see it develop, and never take a single photo
-- themselves, while someone else's photo is what makes that roll's reveal
-- exist at all. Keying the reward on a roll event means the trigger would
-- have to decide whether ROLL MEMBERSHIP or A PHOTO IN THAT ROLL is the real
-- signal, and either choice quietly measures a different person's behavior
-- than the one being rewarded.
--
-- A PHOTO has none of that ambiguity: public.photos.user_id is who took it,
-- enforced at INSERT by RLS ("photos: can insert own", auth.uid() = user_id),
-- so it is both unambiguous and server-verifiable without trusting anything
-- the client claims about itself. It is also, concretely, the moment a fresh
-- signup stops being a dead account and starts being a user of the app. This
-- migration triggers on `public.photos` AFTER INSERT, not on roll membership
-- or roll development.
--
-- WHY ONLY THE INVITER GETS THE CREDIT, NOT BOTH SIDES
-- ----------------------------------------------------------------------
-- The design doc's copy is "you both get one back." This migration
-- deliberately implements only the inviter's half. Reasoning:
--
--   1. The invitee is not supply-constrained. Every new account already
--      starts with 3 invites they have not spent (2026-08-29_invite_quota.sql).
--      Measured against production the same day: 51 users, only 6 have EVER
--      sent a single invite. Handing a brand-new, statistically-non-inviting
--      user a 4th invite for taking one photo adds supply to exactly the
--      population that isn't using the supply it already has.
--   2. Crediting both sides mints a net-new invite from nothing on every
--      activation: the inviter's spent invite comes back AND the invitee
--      gets an extra one, so one redemption plus one photo produces two
--      invites where the system started with one. That is not scarcity, it
--      is inflation with a growth-mechanic label on it. Crediting only the
--      inviter is a strict give-back: the inviter's slot they spent to bring
--      this person in is refunded once that person proves real, and total
--      invite supply in the system never increases beyond what was spent.
--
-- If the owner disagrees after seeing this in practice, adding the
-- invitee's half later is one extra UPDATE against public.users guarded the
-- same way the inviter's UPDATE already is below (WHERE id = NEW.user_id AND
-- invite_uses_remaining IS NOT NULL) -- not a redesign of the ledger, the
-- trigger, or the exactly-once guarantee.
--
-- EXACTLY ONCE PER INVITEE, FOREVER -- WHY THE LEDGER INSERT IS THE GUARD
-- ----------------------------------------------------------------------
-- invite_earnbacks is keyed on invitee_id alone (PRIMARY KEY). That single
-- fact is the entire exactly-once guarantee: no matter how many photos this
-- person ever takes, or how many of those inserts race each other, at most
-- one row for them can ever exist. The trigger below leans on that PRIMARY
-- KEY directly -- `INSERT ... ON CONFLICT (invitee_id) DO NOTHING RETURNING
-- inviter_id INTO v_credited` -- as the guard itself, not as a cleanup after
-- a separate check:
--   * NOT a photo-count query ("is this their Nth photo, does this fire
--     only when N model= 1?"). That is both wrong and slow: wrong because
--     two simultaneous first-photo uploads could both observe count = 1 and
--     both proceed; slow because it means scanning or counting this user's
--     whole photo history on every single photo they will ever take, for
--     the rest of the app's life, just to answer a question the ledger
--     already answers for free.
--   * NOT a check-then-act ("does a ledger row already exist? if not,
--     insert"). Two concurrent photo inserts from the same brand-new user
--     (a real scenario -- an invitee's very first roll can easily contain
--     more than one shot within the same second) would both pass the
--     existence check before either commits its insert, and both would
--     then try to credit the inviter -- exactly the double-credit this
--     table exists to prevent.
-- The single `INSERT ... ON CONFLICT ... RETURNING` makes the database's own
-- row-level conflict resolution the race referee: exactly one concurrent
-- caller ever gets a non-NULL v_credited back, and only that one proceeds to
-- touch users.invite_uses_remaining.
--
-- PERFORMANCE -- THIS FIRES ON EVERY PHOTO INSERT, FOR THE LIFE OF THE APP
-- ----------------------------------------------------------------------
-- Two fast paths, checked in this order, both before anything resembling a
-- join across the two invite-adjacent tables:
--   1. Already credited: `EXISTS (SELECT 1 FROM invite_earnbacks WHERE
--      invitee_id = NEW.user_id)` is a single probe against that table's own
--      PRIMARY KEY. This is the path every photo after an invitee's first
--      one hits, forever -- including every future photo from the entire
--      downstream network of the app's most active inviters.
--   2. Never invited by anyone: this is the case the ledger can never
--      short-circuit, because a row is never written for someone with no
--      inviter to credit. It still costs very little: one SQL statement,
--      `SELECT ae.note FROM users u LEFT JOIN allowed_emails ae ON
--      ae.email = lower(u.email) WHERE u.id = NEW.user_id`, which the planner
--      resolves as two PRIMARY KEY point lookups in a nested loop (users.id,
--      then allowed_emails.email) -- not a scan of either table, and
--      critically NOT the shape the badge system's brought_someone/patron/
--      good_company predicates use, which filter allowed_emails BY NOTE
--      (unindexed) to find every invitee OF a given inviter. That direction
--      is fine for a once-in-a-while badge ratchet; run on every photo
--      insert forever it would mean an unindexed scan of the whole allowed
--      emails table per photo. This trigger only ever needs the OPPOSITE
--      direction -- given one invitee, find their own note -- which is a
--      direct PRIMARY KEY hit both times.
-- Accepted cost: for a user nobody ever invited (most founding accounts,
-- anyone admitted before invite codes existed, or one of the 4 production
-- accounts admitted some other way per point 7 below), every one of their
-- photos pays those two indexed point lookups, forever, because there is no
-- ledger row for them that could ever short-circuit it. That is a small,
-- constant, indexed cost, not a scan, and is accepted rather than engineered
-- away. If photo volume ever makes it measurable, the fix is a denormalized
-- `users.invited_by UUID` column written once at signup (inside
-- redeem_invite(), the only place that ever learns the fact) so this
-- trigger's fast path becomes a single column read with no join at all --
-- deliberately NOT done here, to keep this change to one new table and one
-- new trigger.
--
-- NULL MUST STAY NULL
-- ----------------------------------------------------------------------
-- invite_uses_remaining = NULL means "deliberately unlimited" (production:
-- exactly one account, signup_ordinal 1, see 2026-08-29_invite_quota.sql).
-- The credit UPDATE is guarded with `AND invite_uses_remaining IS NOT NULL`,
-- identical in spirit to redeem_invite()'s own decrement guard, so an
-- increment can never turn NULL into a finite number.
--
-- SECURITY -- WHY SECURITY DEFINER IS SAFE HERE, NOT JUST CONVENIENT
-- ----------------------------------------------------------------------
-- The trigger writes to public.users on behalf of the INVITER, a row the
-- INVITEE (whose INSERT on photos fired it) has no RLS right to touch --
-- "users: own row" only permits auth.uid() = id. The trigger function is
-- SECURITY DEFINER with `SET search_path = public` so its body runs with
-- the definer's rights and bypasses that policy for this one, narrow write.
--
-- This cannot be abused to credit an arbitrary account, because the inviter
-- is never read from anything the client supplies on the photos row itself
-- (there is no such column, and if there were, it would be client-writable
-- and trivially spoofable). It is derived exclusively from
-- allowed_emails.note for the INSERTING user's OWN email -- and that note
-- column is itself only ever written by redeem_invite() (SECURITY DEFINER;
-- allowed_emails has zero client-facing policies of any kind, per this
-- project's standing rule that it is reachable only through
-- is_email_allowed()/redeem_invite()). So the only way a 'invited_by:<uuid>'
-- note can exist for a given email is a genuine, rate-limited redemption of
-- that UUID's real invite_code against that email, at some point in the
-- past. A photo row supplies WHICH invitee to check (pinned to auth.uid() by
-- "photos: can insert own"), never WHO their inviter is.
--
-- WHAT IF THE INVITEE'S INVITER NO LONGER EXISTS (DELETED ACCOUNT)?
-- ----------------------------------------------------------------------
-- invite_earnbacks.inviter_id deliberately carries NO foreign key (see the
-- table definition below) -- it is a plain audit column, the same shape as
-- allowed_emails.note already is for the identical reason. That means the
-- ledger INSERT always succeeds once a valid `invited_by:<uuid>` note is
-- found, regardless of whether that uuid still exists in public.users today.
-- The invitee is still marked credited, exactly once, forever -- correct,
-- because from the invitee's side this fact never changes no matter what
-- later happens to the inviter's account. The actual reward step,
-- `UPDATE users ... WHERE id = v_credited`, then simply matches zero rows if
-- that account is gone, which is a silent no-op: nothing to raise, nothing
-- to retry, nobody left to credit.
--
-- WHAT IF allowed_emails HAS NO MATCHING ROW AT ALL?
-- ----------------------------------------------------------------------
-- Production has 4 accounts admitted some other way (manually seeded,
-- pre-invite-code accounts, etc.) with no allowed_emails row, or a row whose
-- note doesn't match the `invited_by:<uuid>` shape redeem_invite() writes
-- (e.g. the owner's own seed row, note = 'owner'). The LEFT JOIN in the fast
-- path above returns NULL for v_note in the first case; the regex check
-- below rejects any note that doesn't parse in the second. Both fall through
-- to a plain `RETURN NEW` -- no error, no ledger row, no credit. Every path
-- through this function ends in RETURN NEW (or is caught by the outer
-- EXCEPTION WHEN OTHERS, matching auto_follow_owner()'s discipline): this
-- trigger's one hard rule is that it may never be the reason a photo insert
-- fails.
--
-- BACKFILL DECISION -- MY RECOMMENDATION: INCLUDE IT (see the labeled block
-- at the bottom; delete it if you disagree, same shape as invite_quota's
-- "THE SEEDING EXCEPTION")
-- ----------------------------------------------------------------------
-- Should invitees who already took their first photo BEFORE this migration
-- ran get their inviter credited retroactively? I recommend yes:
--   * It is bounded and cheap to reason about. 2026-08-29_invite_quota.sql
--     measured production at 51 users, 44 invite-code redemptions ever, only
--     6 accounts that have ever sent one. The backfill can only touch
--     invitees who (a) exist via a genuine `invited_by:<uuid>` note AND
--     (b) already have at least one photo -- a strict subset of 44, in
--     practice far smaller once photo-taking is required.
--   * Excluding it means the feature ignores every conversion that already
--     happened before deploy day, which for the 6 accounts who have ever
--     invited anyone means ignoring the very conversions that would
--     motivate them to invite more -- the same "don't punish the people who
--     already did the desired thing" reasoning that kept signup_ordinal 1 on
--     NULL in the quota migration rather than capping them at 3 like
--     everyone else.
--   * It cannot double-credit anything: the backfill uses the exact same
--     `invite_earnbacks (invitee_id) ON CONFLICT DO NOTHING` guard as the
--     live trigger, so if the trigger has already fired for someone (e.g.
--     this migration is applied, then re-applied later) the backfill's
--     INSERT for them returns zero rows and credits nothing a second time.
-- The counterargument -- it retroactively increases some inviters' quota
-- above the 3 they started with -- is not a bug, it is the feature working
-- on history instead of only the future; earn-back existing to let a
-- successful inviter invite MORE than the flat baseline is the entire point.
-- ============================================================


-- ============================================================
-- 1. The ledger. PRIMARY KEY on invitee_id alone is the exactly-once
--    mechanism (see header). inviter_id is a plain UUID with NO foreign key
--    -- deliberately, so a later-deleted inviter can never block or cascade
--    away this row; see the header's "inviter no longer exists" section. No
--    RLS policies are added (same shape as redeem_invite_rate): every role's
--    implicit table privileges are stripped below, so this table is reachable
--    only from inside the SECURITY DEFINER trigger body.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.invite_earnbacks (
    invitee_id  UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    inviter_id  UUID NOT NULL,
    credited_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Not on the hot path (the trigger never queries by inviter_id), but cheap
-- and useful for the analytics question "how many earn-backs has X earned",
-- and for the backfill's own GROUP BY inviter_id below.
CREATE INDEX IF NOT EXISTS invite_earnbacks_inviter_idx
    ON public.invite_earnbacks (inviter_id);

ALTER TABLE public.invite_earnbacks ENABLE ROW LEVEL SECURITY;
-- No policies, and every role's implicit table privileges are stripped
-- here, same shape as redeem_invite_rate: this table is readable/writable
-- only from inside the trigger's SECURITY DEFINER body.
REVOKE ALL ON public.invite_earnbacks FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 2. The trigger function. See the header for the full reasoning behind
--    every decision below; this body implements it in the order described.
-- ============================================================
CREATE OR REPLACE FUNCTION public.credit_invite_earnback()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_note     TEXT;
    v_inviter  UUID;
    v_credited UUID;
BEGIN
    -- FAST PATH 1: already credited. Single PRIMARY KEY probe.
    IF EXISTS (SELECT 1 FROM public.invite_earnbacks WHERE invitee_id = NEW.user_id) THEN
        RETURN NEW;
    END IF;

    -- FAST PATH 2: was this photo's owner ever admitted via someone's
    -- invite code at all, and if so, whose? One statement, two PRIMARY
    -- KEY-indexed point lookups (users.id, then allowed_emails.email) in a
    -- nested loop -- see header for why this is cheap and why it is not the
    -- same shape as the badge system's inviter-to-invitees join.
    SELECT ae.note INTO v_note
    FROM public.users u
    LEFT JOIN public.allowed_emails ae ON ae.email = lower(u.email)
    WHERE u.id = NEW.user_id;

    -- No allowed_emails row at all (admitted some other way -- 4 production
    -- accounts today), or a note that doesn't match the exact
    -- 'invited_by:<uuid>' shape redeem_invite() writes (e.g. 'owner', or
    -- anything hand-inserted). Both are silent no-ops: this trigger only
    -- ever acts on a note it can prove came from a genuine redemption.
    IF v_note IS NULL OR v_note !~ '^invited_by:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RETURN NEW;
    END IF;

    v_inviter := substring(v_note FROM 12)::UUID; -- strip the 11-char 'invited_by:' prefix

    -- The ledger insert IS the exactly-once guard (see header): whichever
    -- concurrent photo insert for this invitee wins the PRIMARY KEY
    -- conflict is the only one that gets a non-NULL v_credited back and
    -- proceeds to the credit below.
    INSERT INTO public.invite_earnbacks (invitee_id, inviter_id)
    VALUES (NEW.user_id, v_inviter)
    ON CONFLICT (invitee_id) DO NOTHING
    RETURNING inviter_id INTO v_credited;

    IF v_credited IS NULL THEN
        -- Lost the race to a concurrent insert for the same invitee; that
        -- other invocation already claimed (or is claiming) the credit.
        RETURN NEW;
    END IF;

    -- The actual earn-back. WHERE id = v_credited matches zero rows (silent
    -- no-op, not an error) if the inviter's account was since deleted -- see
    -- header. AND invite_uses_remaining IS NOT NULL keeps NULL
    -- ("unlimited") from ever becoming a finite number by way of an
    -- increment -- same discipline redeem_invite()'s decrement already
    -- follows in the opposite direction.
    UPDATE public.users
    SET invite_uses_remaining = invite_uses_remaining + 1
    WHERE id = v_credited
      AND invite_uses_remaining IS NOT NULL;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- This fires on every photo insert, forever. The one thing it must
    -- never do, under any future bug or unforeseen data shape, is take down
    -- someone's photo upload. Same discipline as auto_follow_owner().
    RETURN NEW;
END;
$$;

-- Trigger function, not called by any client role directly, so no role
-- needs EXECUTE -- same shape as auto_follow_owner()/block_severs_follows().
REVOKE ALL ON FUNCTION public.credit_invite_earnback() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS credit_invite_earnback_trigger ON public.photos;
CREATE TRIGGER credit_invite_earnback_trigger
    AFTER INSERT ON public.photos
    FOR EACH ROW EXECUTE FUNCTION public.credit_invite_earnback();


-- ============================================================
-- 3. THE BACKFILL. *** THIS RAN, AND WAS THEN REVERSED. ***
--    Applied 2026-08-29, then undone the same day by
--    2026-08-29_invite_earnback_reset.sql, because the owner chose to start
--    clean. The ledger rows it wrote were KEPT on purpose, so those 29
--    invitees stay accounted for and can never be credited later; only the
--    invites were taken back. Do not delete those rows, and read that file
--    before touching this section. Re-running this section today is a no-op
--    (ON CONFLICT DO NOTHING finds every row already present).
--
--    Original note follows.
--
--    Read the header's "BACKFILL DECISION" section before
--    running. Recommendation: INCLUDE (this block is left in). Delete this
--    entire numbered section (down to the blank line before "Verify" at the
--    bottom) if the owner disagrees; nothing else in this file depends on it.
--
--    Set-based, not a loop, and uses the SAME two guards as the live
--    trigger (ledger PRIMARY KEY via ON CONFLICT, and
--    invite_uses_remaining IS NOT NULL), so it is idempotent: re-running
--    this whole file a second time inserts zero new ledger rows and credits
--    zero additional invites.
--
--    credited_at is backfilled to the invitee's actual first photo's
--    taken_at, not now() -- the same "record the real historical instant,
--    never the migration's runtime" discipline activation_events'
--    own backfill uses.
-- ============================================================
WITH eligible AS (
    SELECT
        u.id AS invitee_id,
        substring(ae.note FROM 12)::UUID AS inviter_id,
        MIN(p.taken_at) AS first_photo_at
    FROM public.users u
    JOIN public.allowed_emails ae ON ae.email = lower(u.email)
    JOIN public.photos p ON p.user_id = u.id
    WHERE ae.note ~ '^invited_by:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    GROUP BY u.id, ae.note
), inserted AS (
    INSERT INTO public.invite_earnbacks (invitee_id, inviter_id, credited_at)
    SELECT invitee_id, inviter_id, first_photo_at
    FROM eligible
    ON CONFLICT (invitee_id) DO NOTHING
    RETURNING inviter_id
), per_inviter AS (
    SELECT inviter_id, COUNT(*) AS n
    FROM inserted
    GROUP BY inviter_id
)
UPDATE public.users u
SET invite_uses_remaining = u.invite_uses_remaining + per_inviter.n
FROM per_inviter
WHERE u.id = per_inviter.inviter_id
  AND u.invite_uses_remaining IS NOT NULL;


-- ---- Verify -----------------------------------------------------------------
--
--   -- How many invitees have ever been credited (live + backfilled).
--   SELECT COUNT(*) FROM public.invite_earnbacks;
--
--   -- Per-inviter breakdown, for a sanity check against the 6 accounts that
--   -- have ever sent an invite.
--   SELECT inviter_id, COUNT(*) FROM public.invite_earnbacks GROUP BY inviter_id ORDER BY 2 DESC;
--
--   -- Confirm nobody's remaining count went negative or NULL->finite.
--   SELECT id, invite_uses_remaining FROM public.users WHERE invite_uses_remaining IS NOT NULL AND invite_uses_remaining < 0;
