#!/bin/bash
# Bootstraps the two databases of DESIGN §4.6 plus their _test pairs
# (VERIFICATION §11: the test helper refuses to run if either is missing),
# and the four per-service roles of DESIGN §4.6 / STRUCTURE §7.
#
# Roles are cluster-level objects, so they cannot come from a migration; each
# service's *schema* and its grants do (priv/<svc>_repo/migrations). This file
# is idempotent so it can be re-run against an existing cluster with
#   docker compose exec -T db bash < docker/postgres/init/01-databases.sh
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['aerox_pds','aerox_plc','aerox_relay','aerox_appview'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', r, r);
    END IF;
  END LOOP;
END $$;
SQL

create_db() {
  local db="$1"
  if ! psql -tA --username "$POSTGRES_USER" --dbname postgres -c "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    echo "creating database $db"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "CREATE DATABASE $db OWNER $POSTGRES_USER"
  fi
  # pg_trgm backs the CJK search path (DESIGN §15.8)
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"
}

for suffix in "" "_test"; do
  pds="aerox_pds$suffix"; core="aerox_core$suffix"
  create_db "$pds"; create_db "$core"

  # The PDS role owns its database outright.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "ALTER DATABASE $pds OWNER TO aerox_pds"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "REVOKE CONNECT ON DATABASE $pds FROM PUBLIC"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$pds" -c "ALTER SCHEMA public OWNER TO aerox_pds"
  for r in aerox_plc aerox_relay aerox_appview; do
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "REVOKE CONNECT ON DATABASE $pds FROM $r"
  done

  # The three core roles may connect to and create their own schema in aerox_core,
  # and nothing else: REVOKE on public stops the default shared schema being a
  # back door. The AppView role also hosts Oban (DESIGN §21.6).
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "REVOKE CONNECT ON DATABASE $core FROM PUBLIC"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "REVOKE CONNECT ON DATABASE $core FROM aerox_pds"
  for r in aerox_plc aerox_relay aerox_appview; do
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "GRANT CONNECT, CREATE ON DATABASE $core TO $r"
  done
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$core" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC"
  # Each service's schema pre-exists, owned by its role: Ecto puts the repo's
  # `schema_migrations` wherever `search_path` points, so the schema has to be
  # there before the first migration can record itself (STRUCTURE §10).
  for r in aerox_plc aerox_relay aerox_appview; do
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$core" -c "CREATE SCHEMA IF NOT EXISTS ${r#aerox_} AUTHORIZATION $r"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$core" -c "REVOKE ALL ON SCHEMA ${r#aerox_} FROM PUBLIC"
  done
  # pg_trgm's functions live in public; USAGE (not CREATE) keeps them callable.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$core" -c "GRANT USAGE ON SCHEMA public TO aerox_plc, aerox_relay, aerox_appview"
done
