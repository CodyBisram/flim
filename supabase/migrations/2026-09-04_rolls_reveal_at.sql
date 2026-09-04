-- ============================================================
-- Migration: rolls.reveal_at, the single source of truth for when a roll
-- develops.
-- Paste into Supabase Dashboard -> SQL Editor and run once.
-- Idempotent: the ALTER/backfill/NOT NULL sequence is safe to re-run (the
-- backfill only touches rows where reveal_at IS NULL, so a second run is a
-- no-op; ALTER COLUMN SET NOT NULL on an already-NOT-NULL column is a no-op
-- too). Functions use CREATE OR REPLACE, triggers are DROP IF EXISTS then
-- recreated. Already mirrored in schema.sql.
--
-- Context (2026-09-04 rolls audit, recommendation 2 in docs/PENDING.md's
-- "the rolls audit, and what it changed"): a roll's reveal has always been
-- created_at + 12h, but that math was computed in three separate places --
-- the client's Roll.developDelay constant, is_roll_developed() on the
-- server, and each roll photo's develops_at column, written by the client
-- at capture time from whatever the client believed the roll's reveal was.
-- Extending a roll this week took two hand SQL edits plus a straggler sweep
-- to catch photos develops_at missed, and a phone that had cached the old
-- reveal time showed it on the lock screen until the app reopened. This
-- migration makes rolls.reveal_at the one column every reader (the photos
-- INSERT policy via is_roll_developed, join_roll via the same function, the
-- develop push, the is_developed cron, and RollService on the client) reads,
-- and the one column every writer (roll creation's 12h default, the new
-- set_roll_reveal_at RPC, or a hand SQL edit) can move, with the cascade to
-- photos.develops_at happening automatically either way.
--
-- Full detail (why a trigger-filled default and not a NOT NULL DEFAULT
-- expression, why the photos-side pin overrides the client instead of just
-- trusting it, why the cascade lives in a trigger shared by the RPC and a
-- hand edit rather than duplicated in the RPC body) is in the comments this
-- migration adds to schema.sql, next to each object below.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The column: backfill existing rows, then require it going forward.
-- ------------------------------------------------------------
ALTER TABLE public.rolls ADD COLUMN IF NOT EXISTS reveal_at TIMESTAMPTZ;
UPDATE public.rolls SET reveal_at = created_at + interval '12 hours' WHERE reveal_at IS NULL;
ALTER TABLE public.rolls ALTER COLUMN reveal_at SET NOT NULL;

-- ------------------------------------------------------------
-- 2. Default-fill on roll creation. Only fills when the caller (any
--    existing client, which knows nothing about this column) left it NULL;
--    never overrides a caller-supplied value, so this cannot widen roll
--    creation beyond today's 12h-from-creation semantics.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.default_roll_reveal_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.reveal_at IS NULL THEN
        NEW.reveal_at := NEW.created_at + interval '12 hours';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.default_roll_reveal_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS default_roll_reveal_at_trigger ON public.rolls;
CREATE TRIGGER default_roll_reveal_at_trigger
    BEFORE INSERT ON public.rolls
    FOR EACH ROW EXECUTE FUNCTION public.default_roll_reveal_at();

-- ------------------------------------------------------------
-- 3. Cascade: any change to rolls.reveal_at (the RPC in step 6, or a hand
--    SQL edit -- indistinguishable to this trigger on purpose) pushes the
--    same value onto that roll's still-undeveloped photos. Developed photos
--    (is_developed = true) are left alone.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cascade_roll_reveal_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.photos
    SET develops_at = NEW.reveal_at
    WHERE roll_id = NEW.id AND is_developed = false;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.cascade_roll_reveal_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS cascade_roll_reveal_at_trigger ON public.rolls;
CREATE TRIGGER cascade_roll_reveal_at_trigger
    AFTER UPDATE OF reveal_at ON public.rolls
    FOR EACH ROW
    WHEN (OLD.reveal_at IS DISTINCT FROM NEW.reveal_at)
    EXECUTE FUNCTION public.cascade_roll_reveal_at();

-- ------------------------------------------------------------
-- 4. is_roll_developed reads reveal_at instead of created_at + 12h. Same
--    signature, same callers (the photos INSERT policy, join_roll,
--    set_roll_reveal_at itself), no drift possible between them because
--    they all still go through this one function.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_roll_developed(p_roll UUID)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.rolls
        WHERE id = p_roll AND reveal_at <= now()
    );
$$;

-- ------------------------------------------------------------
-- 5. Pin a roll photo's develops_at to its roll's reveal_at on INSERT,
--    overriding whatever the client sent, so a stale phone can no longer
--    write a wrong develop time. Personal shots (roll_id IS NULL) keep the
--    client's own develops_at, unchanged from today.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pin_roll_photo_develops_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.roll_id IS NOT NULL THEN
        SELECT reveal_at INTO NEW.develops_at FROM public.rolls WHERE id = NEW.roll_id;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.pin_roll_photo_develops_at() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS pin_roll_photo_develops_at_trigger ON public.photos;
CREATE TRIGGER pin_roll_photo_develops_at_trigger
    BEFORE INSERT ON public.photos
    FOR EACH ROW EXECUTE FUNCTION public.pin_roll_photo_develops_at();

-- ------------------------------------------------------------
-- 6. set_roll_reveal_at: lets a roll's creator move its reveal. Creator
--    only, refuses once the roll has developed, bounds the new time to
--    [now(), created_at + 7 days], truncates to milliseconds on the way in
--    (the client's keyset cursor formats to milliseconds; see the
--    2026-09-03 Islands roll microsecond incident in docs/PENDING.md).
--    Returns the saved, truncated reveal_at. The photos.develops_at cascade
--    is not duplicated here -- the trigger in step 3 fires on this
--    function's own UPDATE.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_roll_reveal_at(p_roll UUID, p_reveal_at TIMESTAMPTZ)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r public.rolls;
    v_reveal_at TIMESTAMPTZ;
BEGIN
    SELECT * INTO r FROM public.rolls WHERE id = p_roll;
    IF r.id IS NULL THEN
        RAISE EXCEPTION 'roll_not_found' USING ERRCODE = 'P0002';
    END IF;

    IF r.created_by <> auth.uid() THEN
        RAISE EXCEPTION 'not_creator' USING ERRCODE = 'P0003';
    END IF;

    IF public.is_roll_developed(r.id) THEN
        RAISE EXCEPTION 'roll_developed' USING ERRCODE = 'P0004';
    END IF;

    v_reveal_at := date_trunc('milliseconds', p_reveal_at);

    IF v_reveal_at < now() OR v_reveal_at > r.created_at + interval '7 days' THEN
        RAISE EXCEPTION 'reveal_out_of_range' USING ERRCODE = 'P0005';
    END IF;

    UPDATE public.rolls SET reveal_at = v_reveal_at WHERE id = p_roll;

    RETURN v_reveal_at;
END;
$$;
REVOKE ALL ON FUNCTION public.set_roll_reveal_at(UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_roll_reveal_at(UUID, TIMESTAMPTZ) TO authenticated;
