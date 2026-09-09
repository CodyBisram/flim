-- Trust batch, 2026-09-09 (from docs/REPOSITORY_AUDIT_2026-09-09.md items 4, 6 and the
-- deployment-verification item). Four changes, each closing a path the app never offered but the
-- database allowed.

-- 1. Invite-only, enforced where accounts are made. The app checks the allowlist before it
--    asks Auth for a code; nothing on the server did, so a direct call to Auth with the public
--    key could create an account for any email. This trigger is the server's own gate: an auth
--    user may only be created for an allowlisted email, or the App Review login. Existing
--    accounts are untouched (insert only). The app's own pre-check still runs first, so a real
--    person still sees the friendly "you need an invite" rather than a database error.
CREATE OR REPLACE FUNCTION public.gate_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.email IS NULL THEN
        RAISE EXCEPTION 'not_invited' USING ERRCODE = 'P0005';
    END IF;
    IF LOWER(TRIM(NEW.email)) = 'review@flim-app.com' THEN
        RETURN NEW;
    END IF;
    IF NOT public.is_email_allowed(NEW.email) THEN
        RAISE EXCEPTION 'not_invited' USING ERRCODE = 'P0005';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS gate_new_auth_user_trigger ON auth.users;
CREATE TRIGGER gate_new_auth_user_trigger
    BEFORE INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.gate_new_auth_user();

-- 2. Discussion inherits the post's visibility. Comments, reactions, tags and comment likes were
--    readable to anyone the author had not blocked, whether or not the post itself could be
--    read (hidden, or covered). Requiring the parent row to be visible runs the posts policy
--    inside the subquery, so every rule that hides a post hides its discussion with it.
DROP POLICY IF EXISTS "post_comments: readable" ON public.post_comments;
CREATE POLICY "post_comments: readable"
    ON public.post_comments FOR SELECT
    USING (
        NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_comments.post_id)
    );
DROP POLICY IF EXISTS "post_reactions: readable" ON public.post_reactions;
CREATE POLICY "post_reactions: readable"
    ON public.post_reactions FOR SELECT
    USING (
        NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_reactions.post_id)
    );
DROP POLICY IF EXISTS "post_tags: readable" ON public.post_tags;
CREATE POLICY "post_tags: readable"
    ON public.post_tags FOR SELECT
    USING (
        NOT public.is_blocked_either_way(auth.uid(), tagged_user_id)
        AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = post_tags.post_id)
    );
DROP POLICY IF EXISTS "comment_likes: readable" ON public.comment_likes;
CREATE POLICY "comment_likes: readable"
    ON public.comment_likes FOR SELECT
    USING (
        NOT public.is_blocked_either_way(auth.uid(), user_id)
        AND EXISTS (SELECT 1 FROM public.post_comments c WHERE c.id = comment_likes.comment_id)
    );

-- 3. Joining a roll goes through join_roll. The INSERT policy let any member add themselves to
--    any roll whose id they knew, past the developed-roll refusal and the cap, both of which live
--    only in the function. Now the only direct insert allowed is a creator joining their own
--    roll; everyone else arrives through join_roll, which is SECURITY DEFINER and not subject to
--    this policy. The function also locks the roll row so two simultaneous joins cannot both
--    count 49 and both insert.
DROP POLICY IF EXISTS "roll_members: can join" ON public.roll_members;
CREATE POLICY "roll_members: creator joins own roll"
    ON public.roll_members FOR INSERT
    WITH CHECK (
        user_id = auth.uid()
        AND EXISTS (SELECT 1 FROM public.rolls r WHERE r.id = roll_members.roll_id AND r.created_by = auth.uid())
    );

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
    -- FOR UPDATE: the cap below is counted under this lock, so joins to one roll serialise.
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
    RETURN r;
END;
$$;
