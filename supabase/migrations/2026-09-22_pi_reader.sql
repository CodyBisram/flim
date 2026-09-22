-- The Pi's read-only database role, fixed (docs/reviews/2026-09-22.md finding 1).
--
-- docs/sql/flim_reader_role.sql, written last night, granted flim_reader plain table SELECT.
-- That role connects as a bare Postgres login over the session pooler, never through
-- PostgREST/GoTrue, so auth.uid() is NULL in its session. Every table it needs is RLS-gated on
-- auth.uid() or scoped TO authenticated, so every query it runs succeeds and returns zero rows,
-- with nothing logged as an error. On Supabase the postgres role cannot grant BYPASSRLS, so the
-- table-grant approach can never work here.
--
-- The fix is the pattern public.nightly_numbers() already uses: a SECURITY DEFINER function
-- owned by postgres, which runs with the owner's privileges regardless of the caller's RLS
-- context, computing exactly what the caller needs and nothing else. flim_reader gets EXECUTE on
-- two such functions and no table grants at all; there is nothing else it can read.
--
-- Confirmed before writing this: nothing in supabase/bootstrap/platform.sql or schema.sql runs
-- ALTER DEFAULT PRIVILEGES ... TO PUBLIC (grep came back empty), and CREATE TABLE never grants
-- to PUBLIC on its own, so a freshly created role gets no table access until something grants it
-- by name. flim_reader is never named in any table grant anywhere in this file.

-- ------------------------------------------------------------
-- 1. The role. NOINHERIT: it should never pick up privileges through group membership later
--    without that being an explicit, visible grant. No password here and no BYPASSRLS (Supabase
--    does not allow postgres to grant that). The password is set once by the owner, by hand, in
--    docs/sql/flim_reader_role.sql; it never belongs in a migration that lives in git history.
-- ------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flim_reader') THEN
        CREATE ROLE flim_reader LOGIN NOINHERIT;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO flim_reader;

-- ------------------------------------------------------------
-- 2. memo_snapshot(): the Monday memo's "What the database says" section, one JSON document,
--    every count a COUNT(*) in SQL, never a fetched-row count (PostgREST's 1000-row cap has
--    already bitten this codebase once, 2026-09-02, a one-shot push cohort silently truncated).
--
--    Sourced from docs/METRICS.md's tested queries and the admin_* functions in
--    2026-08-19_admin_analytics.sql, reshaped to answer the eleven questions the 2026-09-21 data
--    pass defined (docs/PENDING.md, "done 2026-09-21"). Excludes the applereview username in the
--    same narrow spots nightly_numbers() does: durable per-account classifications (who counts
--    as a real account for a cohort or an adoption denominator), never a per-day event count,
--    matching nightly_numbers' own accounts / founding_left split from new_accounts / shooters.
--
--    Not owner-gated with is_owner(): that check reads auth.uid(), which is NULL for a plain
--    login role exactly like the problem this migration exists to fix. This function's only gate
--    is its EXECUTE grant, to flim_reader and service_role alone, at the bottom of this file.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.memo_snapshot()
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH ny AS (
    SELECT (NOW() AT TIME ZONE 'America/New_York')::date AS today
),
days14 AS (
    SELECT (ny.today - g)::date AS d FROM ny, generate_series(0, 13) g
),
actives7 AS (
    SELECT DISTINCT e.user_id
    FROM public.usage_events e, ny
    WHERE e.event = 'app_open' AND e.day >= ny.today - 7
),
gate AS (
    SELECT latest_version FROM public.app_release_gate WHERE id = TRUE
),
retention_cohort AS (
    SELECT ae.user_id AS user_id, MIN(ae.created_at) AS first_open
    FROM public.activation_events ae
    JOIN public.users u ON u.id = ae.user_id AND u.username <> 'applereview'
    WHERE ae.event = 'first_launch' AND ae.created_at >= '2026-08-10'
    GROUP BY ae.user_id
),
retention_acts AS (
    SELECT user_id, taken_at AS at FROM public.photos
    UNION ALL SELECT user_id, created_at FROM public.posts
    UNION ALL SELECT user_id, created_at FROM public.post_reactions
    UNION ALL SELECT user_id, created_at FROM public.post_comments
),
recip_post_edges AS (
    SELECT DISTINCT r.user_id AS a, po.user_id AS b FROM public.post_reactions r JOIN public.posts po ON po.id = r.post_id
    WHERE r.created_at > NOW() - INTERVAL '7 days' AND r.user_id <> po.user_id
    UNION
    SELECT DISTINCT k.user_id, po.user_id FROM public.post_comments k JOIN public.posts po ON po.id = k.post_id
    WHERE k.created_at > NOW() - INTERVAL '7 days' AND k.user_id <> po.user_id
),
recip_roll_edges AS (
    SELECT DISTINCT r.user_id AS a, ph.user_id AS b FROM public.photo_reactions r JOIN public.photos ph ON ph.id = r.photo_id
    WHERE r.created_at > NOW() - INTERVAL '7 days' AND r.user_id <> ph.user_id
    UNION
    SELECT DISTINCT k.user_id, ph.user_id FROM public.photo_comments k JOIN public.photos ph ON ph.id = k.photo_id
    WHERE k.created_at > NOW() - INTERVAL '7 days' AND k.user_id <> ph.user_id
),
recip_post_pairs AS (
    SELECT LEAST(e.a, e.b) x, GREATEST(e.a, e.b) y FROM recip_post_edges e JOIN recip_post_edges o ON o.a = e.b AND o.b = e.a WHERE e.a < e.b
),
recip_roll_pairs AS (
    SELECT LEAST(e.a, e.b) x, GREATEST(e.a, e.b) y FROM recip_roll_edges e JOIN recip_roll_edges o ON o.a = e.b AND o.b = e.a WHERE e.a < e.b
),
recip_either AS (
    SELECT x, y FROM recip_post_pairs UNION SELECT x, y FROM recip_roll_pairs
)
SELECT jsonb_build_object(
    'generated_at', NOW(),

    'weekly', jsonb_build_object(
        'this_week', jsonb_build_object(
            'openers',    (SELECT COUNT(DISTINCT user_id) FROM public.usage_events e, ny WHERE e.event = 'app_open' AND e.day >= ny.today - 7 AND e.day < ny.today),
            'shooters',   (SELECT COUNT(DISTINCT user_id) FROM public.photos p, ny WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (p.taken_at AT TIME ZONE 'America/New_York')::date < ny.today),
            'posters',    (SELECT COUNT(DISTINCT user_id) FROM public.posts po, ny WHERE (po.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (po.created_at AT TIME ZONE 'America/New_York')::date < ny.today),
            'reactors',   (SELECT COUNT(DISTINCT user_id) FROM public.post_reactions r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (r.created_at AT TIME ZONE 'America/New_York')::date < ny.today),
            'commenters', (SELECT COUNT(DISTINCT user_id) FROM public.post_comments c, ny WHERE (c.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (c.created_at AT TIME ZONE 'America/New_York')::date < ny.today),
            'posts',      (SELECT COUNT(*) FROM public.posts po, ny WHERE (po.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (po.created_at AT TIME ZONE 'America/New_York')::date < ny.today),
            'reactions',  (SELECT COUNT(*) FROM public.post_reactions r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (r.created_at AT TIME ZONE 'America/New_York')::date < ny.today),
            'comments',   (SELECT COUNT(*) FROM public.post_comments c, ny WHERE (c.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 7 AND (c.created_at AT TIME ZONE 'America/New_York')::date < ny.today)
        ),
        'last_week', jsonb_build_object(
            'openers',    (SELECT COUNT(DISTINCT user_id) FROM public.usage_events e, ny WHERE e.event = 'app_open' AND e.day >= ny.today - 14 AND e.day < ny.today - 7),
            'shooters',   (SELECT COUNT(DISTINCT user_id) FROM public.photos p, ny WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (p.taken_at AT TIME ZONE 'America/New_York')::date < ny.today - 7),
            'posters',    (SELECT COUNT(DISTINCT user_id) FROM public.posts po, ny WHERE (po.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (po.created_at AT TIME ZONE 'America/New_York')::date < ny.today - 7),
            'reactors',   (SELECT COUNT(DISTINCT user_id) FROM public.post_reactions r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (r.created_at AT TIME ZONE 'America/New_York')::date < ny.today - 7),
            'commenters', (SELECT COUNT(DISTINCT user_id) FROM public.post_comments c, ny WHERE (c.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (c.created_at AT TIME ZONE 'America/New_York')::date < ny.today - 7),
            'posts',      (SELECT COUNT(*) FROM public.posts po, ny WHERE (po.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (po.created_at AT TIME ZONE 'America/New_York')::date < ny.today - 7),
            'reactions',  (SELECT COUNT(*) FROM public.post_reactions r, ny WHERE (r.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (r.created_at AT TIME ZONE 'America/New_York')::date < ny.today - 7),
            'comments',   (SELECT COUNT(*) FROM public.post_comments c, ny WHERE (c.created_at AT TIME ZONE 'America/New_York')::date >= ny.today - 14 AND (c.created_at AT TIME ZONE 'America/New_York')::date < ny.today - 7)
        )
    ),

    -- First-open (activation_events.first_launch) weekly cohorts since 2026-08-10, the day that
    -- event started logging (docs/METRICS.md, the activation funnel's own caveat table). "Active"
    -- reuses admin_retention()'s signal (a shot, a post or a reaction) plus a comment, in the
    -- week-after-signup window named by each column, not a running total.
    'retention', jsonb_build_object(
        'since', '2026-08-10',
        'cohorts', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'week', wk, 'size', size,
                'week1_active', w1, 'week1_pct', CASE WHEN size > 0 THEN ROUND(100.0 * w1 / size, 1) ELSE 0 END,
                'week2_active', w2, 'week2_pct', CASE WHEN size > 0 THEN ROUND(100.0 * w2 / size, 1) ELSE 0 END,
                'week3_active', w3, 'week3_pct', CASE WHEN size > 0 THEN ROUND(100.0 * w3 / size, 1) ELSE 0 END,
                'week4_active', w4, 'week4_pct', CASE WHEN size > 0 THEN ROUND(100.0 * w4 / size, 1) ELSE 0 END
            ) ORDER BY wk)
            FROM (
                SELECT date_trunc('week', c.first_open)::date AS wk,
                       COUNT(DISTINCT c.user_id) AS size,
                       COUNT(DISTINCT c.user_id) FILTER (WHERE EXISTS (
                           SELECT 1 FROM retention_acts a WHERE a.user_id = c.user_id
                             AND a.at >= c.first_open + INTERVAL '7 days' AND a.at < c.first_open + INTERVAL '14 days')) AS w1,
                       COUNT(DISTINCT c.user_id) FILTER (WHERE EXISTS (
                           SELECT 1 FROM retention_acts a WHERE a.user_id = c.user_id
                             AND a.at >= c.first_open + INTERVAL '14 days' AND a.at < c.first_open + INTERVAL '21 days')) AS w2,
                       COUNT(DISTINCT c.user_id) FILTER (WHERE EXISTS (
                           SELECT 1 FROM retention_acts a WHERE a.user_id = c.user_id
                             AND a.at >= c.first_open + INTERVAL '21 days' AND a.at < c.first_open + INTERVAL '28 days')) AS w3,
                       COUNT(DISTINCT c.user_id) FILTER (WHERE EXISTS (
                           SELECT 1 FROM retention_acts a WHERE a.user_id = c.user_id
                             AND a.at >= c.first_open + INTERVAL '28 days' AND a.at < c.first_open + INTERVAL '35 days')) AS w4
                FROM retention_cohort c GROUP BY 1
            ) t
        ), '[]'::jsonb)
    ),

    -- client_versions by version and build (admin_versions()'s own shape), plus how many of the
    -- last 7 days' actives are behind app_release_gate.latest_version. Version compare tries a
    -- numeric dotted-triple first and falls back to a plain inequality for anything that does not
    -- parse, so a malformed version string can never raise inside this function.
    'adoption', jsonb_build_object(
        'versions', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'version', v.version, 'users', v.users, 'builds', v.builds, 'last_seen', v.last_seen
            ) ORDER BY v.users DESC, v.version DESC), '[]'::jsonb)
            FROM (
                SELECT version, COUNT(*) AS users,
                       string_agg(DISTINCT COALESCE(build, '?'), ', ' ORDER BY COALESCE(build, '?')) AS builds,
                       MAX(updated_at) AS last_seen
                FROM public.client_versions GROUP BY version
            ) v
        ),
        'latest_version', (SELECT latest_version FROM gate),
        'actives_7d_behind_latest', (
            SELECT COUNT(*)
            FROM actives7 a
            JOIN public.users u ON u.id = a.user_id AND u.username <> 'applereview'
            JOIN public.client_versions c ON c.user_id = a.user_id
            CROSS JOIN gate g
            WHERE CASE
                WHEN c.version ~ '^[0-9]+(\.[0-9]+){0,2}$' AND g.latest_version ~ '^[0-9]+(\.[0-9]+){0,2}$'
                THEN (string_to_array(c.version, '.') || ARRAY['0','0','0'])[1:3]::int[]
                     < (string_to_array(g.latest_version, '.') || ARRAY['0','0','0'])[1:3]::int[]
                ELSE c.version <> g.latest_version
            END
        )
    ),

    'rolls', jsonb_build_object(
        'created_7d', (SELECT COUNT(*) FROM public.rolls WHERE created_at > NOW() - INTERVAL '7 days'),
        'created_28d', (SELECT COUNT(*) FROM public.rolls WHERE created_at > NOW() - INTERVAL '28 days'),
        'follow_ups_ever', (SELECT COUNT(*) FROM public.roll_follow_up_invites),
        'developed_7d', (SELECT COUNT(*) FROM public.rolls WHERE reveal_at <= NOW() AND reveal_at > NOW() - INTERVAL '7 days'),
        'reveal_opens_7d', (
            SELECT COUNT(*) FROM public.roll_reveal_views v JOIN public.rolls r ON r.id = v.roll_id
            WHERE r.reveal_at <= NOW() AND r.reveal_at > NOW() - INTERVAL '7 days'
        ),
        'reveal_completions_7d', (
            SELECT COUNT(*) FROM public.roll_reveal_views v JOIN public.rolls r ON r.id = v.roll_id
            WHERE r.reveal_at <= NOW() AND r.reveal_at > NOW() - INTERVAL '7 days' AND v.completed_at IS NOT NULL
        )
    ),

    -- device_tokens coverage and the never-answered notification ask, both scoped to the last 7
    -- days' actives (admin_reach()'s said_yes/said_no split, narrowed to people who were
    -- actually around to be asked). push_deliveries has no status column; status here is derived
    -- the same way nightly_numbers()'s push_deliveries_failed_terminal_24h derives "terminal".
    'pushes', jsonb_build_object(
        'actives_7d', (SELECT COUNT(*) FROM actives7 a JOIN public.users u ON u.id = a.user_id AND u.username <> 'applereview'),
        'with_token', (
            SELECT COUNT(*) FROM actives7 a JOIN public.users u ON u.id = a.user_id AND u.username <> 'applereview'
            WHERE EXISTS (SELECT 1 FROM public.device_tokens d WHERE d.user_id = a.user_id)
        ),
        'never_answered_ask', (
            SELECT COUNT(*) FROM actives7 a JOIN public.users u ON u.id = a.user_id AND u.username <> 'applereview'
            WHERE NOT EXISTS (SELECT 1 FROM public.activation_events ae WHERE ae.user_id = a.user_id AND ae.event = 'notifications_authorized')
              AND NOT EXISTS (SELECT 1 FROM public.activation_events ae WHERE ae.user_id = a.user_id AND ae.event = 'notifications_denied')
        ),
        'deliveries_by_status_7d', (
            SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb)
            FROM (
                SELECT CASE WHEN delivered THEN 'delivered' WHEN attempts >= 3 THEN 'failed_terminal' ELSE 'pending' END AS status,
                       COUNT(*) AS n
                FROM public.push_deliveries
                WHERE updated_at > NOW() - INTERVAL '7 days'
                GROUP BY 1
            ) t
        )
    ),

    'renditions', jsonb_build_object(
        'total', (SELECT COUNT(*) FROM public.photos),
        'missing_thumb', (SELECT COUNT(*) FROM public.photos WHERE thumb_path IS NULL),
        'missing_feed', (SELECT COUNT(*) FROM public.photos WHERE feed_path IS NULL),
        'pct_missing_feed', (
            SELECT CASE WHEN COUNT(*) > 0 THEN ROUND(100.0 * COUNT(*) FILTER (WHERE feed_path IS NULL) / COUNT(*), 1) ELSE 0 END
            FROM public.photos
        )
    ),

    'volume', jsonb_build_object(
        'photos_per_day_14d', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('day', d.d, 'count', (
                SELECT COUNT(*) FROM public.photos p WHERE (p.taken_at AT TIME ZONE 'America/New_York')::date = d.d
            )) ORDER BY d.d)
            FROM days14 d
        ), '[]'::jsonb),
        'storage_bytes', (SELECT COALESCE(SUM((metadata->>'size')::bigint), 0) FROM storage.objects WHERE bucket_id = 'photos'),
        'db_bytes', (SELECT pg_database_size(current_database()))
    ),

    'invites', jsonb_build_object(
        'campaigns', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'code', c.code, 'inviter', u.username, 'uses', c.uses, 'max_uses', c.max_uses,
                'valid_from', c.valid_from, 'valid_until', c.valid_until, 'note', c.note
            ) ORDER BY c.valid_from DESC), '[]'::jsonb)
            FROM public.invite_campaigns c JOIN public.users u ON u.id = c.inviter_id
        ),
        'signups_per_day_14d', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('day', d.d, 'count', (
                SELECT COUNT(*) FROM public.users u WHERE (u.created_at AT TIME ZONE 'America/New_York')::date = d.d
            )) ORDER BY d.d)
            FROM days14 d
        ), '[]'::jsonb)
    ),

    -- reciprocal_pairs_detail(7) for the tested posts/rolls/either counts; owner_included_7d is
    -- computed here by re-deriving the same edges restricted to pairs that name owner_user_id(),
    -- because the detail function returns aggregate counts only, never the pairs themselves.
    'reciprocity', jsonb_build_object(
        'posts_7d', (SELECT pairs FROM public.reciprocal_pairs_detail(7) WHERE context = 'posts'),
        'rolls_7d', (SELECT pairs FROM public.reciprocal_pairs_detail(7) WHERE context = 'rolls'),
        'either_7d', (SELECT pairs FROM public.reciprocal_pairs_detail(7) WHERE context = 'either'),
        'owner_included_7d', (SELECT COUNT(*) FROM recip_either WHERE public.owner_user_id() IN (x, y))
    ),

    'moderation', jsonb_build_object(
        'photo_reports_7d', (SELECT COUNT(*) FROM public.photo_reports WHERE created_at > NOW() - INTERVAL '7 days'),
        'user_reports_7d', (SELECT COUNT(*) FROM public.user_reports WHERE created_at > NOW() - INTERVAL '7 days'),
        'blocks_7d', (SELECT COUNT(*) FROM public.blocks WHERE created_at > NOW() - INTERVAL '7 days'),
        'crash_rows_7d', (SELECT COUNT(*) FROM public.crash_diagnostics WHERE kind IN ('crash', 'hang', 'cpuException') AND created_at > NOW() - INTERVAL '7 days'),
        'edge_non_200_7d', (SELECT COUNT(*) FROM public.edge_response_log WHERE created > NOW() - INTERVAL '7 days' AND status_code IS NOT NULL),
        'edge_null_status_7d', (SELECT COUNT(*) FROM public.edge_response_log WHERE created > NOW() - INTERVAL '7 days' AND status_code IS NULL)
    ),

    'crons', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'jobname', j.jobname, 'schedule', j.schedule, 'active', j.active,
            'last_status', lr.status, 'last_run', lr.start_time
        ) ORDER BY j.jobname), '[]'::jsonb)
        FROM cron.job j
        LEFT JOIN LATERAL (
            SELECT status, start_time FROM cron.job_run_details d
            WHERE d.jobid = j.jobid ORDER BY d.start_time DESC LIMIT 1
        ) lr ON TRUE
    )
);
$$;

-- ------------------------------------------------------------
-- 3. receiver_lookup(): the webhook receiver's answer for a new public.users row (docs/ROUTINES.md,
--    "The receiver's answers"). Deliberately narrow: username, who invited them, how many people
--    they would already know on day one, and their latest reported client version. NEVER email,
--    NEVER invite_code, and never any column the security notes forbid a client to read; the
--    receiver already drops the payload's email at the door and this function gives it nothing
--    to leak even if it tried.
--
--    invited_by resolves allowed_emails.note the same TEXT-equality way public.invite_tree() does
--    (note = 'invited_by:' || <uuid>::text), never a substring-then-cast, so a hand-seeded note
--    that is not that exact shape (invite_earnback's trigger comment names 'owner' as one example)
--    simply matches nothing instead of raising a cast error. When the resolved inviter also had a
--    live invite_campaigns code at the moment of signup, the code is named alongside the username,
--    matching docs/ROUTINES.md's "a cohort code is named when the inviter had one live at signup,
--    otherwise it was the personal code" -- the note itself does not distinguish a personal, a
--    campaign or a roll code redemption (redeem_invite writes the identical shape for all three),
--    so this is the best a post-hoc read of allowed_emails can do.
--
--    day_one_known reuses invite_tree()'s inviter / sibling / invited / inviter-follows relations
--    for an arbitrary target instead of auth.uid(), plus roll mates (docs/ROUTINES.md and
--    docs/prompts/PI_ROUTINES_2026-09-21.md both name roll mates as part of this set), deduplicated
--    and never counting the target themselves.
--
--    STABLE, no writes, and every branch degrades to NULL/0/empty rather than raising, including
--    for a uuid that matches no user row at all.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receiver_lookup(p_user_id UUID)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
WITH me AS (
    SELECT id, LOWER(email) AS email, created_at FROM public.users WHERE id = p_user_id
),
my_inviter AS (
    SELECT u.id, u.username
    FROM me
    JOIN public.allowed_emails a ON a.email = me.email
    JOIN public.users u ON a.note = 'invited_by:' || u.id::text
    WHERE u.id <> me.id
),
my_campaign AS (
    SELECT c.code
    FROM my_inviter i
    JOIN public.invite_campaigns c ON c.inviter_id = i.id
    CROSS JOIN me
    WHERE me.created_at >= c.valid_from AND me.created_at < c.valid_until
    ORDER BY c.valid_from DESC
    LIMIT 1
),
known AS (
    SELECT id FROM my_inviter
    UNION
    SELECT u.id FROM my_inviter i
        JOIN public.allowed_emails a ON a.note = 'invited_by:' || i.id::text
        JOIN public.users u ON LOWER(u.email) = a.email
    WHERE u.id <> p_user_id
    UNION
    SELECT u.id FROM public.allowed_emails a
        JOIN public.users u ON LOWER(u.email) = a.email
    WHERE a.note = 'invited_by:' || p_user_id::text AND u.id <> p_user_id
    UNION
    SELECT f.following_id FROM my_inviter i
        JOIN public.follows f ON f.follower_id = i.id
    WHERE f.following_id <> p_user_id
    UNION
    SELECT rm2.user_id FROM public.roll_members rm1
        JOIN public.roll_members rm2 ON rm2.roll_id = rm1.roll_id AND rm2.user_id <> p_user_id
    WHERE rm1.user_id = p_user_id
)
SELECT jsonb_build_object(
    'username', (SELECT username FROM public.users WHERE id = p_user_id),
    'invited_by', (
        SELECT CASE
            WHEN i.username IS NULL THEN NULL
            WHEN c.code IS NOT NULL THEN i.username || ' (' || c.code || ')'
            ELSE i.username
        END
        FROM (SELECT username FROM my_inviter LIMIT 1) i
        LEFT JOIN my_campaign c ON TRUE
    ),
    'day_one_known', (SELECT COUNT(*) FROM known),
    'client_version', (
        SELECT jsonb_build_object('version', version, 'build', build, 'updated_at', updated_at)
        FROM public.client_versions WHERE user_id = p_user_id
    )
);
$$;

-- ------------------------------------------------------------
-- 4. Grants. Both functions are REVOKEd from PUBLIC, anon and authenticated -- there is no client
--    surface here, only the Pi -- and EXECUTE is granted to exactly flim_reader and service_role.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.memo_snapshot() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.memo_snapshot() TO flim_reader, service_role;

REVOKE ALL ON FUNCTION public.receiver_lookup(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.receiver_lookup(UUID) TO flim_reader, service_role;
