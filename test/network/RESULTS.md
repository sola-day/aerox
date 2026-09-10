# Network faults (VERIFICATION §10.3) — run record

`test/network/faults.sh` against the dev stack with Toxiproxy 2.11 on the
AppView ↔ firehose link (`AEROX_RELAY_WS_URL=ws://localhost:2585`, proxied to
the PDS firehose). 2026-09-10, commit 1eb07d0 + the pong deadline.

| Fault | Expected (§10.3) | Observed |
|---|---|---|
| Partition 60 s | consumer backs off, reconnects with cursor, continuity | 3 posts made during the outage indexed exactly once after heal; one reconnect; cursor advanced |
| Half-open (data black-holed, connection held) | keepalive detects the dead peer within the configured interval | detected by the new pong deadline after 85–96 s (75 s deadline checked on the 30 s ping tick); reconnect from cursor; post indexed once |
| Added latency 2 s | still delivers within SLO | indexed 2 s after the write |
| Bandwidth cap 8 KB/s | only that link is slowed | indexed 2 s after the write |
| Flapping (down/up every 3 s, 30 s) | back-off grows, recovers | 5 reconnects, exponential back-off, recovered; post indexed once |
| Whole run | no lost / duplicated event | no duplicate post URIs |

What the run found: neither the AppView producer nor the Relay consumer
had a liveness deadline — they sent pings but never noticed missing pongs,
so a half-open link would have hung forever. Both now reconnect after 75 s
of silence (`@dead_after`).

Not covered here (needs the multi-container topology of §7.3): PDS↔PLC
DNS failure, TLS rotation on a peer, the Relay-side `OutdatedCursor`
beyond the retention window.
