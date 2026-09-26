-- Outreach invite codes from the Pi (2026-09-26). NOT YET APPLIED.
--
-- The weekly outreach job (scripts/pi/outreach-weekly.sh, docs/ROUTINES.md) emails five to ten
-- people a week, each with their own one-use invite code. The first batch, 2026-09-25, minted
-- those codes by hand in the SQL editor. The Pi holds no service key and no management token; its
-- only database credential is the flim_reader login from 2026-09-22_pi_reader.sql, which can
-- EXECUTE two read functions and nothing else. This adds exactly two more functions and a group
-- role that holds them, so minting never needs a table grant and never widens flim_reader itself.
--
-- 1. flim_outreach: a NOLOGIN group role. It can log in as nobody. The owner grants it to
--    flim_reader by hand, WITH INHERIT FALSE (flim_reader is NOINHERIT anyway), so the memo and the
--    receiver, which connect as flim_reader, still cannot mint anything. Only a session that runs
--    SET ROLE flim_outreach first, which the outreach script does and nothing else does, can call
--    these two functions. No password here, and no GRANT to a login role here: that step is the
--    owner's, one line, in docs/ROUTINES.md.
--
-- 2. public.mint_outreach_code(p_name): one invite_campaigns row, the same shape the first batch
--    used by hand: a six character code from ABCDEFGHJKLMNPQRSTUVWXYZ23456789 (no I, O, 0 or 1),
--    attributed to the owner, live from now for 30 days, max_uses 1, note
--    'outreach <today in New York>: <name>'. The code is checked against users.invite_code,
--    invite_campaigns.code and rolls.invite_code (all three share the six character namespace
--    redeem_invite and join_roll read). The name to code mapping lives only in that note: the repo
--    is public and the code never goes into it.
--    Two guards, because the caller is an unattended job:
--    - Idempotent per person per day: the same name on the same New York date gets its unused code
--      back instead of a second one, so a retried run never hands one person two codes.
--    - At most ten outreach codes per New York date, the job's own ceiling. An eleventh raises
--      daily_cap. A runaway loop mints ten dead codes at worst, never hundreds.
--
-- 3. public.outreach_codes_status(): every outreach code with its note, uses and expiry, so the
--    job can report how many earlier codes were redeemed and can check the committed file carries
--    none of them.
--
-- Both functions are SECURITY DEFINER (owned by postgres, like memo_snapshot) because
-- invite_campaigns has RLS on and no policy at all; search_path is pinned; EXECUTE is revoked from
-- PUBLIC, anon and authenticated and granted to flim_outreach and service_role only. Safe to re-run.

-- ------------------------------------------------------------
-- 1. The group role
-- ------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flim_outreach') THEN
        CREATE ROLE flim_outreach NOLOGIN NOINHERIT;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO flim_outreach;

-- ------------------------------------------------------------
-- 2. Mint one code for one person
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mint_outreach_code(p_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    c_alphabet CONSTANT TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    v_name  TEXT := btrim(regexp_replace(COALESCE(p_name, ''), '[[:space:]]+', ' ', 'g'));
    v_today TEXT := to_char(NOW() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD');
    v_owner UUID := public.owner_user_id();
    v_note  TEXT;
    v_code  TEXT;
    v_bytes BYTEA;
    i INT;
    j INT;
BEGIN
    IF v_name = '' OR length(v_name) > 80 OR v_name ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'bad_name' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_owner) THEN
        RAISE EXCEPTION 'owner_missing' USING ERRCODE = 'P0001';
    END IF;
    v_note := 'outreach ' || v_today || ': ' || v_name;

    -- One minter at a time, so the cap and the collision check cannot race each other.
    PERFORM pg_advisory_xact_lock(hashtext('public.mint_outreach_code'));

    SELECT c.code INTO v_code
    FROM public.invite_campaigns c
    WHERE c.note = v_note AND c.uses = 0 AND c.valid_until > NOW()
    ORDER BY c.created_at DESC
    LIMIT 1;
    IF v_code IS NOT NULL THEN
        RETURN v_code;
    END IF;

    IF (SELECT COUNT(*) FROM public.invite_campaigns c
        WHERE c.note LIKE 'outreach ' || v_today || ': %') >= 10 THEN
        RAISE EXCEPTION 'daily_cap' USING ERRCODE = 'P0001';
    END IF;

    FOR i IN 1..50 LOOP
        -- Bytes 0 to 5 of a v4 uuid are fully random; 256 is a multiple of 32, so byte % 32 has
        -- no bias. gen_random_uuid() is core Postgres, no pgcrypto needed.
        v_bytes := uuid_send(gen_random_uuid());
        v_code := '';
        FOR j IN 0..5 LOOP
            v_code := v_code || substr(c_alphabet, 1 + (get_byte(v_bytes, j) % 32), 1);
        END LOOP;
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.users u WHERE u.invite_code = v_code)
              AND NOT EXISTS (SELECT 1 FROM public.invite_campaigns c WHERE c.code = v_code)
              AND NOT EXISTS (SELECT 1 FROM public.rolls r WHERE r.invite_code = v_code);
        v_code := NULL;
    END LOOP;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'no_code' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.invite_campaigns (code, inviter_id, valid_from, valid_until, max_uses, note)
    VALUES (v_code, v_owner, NOW(), NOW() + INTERVAL '30 days', 1, v_note);
    RETURN v_code;
END;
$$;

-- ------------------------------------------------------------
-- 3. What happened to every outreach code
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.outreach_codes_status()
RETURNS TABLE(code TEXT, note TEXT, uses INT, valid_until TIMESTAMPTZ)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT c.code, c.note, c.uses, c.valid_until
    FROM public.invite_campaigns c
    WHERE c.note LIKE 'outreach %'
    ORDER BY c.created_at;
$$;

-- ------------------------------------------------------------
-- 4. Grants: flim_outreach and service_role, nobody else
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.mint_outreach_code(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mint_outreach_code(TEXT) TO flim_outreach, service_role;

REVOKE ALL ON FUNCTION public.outreach_codes_status() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.outreach_codes_status() TO flim_outreach, service_role;
