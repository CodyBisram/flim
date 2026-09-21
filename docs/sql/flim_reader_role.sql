-- A read-only database role for the Raspberry Pi (docs/ROUTINES.md, 2026-09-21).
-- The Pi holds no database credential: the receiver has only its header secret, the numbers job
-- runs on GitHub with the service key, and the management token rotates daily. The Monday memo's
-- "What the database says" section, and the receiver's inviter / day-one / username lookups,
-- read through this role and nothing else.
--
-- Run once in the SQL editor against production, with a password the owner sets. Then put the
-- session-pooler URI for flim_reader in ~/.ssh/pi-flim-db-url on the Mac and run
-- services/deploy-flim-hooks.sh from the Pi folder, which writes it to ~/.config/flim-hooks.env
-- on the Pi as FLIM_DB_URL. Nothing here is a migration and nothing changes for the app.

create role flim_reader login password '<owner sets this>';
grant usage on schema public to flim_reader;
grant select on all tables in schema public to flim_reader;
alter default privileges in schema public grant select on tables to flim_reader;

-- The receiver keys every lookup on users.id and never passes an email as a value, but the role
-- can still read the column. If that is unwanted, replace the third grant with per-table grants
-- and a column list on users that leaves email out.
