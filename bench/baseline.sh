#!/usr/bin/env bash
# VERIFICATION §10.1 load baselines against a running stack. Needs `oha`
# (https://github.com/hatoo/oha) and a session on the PDS; prints p50/p99 and
# req/s per endpoint. Record the numbers in bench/RESULTS.md with the commit.
#
#   PDS=https://pds.aerox.sola.town HANDLE=alice.aerox.sola.town PASSWORD=… bench/baseline.sh
set -euo pipefail
: "${PDS:?}" "${HANDLE:?}" "${PASSWORD:?}"
dur="${DURATION:-15s}"; conc="${CONCURRENCY:-32}"
session="$(curl -sS "$PDS/xrpc/com.atproto.server.createSession" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$HANDLE\",\"password\":\"$PASSWORD\"}")"
jwt="$(echo "$session" | jq -r .accessJwt)"; did="$(echo "$session" | jq -r .did)"

run() { # name, extra oha args...
  local name="$1"; shift
  echo "== $name"
  oha --no-tui -z "$dur" -c "$conc" --latency-correction "$@" \
    | grep -E "Requests/sec|50.00%|99.00%|^\s+\[[0-9]+\]" | sed 's/^/   /'
}

rkey="$(curl -sS "$PDS/xrpc/com.atproto.repo.listRecords?repo=$did&collection=app.bsky.feed.post&limit=1" | jq -r '.records[0].uri' | awk -F/ '{print $NF}')"
run "getRecord (hot account)" "$PDS/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=$rkey"
run "describeServer" "$PDS/xrpc/com.atproto.server.describeServer"
run "getTimeline (proxied, service-JWT signing per request)" -H "authorization: Bearer $jwt" \
  "$PDS/xrpc/app.bsky.feed.getTimeline?limit=30"
run "getProfile (proxied)" -H "authorization: Bearer $jwt" "$PDS/xrpc/app.bsky.actor.getProfile?actor=$did"
run "createRecord (one hot account)" -m POST -H "authorization: Bearer $jwt" -H 'content-type: application/json' \
  -d "{\"repo\":\"$did\",\"collection\":\"app.bsky.feed.post\",\"record\":{\"\$type\":\"app.bsky.feed.post\",\"text\":\"bench\",\"createdAt\":\"$(date -u +%FT%TZ)\"}}" \
  "$PDS/xrpc/com.atproto.repo.createRecord"
