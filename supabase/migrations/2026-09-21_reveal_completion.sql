-- ============================================================
-- Reveal completion, not just opened (audit item 1, 2026-09-21).
--
-- roll_reveal_views.viewed_at is written the moment a reveal deck opens. Every
-- reader that feeds "am I done with this roll" (rollRevealSeen, the Rolls dot,
-- the widget, save-on-develop) is downstream of that row existing, so opening a
-- reveal and bailing at frame two reads exactly like finishing it. completed_at
-- is a second timestamp, set only once the reveal actually finishes, so a
-- client can seed its local seen flag from completion instead of the open.
-- ============================================================

ALTER TABLE public.roll_reveal_views ADD COLUMN IF NOT EXISTS completed_at timestamptz;

-- Every historical open is treated as watched, because replaying every reveal for everyone would be worse.
UPDATE public.roll_reveal_views SET completed_at = viewed_at WHERE completed_at IS NULL;

-- A member's own row used to be readable only through "read for member rolls"
-- (is_roll_member(roll_id)), which stops being true the moment they leave the
-- roll ("roll_members: leave or creator removes" lets a member delete their own
-- membership). Their roll_reveal_views row survives that delete (no cascade
-- from roll_members), so without this a departed member's own completion could
-- no longer be read back, even by themselves.
DROP POLICY IF EXISTS "reveal_views: read own" ON public.roll_reveal_views;
CREATE POLICY "reveal_views: read own"
    ON public.roll_reveal_views FOR SELECT TO authenticated
    USING (user_id = auth.uid());

-- Records (or completes) the caller's own reveal view. Called once a reveal
-- deck actually finishes, distinct from the open recorded elsewhere. Upserts
-- rather than requiring the open to have happened first: a reveal that somehow
-- finishes without an earlier open-row still gets one. completed_at only ever
-- moves from NULL to a timestamp, never back, and never forward once set.
CREATE OR REPLACE FUNCTION public.complete_reveal_view(p_roll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.roll_members
        WHERE roll_id = p_roll_id AND user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'not a member of this roll';
    END IF;

    INSERT INTO public.roll_reveal_views (roll_id, user_id, viewed_at, completed_at)
    VALUES (p_roll_id, auth.uid(), now(), now())
    ON CONFLICT (roll_id, user_id) DO UPDATE
        SET completed_at = COALESCE(public.roll_reveal_views.completed_at, now());
END;
$$;

REVOKE ALL ON FUNCTION public.complete_reveal_view(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_reveal_view(uuid) TO authenticated;
