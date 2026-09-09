-- The accent colour a person picks at sign-up (and in Settings) only ever lived in UserDefaults,
-- so a reinstall or a new phone sent it back to amber. It is theirs, so it belongs on their row.
-- Nobody else reads it: it is not in the profiles view and there is no SELECT grant for other
-- rows. get_own_profile returns the whole row, so the app sees it without a signature change.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS accent_color TEXT;
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_accent_color_known;
ALTER TABLE public.users ADD CONSTRAINT users_accent_color_known
    CHECK (accent_color IS NULL OR accent_color IN ('amber', 'rose', 'violet', 'teal', 'lime', 'sky'));
-- Column-scoped, like the other own-row edits (the row policy "users: own row" still applies).
GRANT UPDATE (accent_color) ON public.users TO authenticated;
