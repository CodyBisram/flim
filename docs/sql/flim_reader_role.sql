-- The hand-run companion to supabase/migrations/2026-09-22_pi_reader.sql (docs/ROUTINES.md,
-- 2026-09-21). The Pi holds no database credential: the receiver has only its header secret, the
-- numbers job runs on GitHub with the service key, and the management token rotates daily. The
-- Monday memo's "What the database says" section, and the receiver's inviter / day-one / username
-- lookups, read through this role and nothing else.
--
-- flim_reader is a plain Postgres login (no BYPASSRLS -- Supabase does not allow postgres to
-- grant that), so it cannot read a single table directly: every table here is RLS-gated on
-- auth.uid(), which is NULL for a session with no JWT. The 2026-09-22 migration fixed that the
-- right way, the one nightly_numbers() already uses: two SECURITY DEFINER functions, owned by
-- postgres, that compute exactly what the Pi needs. flim_reader can EXECUTE
-- public.memo_snapshot() and public.receiver_lookup(uuid) and read nothing else at all. If that
-- ever needs to change, add a third function, never a table grant.
--
-- Run this once in the SQL editor against production, after the migration is applied, with a
-- password the owner sets. Then put the session-pooler URI for flim_reader in
-- ~/.ssh/pi-flim-db-url on the Mac and run services/deploy-flim-hooks.sh from the Pi folder,
-- which writes it to ~/.config/flim-hooks.env on the Pi as FLIM_DB_URL. Nothing here is a
-- migration and nothing changes for the app.

ALTER ROLE flim_reader PASSWORD '<owner sets this>';

-- Connection note: session pooler, not the direct connection (the Pi's network path only reaches
-- the pooler), database postgres, user flim_reader, the password just set above.

-- Nothing else to run here. flim_reader already has USAGE on schema public and EXECUTE on the
-- two functions from the migration; it has no SELECT, INSERT, UPDATE or DELETE on any table, and
-- no BYPASSRLS. If a query against it returns zero rows instead of an error, that means an RLS
-- policy said no, not that this role is misconfigured -- it is not supposed to reach tables at
-- all.
