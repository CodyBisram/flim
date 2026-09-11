-- 1.5.3, the audit's top product item: one invitation journey. A roll's invite code now also
-- admits someone to the app, with the roll's creator as their inviter. Before this, a newcomer
-- who opened a roll link was told to go and ask for a separate app invite, at exactly the moment
-- they wanted to join their friends.
--
-- Precedence stays personal code, then campaign code, then roll code. Roll codes and personal
-- codes come from the same six-character generator, so a collision is possible but resolves the
-- same way it always has: the personal code wins. A developed roll's code admits nobody (there
-- is nothing left to join). Admission through a roll spends none of the creator's invite quota;
-- the roll is their group and creating one should never cost invites. The allowed_emails note
-- is the same 'invited_by:<creator>' the other paths write, so the first-run follow and the
-- invite tree treat the creator as the inviter.

DROP FUNCTION IF EXISTS public.invite_preview(TEXT);
CREATE OR REPLACE FUNCTION public.invite_preview(p_code TEXT)
RETURNS TABLE (inviter_id UUID, username TEXT, display_name TEXT, roll_name TEXT)
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
    SELECT u.id, u.username, u.display_name, NULL::TEXT
    FROM public.users u
    WHERE u.invite_code = v_code
      AND (u.invite_uses_remaining IS NULL OR u.invite_uses_remaining > 0)
    UNION ALL
    SELECT u.id, u.username, u.display_name, NULL::TEXT
    FROM public.invite_campaigns c
    JOIN public.users u ON u.id = c.inviter_id
    WHERE c.code = v_code
      AND NOW() >= c.valid_from AND NOW() < c.valid_until
      AND (c.max_uses IS NULL OR c.uses < c.max_uses)
    UNION ALL
    SELECT u.id, u.username, u.display_name, r.name
    FROM public.rolls r
    JOIN public.users u ON u.id = r.created_by
    WHERE r.invite_code = v_code
      AND NOT public.is_roll_developed(r.id)
    LIMIT 1;
END;
$$;
REVOKE ALL ON FUNCTION public.invite_preview(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_preview(TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.redeem_invite(p_code TEXT, p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email      TEXT := LOWER(TRIM(p_email));
    v_code       TEXT := UPPER(TRIM(p_code));
    v_inviter    UUID;
    v_remaining  INT;
    v_did_insert BOOLEAN;
    v_campaign   public.invite_campaigns%ROWTYPE;
    v_roll_owner UUID;
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
        IF v_campaign.code IS NOT NULL THEN
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
        -- A roll code: the creator vouches for whoever holds it, for as long as the roll is open.
        SELECT r.created_by INTO v_roll_owner
        FROM public.rolls r
        WHERE r.invite_code = v_code
          AND NOT public.is_roll_developed(r.id)
        LIMIT 1;
        IF v_roll_owner IS NULL THEN
            RETURN FALSE;
        END IF;
        INSERT INTO public.allowed_emails (email, note)
        VALUES (v_email, 'invited_by:' || v_roll_owner::text)
        ON CONFLICT (email) DO NOTHING;
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
