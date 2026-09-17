-- Feed seen-marks follow the account (2026-09-16, owner's ask after a reinstall showed "16 shots
-- from 8 friends" he had already read). Until now the marks were device-only by design; they
-- now also live here, one row per (person, post), readable and writable ONLY by that person.
-- The author of a post can never learn who reached it: there is no SELECT path for anyone but
-- the viewer, and nothing aggregates this table. Written in small batches by the client, read
-- once at sign-in to seed a fresh install. Rows go with the post or the account.
CREATE TABLE IF NOT EXISTS public.post_seen (
    user_id  uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    post_id  uuid NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    seen_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, post_id)
);
ALTER TABLE public.post_seen ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS post_seen_user_seen_idx ON public.post_seen (user_id, seen_at DESC);

DROP POLICY IF EXISTS "post_seen: own rows" ON public.post_seen;
CREATE POLICY "post_seen: own rows"
    ON public.post_seen FOR SELECT TO authenticated
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "post_seen: record own" ON public.post_seen;
CREATE POLICY "post_seen: record own"
    ON public.post_seen FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id);

REVOKE ALL ON public.post_seen FROM PUBLIC, anon;
GRANT SELECT, INSERT ON public.post_seen TO authenticated;
