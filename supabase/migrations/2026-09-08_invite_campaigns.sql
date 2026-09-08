-- Cohort invite codes: a code that is not any one member's personal code, valid for a window,
-- attributed to a member as the inviter, and never drawing on that member's own invite quota.
-- Built for the owner's 2026-09-10 cohort: everyone who joins on that one day with SEPT10 is
-- recorded as invited by the owner (the same allowed_emails note the personal path writes, so
-- every reader of that note, the earnback trigger included, sees the owner), follows the owner
-- one way through the first-run flow, and the code is dead the next morning.
CREATE TABLE IF NOT EXISTS public.invite_campaigns (
    code        TEXT PRIMARY KEY CHECK (code ~ '^[A-Z0-9]{6}$'),
    inviter_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    valid_from  TIMESTAMPTZ NOT NULL,
    valid_until TIMESTAMPTZ NOT NULL,
    max_uses    INT NULL,
    uses        INT NOT NULL DEFAULT 0,
    note        TEXT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (valid_until > valid_from)
);
ALTER TABLE public.invite_campaigns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invite_campaigns FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.invite_campaigns IS 'Time-boxed cohort invite codes, read only by redeem_invite and invite_preview (SECURITY DEFINER). No client access.';

-- redeem_invite: a personal code first, exactly as before; failing that, a live campaign code.
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code TEXT, p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_email      TEXT := LOWER(TRIM(p_email));
    v_code       TEXT := UPPER(TRIM(p_code));
    v_inviter    UUID;
    v_remaining  INT;
    v_did_insert BOOLEAN;
    v_window     TIMESTAMPTZ;
    v_attempts   INT;
    v_campaign   public.invite_campaigns%ROWTYPE;
BEGIN
    SELECT window_start, attempts INTO v_window, v_attempts
    FROM public.redeem_invite_rate
    WHERE id = TRUE
    FOR UPDATE;
    IF v_window < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.redeem_invite_rate SET window_start = NOW(), attempts = 1 WHERE id = TRUE;
    ELSIF v_attempts >= 30 THEN
        RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0003';
    ELSE
        UPDATE public.redeem_invite_rate SET attempts = attempts + 1 WHERE id = TRUE;
    END IF;

    SELECT id, invite_uses_remaining INTO v_inviter, v_remaining
    FROM public.users
    WHERE invite_code = v_code
    FOR UPDATE;

    IF v_inviter IS NULL THEN
        -- Not a personal code. A campaign code that is live right now admits the email and is
        -- attributed to its inviter; it never touches that inviter's own remaining uses.
        SELECT * INTO v_campaign
        FROM public.invite_campaigns c
        WHERE c.code = v_code
          AND NOW() >= c.valid_from AND NOW() < c.valid_until
          AND (c.max_uses IS NULL OR c.uses < c.max_uses)
        FOR UPDATE;
        IF v_campaign.code IS NULL THEN
            RETURN FALSE;
        END IF;
        v_did_insert := FALSE;
        INSERT INTO public.allowed_emails (email, note)
        VALUES (v_email, 'invited_by:' || v_campaign.inviter_id::text)
        ON CONFLICT (email) DO NOTHING
        RETURNING TRUE INTO v_did_insert;
        IF v_did_insert IS TRUE THEN
            UPDATE public.invite_campaigns SET uses = uses + 1 WHERE code = v_campaign.code;
        END IF;
        RETURN TRUE;
    END IF;

    IF v_remaining IS NOT NULL AND v_remaining <= 0 THEN
        IF EXISTS (SELECT 1 FROM public.allowed_emails WHERE email = v_email) THEN
            RETURN TRUE;
        ELSE
            RETURN FALSE;
        END IF;
    END IF;

    v_did_insert := FALSE;
    INSERT INTO public.allowed_emails (email, note)
    VALUES (v_email, 'invited_by:' || v_inviter::text)
    ON CONFLICT (email) DO NOTHING
    RETURNING TRUE INTO v_did_insert;
    IF v_did_insert IS TRUE AND v_remaining IS NOT NULL THEN
        UPDATE public.users SET invite_uses_remaining = invite_uses_remaining - 1 WHERE id = v_inviter;
    END IF;
    RETURN TRUE;
END;
$$;

-- invite_preview learns the same second branch, so the sign-in screen names the campaign's
-- inviter exactly as it names a personal code's.
CREATE OR REPLACE FUNCTION public.invite_preview(p_code TEXT)
RETURNS TABLE (inviter_id UUID, username TEXT, display_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_code     TEXT := UPPER(TRIM(p_code));
    v_window   TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;

    SELECT window_start, attempts INTO v_window, v_attempts
    FROM public.redeem_invite_rate
    WHERE id = TRUE
    FOR UPDATE;
    IF v_window < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.redeem_invite_rate SET window_start = NOW(), attempts = 1 WHERE id = TRUE;
    ELSIF v_attempts >= 30 THEN
        RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0003';
    ELSE
        UPDATE public.redeem_invite_rate SET attempts = attempts + 1 WHERE id = TRUE;
    END IF;

    RETURN QUERY
    SELECT u.id, u.username, u.display_name
    FROM public.users u
    WHERE u.invite_code = v_code
      AND (u.invite_uses_remaining IS NULL OR u.invite_uses_remaining > 0)
    UNION ALL
    SELECT u.id, u.username, u.display_name
    FROM public.invite_campaigns c
    JOIN public.users u ON u.id = c.inviter_id
    WHERE c.code = v_code
      AND NOW() >= c.valid_from AND NOW() < c.valid_until
      AND (c.max_uses IS NULL OR c.uses < c.max_uses)
    LIMIT 1;
END;
$$;

-- The 2026-09-10 cohort, owner's account, the whole of that day in New York.
INSERT INTO public.invite_campaigns (code, inviter_id, valid_from, valid_until, max_uses, note)
VALUES ('SEPT10', 'f43287d4-f239-415b-af45-650bbee62e83',
        timestamptz '2026-09-10 00:00 America/New_York', timestamptz '2026-09-11 00:00 America/New_York',
        NULL, 'One-day cohort code, 2026-09-10, attributed to the owner')
ON CONFLICT (code) DO NOTHING;
