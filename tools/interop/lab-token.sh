#!/bin/bash
# Prints the newest emailed token a lab PDS on generic.dev holds for a DID
# (VERIFICATION §7.4): none of the seven sends mail there, so the migration
# harness reads the token straight from each implementation's own store.
# Read-only; only the row of the given test account is touched.
#
#   ssh ubuntu@generic.dev 'bash -s' -- <impl> <did> < tools/interop/lab-token.sh
set -euo pipefail
impl="$1"; did="$2"
[[ "$did" =~ ^did:plc:[a-z2-7]{24}$ ]] || { echo "bad did" >&2; exit 2; }
lab=/opt/xjdao/lab
q() { sudo sqlite3 -readonly "$1" "$2"; }

case "$impl" in
  atproto|rsky)
    q "$lab/$impl/account.sqlite" "select token from email_token where did='$did' and purpose='plc_operation' order by requestedAt desc limit 1" ;;
  crates)
    q "$lab/crates/accounts.sqlite" "select token from email_token where did='$did' and purpose like '%plc%' order by expires_at desc limit 1" ;;
  cocoon)
    q "$lab/cocoon/cocoon.db" "select plc_operation_code from repos where did='$did'" ;;
  zds)
    q "$lab/zds/zds.sqlite3" "select auth_code from accounts where did='$did'" ;;
  pegasus)
    q "$lab/pegasus/pegasus.db" "select auth_code from actors where did='$did'" ;;
  tranquil)
    pg=$(sudo docker ps -qf name=^postgres-)
    sudo docker exec "$pg" psql -U postgres -d lab_tranquil -tAc \
      "select t.token from plc_operation_tokens t join users u on u.id = t.user_id where u.did='$did' order by t.created_at desc limit 1" ;;
  *) echo "unknown implementation $impl" >&2; exit 2 ;;
esac
