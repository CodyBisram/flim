-- ============================================================
-- Migration: SQL layer for the flim-app.com/admin dashboard
-- Paste into Supabase Dashboard -> SQL Editor and run. Safe to re-run.
-- Requires 2026-08-07_invite_requests.sql and 2026-08-07_approve_invite_request.sql.
--
-- The dashboard is a static page calling Supabase from the browser with the
-- publishable key and the owner's own logged-in session. There is no service
-- role in that picture, so grants alone cannot be the gate: authenticated has
-- to be able to CALL every function here, because the owner is just a signed
-- in user like anyone else. The gate lives inside each function body instead,
-- via is_owner() below, and every mutation raises while every list function
-- quietly returns nothing to a non-owner caller.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The shared gate. Same identity check send-social-push uses for its
--    OWNER_EMAIL constant: resolve against public.users.email, case
--    insensitively, instead of pinning a UUID that would go stale the day
--    the owner's row is ever recreated (account deletion + resignup, a
--    migration, testing on a second account). auth.uid() with no session
--    is NULL, which matches nothing here and returns FALSE, not an error.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid()
          AND lower(email) = lower('codyysb@gmail.com')
    );
$$;

-- ------------------------------------------------------------
-- 2. Invite queue reads. invite_requests has RLS on with zero policies, so
--    this is the only way the browser ever sees a row of it.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_invite_requests()
RETURNS TABLE (
    email      TEXT,
    note       TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT ir.email, ir.note, ir.created_at
    FROM public.invite_requests ir
    WHERE NOT ir.handled
    ORDER BY ir.created_at ASC;
END;
$$;

-- ------------------------------------------------------------
-- 3. Re-create approve_invite_request so the dashboard can call it. It was
--    revoked from authenticated entirely in 2026-08-07_approve_invite_request.sql,
--    which was correct back when the only caller was meant to be the SQL editor
--    or the service role. Now the owner's own session has to call it too, so the
--    boundary moves inside the function body via is_owner() and the grant opens
--    up to authenticated. Everything else about it, including why it exists and
--    why allowlisting happens before marking handled, is unchanged.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;

    -- Allowlisting is the part that matters, so it happens first and is
    -- idempotent. Approving somebody twice is harmless.
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invite request')
    ON CONFLICT (email) DO NOTHING;

    -- Marking handled is bookkeeping. An address approved without ever having
    -- asked (someone you just decided to add) updates nothing here, which is
    -- correct rather than an error.
    UPDATE public.invite_requests SET handled = TRUE WHERE email = v_email;

    RETURN TRUE;
END;
$$;

-- Turning somebody down keeps them out of the queue without touching
-- allowed_emails at all, mirroring the manual UPDATE the earlier migration's
-- comment described doing by hand.
CREATE OR REPLACE FUNCTION public.decline_invite_request(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email TEXT;
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN FALSE;
    END IF;

    UPDATE public.invite_requests SET handled = TRUE WHERE email = v_email;

    RETURN TRUE;
END;
$$;

-- ------------------------------------------------------------
-- 4. Report queue bookkeeping. Neither table tracked whether a report had
--    been looked at; push_sent tracks whether send-social-push already
--    notified the owner's phone about it, which is a separate concern and is
--    not touched here.
-- ------------------------------------------------------------
ALTER TABLE public.photo_reports ADD COLUMN IF NOT EXISTS handled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.user_reports  ADD COLUMN IF NOT EXISTS handled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS photo_reports_unhandled_idx ON public.photo_reports (handled) WHERE handled = FALSE;
CREATE INDEX IF NOT EXISTS user_reports_unhandled_idx  ON public.user_reports  (handled) WHERE handled = FALSE;

-- ------------------------------------------------------------
-- 5. Report queue reads, one row per reported thing rather than one row per
--    report. Five people reporting the same photo is one decision for the
--    owner to make, not five, so both list functions collapse on the thing
--    being reported (photo_id / reported_id) and surface a report_count
--    instead of duplicate rows. The freshest reason is shown, since whoever
--    reported most recently saw the content most recently; the timestamp
--    shown is the earliest report, so the queue orders by how long something
--    has been waiting rather than how long since it was last piled on.
--    Dismissing a group (see below) clears every report underneath it.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_photo_reports()
RETURNS TABLE (
    report_id         UUID,
    photo_id          UUID,
    reason            TEXT,
    report_count      BIGINT,
    created_at        TIMESTAMPTZ,
    reported_username TEXT,
    hidden            BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RETURN;
    END IF;

    -- Postgres window aggregates cannot take DISTINCT (COUNT(DISTINCT ..) OVER
    -- (...) is a parse error), so the count is a plain GROUP BY in its own CTE
    -- and the "which reason/id to show" pick is a separate DISTINCT ON, joined
    -- back together.
    RETURN QUERY
    WITH counts AS (
        SELECT
            pr.photo_id,
            COUNT(DISTINCT pr.reporter_id) AS report_count,
            MIN(pr.created_at)             AS first_reported_at
        FROM public.photo_reports pr
        WHERE NOT pr.handled
        GROUP BY pr.photo_id
    ),
    latest AS (
        SELECT DISTINCT ON (pr.photo_id)
            pr.id, pr.photo_id, pr.reason
        FROM public.photo_reports pr
        WHERE NOT pr.handled
        ORDER BY pr.photo_id, pr.created_at DESC
    )
    SELECT
        latest.id,
        latest.photo_id,
        latest.reason,
        counts.report_count,
        counts.first_reported_at,
        u.username,
        ph.hidden
    FROM latest
    JOIN counts             ON counts.photo_id = latest.photo_id
    JOIN public.photos ph   ON ph.id = latest.photo_id
    JOIN public.users  u    ON u.id = ph.user_id
    ORDER BY counts.first_reported_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_user_reports()
RETURNS TABLE (
    report_id         UUID,
    reported_id       UUID,
    reported_username TEXT,
    reason            TEXT,
    report_count      BIGINT,
    created_at        TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH counts AS (
        SELECT
            ur.reported_id,
            COUNT(DISTINCT ur.reporter_id) AS report_count,
            MIN(ur.created_at)             AS first_reported_at
        FROM public.user_reports ur
        WHERE NOT ur.handled
        GROUP BY ur.reported_id
    ),
    latest AS (
        SELECT DISTINCT ON (ur.reported_id)
            ur.id, ur.reported_id, ur.reason
        FROM public.user_reports ur
        WHERE NOT ur.handled
        ORDER BY ur.reported_id, ur.created_at DESC
    )
    SELECT
        latest.id,
        latest.reported_id,
        u.username,
        latest.reason,
        counts.report_count,
        counts.first_reported_at
    FROM latest
    JOIN counts          ON counts.reported_id = latest.reported_id
    JOIN public.users u  ON u.id = latest.reported_id
    ORDER BY counts.first_reported_at ASC;
END;
$$;

-- ------------------------------------------------------------
-- 6. Report queue actions.
-- ------------------------------------------------------------

-- Hide or restore a reported photo by hand. photos.hidden is what
-- auto_hide_reported flips automatically at >= 2 distinct reporters; a manual
-- call here is either backing that up early (one credible report is enough)
-- or overriding it (the auto-hide was a false positive). posts denormalizes
-- the same photo and auto_hide_reported keeps both in lockstep, so a manual
-- override has to touch both too or the feed and the photo disagree.
CREATE OR REPLACE FUNCTION public.set_photo_hidden(p_photo_id UUID, p_hidden BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.photos SET hidden = p_hidden WHERE id = p_photo_id;
    UPDATE public.posts  SET hidden = p_hidden WHERE photo_id = p_photo_id;

    RETURN TRUE;
END;
$$;

-- Dismissing a row from list_photo_reports means every report underneath
-- that photo, not just one, or the photo would reappear next load carrying
-- whichever report happened to survive.
CREATE OR REPLACE FUNCTION public.dismiss_photo_report(p_photo_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.photo_reports SET handled = TRUE WHERE photo_id = p_photo_id AND NOT handled;

    RETURN TRUE;
END;
$$;

-- Same idea for a reported user: clears every report against that person.
CREATE OR REPLACE FUNCTION public.dismiss_user_report(p_reported_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_owner() THEN
        RAISE EXCEPTION 'owner only';
    END IF;

    UPDATE public.user_reports SET handled = TRUE WHERE reported_id = p_reported_id AND NOT handled;

    RETURN TRUE;
END;
$$;

-- ------------------------------------------------------------
-- 7. Grants. This project carries the stock Supabase default privileges,
--    which GRANT EXECUTE on every newly created function to anon,
--    authenticated AND service_role at creation time. Without the explicit
--    revokes below, anon could call any of these over the public REST
--    endpoint and get past is_owner() for free the moment auth.uid() being
--    NULL ever stopped mattering, or simply learn from the error message
--    that these functions exist. Revoking PUBLIC alone does not remove a
--    grant already made to a named role, so anon is revoked separately from
--    every one of them. authenticated is granted EXECUTE on all of them,
--    because the owner reaching them is a signed in user like anyone else,
--    and is_owner() inside each body is what actually keeps everyone else out.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.is_owner() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_owner() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_owner() TO authenticated;

REVOKE ALL ON FUNCTION public.list_invite_requests() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_invite_requests() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_invite_requests() TO authenticated;

REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_invite_request(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_invite_request(TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.decline_invite_request(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decline_invite_request(TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.decline_invite_request(TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.list_photo_reports() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_photo_reports() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_photo_reports() TO authenticated;

REVOKE ALL ON FUNCTION public.list_user_reports() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_user_reports() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_user_reports() TO authenticated;

REVOKE ALL ON FUNCTION public.set_photo_hidden(UUID, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_photo_hidden(UUID, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_photo_hidden(UUID, BOOLEAN) TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_photo_report(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dismiss_photo_report(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.dismiss_photo_report(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_user_report(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dismiss_user_report(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.dismiss_user_report(UUID) TO authenticated;

-- ---- How the dashboard uses this --------------------------------------------
--
-- Invite queue:
--   SELECT * FROM list_invite_requests();
--   SELECT approve_invite_request('them@example.com');
--   SELECT decline_invite_request('them@example.com');
--
-- Report queue:
--   SELECT * FROM list_photo_reports();
--   SELECT * FROM list_user_reports();
--   SELECT set_photo_hidden('<photo-uuid>', true);   -- or false to restore
--   SELECT dismiss_photo_report('<photo-uuid>');
--   SELECT dismiss_user_report('<user-uuid>');
--
-- All of the above no-op (empty list, or a raised exception on the write
-- calls) for any caller whose auth.uid() does not resolve to codyysb@gmail.com
-- in public.users, regardless of what key or session called them with.
