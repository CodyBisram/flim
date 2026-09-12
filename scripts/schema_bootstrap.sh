#!/usr/bin/env bash
# Builds an empty FLIM database from supabase/schema.sql and stops at the first error.
#
# The schema file is a ledger: every migration is appended in order, including ones that
# redefine what an earlier one created. Production only ever ran each once, so nothing had ever
# run the whole file until 2026-09-11, when it turned out three redefinitions could not be
# applied fresh (a function whose return shape changed without a DROP first, a policy created
# twice). This script is the check that the file still produces a database, and the way to get
# a staging copy to test migrations against instead of production.
#
# Runs Supabase's own Postgres image (auth.uid(), auth.users, storage.objects, pg_net, pg_cron
# and the anon/authenticated/service_role roles are all there, like on the platform), applies
# the file with ON_ERROR_STOP, then applies it a SECOND time to prove it is rerunnable, which
# the file's own header promises. Leaves the container running when asked, so migrations can be
# tried against it: `scripts/schema_bootstrap.sh --keep`, then
# `psql postgresql://postgres:postgres@localhost:54329/postgres`.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${FLIM_PG_IMAGE:-supabase/postgres:17.6.1.121}"
NAME=flim-schema-bootstrap
PORT="${FLIM_PG_PORT:-54329}"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1

docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:5432" -e POSTGRES_PASSWORD=postgres "$IMAGE" > /dev/null
trap '[[ $KEEP -eq 1 ]] || docker rm -f "$NAME" > /dev/null 2>&1 || true' EXIT

echo "waiting for postgres"
for _ in $(seq 1 60); do
  docker exec "$NAME" pg_isready -U postgres -h localhost > /dev/null 2>&1 && break
  sleep 1
done
docker exec "$NAME" pg_isready -U postgres -h localhost > /dev/null 2>&1 || { echo "postgres never came up"; exit 1; }
# The platform image's own init takes a moment after pg_isready; wait for the auth schema.
for _ in $(seq 1 60); do
  docker exec -e PGPASSWORD=postgres "$NAME" psql -U postgres -h localhost -d postgres -tAc "select 1 from pg_namespace where nspname = 'auth'" 2>/dev/null | grep -q 1 && break
  sleep 1
done

echo "== platform shim (storage tables, pg_net, pg_cron)"
docker exec -i -e PGPASSWORD=postgres "$NAME" psql -U supabase_admin -h localhost -d postgres -v ON_ERROR_STOP=1 -q -f - < supabase/bootstrap/platform.sql > /tmp/flim-bootstrap-platform.log 2>&1 \
  || { echo "   shim FAILED"; grep -m1 -A4 ERROR /tmp/flim-bootstrap-platform.log | sed 's/^/   /'; exit 1; }

apply() {
  local label=$1
  echo "== $label"
  if docker exec -i -e PGPASSWORD=postgres "$NAME" psql -U postgres -h localhost -d postgres -v ON_ERROR_STOP=1 -q -f - < supabase/schema.sql > /tmp/flim-bootstrap-$label.log 2>&1; then
    echo "   ok"
  else
    echo "   FAILED. First error:"
    grep -m1 -B2 -A6 "ERROR" /tmp/flim-bootstrap-$label.log | sed 's/^/   /'
    echo "   (full log: /tmp/flim-bootstrap-$label.log)"
    return 1
  fi
}
apply first
apply second
echo "== objects"
docker exec -e PGPASSWORD=postgres "$NAME" psql -U postgres -h localhost -d postgres -tAc "select 'tables ' || count(*) from pg_tables where schemaname = 'public' union all select 'functions ' || count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' union all select 'policies ' || count(*) from pg_policies where schemaname = 'public' union all select 'triggers ' || count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal" | sed 's/^/   /'
[[ $KEEP -eq 1 ]] && echo "container $NAME kept on port $PORT (postgres/postgres)"
