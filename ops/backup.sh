#!/usr/bin/env bash
# Physical backup (DESIGN §4.4, §14.5): both Postgres databases plus the blob
# store *with ownership bits*, in one dated directory, encrypted at rest with
# age (the operator's public key; the private key is not on this host).
#
#   ops/backup.sh <dest-dir> <age-recipient>
# Env: PDS_DATABASE_URL, PLC_DATABASE_URL (any aerox_core role URL), BLOB_ROOT.
# Restore with ops/restore.sh. Exercised by VERIFICATION §10.4's restore drill.
set -euo pipefail
dest="${1:?dest dir}"; recipient="${2:?age recipient}"
: "${PDS_DATABASE_URL:?}" "${PLC_DATABASE_URL:?}" "${BLOB_ROOT:?}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
out="$dest/aerox-$stamp"; mkdir -p "$out"

pg_url() { echo "${1#ecto://}" | sed 's#^#postgresql://#'; }
pg_dump --format=custom --no-owner --file="$work/aerox_pds.dump"  "$(pg_url "$PDS_DATABASE_URL")"
pg_dump --format=custom --no-owner --file="$work/aerox_core.dump" "$(pg_url "$PLC_DATABASE_URL")"
# --numeric-owner + xattrs: the rice-storage lesson (DESIGN §4.4) — ownership bits travel with the blobs.
tar --numeric-owner --xattrs -C "$BLOB_ROOT" -cf "$work/blobs.tar" .
git -C "$(dirname "$0")/.." rev-parse HEAD > "$work/COMMIT" 2>/dev/null || echo unknown > "$work/COMMIT"

for f in aerox_pds.dump aerox_core.dump blobs.tar COMMIT; do
  age --recipient "$recipient" --output "$out/$f.age" "$work/$f"
done
( cd "$out" && sha256sum ./*.age > SHA256SUMS )
chmod -R go-rwx "$out"
echo "backup written to $out"
