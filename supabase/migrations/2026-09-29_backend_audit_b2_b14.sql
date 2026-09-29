-- Backend audit follow-ups, 2026-09-29 (docs/AUDIT_1_6_1_POLISH_2026-09-28.md, section B).
-- NOT YET APPLIED. The owner applies it. Idempotent: safe to re-run.
--
-- Six pieces, each additive or a same-signature replacement. No data is transformed or deleted.
--
--   B-3   invite_preview no longer spends the 'global' budget that redeem_invite spends. 300
--         signed-out previews an hour could stop every signup for the rest of that hour. Preview
--         now has its own ceiling ('preview:global', 600 an hour) and a per-client key checked
--         first ('preview:ip:<address>', 60 an hour). redeem_invite keeps 'global' unchanged.
--   B-14  invite_landing's 'landing:global' (2000 an hour) could be spent by one client asking
--         for made-up codes, turning the page generic for everyone. It gains the same per-client
--         key ('landing:ip:<address>', 120 an hour), checked first.
--   B-7   Only a person's own invite code earns an invite back (owner decision 2026-09-29).
--         redeem_invite records how someone was admitted (allowed_emails.via: personal, campaign
--         or roll); credit_invite_earnback refills an invite, and leaves a row for the "Your invite
--         came back" push, only for personal-code admissions. Attribution is untouched: the note
--         stays 'invited_by:<uuid>' on every path, so Recruiter, Brought Someone, Patron, Open
--         Door, the invite tree and the first-run follow count roll and campaign admissions
--         exactly as before.
--   B-10  photos_unpushed_develop_idx covered every personal photo (roll_id NULL), which
--         send-develop-push never reads and never marks, so the "unsent" index grew with every
--         personal shot. Replaced by a partial on roll photos only. posts.push_sent, polled by
--         send-social-push every two minutes, gains the partial index its siblings have.
--   B-12  gate_new_auth_user (the invite gate trigger on auth.users) was executable by PUBLIC,
--         anon and authenticated. A trigger function cannot be called directly, but the house
--         rule is that every internal and trigger function revokes EXECUTE; this one was missed.
--         Revoking does not affect the trigger, which Postgres fires without an EXECUTE check.
--
--   B-11  (server half) invite_preview returns inviter_id to anon. Every installed build decodes
--         it as a required UUID and keeps it for the new account's first follow, so it cannot be
--         removed yet. get_own_inviter() gives a signed-in account its own inviter instead, read
--         from its own allowlist row; once every installed build uses it, invite_preview can stop
--         returning inviter_id to anon. invite_preview's result is unchanged here.

-- ------------------------------------------------------------
-- B-3 and B-14: a per-client rate key
-- ------------------------------------------------------------
-- The caller's address, as PostgREST passes the request headers to the transaction. Cloudflare's
-- cf-connecting-ip first (set by the edge, not by the client), then the first x-forwarded-for
-- hop. NULL when there is no request (SQL editor, cron) or nothing usable, and the callers then
-- skip the per-client key: never a shared bucket that one caller could fill for everyone.
CREATE OR REPLACE FUNCTION public.invite_rate_client()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_headers JSON;
    v_ip      TEXT;
BEGIN
    BEGIN
        v_headers := NULLIF(current_setting('request.headers', true), '')::json;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
    IF v_headers IS NULL THEN
        RETURN NULL;
    END IF;
    v_ip := NULLIF(TRIM(COALESCE(v_headers->>'cf-connecting-ip',
                                 split_part(COALESCE(v_headers->>'x-forwarded-for', ''), ',', 1))), '');
    IF v_ip IS NULL OR length(v_ip) > 64 THEN
        RETURN NULL;
    END IF;
    RETURN lower(v_ip);
END;
$$;
REVOKE ALL ON FUNCTION public.invite_rate_client() FROM PUBLIC, anon, authenticated;

-- Same signature and return shape as the 2026-09-15 definition; only the rate keys change.
--
-- 2026-09-29, B-11: inviter_id is still returned to anon ON PURPOSE. Every installed build decodes
-- it as a required UUID and uses it for the new account's inviter follow. It may be set to NULL
-- for anon (auth.uid() IS NULL) only once every installed build takes the inviter from
-- public.get_own_inviter() after sign-in instead, weeks from now. Changing it sooner breaks the
-- invite preview and the inviter follow on every older phone.
-- The per-client key is bumped first. A call refused by any key raises, which rolls back every
-- counter this call touched, so a refused call never spends the shared ceiling.
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
    SELECT u.id, u.username, u.display_name, NULL::TEXT, 'personal'::TEXT
    FROM public.users u
    WHERE u.invite_code = v_code
      AND (u.invite_uses_remaining IS NULL OR u.invite_uses_remaining > 0)
    UNION ALL
    SELECT u.id, u.username, u.display_name, NULL::TEXT, 'campaign'::TEXT
    FROM public.invite_campaigns c
    JOIN public.users u ON u.id = c.inviter_id
    WHERE c.code = v_code
      AND NOW() >= c.valid_from AND NOW() < c.valid_until
      AND (c.max_uses IS NULL OR c.uses < c.max_uses)
    UNION ALL
    SELECT u.id, u.username, u.display_name, r.name, 'roll'::TEXT
    FROM public.rolls r
    JOIN public.users u ON u.id = r.created_by
    WHERE r.invite_code = v_code
      AND NOT public.is_roll_developed(r.id)
    LIMIT 1;
END;
$function$;
REVOKE ALL ON FUNCTION public.invite_preview(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_preview(text) TO anon, authenticated;

-- Same signature and return shape as the 2026-09-25 definition; only the per-client key is new.
CREATE OR REPLACE FUNCTION public.invite_landing(p_code TEXT)
RETURNS TABLE(username TEXT, display_name TEXT, founding_left INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_code   TEXT := UPPER(TRIM(COALESCE(p_code, '')));
    v_client TEXT := public.invite_rate_client();
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;
    -- Its own budgets, never 'global': a shared link opened a thousand times must not be able to
    -- stop anyone from signing up. The per-client key comes first, so one client asking for
    -- made-up codes runs out of its own allowance long before the page's shared one.
    IF v_client IS NOT NULL THEN
        PERFORM public.bump_invite_rate('landing:ip:' || v_client, 120);
    END IF;
    PERFORM public.bump_invite_rate('landing:global', 2000);
    PERFORM public.bump_invite_rate('landing:code:' || v_code, 60);
    RETURN QUERY
    SELECT u.username,
           u.display_name,
           GREATEST(0, 100 - (SELECT COUNT(*) FROM public.users x
                              WHERE x.signup_ordinal IS NOT NULL AND x.username <> 'applereview'))::INT
    FROM public.users u
    WHERE u.invite_code = v_code
      AND (u.invite_uses_remaining IS NULL OR u.invite_uses_remaining > 0)
    LIMIT 1;
END;
$$;
REVOKE ALL ON FUNCTION public.invite_landing(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invite_landing(TEXT) TO anon, authenticated;

-- ------------------------------------------------------------
-- B-7: only a personal code earns an invite back
-- ------------------------------------------------------------
-- How an allowlisted email was admitted. Written once, by redeem_invite, when the row is created.
-- NULL for every row that predates this migration (personal, campaign and roll admissions all
-- wrote the same note, so the past cannot be told apart), for the owner's own rows, and for
-- approve_invite_request's 'invite request' rows. allowed_emails has no client access at all.
ALTER TABLE public.allowed_emails
    ADD COLUMN IF NOT EXISTS via TEXT CHECK (via IN ('personal', 'campaign', 'roll'));

-- Whether an invitee's first photo refilled their inviter's invite. Every row that exists when the
-- column is added was written under the old rule, so it defaults to TRUE; the trigger below
-- writes it explicitly from now on. The row itself stays for every admission: it is the
-- exactly-once marker the trigger relies on, and it carries the attribution of who brought whom.
ALTER TABLE public.invite_earnbacks
    ADD COLUMN IF NOT EXISTS earns_invite BOOLEAN NOT NULL DEFAULT TRUE;

-- Repo parity only: production has had this column since 2026-08-29_invite_earnback_reset.sql,
-- which was never folded into schema.sql. A no-op wherever it already exists.
ALTER TABLE public.invite_earnbacks
    ADD COLUMN IF NOT EXISTS reversed BOOLEAN NOT NULL DEFAULT FALSE;

-- Same signature and return type as the 2026-09-11 definition. The only changes: each path writes
-- `via` alongside the note it always wrote. The rate keys, quota, precedence (personal, then
-- campaign, then roll) and every return value are unchanged. ON CONFLICT DO NOTHING keeps an
-- already-allowlisted email's original `via`, as it keeps its original note.
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
            INSERT INTO public.allowed_emails (email, note, via)
            VALUES (v_email, 'invited_by:' || v_campaign.inviter_id::text, 'campaign')
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
        INSERT INTO public.allowed_emails (email, note, via)
        VALUES (v_email, 'invited_by:' || v_roll_owner::text, 'roll')
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
    INSERT INTO public.allowed_emails (email, note, via)
    VALUES (v_email, 'invited_by:' || v_inviter::text, 'personal')
    ON CONFLICT (email) DO NOTHING
    RETURNING TRUE INTO v_did_insert;
    IF v_did_insert IS TRUE AND v_remaining IS NOT NULL THEN
        UPDATE public.users SET invite_uses_remaining = invite_uses_remaining - 1 WHERE id = v_inviter;
    END IF;
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.redeem_invite(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(TEXT, TEXT) TO anon, authenticated;

-- Same signature (a trigger function) as the 2026-08-29 definition. What changed: the ledger row
-- is still written for every invited admission (the exactly-once marker, and the record of who
-- brought whom), but only a personal-code admission refills an invite and leaves the row unsent
-- for send-social-push's "Your invite came back" push. A campaign or roll admission is written
-- with earns_invite = FALSE and push_sent = TRUE, so it refills nothing and no push reads it. An
-- admission with no recorded `via` (everything before this migration, and anything allowlisted
-- by hand with an invited_by note) keeps the rule it was admitted under and earns as before.
CREATE OR REPLACE FUNCTION public.credit_invite_earnback()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_note     TEXT;
    v_via      TEXT;
    v_inviter  UUID;
    v_earns    BOOLEAN;
    v_credited UUID;
BEGIN
    -- FAST PATH 1: already decided. Single PRIMARY KEY probe.
    IF EXISTS (SELECT 1 FROM public.invite_earnbacks WHERE invitee_id = NEW.user_id) THEN
        RETURN NEW;
    END IF;

    -- FAST PATH 2: was this photo's owner admitted via an invite code, whose, and how? Two
    -- PRIMARY KEY lookups (users.id, then allowed_emails.email).
    SELECT ae.note, ae.via INTO v_note, v_via
    FROM public.users u
    LEFT JOIN public.allowed_emails ae ON ae.email = lower(u.email)
    WHERE u.id = NEW.user_id;

    -- No allowed_emails row at all (admitted some other way), or a note that doesn't match the
    -- exact 'invited_by:<uuid>' shape redeem_invite() writes. Both are silent no-ops.
    IF v_note IS NULL OR v_note !~ '^invited_by:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RETURN NEW;
    END IF;

    v_inviter := substring(v_note FROM 12)::UUID; -- strip the 11-char 'invited_by:' prefix
    v_earns := v_via IS NULL OR v_via = 'personal';

    -- The ledger insert IS the exactly-once guard: whichever concurrent photo insert for this
    -- invitee wins the PRIMARY KEY conflict is the only one that gets a non-NULL v_credited back.
    INSERT INTO public.invite_earnbacks (invitee_id, inviter_id, earns_invite, push_sent)
    VALUES (NEW.user_id, v_inviter, v_earns, NOT v_earns)
    ON CONFLICT (invitee_id) DO NOTHING
    RETURNING inviter_id INTO v_credited;

    IF v_credited IS NULL OR NOT v_earns THEN
        RETURN NEW;
    END IF;

    -- WHERE id = v_credited silently matches zero rows if the inviter's account was since
    -- deleted. AND invite_uses_remaining IS NOT NULL keeps NULL ("unlimited") from ever becoming
    -- finite by way of an increment.
    UPDATE public.users
    SET invite_uses_remaining = invite_uses_remaining + 1
    WHERE id = v_credited
      AND invite_uses_remaining IS NOT NULL;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Fires on every photo insert, forever. Must never be the reason a photo upload fails.
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_invite_earnback() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- B-11 (server half): the caller's own inviter
-- ------------------------------------------------------------
-- Who let the signed-in caller in, and how: the user id in their own allowlist row's
-- 'invited_by:<uuid>' note (the same note every admission path writes: personal, campaign or roll
-- code), and that row's `via` ('personal', 'campaign', 'roll'; NULL for anyone admitted before
-- via was recorded). The email comes from auth.users for auth.uid(), never from a parameter, so
-- nobody can ask about anyone else. No row when there is no session, no allowlist row, a note of
-- any other shape (the owner, an approved invite request), or an inviter whose account no longer
-- exists. Replaces the inviter_id the app reads from invite_preview before sign-in; see the
-- comment above invite_preview.
CREATE OR REPLACE FUNCTION public.get_own_inviter()
RETURNS TABLE(inviter_id uuid, via text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id, ae.via
    FROM auth.users au
    JOIN public.allowed_emails ae ON ae.email = lower(au.email)
    JOIN public.users u
      ON ae.note ~ '^invited_by:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     AND u.id = substring(ae.note FROM 12)::uuid
    WHERE au.id = auth.uid()
      AND u.id <> au.id
    LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.get_own_inviter() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_inviter() TO authenticated;

-- ------------------------------------------------------------
-- B-10: push-poll indexes
-- ------------------------------------------------------------
-- send-develop-push reads push_sent = false AND roll_id IS NOT NULL AND develops_at <= now().
-- Personal photos never match and are never marked, so the old partial held nearly every
-- personal photo ever taken. Built before the old one is dropped, so the poll is never without
-- an index. Dropping an index removes no data.
CREATE INDEX IF NOT EXISTS photos_unpushed_roll_develop_idx
    ON public.photos (develops_at) WHERE push_sent = FALSE AND roll_id IS NOT NULL;
DROP INDEX IF EXISTS public.photos_unpushed_develop_idx;

-- send-social-push's new-posts poll (push_sent = false), the sibling of post_tags_unpushed_idx.
CREATE INDEX IF NOT EXISTS posts_unpushed_idx
    ON public.posts (push_sent) WHERE push_sent = FALSE;

-- ------------------------------------------------------------
-- B-12: the invite gate trigger function is not callable
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.gate_new_auth_user() FROM PUBLIC, anon, authenticated;

-- Verify (owner, read-only):
--   select has_function_privilege('anon', 'public.gate_new_auth_user()', 'EXECUTE');      -- false
--   select indexname from pg_indexes where indexname in
--     ('photos_unpushed_roll_develop_idx', 'photos_unpushed_develop_idx', 'posts_unpushed_idx');
--   select via, count(*) from public.allowed_emails group by 1;                           -- NULLs only, until the next admission
--   select earns_invite, count(*) from public.invite_earnbacks group by 1;                -- all true, until the next non-personal first photo
