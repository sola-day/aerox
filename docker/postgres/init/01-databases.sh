#!/bin/bash
# Creates the two databases of DESIGN §4.6 plus their _test pairs
# (VERIFICATION §11: the test helper refuses to run if either is missing).
set -euo pipefail

for db in aerox_pds aerox_core aerox_pds_test aerox_core_test; do
  echo "creating database $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE DATABASE $db OWNER $POSTGRES_USER;
SQL
  # pg_trgm backs the CJK search path (DESIGN §15.8)
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-SQL
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
done
