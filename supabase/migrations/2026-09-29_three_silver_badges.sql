-- Three silver badges (2026-09-29, for 1.6.2). NOT YET APPLIED. The owner applies it.
--
-- docs/PLAN_1_6_2_BADGES_AND_RATING.md, section 1: Recruiter (automatic), Feedback and Bug Catcher
-- (awarded by the owner from the dashboard). Safe to re-run: every statement is IF NOT EXISTS,
-- CREATE OR REPLACE, DROP FUNCTION IF EXISTS before a changed return shape, or a DROP/ADD of a
-- CHECK as a superset of the live one. No existing row is changed.
--
--   1. Recruiter counts everyone who joined through this person, however they came in: a
--      personal code, a campaign code or a roll code. All three paths in redeem_invite write the
--      same note, 'invited_by:<uuid>', which is the attribution Brought Someone, Patron and Open
--      Door already use (lead decision, 2026-09-29). redeem_invite, the sign-up path, is not
--      touched by this migration.
--   2. earned_badges_badge_id_check gains recruiter, feedback, bug_catcher. Inline CHECKs never
--      change on a table that already exists, so both CHECKs are dropped and re-added as full
--      supersets of the live definitions (read from production 2026-09-29: 30 ids; 2 grantable).
--   3. earned_badges_grantable_check and grant_badge's allow list gain feedback and bug_catcher,
--      nothing else. grant_badge stays owner-only (is_owner()) and idempotent (ON CONFLICT DO
--      NOTHING), and now returns whether it actually inserted: TRUE for a new award, FALSE when
--      the person already held the badge (for the dashboard's "Awarded" state). No caller in the
--      app, web/ or scripts reads the result today. Its owner gate and list_feedback's now treat
--      a NULL is_owner() (no JWT subject) as not the owner.
--   4. list_feedback also returns the author's user_id, so the dashboard can award a badge to the
--      person who sent an entry without looking them up by username. The return shape changes, so
--      it is dropped first; the grants are restated exactly as before (authenticated only, the
--      owner gate lives inside the body).
--   5. The ratchet gains the Recruiter predicate. Production's definition (read back 2026-09-29,
--      identical to the last one in schema.sql) with one block added before full_set, which must
--      stay last, and one change inside full_set: like spotlight, feedback and bug_catcher are the
--      owner's choice rather than the person's own effort, so full_set does not count them.
--      Recruiter does count.
--   6. Indexes for the invite predicates: allowed_emails (note), which Brought Someone, Patron,
--      Open Door and now Recruiter all filter on and nothing indexed, and users (lower(email)),
--      the join all four use.

-- ---------------------------------------------------------------------------
-- 6. Indexes (created before the functions that lean on them)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS allowed_emails_note_idx ON public.allowed_emails (note);
CREATE INDEX IF NOT EXISTS users_email_lower_idx ON public.users (lower(email));

-- ---------------------------------------------------------------------------
-- 2 and 3. The catalogue and the grantable list
-- ---------------------------------------------------------------------------
ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_badge_id_check;
ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_badge_id_check CHECK (badge_id IN (
    'brought_someone', 'chimed_in', 'chipped_in', 'cover_to_cover', 'darkroom',
    'first_in', 'first_light', 'founder', 'founding_100', 'founding_crew',
    'front_row', 'full_house', 'full_roll', 'full_set', 'good_company', 'in_frame',
    'joined_in', 'kept_one', 'one_year', 'open_door', 'packed_house', 'patron',
    'regular', 'roll_maker', 'said_it', 'shared', 'spotter', 'ten_frames', 'well_met',
    'spotlight',
    'recruiter', 'feedback', 'bug_catcher'
));

ALTER TABLE public.earned_badges DROP CONSTRAINT IF EXISTS earned_badges_grantable_check;
ALTER TABLE public.earned_badges ADD CONSTRAINT earned_badges_grantable_check CHECK (
    granted_by IS NULL OR badge_id IN ('founding_crew', 'founder', 'feedback', 'bug_catcher')
);

CREATE OR REPLACE FUNCTION public.grant_badge(p_user_id UUID, p_badge_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- COALESCE: is_owner() is NULL, not FALSE, when auth.uid() is NULL (a session with no JWT
    -- subject), and IF NOT NULL does not take the branch. Only trusted server roles can be in
    -- that position (anon has no EXECUTE), but the gate should not depend on it.
    IF NOT COALESCE(public.is_owner(), FALSE) THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    IF p_badge_id NOT IN ('founding_crew', 'founder', 'feedback', 'bug_catcher') THEN
        RAISE EXCEPTION 'badge % is not grantable', p_badge_id;
    END IF;

    INSERT INTO public.earned_badges (user_id, badge_id, earned_at, granted_by)
    VALUES (p_user_id, p_badge_id, now(), auth.uid())
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- TRUE when this call awarded it, FALSE when they already held it.
    RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.grant_badge(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_badge(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. list_feedback with the author's id
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_feedback();
CREATE FUNCTION public.list_feedback()
RETURNS TABLE (
    id           UUID,
    message      TEXT,
    app_version  TEXT,
    app_build    TEXT,
    os_version   TEXT,
    device_model TEXT,
    username     TEXT,
    created_at   TIMESTAMPTZ,
    user_id      UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- COALESCE: is_owner() is NULL, not FALSE, when auth.uid() is NULL (a session with no JWT
    -- subject), and IF NOT NULL does not take the branch. Only trusted server roles can be in
    -- that position (anon has no EXECUTE), but the gate should not depend on it.
    IF NOT COALESCE(public.is_owner(), FALSE) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        f.id,
        f.message,
        f.app_version,
        f.app_build,
        f.os_version,
        f.device_model,
        u.username,
        f.created_at,
        f.user_id
    FROM public.feedback f
    LEFT JOIN public.users u ON u.id = f.user_id
    WHERE NOT f.handled
    ORDER BY f.created_at ASC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_feedback() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_feedback() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_feedback() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. The ratchet with the Recruiter predicate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ratchet_badges(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- first_light: their first frame ever, full stop.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'first_light', MIN(p.taken_at)
    FROM public.photos p
    WHERE p.user_id = p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_roll: shot into the roll on both sides of its halfway point, on a
    -- roll that actually developed.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'full_roll', MIN(agg.earned_at)
    FROM (
        SELECT
            BOOL_OR(p.taken_at < r.created_at + INTERVAL '6 hours') AS shot_early,
            MIN(p.taken_at) FILTER (WHERE p.taken_at >= r.created_at + INTERVAL '6 hours') AS earned_at
        FROM public.rolls r
        JOIN public.photos p ON p.roll_id = r.id AND p.user_id = p_user_id
        WHERE public.is_roll_developed(r.id)
        GROUP BY r.id, r.created_at
    ) agg
    WHERE agg.shot_early AND agg.earned_at IS NOT NULL
    HAVING MIN(agg.earned_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- darkroom: had a perfect reveal-opening streak at some point, across
    -- every developed roll they were ever a member of. Frozen the instant
    -- this INSERT first lands -- a later skipped reveal no longer removes it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'darkroom', MAX(v.viewed_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    LEFT JOIN public.roll_reveal_views v
        ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
    WHERE rm.user_id = p_user_id
      AND public.is_roll_developed(r.id)
    HAVING COUNT(r.id) > 0 AND COUNT(r.id) = COUNT(v.viewed_at)
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- founding_100: signup_ordinal <= 100. earned_at = the account's own
    -- created_at (the ordinal was decided at signup), never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT u.id, 'founding_100', u.created_at
    FROM public.users u
    WHERE u.id = p_user_id
      -- 2026-09-08: the hundred are the first hundred PEOPLE. An account hidden from
      -- discovery (the App Review login) keeps its ordinal, the ordinal stays immutable,
      -- but it neither earns this nor takes a seat: the rank counted here skips it, so
      -- the 101st ordinal is the 100th founder when one hidden account sits before it.
      AND NOT u.hidden_from_discovery
      AND (SELECT count(*) FROM public.users x
           WHERE NOT x.hidden_from_discovery AND x.signup_ordinal <= u.signup_ordinal) <= 100
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- first_in: first to open a roll's reveal, on a roll with >= 2 MEMBERS
    -- (an empty race beats no one). Ranked with a deterministic tiebreak so
    -- this is stable forever once earned.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    )
    SELECT p_user_id, 'first_in', MIN(r.viewed_at)
    FROM ranked r
    JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
    WHERE r.user_id = p_user_id AND r.rn = 1
    HAVING MIN(r.viewed_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- roll_maker: created a roll that went on to hold at least one photo
    -- from anyone. The photo requirement keeps this from being farmable by
    -- creating and abandoning empty rolls.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'roll_maker', MIN(r.created_at)
    FROM public.rolls r
    WHERE r.created_by = p_user_id
      AND EXISTS (SELECT 1 FROM public.photos p WHERE p.roll_id = r.id)
    HAVING MIN(r.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- brought_someone: someone signed up using this user's invite code.
    -- Records only that it happened and when (u.created_at), never who.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'brought_someone', MIN(u.created_at)
    FROM public.allowed_emails ae
    JOIN public.users u ON lower(u.email) = ae.email
    WHERE ae.note = 'invited_by:' || p_user_id::text
    HAVING MIN(u.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- joined_in: joined a roll (roll_members) that somebody ELSE created.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'joined_in', MIN(rm.joined_at)
    FROM public.roll_members rm
    JOIN public.rolls r ON r.id = rm.roll_id
    WHERE rm.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(rm.joined_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chipped_in: shot at least one photo into a roll they did not create.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chipped_in', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.rolls r ON r.id = p.roll_id
    WHERE p.user_id = p_user_id
      AND r.created_by <> p_user_id
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- shared: posted a frame to the feed, full stop. earned_at is the
    -- honest global first posts.created_at; the covered-post gate is
    -- applied at READ time by profile_badges, not here.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'shared', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- well_met: somebody ELSE reacted to one of their photos. Excludes
    -- self-reactions. Deliberately photo_reactions (not post_reactions) ,
    -- see five_more_badges.sql's header for the full reasoning.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'well_met', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE p.user_id = p_user_id
      AND pr.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_house: a roll reaches >= 5 DISTINCT CONTRIBUTORS, and this user
    -- is one of them. See five_more_badges.sql's own comment for the full
    -- >= vs = reasoning and the shared-earned_at behaviour.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH roll_contributors AS (
        SELECT p.roll_id, p.user_id AS contributor_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        WHERE p.roll_id IS NOT NULL
        GROUP BY p.roll_id, p.user_id
    ), ranked AS (
        SELECT roll_id, contributor_id, first_shot,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY first_shot ASC, contributor_id ASC) AS rn
        FROM roll_contributors
    ), roll_threshold AS (
        SELECT roll_id, first_shot AS threshold_at
        FROM ranked
        WHERE rn = 5
    )
    SELECT p_user_id, 'full_house', MIN(rt.threshold_at)
    FROM roll_threshold rt
    JOIN ranked me ON me.roll_id = rt.roll_id AND me.contributor_id = p_user_id
    HAVING MIN(rt.threshold_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- front_row -- NEW. See PART 1's matching block for the full comment.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT roll_id, user_id, viewed_at,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY viewed_at ASC, user_id ASC) AS rn
        FROM public.roll_reveal_views
    ), qualifying_rolls AS (
        SELECT roll_id FROM public.roll_members GROUP BY roll_id HAVING COUNT(*) >= 2
    ), my_wins AS (
        SELECT r.roll_id, r.viewed_at,
               ROW_NUMBER() OVER (ORDER BY r.viewed_at ASC, r.roll_id ASC) AS frn
        FROM ranked r
        JOIN qualifying_rolls qr ON qr.roll_id = r.roll_id
        WHERE r.user_id = p_user_id AND r.rn = 1
    )
    SELECT p_user_id, 'front_row', viewed_at
    FROM my_wins
    WHERE frn = 5
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- packed_house -- NEW. Identical to full_house above, rn = 10 not 5.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH roll_contributors AS (
        SELECT p.roll_id, p.user_id AS contributor_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        WHERE p.roll_id IS NOT NULL
        GROUP BY p.roll_id, p.user_id
    ), ranked AS (
        SELECT roll_id, contributor_id, first_shot,
               ROW_NUMBER() OVER (PARTITION BY roll_id ORDER BY first_shot ASC, contributor_id ASC) AS rn
        FROM roll_contributors
    ), roll_threshold AS (
        SELECT roll_id, first_shot AS threshold_at
        FROM ranked
        WHERE rn = 10
    )
    SELECT p_user_id, 'packed_house', MIN(rt.threshold_at)
    FROM roll_threshold rt
    JOIN ranked me ON me.roll_id = rt.roll_id AND me.contributor_id = p_user_id
    HAVING MIN(rt.threshold_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- patron -- NEW. Identical lineage join to brought_someone above, rn = 5
    -- over this caller's own invitees ordered by their own created_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH invitees AS (
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || p_user_id::text
    ), ranked AS (
        SELECT created_at,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, invitee_id ASC) AS rn
        FROM invitees
    )
    SELECT p_user_id, 'patron', created_at
    FROM ranked
    WHERE rn = 5
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- cover_to_cover: ten rolls you shot into before they developed.
    -- REWRITTEN (2026-08-18_cover_to_cover_ten_rolls.sql). It used to mean
    -- "every developed roll you were ever a member of contains a photo of
    -- yours", which had the floor at ONE roll and turned out to be trivial:
    -- of its first five holders, three earned it by joining a single roll
    -- and shooting into it. It was also unearnable forever after one miss,
    -- because the missed roll counts against you permanently -- easy for a
    -- brand-new account and impossible for an engaged one, which is exactly
    -- backwards. Cumulative counting fixes both: it always progresses, one
    -- skipped roll never poisons it, and ten is real work.
    -- Same rank-the-nth shape as every other threshold badge here, so a
    -- later eleventh roll can never displace the recorded earned_at.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH mine AS (
        SELECT p.roll_id, MIN(p.taken_at) AS first_shot
        FROM public.photos p
        JOIN public.rolls r ON r.id = p.roll_id
        WHERE p.user_id = p_user_id
          AND public.is_roll_developed(r.id)
        GROUP BY p.roll_id
    ), ranked AS (
        SELECT first_shot,
               ROW_NUMBER() OVER (ORDER BY first_shot ASC, roll_id ASC) AS rn
        FROM mine
    )
    SELECT p_user_id, 'cover_to_cover', first_shot
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- kept_one -- NEW. See PART 1's matching block for what "developed but
    -- never shared" means here and why develops_at (not is_developed) is
    -- the condition.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH kept AS (
        SELECT p.taken_at, p.id,
               ROW_NUMBER() OVER (ORDER BY p.taken_at ASC, p.id ASC) AS rn
        FROM public.photos p
        WHERE p.user_id = p_user_id
          AND p.develops_at <= now()
          AND NOT EXISTS (SELECT 1 FROM public.posts po WHERE po.photo_id = p.id)
    )
    SELECT p_user_id, 'kept_one', taken_at
    FROM kept
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- regular -- NEW. Seven distinct app_open days. Not retroactive; see
    -- this file's header.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH days AS (
        SELECT DISTINCT day
        FROM public.usage_events
        WHERE user_id = p_user_id AND event = 'app_open'
    ), ranked AS (
        SELECT day, ROW_NUMBER() OVER (ORDER BY day ASC) AS rn
        FROM days
    )
    SELECT p_user_id, 'regular', day::timestamptz
    FROM ranked
    WHERE rn = 7
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- one_year: a year old, AND still shooting.
    -- Was pure tenure: "now() >= created_at + 1 year", nothing else. That made
    -- it the only badge in the catalogue reachable by doing nothing, which is
    -- survivable at silver and wrong at gold -- and 14 of 48 accounts have never
    -- shot a single frame, so the first cohort to reach a passive gold badge
    -- would have been mostly dormant accounts collecting a medal for existing.
    --
    -- Now it needs a frame taken ON OR AFTER the first anniversary. Monotonic
    -- like everything else here: once true it stays true, and it is never
    -- blocked -- miss your anniversary week and any later frame still earns it,
    -- unlike a "shot during month twelve" window which would shut forever.
    -- earned_at is that qualifying frame, the honest instant both halves became
    -- true, never now().
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'one_year', MIN(p.taken_at)
    FROM public.photos p
    JOIN public.users u ON u.id = p.user_id
    WHERE p.user_id = p_user_id
      AND p.taken_at >= u.created_at + INTERVAL '1 year'
    HAVING MIN(p.taken_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- open_door -- NEW. Same lineage join as patron/brought_someone, rn = 10.
    -- Ten is chosen off real numbers, not a round figure: the top inviter in
    -- production has 24 joined invitees and the next has 9, so ten is held by
    -- exactly one account today with a second one invite away. Twenty would
    -- have sat empty for years.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH invitees AS (
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || p_user_id::text
    ), ranked AS (
        SELECT created_at,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, invitee_id ASC) AS rn
        FROM invitees
    )
    SELECT p_user_id, 'open_door', created_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- chimed_in -- NEW. Reacted to SOMEBODY ELSE'S photo. The mirror of
    -- well_met, which fires when someone reacts to yours: one rewards being
    -- seen, this one rewards looking.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'chimed_in', MIN(pr.created_at)
    FROM public.photo_reactions pr
    JOIN public.photos p ON p.id = pr.photo_id
    WHERE pr.user_id = p_user_id
      AND p.user_id <> p_user_id
    HAVING MIN(pr.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- in_frame -- NEW. Somebody tagged you in a photo. Nothing you can do to
    -- cause it, which is the point: it marks being part of someone's roll.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'in_frame', MIN(pt.created_at)
    FROM public.post_tags pt
    WHERE pt.tagged_user_id = p_user_id
    HAVING MIN(pt.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- spotter -- NEW. You tagged someone else in one of your own posts.
    -- Self-tags excluded, or this would fire for anyone who tapped their own
    -- face once.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'spotter', MIN(pt.created_at)
    FROM public.post_tags pt
    JOIN public.posts po ON po.id = pt.post_id
    WHERE po.user_id = p_user_id
      AND pt.tagged_user_id <> p_user_id
    HAVING MIN(pt.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- said_it -- NEW. Wrote a caption. Reads posts.caption, NOT photos.caption:
    -- both columns exist, but a caption is typed when a frame is posted, so
    -- photos.caption holds 0 rows in production against posts.caption's 47.
    -- Written against photos first, which made the badge unearnable by anyone
    -- -- caught because the backfill granted it to nobody at all.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'said_it', MIN(po.created_at)
    FROM public.posts po
    WHERE po.user_id = p_user_id
      AND po.caption IS NOT NULL
      AND btrim(po.caption) <> ''
    HAVING MIN(po.created_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- ten_frames -- NEW. The tenth frame ever shot, ranked so earned_at pins to
    -- that frame and a later eleventh can never move it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT p.taken_at,
               ROW_NUMBER() OVER (ORDER BY p.taken_at ASC, p.id ASC) AS rn
        FROM public.photos p
        WHERE p.user_id = p_user_id
    )
    SELECT p_user_id, 'ten_frames', taken_at
    FROM ranked
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- good_company: TEN people follow you.
    -- Shipped as "somebody followed you", which the backfill granted to all 48
    -- accounts: every account HAS a follower by construction, because
    -- 2026-08-14_auto_follow_owner_backfill.sql wires one up at signup. A badge
    -- every account holds on arrival is a side effect wearing a pill, and it
    -- dilutes the bronze rung it sits on.
    -- Five was tried first and was still too generous, landing on 35 of 48.
    -- Measured across candidate thresholds -- 5:35, 8:24, 10:22, 12:20, 15:14 --
    -- ten is where the curve flattens, and the last round number before the
    -- badge starts excluding people who genuinely have an audience.
    -- Ranked rather than counted so earned_at pins to the tenth follow and an
    -- eleventh can never move it.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked_follows AS (
        SELECT f.created_at,
               ROW_NUMBER() OVER (ORDER BY f.created_at ASC, f.follower_id ASC) AS rn
        FROM public.follows f
        WHERE f.following_id = p_user_id
    )
    SELECT p_user_id, 'good_company', created_at
    FROM ranked_follows
    WHERE rn = 10
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- spotlight (2026-09-25): a frame of theirs chosen and published in Spotlight. earned_at is
    -- the week's publish time. A frame taken out after publish still counts (the badge stays);
    -- one removed before publish never went out, so it does not. publish_spotlight_week runs
    -- this for each chosen person inside its own transaction.
    -- Hardening (2026-09-25): a hidden photo or a covered post never earns it, the same rule
    -- publish_spotlight_week counts by.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    SELECT p_user_id, 'spotlight', MIN(w.published_at)
    FROM public.spotlight_entries e
    JOIN public.spotlight_weeks w ON w.week_key = e.week_key
    JOIN public.posts po ON po.id = e.post_id
    WHERE e.user_id = p_user_id
      AND e.chosen_at IS NOT NULL
      AND w.published_at IS NOT NULL
      AND (e.removed_at IS NULL OR e.removed_at >= w.published_at)
      AND NOT po.hidden
      AND NOT EXISTS (SELECT 1 FROM public.photos ph WHERE ph.id = po.photo_id AND ph.hidden)
      AND NOT public.post_is_covered(po.user_id, po.created_at)
    HAVING MIN(w.published_at) IS NOT NULL
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- recruiter (2026-09-29): three people who joined through this user, however they came in
    -- (the same 'invited_by:<uuid>' lineage as brought_someone, patron and open_door: a personal,
    -- campaign or roll code), are still shooting a month in: the account is at least 30 days old
    -- and took a frame on or after its 30th day. earned_at is the frame that made the third one
    -- count, ranked so a fourth can never move it and a later quiet spell can never take it away.
    -- Index path: allowed_emails_note_idx, users_email_lower_idx, then the photos (user_id,
    -- taken_at) index for the first late frame.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH qualifying AS (
        SELECT u.id AS invitee_id, late.taken_at AS qualified_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        CROSS JOIN LATERAL (
            SELECT p.taken_at
            FROM public.photos p
            WHERE p.user_id = u.id
              AND p.taken_at >= u.created_at + INTERVAL '30 days'
            ORDER BY p.taken_at ASC
            LIMIT 1
        ) late
        WHERE ae.note = 'invited_by:' || p_user_id::text
          AND u.id <> p_user_id
          AND u.created_at <= now() - INTERVAL '30 days'
    ), ranked AS (
        SELECT qualified_at,
               ROW_NUMBER() OVER (ORDER BY qualified_at ASC, invitee_id ASC) AS rn
        FROM qualifying
    )
    SELECT p_user_id, 'recruiter', qualified_at
    FROM ranked
    WHERE rn = 3
    ON CONFLICT (user_id, badge_id) DO NOTHING;

    -- full_set: TWENTY other badge ids, LAST.
    -- Was ten, which the catalogue outgrew: adding seven badges in one day took
    -- its holders from 3 to 9 without anyone doing anything, because a fixed
    -- count gets easier every time the catalogue grows. Twenty is 80% of the 25
    -- a normal account can actually obtain (the other four are hand-granted or
    -- the closed founding window), so it reads as "you have nearly everything"
    -- rather than "you have a third of it".
    -- Still must run after every predicate above in this same pass: it is the
    -- only one that reads the ledger it writes to. WHERE badge_id NOT IN
    -- ('full_set', ...) is the explicit cannot-count-itself guarantee, and keeps the
    -- editorial spotlight badge and the owner-awarded feedback and bug_catcher (2026-09-29)
    -- out of a count meant to be reached by effort.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH ranked AS (
        SELECT eb.earned_at,
               ROW_NUMBER() OVER (ORDER BY eb.earned_at ASC, eb.badge_id ASC) AS rn
        FROM public.earned_badges eb
        WHERE eb.user_id = p_user_id
          AND eb.badge_id NOT IN ('full_set', 'spotlight', 'feedback', 'bug_catcher')
    )
    SELECT p_user_id, 'full_set', earned_at
    FROM ranked
    WHERE rn = 20
    ON CONFLICT (user_id, badge_id) DO NOTHING;
END;
$function$
;

REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM PUBLIC, anon, authenticated;

-- 5. The rating prompt's four "asked" counters (1.6.2, ReviewPrompt): which good moment asked.
--    A superset of the live list, so nothing already logged can fail it. The events only say the
--    app asked; whether Apple showed the card, or what anyone gave, is never known.
ALTER TABLE public.usage_events DROP CONSTRAINT IF EXISTS usage_events_event_check;
ALTER TABLE public.usage_events ADD CONSTRAINT usage_events_event_check CHECK (event IN (
    'app_open', 'photo_captured', 'post_shared', 'feed_viewed', 'reveal_watched',
    'invite_shared_profile', 'invite_shared_feed', 'invite_shared_reveal',
    'spotlight_put_up', 'spotlight_withdraw', 'spotlight_strip_open', 'spotlight_weeks_open',
    'review_asked_spotlight', 'review_asked_reveal', 'review_asked_tenth_post', 'review_asked_reactions'
));
