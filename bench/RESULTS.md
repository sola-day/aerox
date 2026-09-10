# Load baselines (VERIFICATION §10.1)

Each row is `bench/baseline.sh` on the dev box (AWS, 4 vCPU, Postgres 18 in
Docker on the same host, Traefik in front terminating TLS, load generator
`oha` on the same box), 32 connections for 15 s, against the dev server
started with `AEROX_BENCH=1` (no code reloader, info logging, rate limits
off, its own `_build/bench`). A release build is re-measured when the first
release is cut. A release that regresses a p99 by more than 25 % against
the last row fails the checklist.

| Commit | Endpoint | req/s | p50 | p99 | Notes |
|---|---|---|---|---|---|
| f254186 | describeServer | 1347 | 21 ms | 64 ms | HTTP + Traefik floor: ~1.3k req/s on 4 vCPU |
| f254186 | getRecord (hot account) | 648 | 44 ms | 137 ms | one record read + CBOR→JSON |
| f254186 | getTimeline (proxied) | 43 | 662 ms | 2.02 s | see "timeline cost" |
| f254186 | getProfile (proxied) | 111 | 248 ms | 1.20 s | |
| f254186 | createRecord (one hot account, 32 writers) | 30 | 1.11 s | 1.63 s | fully serialised per repo (FIFO `Aerox.PDS.RepoLock`); ~33 ms per commit, no errors |

## What the first run found (fixed before these numbers)

- **Sequencer starvation.** Every write held a pool connection while waiting
  on the sequencer, whose flush then queued behind them: on a pool of 5, 32
  writers made every write time out (500). The sequencer now owns a
  one-connection pool (`Aerox.Sequencer`, dynamic repo) and never waits on
  request connections. Regression test in `test/pds/faults_test.exs`.
- **Hot-account writers exhausted the pool.** Writers to one repo waited on
  the `FOR UPDATE` row lock *inside* their transaction, holding a connection
  each. `Aerox.PDS.RepoLock` (FIFO, per node) is taken before the
  transaction, so waiters hold nothing. A first attempt with `:global.trans`
  gave a 7.6 s p99 from its random retry back-off; the FIFO lock gives 1.6 s
  at 32 writers, i.e. queueing delay only.
- **Rate limits.** Legitimately kicked in (429) once the reloader was out of
  the way; `config :aerox, Aerox.RateLimit, disabled: true` is the
  bench-only switch.

## Timeline cost (R2 check, DESIGN §10)

A single proxied `getTimeline` is ~70 ms end to end of which the PDS proxy
(service JWT signing + hop) is ~10 ms. The AppView itself runs **21
sequential queries** (feed page, posts, records, aggregates, viewer state,
labels, blocks/mutes/lists…) each 1–4 ms; the cost is round trips, not SQL
or CBOR. So the R2 trigger (pure-Elixir kernel crypto/CBOR) is *not* what
limits the read path; the lever is running independent hydration stages
concurrently (upstream's `Promise.all`), a scheduled AppView optimisation,
not a Rustler swap. Sequencer coalescing (10 ms) bounds a single hot repo
at ~100 commits/s by construction.

Follow-up (2026-09-10): independent hydration stages now run concurrently
(`Aerox.AppView.Hydration.parallel/2`): one timeline hydration went from
35 ms / 21 sequential queries to 22 ms measured in-process; the proxied
`getTimeline` single request stays ~85 ms end to end through Traefik and
the dev server. Re-measure under load with `bench/baseline.sh` on the next
bench-mode run.

Not yet measured (need a multi-host topology): relay fan-out to 1 000
subscribers, ingest events/s by partition, image CDN at the libvips bound.
