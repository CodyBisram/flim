-- Invite codes belong to the server, and one client cannot block signups (2026-10-10). NOT YET
-- APPLIED. The owner applies it. Idempotent: safe to re-run. Changes no existing row (checked in
-- production before writing: 0 personal codes clash with a campaign or roll code, 0 malformed,
-- 0 users rows whose email differs from their auth email).
--
-- From the 2026-10-10 audit:
--
--   BE-1  users.invite_code was whatever the client sent at signup, and redeem_invite tried
--         personal codes before campaign codes. Anyone could sign up and give themselves a live
--         campaign code (LAST15, SPOT26) as their personal code. Every later redemption of it was
--         then credited to them, every newcomer followed them, and once their own invites ran out
--         the campaign silently stopped admitting anyone.
--   BE-2  redeem_invite spent only the shared 'global' budget (300 an hour) and a per-email one, so
--         one script with the public key and made-up addresses could block every signup.
--   BE-4  users.email was also whatever the client sent, and credit_invite_earnback, invite_tree
--         and the founding-seats push all trust it to say who invited whom.
--   BE-8  is_email_allowed answered anyone, as fast as they liked, which of a list of addresses
--         are invited (join_waitlist goes out of its way never to reveal that), and request_invite
--         let anyone overwrite the note on someone else's request.
--
-- What changes:
--   a. users_server_fields (BEFORE INSERT on users): email is copied from auth.users, and an
--      invite_code that is malformed, or already taken by a campaign, a roll or another person,
--      is replaced with a fresh server-made one. The app sends a random six-character code and
--      re-reads its row right after the insert (AuthService.setUsername -> refreshCurrentUser), so
--      a replaced code shows up at once; a real client's code is replaced only on a clash.
--   b. guard_campaign_code (BEFORE INSERT OR UPDATE OF code on invite_campaigns): a new campaign
--      code that is already someone's personal code, or a roll's, is refused with a message, so
--      the owner picks another rather than silently killing that person's invites.
--   c. redeem_invite: campaign codes first, then personal, then roll (was personal, campaign,
--      roll). A malformed code is refused before any counter. A per-client key (40 an hour) is
--      bumped before 'global'; a refused call raises, which rolls back every counter it touched,
--      so a client over its own limit never spends the shared one. Return values unchanged.
--   d. invite_preview: the same precedence, made explicit with ORDER BY (UNION ALL ... LIMIT 1
--      never promised an order). Same signature, same return shape, same rate keys.
--   e. is_email_allowed: a per-client key (60 an hour), only for calls through the API
--      (session_user = 'authenticator'). gate_new_auth_user calls it from inside Auth's own
--      insert, where session_user is Auth's role, so account creation is never rate limited.
--      A client over its limit gets an error (the app shows its generic retry message), never a
--      FALSE that would tell a member they are not invited.
--   f. request_invite: ON CONFLICT DO NOTHING, as join_waitlist does. The first request stands.
--
-- Before applying, re-check the clash counts (expect 0 | 0 | 0 | 0):
--   SELECT (SELECT count(*) FROM public.users u JOIN public.invite_campaigns c ON c.code = u.invite_code),
--          (SELECT count(*) FROM public.users u JOIN public.rolls r ON r.invite_code = u.invite_code),
--          (SELECT count(*) FROM public.users WHERE invite_code !~ '^[A-Z0-9]{6}$'),
--          (SELECT count(*) FROM public.users u JOIN auth.users a ON a.id = u.id
--             WHERE lower(u.email) IS DISTINCT FROM lower(a.email));
--
-- After applying: the next signup's row should carry its auth email and a six-character code
-- (SELECT u.invite_code, u.email = a.email FROM public.users u JOIN auth.users a ON a.id = u.id
--  ORDER BY u.created_at DESC LIMIT 1), and redeem:ip keys appear in invite_rate_keys after the
-- next redemption.

-- ------------------------------------------------------------
-- a. The server's fields on a new users row
-- ------------------------------------------------------------
-- SECURITY DEFINER: authenticated cannot read auth.users. Runs for every insert, whoever makes
-- it; a row with no auth user cannot exist (users.id references auth.users).
CREATE OR REPLACE FUNCTION public.users_server_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_auth_email TEXT;
    v_code       TEXT := UPPER(TRIM(COALESCE(NEW.invite_code, '')));
    v_chars      CONSTANT TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    v_tries      INT := 0;
BEGIN
    SELECT a.email INTO v_auth_email FROM auth.users a WHERE a.id = NEW.id;
    IF v_auth_email IS NOT NULL THEN
        NEW.email := v_auth_email;
    END IF;

    WHILE v_code !~ '^[A-Z0-9]{6}$'
       OR EXISTS (SELECT 1 FROM public.invite_campaigns c WHERE c.code = v_code)
       OR EXISTS (SELECT 1 FROM public.rolls r WHERE r.invite_code = v_code)
       OR EXISTS (SELECT 1 FROM public.users u WHERE u.invite_code = v_code AND u.id <> NEW.id)
    LOOP
        v_tries := v_tries + 1;
        IF v_tries > 20 THEN
            RAISE EXCEPTION 'could not make an invite code';
        END IF;
        v_code := '';
        FOR i IN 1..6 LOOP
            v_code := v_code || substr(v_chars, 1 + floor(random() * 36)::INT, 1);
        END LOOP;
    END LOOP;
    NEW.invite_code := v_code;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.users_server_fields() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS users_server_fields_trigger ON public.users;
CREATE TRIGGER users_server_fields_trigger
    BEFORE INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.users_server_fields();

-- ------------------------------------------------------------
-- b. A campaign code may not be anyone's personal or roll code
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_campaign_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.users u WHERE u.invite_code = NEW.code) THEN
        RAISE EXCEPTION 'campaign code % is already a member''s personal invite code; pick another', NEW.code;
    END IF;
    IF EXISTS (SELECT 1 FROM public.rolls r WHERE r.invite_code = NEW.code) THEN
        RAISE EXCEPTION 'campaign code % is already a roll''s invite code; pick another', NEW.code;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_campaign_code() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guard_campaign_code_trigger ON public.invite_campaigns;
CREATE TRIGGER guard_campaign_code_trigger
    BEFORE INSERT OR UPDATE OF code ON public.invite_campaigns
    FOR EACH ROW EXECUTE FUNCTION public.guard_campaign_code();

-- ------------------------------------------------------------
-- c. redeem_invite: campaign first, a per-client key
-- ------------------------------------------------------------
-- Same signature and return values as the 2026-09-29 definition (B-7). Each path writes the
-- same note and `via` it always did.
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code TEXT, p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email      TEXT := LOWER(TRIM(p_email));
    v_code       TEXT := UPPER(TRIM(p_code));
    v_client     TEXT := public.invite_rate_client();
    v_inviter    UUID;
    v_remaining  INT;
    v_did_insert BOOLEAN;
    v_campaign   public.invite_campaigns%ROWTYPE;
    v_roll_owner UUID;
BEGIN
    -- No code is anything but six letters and digits; nothing to look up, nothing to count.
    IF v_code IS NULL OR v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN FALSE;
    END IF;
    -- Per client first: one caller runs out of its own allowance long before the shared one.
    IF v_client IS NOT NULL THEN
        PERFORM public.bump_invite_rate('redeem:ip:' || v_client, 40);
    END IF;
    PERFORM public.bump_invite_rate('global', 300);
    PERFORM public.bump_invite_rate('redeem:email:' || v_email, 10);

    -- A campaign code. Checked before personal codes, so a personal code can never stand in
    -- front of a campaign (users_server_fields and guard_campaign_code keep the two apart too).
    SELECT * INTO v_campaign
    FROM public.invite_campaigns c
    WHERE c.code = v_code
      AND NOW() >= c.valid_from AND NOW() < c.valid_until
      AND (c.max_uses IS NULL OR c.uses < c.max_uses)
    FOR UPDATE;
    IF v_campaign.code IS NOT NULL THEN
        v_did_insert := FALSE;
        INSERT INTO public.allowed_emails (email, note, via)
        VALUES (v_email, 'invited_by:' || v_campaign.inviter_id::text, 'campaign')
        ON CONFLICT (email) DO NOTHING
        RETURNING TRUE INTO v_did_insert;
        IF v_did_insert IS TRUE THEN
            UPDATE public.invite_campaigns SET uses = uses + 1 WHERE code = v_campaign.code;
        END IF;
        RETURN TRUE;
    END IF;

    -- A personal code.
    SELECT id, invite_uses_remaining INTO v_inviter, v_remaining
    FROM public.users
    WHERE invite_code = v_code
    FOR UPDATE;
    IF v_inviter IS NOT NULL THEN
        IF v_remaining IS NOT NULL AND v_remaining <= 0 THEN
            RETURN EXISTS (SELECT 1 FROM public.allowed_emails WHERE email = v_email);
        END IF;
        v_did_insert := FALSE;
        INSERT INTO public.allowed_emails (email, note, via)
        VALUES (v_email, 'invited_by:' || v_inviter::text, 'personal')
        ON CONFLICT (email) DO NOTHING
        RETURNING TRUE INTO v_did_insert;
        IF v_did_insert IS TRUE AND v_remaining IS NOT NULL THEN
            UPDATE public.users SET invite_uses_remaining = invite_uses_remaining - 1 WHERE id = v_inviter;
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
    INSERT INTO public.allowed_emails (email, note, via)
    VALUES (v_email, 'invited_by:' || v_roll_owner::text, 'roll')
    ON CONFLICT (email) DO NOTHING;
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.redeem_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(TEXT, TEXT) TO anon, authenticated;

-- ------------------------------------------------------------
-- d. invite_preview: the same precedence, stated
-- ------------------------------------------------------------
-- Same signature, return shape and rate keys as the 2026-09-29 definition. inviter_id is still
-- returned to anon on purpose (see the B-11 note there).
CREATE OR REPLACE FUNCTION public.invite_preview(p_code text)
 RETURNS TABLE(inviter_id uuid, username text, display_name text, roll_name text, kind text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_code   TEXT := UPPER(TRIM(p_code));
    v_client TEXT := public.invite_rate_client();
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;
    IF v_client IS NOT NULL THEN
        PERFORM public.bump_invite_rate('preview:ip:' || v_client, 60);
    END IF;
    -- Its own ceiling, never 'global': looking a code up must not be able to stop anyone from
    -- redeeming one.
    PERFORM public.bump_invite_rate('preview:global', 600);
    PERFORM public.bump_invite_rate('preview:code:' || v_code, 40);
    RETURN QUERY
    SELECT s.inviter_id, s.username, s.display_name, s.roll_name, s.kind
    FROM (
        SELECT u.id AS inviter_id, u.username, u.display_name, NULL::TEXT AS roll_name,
               'campaign'::TEXT AS kind, 1 AS rank
        FROM public.invite_campaigns c
        JOIN public.users u ON u.id = c.inviter_id
        WHERE c.code = v_code
          AND NOW() >= c.valid_from AND NOW() < c.valid_until
          AND (c.max_uses IS NULL OR c.uses < c.max_uses)
        UNION ALL
        SELECT u.id, u.username, u.display_name, NULL::TEXT, 'personal'::TEXT, 2
        FROM public.users u
        WHERE u.invite_code = v_code
          AND (u.invite_uses_remaining IS NULL OR u.invite_uses_remaining > 0)
        UNION ALL
        SELECT u.id, u.username, u.display_name, r.name, 'roll'::TEXT, 3
        FROM public.rolls r
        JOIN public.users u ON u.id = r.created_by
        WHERE r.invite_code = v_code
          AND NOT public.is_roll_developed(r.id)
    ) s
    ORDER BY s.rank
    LIMIT 1;
END;
$function$;
REVOKE ALL ON FUNCTION public.invite_preview(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_preview(text) TO anon, authenticated;

-- ------------------------------------------------------------
-- e. is_email_allowed: a per-client key for API callers
-- ------------------------------------------------------------
-- Same signature and return type. Was LANGUAGE sql STABLE; a counter is a write, so it is
-- plpgsql and VOLATILE now.
CREATE OR REPLACE FUNCTION public.is_email_allowed(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_client TEXT;
BEGIN
    -- Only calls through the API count. gate_new_auth_user runs this inside Auth's own insert
    -- (session_user is Auth's role there), and account creation must never be rate limited.
    IF session_user = 'authenticator' THEN
        v_client := public.invite_rate_client();
        IF v_client IS NOT NULL THEN
            PERFORM public.bump_invite_rate('allowed:ip:' || v_client, 60);
        END IF;
    END IF;
    RETURN EXISTS (
        SELECT 1 FROM public.allowed_emails
        WHERE email = LOWER(TRIM(p_email))
    );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.is_email_allowed(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_email_allowed(TEXT) TO anon, authenticated;

-- ------------------------------------------------------------
-- f. request_invite: the first request stands
-- ------------------------------------------------------------
-- Same signature, return values and rate gate as the original definition; only the conflict
-- branch changes, so a stranger who knows an address cannot rewrite the note the owner reads.
CREATE OR REPLACE FUNCTION public.request_invite(
    p_email TEXT,
    p_note  TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_email    TEXT;
    v_note     TEXT;
    v_start    TIMESTAMPTZ;
    v_attempts INT;
BEGIN
    v_email := lower(trim(COALESCE(p_email, '')));

    IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RETURN FALSE;
    END IF;

    v_note := NULLIF(left(trim(COALESCE(p_note, '')), 500), '');

    SELECT window_start, attempts INTO v_start, v_attempts
    FROM public.invite_request_rate WHERE id FOR UPDATE;

    IF v_start < NOW() - INTERVAL '1 hour' THEN
        UPDATE public.invite_request_rate SET window_start = NOW(), attempts = 1 WHERE id;
    ELSIF v_attempts >= 60 THEN
        RETURN TRUE;
    ELSE
        UPDATE public.invite_request_rate SET attempts = attempts + 1 WHERE id;
    END IF;

    INSERT INTO public.invite_requests (email, note)
    VALUES (v_email, v_note)
    ON CONFLICT (email) DO NOTHING;

    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.request_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_invite(TEXT, TEXT) TO anon, authenticated;
