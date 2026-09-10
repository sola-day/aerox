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

## Multi-host rows (2026-09-10, commit 91aa4a2)

The three rows §10.1 asks for that a single box cannot answer honestly, taken
against the release candidate on the second host (`generic.dev`: 8 vCPU, 31 GB,
Postgres 18 in Docker on the same host, Traefik in front). The load generator is
the dev box, over the public internet, except where a row says loopback.

### Relay fan-out (`test/harness/fanout.mjs`)

A backlog of 609 firehose events replayed to N subscribers at once from cursor 0.
Every subscriber received every event in every run.

| Subscribers | Connect | Replay | Frames/s | MB/s |
|---|---|---|---|---|
| 1 | 0.8 s | 2.5 s | 244 | 0.6 |
| 100 | 2.2 s | 4.7 s | 13 080 | 32.7 |
| 1 000 | 20.1 s | 33.6 s | 18 113 | 45.3 |

At 1 000 subscribers the number is the *link*, not the relay: 45 MB/s is what
this pair of hosts sustains, and the receiving node process is the busier of the
two ends. Read the row as "1 000 subscribers replay a backlog without loss and
saturate the wire", not as the relay's ceiling.

**Memory per subscriber: ~17 KB.** 1 000 idle subscribers took the release from
141 MB to 158 MB total (processes 32 → 38 MB, binary 10 → 19 MB) and the process
count from 752 to 1 752 — one process per subscriber, exactly.

### AppView ingest by partition count (`INGEST_CONCURRENCY`)

A backlog of 2 689 relay events over 20 repos, replayed from scratch (the
`appview` schema is dropped between rows, so each run indexes everything).
Partitioning is by `hash(did)`, so the axis only means anything with many repos.

| Partitions | Replay | Events/s |
|---|---|---|
| 1 | 12.0 s | 224 |
| 2 | 12.0 s | 225 |
| 4 | 8.9 s | 302 |
| 8 | 6.0 s | 449 |
| 16 | 6.0 s | 448 |

Two partitions buy nothing and sixteen buy nothing over eight: the ceiling is
~450 events/s, about 2× the serial rate, and it is the database, not the
pipeline. Raising `POOL_SIZE` to 30 to test that made it *worse* (304 events/s
at 8 partitions, and a 53 s boot, then 181 events/s and a 190 s boot at 16):
five repos × 30 connections plus the sequencers and Oban exceeds Postgres's
default `max_connections`, so the extra pool is spent on connection attempts.
The same arithmetic bit the restore drill (docs/OPS.md §3). Pool 10 stands.

### Image CDN (`test/harness/image-upload.mjs`, loopback)

Measured on the CDN's own host against the loopback port. Over the WAN the row
measures the link instead: 64 cache hits/s from the dev box, p50 240 ms, against
1.1 ms per hit on the host.

Fixtures: 64 blurred-noise JPEGs, 2000×1500, ~125 KB each, referenced by posts
(an unreferenced blob is not served by `getBlob`, so the CDN's origin fetch
404s — worth knowing before pointing a load generator at it). 512 distinct
variants = 64 images × 4 presets × 2 formats, so a cold run is 512 origin
fetches and 512 resizes with no cache hit possible.

Cold, one pass over all 512 variants, client concurrency fixed at 32 so the only
thing varying is `IMAGE_CONCURRENCY` (the `Aerox.ImageServer.Semaphore` bound of
DESIGN §21.8):

| libvips slots | Images/s | p50 | p99 |
|---|---|---|---|
| 1 | 11.2 | 2.75 s | 23.9 s |
| 2 | 19.8 | 1.18 s | 20.1 s |
| 4 | 29.9 | 0.92 s | 10.4 s |
| 8 | 36.8 | 0.54 s | 12.1 s |
| 16 | 37.3 | 0.71 s | 7.5 s |

The bound is real and it is the CPU: throughput scales almost linearly to 8
slots on 8 vCPU and then stops, so ~215 ms of core time goes into fetching,
decoding, resizing and re-encoding one 2000×1500 image. Raising the semaphore
past the core count only moves latency around. **The default of 4 leaves about a
third of the machine unused** — `IMAGE_CONCURRENCY` should be set to the core
count on an image host.

Warm (every variant cached; 100 % hit ratio, 512 cache files for 512 variants):

| Client concurrency | Images/s | p50 | p99 |
|---|---|---|---|
| 8 | 9 862 | 0.70 ms | 1.77 ms |
| 32 | 13 878 | 2.08 ms | 5.75 ms |
| 64 | 15 398 | 4.03 ms | 9.88 ms |

A hit is a file read and a send: three orders of magnitude cheaper than a miss,
which is the whole argument for the cache. Measure warm throughput only after a
full cold pass has certainly covered every variant — `oha --urls-from-file` does
not guarantee one request per URL, and a warm run with a few misses left in it
reads as "warm throughput scales with the libvips bound", which is nonsense.

