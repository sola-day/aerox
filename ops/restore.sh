#!/usr/bin/env bash
# Restore drill (VERIFICATION §10.4): rebuild a stack on a *fresh* host from a
# backup made by ops/backup.sh. Refuses to run against databases that already
# contain aerox tables, so it cannot clobber a live deployment by accident.
#
#   ops/restore.sh <backup-dir> <age-identity-file>
# Env: PDS_DATABASE_URL, PLC_DATABASE_URL (superuser or owner on the target), BLOB_ROOT.
set -euo pipefail
src="${1:?backup dir}"; identity="${2:?age identity}"
: "${PDS_DATABASE_URL:?}" "${PLC_DATABASE_URL:?}" "${BLOB_ROOT:?}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pg_url() { echo "${1#ecto://}" | sed 's#^#postgresql://#'; }

( cd "$src" && sha256sum --check --quiet SHA256SUMS )
for f in aerox_pds.dump aerox_core.dump blobs.tar COMMIT; do
  age --decrypt --identity "$identity" --output "$work/$f" "$src/$f.age"
done

for url in "$PDS_DATABASE_URL" "$PLC_DATABASE_URL"; do
  n="$(psql -tA "$(pg_url "$url")" -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
  if [ "$n" != "0" ]; then echo "refusing: target database already has $n tables ($url)"; exit 2; fi
done
if [ -e "$BLOB_ROOT/blobs" ] && [ -n "$(ls -A "$BLOB_ROOT/blobs")" ]; then echo "refusing: $BLOB_ROOT/blobs is not empty"; exit 2; fi

pg_restore --no-owner --dbname="$(pg_url "$PDS_DATABASE_URL")" "$work/aerox_pds.dump"
pg_restore --no-owner --dbname="$(pg_url "$PLC_DATABASE_URL")" "$work/aerox_core.dump"
mkdir -p "$BLOB_ROOT"; tar --numeric-owner --xattrs -C "$BLOB_ROOT" -xf "$work/blobs.tar"
echo "restored backup taken at commit $(cat "$work/COMMIT")"
echo "next: run the release's migrations (bin/aerox eval Aerox.Release.migrate) and VERIFICATION §6 scenario 1"
