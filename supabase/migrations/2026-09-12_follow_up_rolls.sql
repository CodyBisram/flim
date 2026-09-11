-- "Start another with this group" (owner's pick, 2026-09-11). After a roll develops, any member
-- can start a follow-up roll: a new roll, name of their choosing (the app prefills "Orlando, day
-- 2"), with every member of the finished roll INVITED, not added. An invite is a row here; it
-- shows as a card in the invitee's Rolls tab and sends one push, and it goes away when they join
-- or dismiss it, or when the roll develops. Someone who wants no part of it does nothing, and
-- nothing about them changes: no membership, no develop push, no reveal, nothing to leave.
ALTER TABLE public.rolls ADD COLUMN IF NOT EXISTS parent_roll_id UUID REFERENCES public.rolls(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.roll_follow_up_invites (
    roll_id    UUID NOT NULL REFERENCES public.rolls(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    invited_by UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    push_sent  BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (roll_id, user_id)
);
CREATE INDEX IF NOT EXISTS roll_follow_up_invites_user_idx ON public.roll_follow_up_invites (user_id);
CREATE INDEX IF NOT EXISTS roll_follow_up_invites_push_idx ON public.roll_follow_up_invites (push_sent) WHERE NOT push_sent;
ALTER TABLE public.roll_follow_up_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.roll_follow_up_invites FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON public.roll_follow_up_invites TO authenticated;
DROP POLICY IF EXISTS "follow_up_invites: own" ON public.roll_follow_up_invites;
CREATE POLICY "follow_up_invites: own"
    ON public.roll_follow_up_invites FOR SELECT TO authenticated
    USING (user_id = auth.uid());
DROP POLICY IF EXISTS "follow_up_invites: dismiss own" ON public.roll_follow_up_invites;
CREATE POLICY "follow_up_invites: dismiss own"
    ON public.roll_follow_up_invites FOR DELETE TO authenticated
    USING (user_id = auth.uid());

-- An invitee can read the roll they are invited to (name, code, creator, reveal time), which is
-- what the card and the join sheet show. Photos stay member-only as before.
DROP POLICY IF EXISTS "rolls: invitees can read" ON public.rolls;
CREATE POLICY "rolls: invitees can read"
    ON public.rolls FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.roll_follow_up_invites i WHERE i.roll_id = rolls.id AND i.user_id = auth.uid()));

-- The whole thing in one call: the roll, the creator's membership, the invites. Caller must be a
-- member of the parent; the parent must have developed (the button only exists there). Members
-- blocked either way are not invited. The code comes from the same alphabet the app uses.
CREATE OR REPLACE FUNCTION public.start_follow_up_roll(p_parent UUID, p_name TEXT)
RETURNS public.rolls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_name TEXT := TRIM(p_name);
    v_code TEXT;
    r      public.rolls;
    i      INT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_signed_in' USING ERRCODE = 'P0001'; END IF;
    IF v_name = '' OR LENGTH(v_name) > 60 THEN RAISE EXCEPTION 'bad_name' USING ERRCODE = 'P0001'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.roll_members WHERE roll_id = p_parent AND user_id = auth.uid()) THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;
    IF NOT public.is_roll_developed(p_parent) THEN
        RAISE EXCEPTION 'parent_not_developed' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 1..20 LOOP
        -- md5 of a fresh uuid, hex, so [0-9A-F]: a subset of the app's [A-Z0-9] alphabet.
        v_code := UPPER(SUBSTRING(md5(gen_random_uuid()::text) FROM 1 FOR 6));
        EXIT WHEN v_code ~ '^[A-Z0-9]{6}$'
             AND NOT EXISTS (SELECT 1 FROM public.rolls WHERE invite_code = v_code)
             AND NOT EXISTS (SELECT 1 FROM public.users WHERE invite_code = v_code);
        v_code := NULL;
    END LOOP;
    IF v_code IS NULL THEN RAISE EXCEPTION 'no_code' USING ERRCODE = 'P0001'; END IF;

    INSERT INTO public.rolls (name, invite_code, created_by, parent_roll_id)
    VALUES (v_name, v_code, auth.uid(), p_parent)
    RETURNING * INTO r;
    INSERT INTO public.roll_members (roll_id, user_id) VALUES (r.id, auth.uid()) ON CONFLICT DO NOTHING;
    INSERT INTO public.roll_follow_up_invites (roll_id, user_id, invited_by)
    SELECT r.id, m.user_id, auth.uid()
    FROM public.roll_members m
    WHERE m.roll_id = p_parent
      AND m.user_id <> auth.uid()
      AND NOT public.is_blocked_either_way(auth.uid(), m.user_id)
    ON CONFLICT DO NOTHING;
    RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public.start_follow_up_roll(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_follow_up_roll(UUID, TEXT) TO authenticated;

-- The invites waiting for the caller, as roll rows, open rolls only.
CREATE OR REPLACE FUNCTION public.follow_up_invites()
RETURNS SETOF public.rolls
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT r.*
    FROM public.roll_follow_up_invites i
    JOIN public.rolls r ON r.id = i.roll_id
    WHERE i.user_id = auth.uid()
      AND NOT public.is_roll_developed(r.id)
    ORDER BY i.created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.follow_up_invites() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.follow_up_invites() TO authenticated;

-- Joining consumes the invite, whichever way the person got in (card, push, or typing the code).
CREATE OR REPLACE FUNCTION public.join_roll(p_code TEXT)
RETURNS public.rolls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r public.rolls;
    member_count INT;
    already_member BOOLEAN;
BEGIN
    SELECT * INTO r FROM public.rolls WHERE invite_code = UPPER(p_code) LIMIT 1 FOR UPDATE;
    IF r.id IS NULL THEN
        RAISE EXCEPTION 'roll_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT EXISTS (
        SELECT 1 FROM public.roll_members WHERE roll_id = r.id AND user_id = auth.uid()
    ) INTO already_member;
    IF NOT already_member AND public.is_roll_developed(r.id) THEN
        RAISE EXCEPTION 'roll_developed' USING ERRCODE = 'P0004';
    END IF;
    IF NOT already_member THEN
        SELECT COUNT(*) INTO member_count FROM public.roll_members WHERE roll_id = r.id;
        IF member_count >= 50 THEN
            RAISE EXCEPTION 'roll_full' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.roll_members (roll_id, user_id)
        VALUES (r.id, auth.uid())
        ON CONFLICT DO NOTHING;
    END IF;
    DELETE FROM public.roll_follow_up_invites WHERE roll_id = r.id AND user_id = auth.uid();
    RETURN r;
END;
$$;
