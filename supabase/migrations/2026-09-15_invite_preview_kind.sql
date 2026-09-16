-- invite_preview says what KIND of code it resolved (2026-09-15, v2 batch 4): 'personal' (a
-- person's own code), 'campaign' (a time-boxed cohort code, whose "inviter" is whoever made it
-- but who did not invite this person in particular), or 'roll'. Additive fifth column; older
-- clients decode by name and never see it. The client uses it to give a campaign arrival the
-- honest first visit: nobody knows them yet, so Find friends opens first.
DROP FUNCTION IF EXISTS public.invite_preview(text);
CREATE OR REPLACE FUNCTION public.invite_preview(p_code text)
 RETURNS TABLE(inviter_id uuid, username text, display_name text, roll_name text, kind text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_code TEXT := UPPER(TRIM(p_code));
BEGIN
    IF v_code !~ '^[A-Z0-9]{6}$' THEN
        RETURN;
    END IF;
    PERFORM public.bump_invite_rate('global', 300);
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
