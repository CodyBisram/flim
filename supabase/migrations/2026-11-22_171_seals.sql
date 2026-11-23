-- FLIM 1.7.1: seals (docs/SEALS_1_7_1.md, section 4). APPLIED to production 2026-11-22; not applied to FLIM Dev.
--
-- Apply BEFORE the 1.7.1 build reaches testers (the app falls back to no progress if the RPC is
-- missing, so applying early is safe). Safe for 1.7.0 clients: it adds two functions, keeps
-- mark_own_badges_seen() unchanged, and changes only which of an account's own seals comes
-- first when it has never chosen one (section 4). Rerunnable.
--
-- 1. _ratchet_badges: Good Company becomes TEN FRIENDS. Re-issued in full from production's body
--    (identical to schema.sql's 2026-10-01 definition, checked 2026-11-22) with only the
--    good_company block and its comment changed. The ratchet never deletes a row, so everyone who
--    holds Good Company today keeps it.
-- 2. own_seal_progress(): progress toward every seal the caller has not earned yet.
-- 3. mark_own_badge_seen(p_badge_id): marks one seal seen (the sheet clears one red dot per card).
-- 4. _resolve_effective_displayed_badges: the automatic default ("rarest") sorts by tier first,
--    then fewest holders, then newest, as the 1.7.1 page seal is specified.

-- 1. Good Company: ten friends. ------------------------------------------------------------------
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
      -- 2026-10-01: a seat is a member NUMBER, nothing else. Until today an account hidden from
      -- discovery took no seat, which was how the App Review login was kept out; since
      -- 2026-09-29 that login has no number at all, so the hidden test is gone. Hiding a real
      -- person from suggestions (the dashboard can now) must not move anyone's Founding rank.
      -- 2026-09-29: an account with no number (the review login, which no longer takes one)
      -- never earns it. Without this line a NULL ordinal counts nobody ahead of it, so the
      -- rank test below would read 0 and pass.
      AND u.signup_ordinal IS NOT NULL
      AND (SELECT count(*) FROM public.users x
           WHERE x.signup_ordinal IS NOT NULL AND x.signup_ordinal <= u.signup_ordinal) <= 100
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

    -- good_company: TEN FRIENDS (2026-11-22, 1.7.1). A friend is someone you follow who follows
    -- you back, the same both-directions test can_see_posts_of has used since 1.7. Was "ten
    -- people follow you" (2026-08-18_good_company_ten.sql), which stopped meaning anything once
    -- 1.7 turned a one-way follow into a request: it rewarded requests nobody had answered.
    -- earned_at is the moment the tenth friendship formed, the later of its two follow rows,
    -- ranked so an eleventh can never move it. A pair with no timestamp on either row (none
    -- exist; follows.created_at defaults to now()) is skipped rather than inserting a NULL
    -- earned_at, and own_seal_progress counts friends with the same test. Unfollowing later never
    -- takes it away: nothing here deletes a row. Index path: follows_follower_idx for my rows,
    -- the follows primary key (follower_id, following_id) for each one back.
    INSERT INTO public.earned_badges (user_id, badge_id, earned_at)
    WITH friends AS (
        SELECT mine.following_id AS friend_id,
               GREATEST(mine.created_at, back.created_at) AS formed_at
        FROM public.follows mine
        JOIN public.follows back
            ON back.follower_id = mine.following_id AND back.following_id = mine.follower_id
        WHERE mine.follower_id = p_user_id
          AND GREATEST(mine.created_at, back.created_at) IS NOT NULL
    ), ranked_friends AS (
        SELECT formed_at,
               ROW_NUMBER() OVER (ORDER BY formed_at ASC, friend_id ASC) AS rn
        FROM friends
    )
    SELECT p_user_id, 'good_company', formed_at
    FROM ranked_friends
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
$function$;
REVOKE ALL ON FUNCTION public._ratchet_badges(UUID) FROM PUBLIC, anon, authenticated;

-- 2. own_seal_progress(): how close the caller is to every seal they have not earned yet. ---------
--    One row per earnable seal that has a progress form (docs/SEALS_1_7_1.md section 2) and is
--    not in the caller's earned_badges. Zero arguments, pinned to auth.uid(), like every other
--    "own" badge function: nobody can read anyone else's progress.
--
--    It ratchets first, the same call refresh_own_badges makes, so the rows are read after
--    everything already true has been recorded. That is what makes "earned exactly when current
--    reaches target" hold: every count below is the predicate of the matching _ratchet_badges
--    block with the rank-the-Nth step replaced by a count, so current >= target can only happen
--    for a seal the ratchet has just written, and that seal is filtered out. Calling this records
--    a newly earned seal (with seen_at NULL, so its red dot shows), exactly as refresh does.
--
--    Forms:
--      count          ten_frames 10, regular 7, good_company 10, front_row 5, cover_to_cover 10,
--                     kept_one 10, patron 5, open_door 10, recruiter 3, full_set 20
--      closest roll   full_house 5, packed_house 10: the most photographers (distinct people with
--                     a frame in it, the ratchet's roll_contributors) on any roll you shot into
--      all of them    darkroom: reveals opened / developed rolls you are a member of. No row
--                     until at least one of your rolls has developed (0 of 0 would read as done).
--      two steps      full_roll: 1 = shot into a developed roll in its first 6 hours, 2 = also
--                     shot into that same roll 6 hours or more after it was created.
--                     roll_maker: 1 = started a roll, 2 = one of your rolls holds a frame (anyone's).
--      date           one_year: due_at = the first anniversary of the account, current/target 0/0.
--    current is capped at target (it can only reach it for a seal written this call).
--
--    Cost: the ratchet (the same pass profile_badges runs on every page view) plus a handful of
--    per-user index lookups: photos_user_idx, photos_roll_user_idx, roll_members_user_idx, the
--    roll_reveal_views and follows primary keys, the usage_events primary key,
--    allowed_emails_note_idx and users_email_lower_idx.
CREATE OR REPLACE FUNCTION public.own_seal_progress()
RETURNS TABLE (badge_id TEXT, current INT, target INT, due_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN
        RETURN;
    END IF;

    PERFORM public._ratchet_badges(v_me);

    RETURN QUERY
    WITH my_rolls AS (
        -- Rolls you shot into (photos.roll_id is a foreign key, so each one exists).
        SELECT DISTINCT p.roll_id
        FROM public.photos p
        WHERE p.user_id = v_me AND p.roll_id IS NOT NULL
    ), developed_rolls AS MATERIALIZED (
        -- is_roll_developed once per roll of yours (cover_to_cover and full_roll both use it),
        -- rather than once per row of rolls before the join.
        SELECT mr.roll_id
        FROM my_rolls mr
        WHERE public.is_roll_developed(mr.roll_id)
    ), invitees AS (
        -- The invite lineage brought_someone, patron, open_door and recruiter all read.
        SELECT u.id AS invitee_id, u.created_at
        FROM public.allowed_emails ae
        JOIN public.users u ON lower(u.email) = ae.email
        WHERE ae.note = 'invited_by:' || v_me::text
    ), closest AS (
        -- full_house / packed_house: earned when a roll you shot into has N contributors.
        SELECT COALESCE(MAX(c.photographers), 0)::int AS photographers
        FROM (
            SELECT COUNT(DISTINCT p.user_id) AS photographers
            FROM my_rolls mr
            JOIN public.photos p ON p.roll_id = mr.roll_id
            GROUP BY mr.roll_id
        ) c
    ), reveals AS (
        -- darkroom: COUNT(r.id) = COUNT(v.viewed_at) over developed rolls you are a member of.
        SELECT COUNT(v.viewed_at)::int AS opened, COUNT(*)::int AS counted
        FROM public.roll_members rm
        LEFT JOIN public.roll_reveal_views v
            ON v.roll_id = rm.roll_id AND v.user_id = rm.user_id
        WHERE rm.user_id = v_me
          AND public.is_roll_developed(rm.roll_id)
    ), full_roll_steps AS (
        -- full_roll: a developed roll with a frame of yours on both sides of created_at + 6h.
        SELECT CASE
                   WHEN COALESCE(BOOL_OR(agg.shot_early AND agg.shot_late), FALSE) THEN 2
                   WHEN COALESCE(BOOL_OR(agg.shot_early), FALSE) THEN 1
                   ELSE 0
               END AS done
        FROM (
            SELECT BOOL_OR(p.taken_at < r.created_at + INTERVAL '6 hours') AS shot_early,
                   BOOL_OR(p.taken_at >= r.created_at + INTERVAL '6 hours') AS shot_late
            FROM developed_rolls d
            JOIN public.rolls r ON r.id = d.roll_id
            JOIN public.photos p ON p.roll_id = r.id AND p.user_id = v_me
            GROUP BY r.id
        ) agg
    ), progress (badge_id, current, target, due_at) AS (
        SELECT 'ten_frames'::text,
               (SELECT COUNT(*) FROM public.photos p WHERE p.user_id = v_me)::int,
               10, NULL::timestamptz
        UNION ALL
        SELECT 'regular',
               (SELECT COUNT(DISTINCT ue.day) FROM public.usage_events ue
                WHERE ue.user_id = v_me AND ue.event = 'app_open')::int,
               7, NULL
        UNION ALL
        SELECT 'good_company',
               (SELECT COUNT(*)
                FROM public.follows mine
                JOIN public.follows back
                    ON back.follower_id = mine.following_id AND back.following_id = mine.follower_id
                WHERE mine.follower_id = v_me
                  AND GREATEST(mine.created_at, back.created_at) IS NOT NULL)::int,
               10, NULL
        UNION ALL
        -- front_row: rolls where you are rn = 1 by (viewed_at, user_id) and the roll has at
        -- least two members; "no earlier view" is that same rank without a whole-table window.
        SELECT 'front_row',
               (SELECT COUNT(*)
                FROM public.roll_reveal_views v
                WHERE v.user_id = v_me
                  AND NOT EXISTS (
                      SELECT 1 FROM public.roll_reveal_views o
                      WHERE o.roll_id = v.roll_id
                        AND (o.viewed_at < v.viewed_at
                             OR (o.viewed_at = v.viewed_at AND o.user_id < v.user_id)))
                  AND (SELECT COUNT(*) FROM public.roll_members m WHERE m.roll_id = v.roll_id) >= 2)::int,
               5, NULL
        UNION ALL
        SELECT 'full_house', (SELECT cl.photographers FROM closest cl), 5, NULL
        UNION ALL
        SELECT 'packed_house', (SELECT cl.photographers FROM closest cl), 10, NULL
        UNION ALL
        SELECT 'cover_to_cover',
               (SELECT COUNT(*) FROM developed_rolls)::int,
               10, NULL
        UNION ALL
        SELECT 'kept_one',
               (SELECT COUNT(*) FROM public.photos p
                WHERE p.user_id = v_me
                  AND p.develops_at <= now()
                  AND NOT EXISTS (SELECT 1 FROM public.posts po WHERE po.photo_id = p.id))::int,
               10, NULL
        UNION ALL
        SELECT 'patron', (SELECT COUNT(*) FROM invitees)::int, 5, NULL
        UNION ALL
        SELECT 'open_door', (SELECT COUNT(*) FROM invitees)::int, 10, NULL
        UNION ALL
        SELECT 'recruiter',
               (SELECT COUNT(*) FROM invitees i
                WHERE i.invitee_id <> v_me
                  AND i.created_at <= now() - INTERVAL '30 days'
                  AND EXISTS (SELECT 1 FROM public.photos p
                              WHERE p.user_id = i.invitee_id
                                AND p.taken_at >= i.created_at + INTERVAL '30 days'))::int,
               3, NULL
        UNION ALL
        SELECT 'darkroom', rv.opened, rv.counted, NULL
        FROM reveals rv
        WHERE rv.counted > 0
        UNION ALL
        SELECT 'full_roll', (SELECT fr.done FROM full_roll_steps fr), 2, NULL
        UNION ALL
        SELECT 'roll_maker',
               (SELECT CASE
                           WHEN EXISTS (SELECT 1 FROM public.rolls r
                                        WHERE r.created_by = v_me
                                          AND EXISTS (SELECT 1 FROM public.photos p WHERE p.roll_id = r.id))
                               THEN 2
                           WHEN EXISTS (SELECT 1 FROM public.rolls r WHERE r.created_by = v_me)
                               THEN 1
                           ELSE 0
                       END),
               2, NULL
        UNION ALL
        -- full_set: read after the ratchet, so it counts what it just wrote, with the same
        -- exclusions as its block.
        SELECT 'full_set',
               (SELECT COUNT(*) FROM public.earned_badges eb
                WHERE eb.user_id = v_me
                  AND eb.badge_id NOT IN ('full_set', 'spotlight', 'feedback', 'bug_catcher'))::int,
               20, NULL
        UNION ALL
        SELECT 'one_year', 0, 0, u.created_at + INTERVAL '1 year'
        FROM public.users u
        WHERE u.id = v_me AND u.created_at IS NOT NULL
    )
    SELECT pr.badge_id, LEAST(pr.current, pr.target), pr.target, pr.due_at
    FROM progress pr
    WHERE NOT EXISTS (
        SELECT 1 FROM public.earned_badges eb
        WHERE eb.user_id = v_me AND eb.badge_id = pr.badge_id
    )
    ORDER BY pr.badge_id;
END;
$$;
REVOKE ALL ON FUNCTION public.own_seal_progress() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.own_seal_progress() TO authenticated;

-- 3. mark_own_badge_seen(p_badge_id): one seal's red dot, cleared when its card opens. ------------
--    Same posture as mark_own_badges_seen() (which stays, unchanged, for 1.7.0): pinned to
--    auth.uid(), so a caller can only ever mark their own row. An id the caller does not hold,
--    or NULL, matches nothing and does nothing.
CREATE OR REPLACE FUNCTION public.mark_own_badge_seen(p_badge_id TEXT)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.earned_badges
    SET seen_at = now()
    WHERE user_id = auth.uid()
      AND badge_id = p_badge_id
      AND seen_at IS NULL;
$$;
REVOKE ALL ON FUNCTION public.mark_own_badge_seen(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_own_badge_seen(TEXT) TO authenticated;

-- 4. The automatic default: tier first, then fewest holders, then newest. -------------------------
--    With no choice made (displayed_badges NULL), this used to pin founder, founding_crew and
--    founding_100 first and sort everything else by fewest holders then OLDEST earned_at, with no
--    notion of tier: a rare accent seal beat a common gold one. 1.7.1 shows one seal, specified as
--    "your rarest: tier first, then fewest holders, then newest", and 1.7.0 already shows the
--    front of this list, so both read the same order from here.
--    tier_rank mirrors ProfileBadgeKind.tier (Flim/Models/ProfileIdentity.swift): the founding
--    rung keeps its fixed ladder (founder, founding_crew, founding_100), then gold, silver,
--    bronze, accent; an id added later without a line here sorts last until it gets one.
--    Re-tier a seal in Swift and here together. An explicit choice is unchanged: stored order,
--    never re-sorted, so a chosen seal is always the first row (unless it is a covered 'shared',
--    which a stranger never sees). Same signature and return shape.
CREATE OR REPLACE FUNCTION public._resolve_effective_displayed_badges(p_profile_id UUID, p_viewer UUID)
RETURNS TABLE (badge_id TEXT, earned_at TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_selection TEXT[];
BEGIN
    SELECT u.displayed_badges INTO v_selection
    FROM public.users u
    WHERE u.id = p_profile_id;

    IF v_selection IS NULL THEN
        RETURN QUERY
        SELECT c.badge_id, c.earned_at
        FROM (
            SELECT eb.badge_id, eb.earned_at,
                   CASE
                       WHEN eb.badge_id = 'founder'       THEN 0
                       WHEN eb.badge_id = 'founding_crew' THEN 1
                       WHEN eb.badge_id = 'founding_100'  THEN 2
                       WHEN eb.badge_id IN ('full_set', 'front_row', 'packed_house', 'cover_to_cover',
                                            'open_door', 'one_year', 'spotlight') THEN 3
                       WHEN eb.badge_id IN ('patron', 'darkroom', 'first_in', 'kept_one', 'regular',
                                            'recruiter', 'feedback', 'bug_catcher') THEN 4
                       WHEN eb.badge_id IN ('full_roll', 'roll_maker', 'brought_someone', 'well_met',
                                            'full_house', 'spotter', 'in_frame', 'good_company') THEN 5
                       WHEN eb.badge_id IN ('first_light', 'shared', 'joined_in', 'chipped_in',
                                            'chimed_in', 'said_it', 'ten_frames') THEN 6
                       ELSE 7
                   END AS tier_rank,
                   rarity.holder_count
            FROM public.earned_badges eb
            JOIN (
                SELECT eb2.badge_id, COUNT(DISTINCT eb2.user_id) AS holder_count
                FROM public.earned_badges eb2
                GROUP BY eb2.badge_id
            ) rarity ON rarity.badge_id = eb.badge_id
            WHERE eb.user_id = p_profile_id
              AND (
                  eb.badge_id <> 'shared'
                  OR public.covered_post_visible(p_viewer, p_profile_id, eb.earned_at)
              )
        ) c
        ORDER BY c.tier_rank ASC, c.holder_count ASC, c.earned_at DESC, c.badge_id ASC
        LIMIT 4;
        RETURN;
    END IF;

    -- Explicit selection, possibly '{}' (show none). Never reordered.
    RETURN QUERY
    SELECT eb.badge_id, eb.earned_at
    FROM unnest(v_selection) WITH ORDINALITY AS sel(badge_id, ord)
    JOIN public.earned_badges eb
        ON eb.user_id = p_profile_id AND eb.badge_id = sel.badge_id
    WHERE eb.badge_id <> 'shared'
       OR public.covered_post_visible(p_viewer, p_profile_id, eb.earned_at)
    ORDER BY sel.ord ASC;
END;
$$;
REVOKE ALL ON FUNCTION public._resolve_effective_displayed_badges(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Check, signed in (each is the caller's own state only):
--   select * from public.own_seal_progress();
--   select public.mark_own_badge_seen('ten_frames');
