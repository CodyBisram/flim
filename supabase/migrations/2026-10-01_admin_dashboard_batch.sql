-- Admin dashboard batch (2026-10-01, owner ask). APPLIED 2026-10-01 by the owner.
--
-- Five owner-only RPCs for the dashboard, all SECURITY DEFINER with search_path pinned, all gated
-- inside their own bodies by `is_owner() IS NOT TRUE` (a NULL answer refuses, the guard
-- list_photo_reports uses), EXECUTE revoked from PUBLIC and anon and granted to authenticated.
-- Nothing here adds a table, a column, a policy or a grant on a table. Rerunnable as a whole.
--
--   1. admin_where()                       where people are, by the phone's IANA time zone
--                                          (client_versions.timezone, 2026-09-29_client_timezone.sql).
--   2. admin_set_user_hidden(uuid, bool)   the first server path that writes
--                                          users.hidden_from_discovery; until now it was set by hand
--                                          in the SQL editor. Refuses the owner and the review login.
--   3. admin_user_recent_posts(uuid, int)  one account's newest posts with their storage paths.
--   4. admin_overview()                    two open review findings fixed (docs/reviews/OPEN.md,
--                                          raised 2026-09-01), return shape unchanged.
--   5. admin_push_health(int)              pushes per New York day per kind, from the ledgers the
--                                          push functions already write. No edge function changes.

-- ---------------------------------------------------------------------------------------------
-- 1. Where people are. One row per distinct client_versions.timezone (NULL is its own row: a
--    build older than the stamp, or a value report_client_version refused). Excludes the owner
--    and the review login (username applereview, or a hidden account named applereview plus
--    digits), so the panel counts people.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_where()
 RETURNS TABLE(timezone text, people bigint, seen_this_week bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF public.is_owner() IS NOT TRUE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT cv.timezone,
           count(*)::bigint,
           (count(*) FILTER (WHERE cv.updated_at > now() - interval '7 days'))::bigint
    FROM public.client_versions cv
    WHERE cv.user_id IS DISTINCT FROM public.owner_user_id()
      AND NOT EXISTS (
          SELECT 1 FROM public.users u
          WHERE u.id = cv.user_id
            AND (lower(u.username) = 'applereview'
                 OR (u.hidden_from_discovery AND lower(u.username) ~ '^applereview[0-9]*$')))
    GROUP BY cv.timezone
    ORDER BY 2 DESC, 1 ASC NULLS LAST;
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_where() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_where() TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. Hide or show an account in suggestions. hidden_from_discovery is a suggestion filter, not a
--    privacy boundary: the app drops these accounts from every Find friends section, and they
--    neither earn Founding 100 nor take a seat in its count. Profiles, posts, search, follows and
--    rolls are untouched. Returns true when the account exists and now holds p_hidden (setting
--    the value it already had counts, Postgres reports the row as updated); false for anyone but
--    the owner, for a NULL argument, for an unknown id, for the owner's own account, and for the
--    review login (which must stay hidden).
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_user_hidden(p_user_id uuid, p_hidden boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF public.is_owner() IS NOT TRUE THEN
        RETURN false;
    END IF;
    IF p_user_id IS NULL OR p_hidden IS NULL OR p_user_id = public.owner_user_id() THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = p_user_id
          AND (lower(u.username) = 'applereview'
               OR (u.hidden_from_discovery AND lower(u.username) ~ '^applereview[0-9]*$'))
    ) THEN
        RETURN false;
    END IF;

    UPDATE public.users SET hidden_from_discovery = p_hidden WHERE id = p_user_id;
    RETURN FOUND;
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_set_user_hidden(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_user_hidden(uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3. One account's newest posts, newest first, p_limit capped to 0..30 (NULL reads as 9). Hidden
--    and covered posts included: this is the owner's review view. Paths are the photo's, as in
--    list_photo_reports; posts carry the same three paths denormalized and kept in step.
--    hidden is true when either the post or its photo is hidden (set_photo_hidden sets both).
--    Served by posts_user_created_idx (user_id, created_at DESC).
--
--    Signing: the owner can sign these paths through "photos: readable when shared to a post"
--    (any post the owner follows the author of, is tagged in, or has in the Spotlight queue, not
--    hidden, not blocked either way), through "photos: owner reads reported" (a photo with an open
--    report), or the owner's own folder. A hidden post with no open report, or a post by someone
--    the owner neither follows nor is tagged by, comes back with paths that will not sign.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_user_recent_posts(p_user_id uuid, p_limit integer DEFAULT 9)
 RETURNS TABLE(post_id uuid, photo_id uuid, created_at timestamp with time zone, caption text,
               thumb_path text, feed_path text, storage_path text, hidden boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF public.is_owner() IS NOT TRUE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT po.id,
           po.photo_id,
           po.created_at,
           po.caption,
           ph.thumb_path,
           ph.feed_path,
           ph.storage_path,
           (po.hidden OR ph.hidden)
    FROM public.posts po
    JOIN public.photos ph ON ph.id = po.photo_id
    WHERE po.user_id = p_user_id
    ORDER BY po.created_at DESC NULLS LAST, po.id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 9), 0), 30);
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_user_recent_posts(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_user_recent_posts(uuid, integer) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4. admin_overview, two fixes, same jsonb keys (production's definition read back 2026-10-01,
--    identical to schema.sql's, with only these two changes):
--
--    a. attention.never_asked_notifications now counts exactly what admin_reach()'s never_asked
--       counts: every account (auth.users) with neither a notifications_authorized nor a
--       notifications_denied event. It used to also require no device_tokens row, and to count
--       public.users, so the two panels showed different numbers for the same question.
--    b. week.reveals compared an 8-day "now" (day >= today - 7, today included) against a 7-day
--       "prev". Both windows are now 7 UTC days: now = today and the 6 days before it, prev = the
--       7 days before that. usage_events.day is a UTC date, so "today" is read in UTC explicitly.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_overview()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH gate AS (SELECT public.is_owner() AS ok),
  w AS (
    SELECT now() AS t_now,
           now() - interval '7 days'  AS t0,
           now() - interval '14 days' AS t1,
           ((now() AT TIME ZONE 'utc')::date - 6)  AS d0,
           ((now() AT TIME ZONE 'utc')::date - 13) AS d1
  )
  SELECT CASE WHEN (SELECT ok FROM gate) THEN jsonb_build_object(
    'generated_at', (SELECT t_now FROM w),

    'totals', jsonb_build_object(
      'users',     (SELECT count(*) FROM public.users),
      'ever_shot', (SELECT count(DISTINCT user_id) FROM public.photos),
      'photos',    (SELECT count(*) FROM public.photos),
      'rolls',     (SELECT count(*) FROM public.rolls)
    ),

    'week', jsonb_build_object(
      'new_users', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.users, w WHERE created_at >= t0),
        'prev', (SELECT count(*) FROM public.users, w WHERE created_at >= t1 AND created_at < t0)),
      'active_shooters', jsonb_build_object(
        'now',  (SELECT count(DISTINCT user_id) FROM public.photos, w WHERE taken_at >= t0),
        'prev', (SELECT count(DISTINCT user_id) FROM public.photos, w WHERE taken_at >= t1 AND taken_at < t0)),
      'shots', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.photos, w WHERE taken_at >= t0),
        'prev', (SELECT count(*) FROM public.photos, w WHERE taken_at >= t1 AND taken_at < t0)),
      'posts', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.posts, w WHERE created_at >= t0),
        'prev', (SELECT count(*) FROM public.posts, w WHERE created_at >= t1 AND created_at < t0)),
      'reveals', jsonb_build_object(
        'now',  (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events, w
                  WHERE event = 'reveal_watched' AND day >= d0),
        'prev', (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events, w
                  WHERE event = 'reveal_watched' AND day >= d1 AND day < d0)),
      'invites_redeemed', jsonb_build_object(
        'now',  (SELECT count(*) FROM public.allowed_emails, w
                  WHERE note LIKE 'invited_by:%' AND added_at >= t0),
        'prev', (SELECT count(*) FROM public.allowed_emails, w
                  WHERE note LIKE 'invited_by:%' AND added_at >= t1 AND added_at < t0))
    ),

    -- Which surface an invite share came from. All-time volume, since the
    -- question is "does the reveal placement get used at all", not this week only.
    'invite_sources', jsonb_build_object(
      'profile', (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events WHERE event = 'invite_shared_profile'),
      'feed',    (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events WHERE event = 'invite_shared_feed'),
      'reveal',  (SELECT coalesce(sum(occurrences), 0) FROM public.usage_events WHERE event = 'invite_shared_reveal')
    ),

    -- New users per day, oldest first, last 14 days. A trend strip for the panel.
    'signups_daily', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'day', to_char(dd, 'MM-DD'),
               'n',   (SELECT count(*) FROM public.users u
                        WHERE u.created_at >= dd AND u.created_at < dd + interval '1 day'))
             ORDER BY dd), '[]'::jsonb)
      FROM generate_series((current_date - 13)::timestamptz, current_date::timestamptz, interval '1 day') dd
    ),

    'attention', jsonb_build_object(
      -- admin_reach()'s never_asked, exactly: everyone the prompt never reached.
      'never_asked_notifications', (
        SELECT count(*) FROM auth.users u
        WHERE NOT EXISTS (SELECT 1 FROM public.activation_events a
                          WHERE a.user_id = u.id AND a.event = 'notifications_authorized')
          AND NOT EXISTS (SELECT 1 FROM public.activation_events a
                          WHERE a.user_id = u.id AND a.event = 'notifications_denied')),
      'invite_senders_ever', (
        SELECT count(DISTINCT substring(note FROM 12))
        FROM public.allowed_emails WHERE note LIKE 'invited_by:%'),
      'days_since_last_roll', (
        SELECT floor(extract(epoch FROM now() - max(created_at)) / 86400)::int
        FROM public.rolls)
    )
  ) ELSE NULL END;
$function$;
REVOKE ALL ON FUNCTION public.admin_overview() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_overview() TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- 5. Push health: per New York day, per kind, for the last p_days days (1..90, NULL reads as
--    14), oldest first. Sparse: a day and kind with nothing recorded has no row. Built only from
--    what the push functions already write:
--
--      social    push_deliveries, every kind but develop (comment, comment_like, post_reaction,
--                photo_comment, photo_reaction, tag, follow, followup, earnback,
--                spotlight_chosen), written by send-social-push. One row per (kind, source,
--                recipient), stamped at its latest attempt. sent = delivered rows, failed = rows
--                not delivered (every device refused, retried up to three runs). A recipient with
--                no device at all is written as delivered, so sent counts "settled", not "landed
--                on a phone".
--      develop   push_deliveries kind develop, written by send-develop-push. Same semantics.
--      digest    digest_state.last_sent_at, written by send-daily-digest. ONE row per person,
--                overwritten on every digest, so only each person's latest digest survives:
--                earlier days undercount. Written even when APNs refused every device, so
--                failed is NULL (not recorded).
--      one_shot  one_shot_push, written by send-one-shot-push. A claim is made before sending
--                and sent_at is set only when a device accepted. sent = rows with sent_at, by
--                that day; failed = claims never sent, by their claim day.
--
--    Not recorded anywhere with a time, so absent here: "reacted to a photo you're in" (sent with
--    no ledger key), the owner's own report and ops alert pushes (push_sent booleans only), and
--    notify-owner.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_push_health(p_days integer DEFAULT 14)
 RETURNS TABLE(day date, kind text, sent bigint, failed bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_first date := (now() AT TIME ZONE 'America/New_York')::date
                    - (LEAST(GREATEST(COALESCE(p_days, 14), 1), 90) - 1);
    v_from  timestamptz := v_first::timestamp AT TIME ZONE 'America/New_York';
BEGIN
    IF public.is_owner() IS NOT TRUE THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH ledger AS (
        SELECT (pd.updated_at AT TIME ZONE 'America/New_York')::date AS d,
               CASE WHEN pd.kind = 'develop' THEN 'develop' ELSE 'social' END AS k,
               count(*) FILTER (WHERE pd.delivered)     AS s,
               count(*) FILTER (WHERE NOT pd.delivered) AS f
        FROM public.push_deliveries pd
        WHERE pd.updated_at >= v_from
        GROUP BY 1, 2
        UNION ALL
        SELECT (ds.last_sent_at AT TIME ZONE 'America/New_York')::date,
               'digest',
               count(*),
               NULL::bigint
        FROM public.digest_state ds
        WHERE ds.last_sent_at >= v_from
        GROUP BY 1
        UNION ALL
        SELECT (COALESCE(o.sent_at, o.claimed_at) AT TIME ZONE 'America/New_York')::date,
               'one_shot',
               count(o.sent_at),
               count(*) FILTER (WHERE o.sent_at IS NULL)
        FROM public.one_shot_push o
        WHERE COALESCE(o.sent_at, o.claimed_at) >= v_from
        GROUP BY 1
    )
    SELECT l.d, l.k, l.s, l.f
    FROM ledger l
    ORDER BY l.d ASC, l.k ASC;
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_push_health(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_push_health(integer) TO authenticated;

-- Check, as the owner in the dashboard (each returns nothing, false or NULL for anyone else):
--   select * from public.admin_where();
--   select * from public.admin_user_recent_posts('<user id>', 9);
--   select admin_overview() -> 'attention' -> 'never_asked_notifications',
--          admin_overview() -> 'attention' -> 'never_asked_notifications' = admin_reach() -> 'never_asked';  -- true
--   select * from public.admin_push_health(14);

-- ---------------------------------------------------------------------------------------------
-- 6. Founding 100 counts member numbers only (2026-10-01). `_ratchet_badges` skipped accounts
--    hidden from discovery, which kept the App Review login out of the hundred. That login has
--    had no number since 2026-09-29, and the dashboard can now hide a real person from
--    suggestions (`admin_set_user_hidden`), which must not move anyone's Founding rank. Same
--    signature; the body is production's as of 2026-10-01 with only the founding_100 test
--    changed. Identical results today: the only hidden account has no number.
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
$function$;
