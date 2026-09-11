-- Audit 2 (2026-09-11), server side of findings 9, 11, 12 and 13.

-- ---------------------------------------------------------------------------
-- 11. rolls: the write boundary the photos got. The only column a client changes on a roll is
-- cover_path (creator, from the roll's own photos); reveal_at goes through set_roll_reveal_at;
-- name is set once at creation and never changes (rename was removed 2026-09-02). Grep of every
-- client write done first this time: RollService.setRollCover is the one UPDATE.
-- ---------------------------------------------------------------------------
REVOKE UPDATE, TRUNCATE, REFERENCES, TRIGGER ON public.rolls FROM anon, authenticated;
GRANT UPDATE (cover_path) ON public.rolls TO authenticated;

-- A cover must be one of this roll's own photographs (any rendition). Server writes skip this.
-- Every existing cover already conforms (9 of 9, checked 2026-09-11).
CREATE OR REPLACE FUNCTION public.lock_roll_cover_to_roll()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN RETURN NEW; END IF;
    IF NEW.cover_path IS NOT NULL AND NEW.cover_path IS DISTINCT FROM OLD.cover_path
       AND NOT EXISTS (
           SELECT 1 FROM public.photos p
           WHERE p.roll_id = NEW.id
             AND (p.storage_path = NEW.cover_path OR p.thumb_path = NEW.cover_path OR p.feed_path = NEW.cover_path)
       ) THEN
        RAISE EXCEPTION 'cover_not_in_roll' USING ERRCODE = 'P0005';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_roll_cover_to_roll() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lock_roll_cover_to_roll_trigger ON public.rolls;
CREATE TRIGGER lock_roll_cover_to_roll_trigger
    BEFORE UPDATE ON public.rolls
    FOR EACH ROW EXECUTE FUNCTION public.lock_roll_cover_to_roll();

-- ---------------------------------------------------------------------------
-- 12. Follow-up rolls: idempotent creation and a daily cap. The client sends a request id it
-- keeps across retries of one create; a second call with the same id returns the roll the
-- first call made instead of a second roll and a second fan-out of invites. Five follow-ups per
-- person per day is more than any trip needs and bounds the pushes one account can cause.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.roll_follow_up_requests (
    request_id UUID PRIMARY KEY,
    roll_id    UUID NOT NULL REFERENCES public.rolls(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE public.roll_follow_up_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.roll_follow_up_requests FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.start_follow_up_roll(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.start_follow_up_roll(p_parent UUID, p_name TEXT, p_request UUID DEFAULT NULL)
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
    IF p_request IS NOT NULL THEN
        SELECT ro.* INTO r FROM public.roll_follow_up_requests q JOIN public.rolls ro ON ro.id = q.roll_id
        WHERE q.request_id = p_request AND q.created_by = auth.uid();
        IF r.id IS NOT NULL THEN RETURN r; END IF;
    END IF;
    IF v_name = '' OR LENGTH(v_name) > 60 THEN RAISE EXCEPTION 'bad_name' USING ERRCODE = 'P0001'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.roll_members WHERE roll_id = p_parent AND user_id = auth.uid()) THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;
    IF NOT public.is_roll_developed(p_parent) THEN
        RAISE EXCEPTION 'parent_not_developed' USING ERRCODE = 'P0001';
    END IF;
    IF (SELECT COUNT(*) FROM public.rolls WHERE created_by = auth.uid() AND parent_roll_id IS NOT NULL
        AND created_at > NOW() - INTERVAL '1 day') >= 5 THEN
        RAISE EXCEPTION 'too_many_follow_ups_today' USING ERRCODE = 'P0003';
    END IF;
    -- Serialize per caller, so two concurrent calls with the same request id cannot both pass
    -- the lookup above.
    PERFORM pg_advisory_xact_lock(hashtext('start_follow_up_roll:' || auth.uid()::text));
    IF p_request IS NOT NULL THEN
        SELECT ro.* INTO r FROM public.roll_follow_up_requests q JOIN public.rolls ro ON ro.id = q.roll_id
        WHERE q.request_id = p_request AND q.created_by = auth.uid();
        IF r.id IS NOT NULL THEN RETURN r; END IF;
    END IF;
    FOR i IN 1..20 LOOP
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
    IF p_request IS NOT NULL THEN
        INSERT INTO public.roll_follow_up_requests (request_id, roll_id, created_by) VALUES (p_request, r.id, auth.uid());
    END IF;
    RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public.start_follow_up_roll(UUID, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_follow_up_roll(UUID, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. Push delivery: one row per (kind, source, recipient) with attempts, so a recipient whose
-- device failed is retried on later runs (up to three) while the ones who got it are not sent
-- twice, and a permanently dead device cannot keep a source row unsent forever. Both push
-- functions read and write this; nothing else does.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.push_deliveries (
    kind       TEXT NOT NULL,
    source_id  TEXT NOT NULL,
    user_id    UUID NOT NULL,
    attempts   INT  NOT NULL DEFAULT 0,
    delivered  BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (kind, source_id, user_id)
);
CREATE INDEX IF NOT EXISTS push_deliveries_updated_idx ON public.push_deliveries (updated_at);
ALTER TABLE public.push_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_deliveries FROM PUBLIC, anon, authenticated;

-- Leases carry an owner token: only the run that took the lease can release it, so a run that
-- outlived its lease cannot release the next run's.
ALTER TABLE public.push_run_locks ADD COLUMN IF NOT EXISTS token UUID;
DROP FUNCTION IF EXISTS public.acquire_push_lock(TEXT, INT);
CREATE OR REPLACE FUNCTION public.acquire_push_lock(p_name TEXT, p_seconds INT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_token UUID := gen_random_uuid();
    v_taken UUID;
BEGIN
    INSERT INTO public.push_run_locks (name, locked_until) VALUES (p_name, NOW() - INTERVAL '1 second')
    ON CONFLICT (name) DO NOTHING;
    UPDATE public.push_run_locks
    SET locked_until = NOW() + make_interval(secs => p_seconds), token = v_token
    WHERE name = p_name AND locked_until < NOW()
    RETURNING token INTO v_taken;
    RETURN v_taken;
END;
$$;
DROP FUNCTION IF EXISTS public.release_push_lock(TEXT);
CREATE OR REPLACE FUNCTION public.release_push_lock(p_name TEXT, p_token UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.push_run_locks SET locked_until = NOW() - INTERVAL '1 second', token = NULL
    WHERE name = p_name AND token = p_token;
$$;
REVOKE ALL ON FUNCTION public.acquire_push_lock(TEXT, INT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_push_lock(TEXT, UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 13. Operational alerts: a scheduled function that stops doing its job says so here, and the
-- social push run turns each row into one push to the owner. First user: the sweeper's cap.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ops_alerts (
    id         BIGSERIAL PRIMARY KEY,
    source     TEXT NOT NULL,
    detail     TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    push_sent  BOOLEAN NOT NULL DEFAULT FALSE
);
ALTER TABLE public.ops_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ops_alerts FROM PUBLIC, anon, authenticated;
