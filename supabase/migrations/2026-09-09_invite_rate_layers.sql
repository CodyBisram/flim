-- Invite rate limits in layers, for the 2026-09-10 cohort and every day after it. One global
-- counter of 30 an hour, shared by invite_preview and redeem_invite, was a launch throttle: thirty
-- people typing a code in the same hour would lock the door for everyone. Now:
--
--   per key      an email may redeem 10 times an hour; a code may be previewed 40 times an hour
--                (six keystrokes' worth of previews per person is one, so 40 is dozens of people)
--   global       300 an hour across everyone, the ceiling a probe still meets
--
-- Same shape as before (a window row, bumped under lock), keyed rather than singular.
CREATE TABLE IF NOT EXISTS public.invite_rate_keys (
    key          TEXT PRIMARY KEY,
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts     INT NOT NULL DEFAULT 0
);
ALTER TABLE public.invite_rate_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invite_rate_keys FROM PUBLIC, anon, authenticated;

-- Bumps one key's hourly counter; raises rate_limited past p_limit. SECURITY DEFINER, called only
-- from the two functions below.
CREATE OR REPLACE FUNCTION public.bump_invite_rate(p_key TEXT, p_limit INT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_window   TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    INSERT INTO public.invite_rate_keys (key) VALUES (p_key) ON CONFLICT (key) DO NOTHING;
    SELECT window_start, attempts INTO v_window, v_attempts
    FROM public.invite_rate_keys WHERE key = p_key FOR UPDATE;
    IF v_window < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.invite_rate_keys SET window_start = NOW(), attempts = 1 WHERE key = p_key;
    ELSIF v_attempts >= p_limit THEN
        RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0003';
    ELSE
        UPDATE public.invite_rate_keys SET attempts = attempts + 1 WHERE key = p_key;
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.bump_invite_rate(TEXT, INT) FROM PUBLIC, anon, authenticated;

-- Old rows expire on their own; a weekly sweep keeps the table small.
SELECT cron.schedule('flim-invite-rate-sweep', '30 9 * * 0',
    $$DELETE FROM public.invite_rate_keys WHERE window_start < NOW() - INTERVAL '1 day'$$)
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flim-invite-rate-sweep');

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
    v_campaign   public.invite_campaigns%ROWTYPE;
BEGIN
    PERFORM public.bump_invite_rate('global', 300);
    PERFORM public.bump_invite_rate('redeem:email:' || v_email, 10);

    SELECT id, invite_uses_remaining INTO v_inviter, v_remaining
    FROM public.users
    WHERE invite_code = v_code
    FOR UPDATE;

    IF v_inviter IS NULL THEN
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

CREATE OR REPLACE FUNCTION public.invite_preview(p_code TEXT)
RETURNS TABLE (inviter_id UUID, username TEXT, display_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
VOLATILE
AS $$
DECLARE
    v_code TEXT := UPPER(TRIM(p_code));
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;
    PERFORM public.bump_invite_rate('global', 300);
    PERFORM public.bump_invite_rate('preview:code:' || v_code, 40);

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
