-- The invite loop, tightened (2026-09-25). NOT YET APPLIED.
--
-- Two additive pieces, safe to re-run, no client change required.
--
-- 1. invite_earnbacks.push_sent. An invite has come back to its inviter since 2026-08-29
--    (credit_invite_earnback, on the invitee's first photo), silently: the count on the
--    invite sheet went up and nothing said so. The earn-back is the one reward the invite
--    loop has, and a reward nobody notices does not change what anyone does. send-social-push
--    reads rows with push_sent = false and tells the inviter, then flips the flag, the same
--    shape as follows.push_sent. Every row that exists when the column is added is marked sent,
--    so applying it announces only earn-backs that happen afterwards, never a backlog.
--
-- 2. invite_landing(p_code). The web page at /i/CODE shows the code and nothing about who sent
--    it. A stranger holding a link from a friend is more likely to install when the page names
--    the friend. invite_preview already answers that for the sign-in screen, but it spends the
--    'global' invite rate budget (300 an hour) that redeem_invite also spends, so page views
--    could lock real sign-ups out. This is a separate, read-only lookup with its own budget:
--    personal codes only (a campaign or roll code resolves to nothing here and the page stays
--    generic), and it returns what invite_preview already returns to anon for that code, the
--    inviter's handle and display name, plus the number of Founding 100 seats left, which the
--    nightly numbers already compute the same way. No email, no id, no invite count.

-- ------------------------------------------------------------
-- 1. Earn-back announcements
-- ------------------------------------------------------------
-- Added with DEFAULT true so every row that exists at that moment is marked sent (history, not
-- news), then the default flips to false for rows credited from now on. On a re-run ADD COLUMN IF
-- NOT EXISTS does nothing, so no later earn-back is ever silenced by running this again.
ALTER TABLE public.invite_earnbacks
    ADD COLUMN IF NOT EXISTS push_sent BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE public.invite_earnbacks ALTER COLUMN push_sent SET DEFAULT false;

CREATE INDEX IF NOT EXISTS invite_earnbacks_unsent_idx
    ON public.invite_earnbacks (credited_at) WHERE NOT push_sent;

-- ------------------------------------------------------------
-- 2. The landing page's lookup
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.invite_landing(p_code TEXT)
RETURNS TABLE(username TEXT, display_name TEXT, founding_left INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_code TEXT := UPPER(TRIM(COALESCE(p_code, '')));
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;
    -- Its own budgets, never 'global': a shared link opened a thousand times must not be able to
    -- stop anyone from signing up.
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
