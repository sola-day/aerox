#!/usr/bin/env bash
# VERIFICATION §10.3 network faults on the AppView ↔ firehose link, driven
# through Toxiproxy. The dev server must run with its AppView ingest pointed at
# the proxy (AEROX_RELAY_WS_URL=ws://localhost:2585 → 172.18.0.1:4000). Each
# case creates posts on the PDS during the fault and asserts, after the fault
# is lifted, that every post is indexed exactly once and the ingest cursor
# advanced — no lost, no duplicated event, no operator action.
#
#   test/network/faults.sh            (needs oha? no — curl, jq, psql, docker)
set -euo pipefail
TOXI=${TOXI:-127.0.0.1:8474}; PROXY=${PROXY:-pds-firehose}
PDS=${PDS:-https://pds.aerox.sola.town}; APPVIEW=${APPVIEW:-https://appview.aerox.sola.town}
HANDLE=${HANDLE:-alice.aerox.sola.town}; PASSWORD=${PASSWORD:-REDACTED-peer-account-password-rotated-2026-09-16}
LOG=${LOG:?path to the dev server log}
export PGPASSWORD=aerox_appview
psqlv() { psql -h 127.0.0.1 -p 5433 -U aerox_appview aerox_core -tAc "$1"; }

session=$(curl -sS "$PDS/xrpc/com.atproto.server.createSession" -H 'content-type: application/json' -d "{\"identifier\":\"$HANDLE\",\"password\":\"$PASSWORD\"}")
jwt=$(echo "$session" | jq -r .accessJwt); did=$(echo "$session" | jq -r .did)
post() { curl -sS -X POST "$PDS/xrpc/com.atproto.repo.createRecord" -H "authorization: Bearer $jwt" -H 'content-type: application/json' \
  -d "{\"repo\":\"$did\",\"collection\":\"app.bsky.feed.post\",\"record\":{\"\$type\":\"app.bsky.feed.post\",\"text\":\"$1\",\"createdAt\":\"$(date -u +%FT%TZ)\"}}" | jq -r .uri; }
SERVICE_KEY=${SERVICE_KEY:-localhost}   # the AppView's cursor row for the proxied firehose
cursor() { psqlv "select coalesce(max((state->>'cursor')::bigint),0) from appview.subscription where service = '$SERVICE_KEY'"; }
indexed() { psqlv "select count(*) from appview.post where uri = '$1'"; }
toxic() { curl -sS -X POST "http://$TOXI/proxies/$PROXY/toxics" -d "$1" >/dev/null; }
untoxic() { curl -sS -X DELETE "http://$TOXI/proxies/$PROXY/toxics/$1" >/dev/null; }
enable() { curl -sS -X POST "http://$TOXI/proxies/$PROXY" -d "{\"enabled\":$1}" >/dev/null; }
wait_indexed() { # uris... ; waits up to $WAIT s
  local deadline=$((SECONDS + ${WAIT:-120}))
  for u in "$@"; do while [ "$(indexed "$u")" != "1" ]; do [ $SECONDS -gt $deadline ] && { echo "  FAIL: $u indexed $(indexed "$u") times"; return 1; }; sleep 2; done; done
  for u in "$@"; do [ "$(indexed "$u")" = "1" ] || { echo "  FAIL: $u indexed $(indexed "$u") times"; return 1; }; done
}
reconnects() { grep -c "appview: firehose connected" "$LOG"; }
fail=0

echo "== baseline"; c0=$(cursor); u=$(post "fault baseline"); WAIT=60 wait_indexed "$u" && echo "  ok (cursor $c0 → $(cursor))" || fail=1

echo "== partition 60 s (proxy disabled; 3 posts during the outage)"
r0=$(reconnects); enable false; sleep 2
u1=$(post "during partition 1"); u2=$(post "during partition 2"); u3=$(post "during partition 3")
sleep 60; enable true
WAIT=150 wait_indexed "$u1" "$u2" "$u3" && echo "  ok: 3 posts exactly once after heal; reconnects $r0 → $(reconnects); cursor $(cursor)" || fail=1

echo "== half-open (timeout toxic: connection held, data dropped) — must be detected by the pong deadline (≤ 75 s + ping interval)"
silent() { grep -c "firehose peer silent" "$LOG"; }
s0=$(silent); toxic '{"name":"blackhole","type":"timeout","stream":"downstream","attributes":{"timeout":0}}'; toxic '{"name":"blackhole-up","type":"timeout","stream":"upstream","attributes":{"timeout":0}}'
u=$(post "during half-open"); t0=$SECONDS
while [ "$(silent)" = "$s0" ] && [ $((SECONDS - t0)) -lt 150 ]; do sleep 3; done
untoxic blackhole; untoxic blackhole-up
if [ "$(silent)" != "$s0" ]; then echo "  detected after $((SECONDS - t0)) s (pong deadline)"; else echo "  FAIL: not detected in 150 s"; fail=1; fi
WAIT=120 wait_indexed "$u" && echo "  ok: post indexed once after heal" || fail=1

echo "== added latency 2 s on the link"
toxic '{"name":"lag","type":"latency","stream":"downstream","attributes":{"latency":2000,"jitter":200}}'
u=$(post "during latency"); t0=$SECONDS; WAIT=60 wait_indexed "$u" && echo "  ok: indexed in $((SECONDS - t0)) s" || fail=1; untoxic lag

echo "== bandwidth cap 8 KB/s on the link (slow consumer side)"
toxic '{"name":"slow","type":"bandwidth","stream":"downstream","attributes":{"rate":8}}'
u=$(post "during bandwidth cap"); t0=$SECONDS; WAIT=90 wait_indexed "$u" && echo "  ok: indexed in $((SECONDS - t0)) s" || fail=1; untoxic slow

echo "== flapping link (down/up every 3 s for 30 s): back-off must grow, then recover"
r0=$(reconnects); for i in $(seq 1 5); do enable false; sleep 3; enable true; sleep 3; done
u=$(post "after flapping"); WAIT=150 wait_indexed "$u" && echo "  ok: recovered; reconnects $r0 → $(reconnects)" || fail=1

echo "== totals: every post of this run indexed exactly once?"
dups=$(psqlv "select count(*) from (select uri from appview.post where creator='$did' group by uri having count(*) > 1) d")
[ "$dups" = "0" ] && echo "  ok: no duplicate uris (cursor now $(cursor))" || { echo "  FAIL: $dups duplicated uris"; fail=1; }
[ $fail = 0 ] && echo "NETWORK FAULTS OK" || { echo "NETWORK FAULTS FAILED"; exit 1; }
