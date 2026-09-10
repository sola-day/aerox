# aerox — Development plan

Companion to `DESIGN.md` (what and why), `VERIFICATION.md` (how we know it is right)
and `STRUCTURE.md` (where code goes, and which boundaries the layout enforces).
This document says **in what order we build it, how we work, and on what**. Drafted
2026-09-09.

---

## 1. Environment: one Ubuntu server with a public IP

Development, integration testing and the standing demo all run on a single Ubuntu
server with a public IPv4 address. The public IP is not a convenience; it is what makes
VERIFICATION §7.3 possible — real DNS, real TLS certificates, real WebSocket traffic
between hostnames, and upstream containers that can crawl us the way a stranger's relay
would.

### 1.1 Base system

| Item | Choice | Note |
|---|---|---|
| OS | Ubuntu 24.04 LTS | unattended security upgrades on |
| Elixir / OTP | Elixir 1.20.x on OTP 29, via `mise` (`.tool-versions` in the repo) | matches the versions the design was verified on; never the distro packages |
| Phoenix | 1.8.13 (`phx_new` archive pinned) | DESIGN §2 |
| Postgres | **18**, as a Docker container (`compose.yaml`) | published on `127.0.0.1:5433` only, to stay clear of the box's existing Postgres containers; two databases per environment (DESIGN §4.6) plus `_test` pairs, created by `docker/postgres/init/`. `pg_trgm` (DESIGN §15.8) enabled per database at init. **Note:** PG18+ images require the volume mounted at `/var/lib/postgresql`, not `.../data` |
| Postgres client | `postgresql-client-18` from the PGDG apt repository | on the host, for `psql`/`pg_dump` against the container and for the migration drills of §1.3; the distro ships 16, and a 16 client cannot dump an 18 server |
| Docker + compose | Postgres 18 and the upstream oracle containers | aerox itself runs on the host BEAM, not in Docker, during development; the Erlang/Elixir toolchain is installed on the host via `mise` |
| Reverse proxy | **Traefik v3** (`ginger-traefik`, already on the box) | not Caddy: :80/:443 are already held by a Traefik that fronts unrelated applications, with `letsencrypt` (HTTP-01) and `letsencrypt-dns` (DNS-01 via Cloudflare) resolvers configured. aerox reuses it; its routers live in `ops/traefik/` and are spliced in by `ops/traefik/install.sh` (§1.2) |
| Node.js | 24.21.0 via `mise` (pinned in `.tool-versions`) | for `ouranos`, `bulletin`, the `@atproto/api` test harness and golden generators |
| Go | 1.27.1 via `mise` (pinned in `.tool-versions`) | for indigo-based golden generators and `goat` |
| Process supervision (demo) | systemd units running `mix release` output | the dev loop uses `mix phx.server` in tmux; the standing demo is a release |
| Observability | LiveDashboard (dev), `recon` in releases, journald | production telemetry export is an open item (DESIGN §10) |

### 1.2 Hostnames

One base domain for the server (call it `<dev-domain>`); every service gets a subdomain
so that service DIDs (`did:web`), handle domains and OAuth `client_id` URLs are real:

```
pds.<dev-domain>         aerox PDS            (handle domain: *.<dev-domain>)
plc.<dev-domain>         aerox PLC directory
relay.<dev-domain>       aerox Relay
appview.<dev-domain>     aerox AppView (+ /img image CDN)
labeler.<dev-domain>     aerox Labeler
ouranos.<dev-domain>     ouranos, pointed at pds.<dev-domain>
bulletin.<dev-domain>    bulletin, OAuth client_id = https://bulletin.<dev-domain>/oauth-client-metadata.json

ref-pds.<dev-domain>     upstream reference PDS      ┐
ref-relay.<dev-domain>   indigo relay                │ Docker, for VERIFICATION §7
ref-appview.<dev-domain> bsky-standalone AppView     │
ref-plc.<dev-domain>     did-method-plc              │
spaces.<dev-domain>      pds-spaces-alpha image      ┘
```

A wildcard DNS record `*.<dev-domain>` → the server, plus `_atproto.<handle>` TXT
records for the handle-resolution tests. Certificates come from Let's Encrypt; the
handle wildcard must go through DNS-01, because HTTP-01 cannot answer a wildcard
challenge at all, and DNS-01 does not require the PDS to be reachable — only the
DNS API.

**Resolved on this box (2026-09-09).** `<dev-domain>` is **`aerox.sola.town`**, not
the `sola.town` apex: the apex already carries other applications, and a handle
catch-all there would race their routers. Everything aerox therefore sits one label
deeper — `pds.aerox.sola.town`, `plc.aerox.sola.town`, … and handles at
`alice.aerox.sola.town`.

* **DNS.** `sola.town` is on Cloudflare (`corey`/`teresa` nameservers) with just two
  records, `sola.town` and `*.sola.town`, both A to the host and unproxied. No new
  record is needed for the aerox subtree: RFC 4592 wildcard synthesis makes
  `*.sola.town` answer at *any* depth below it, and `alice.aerox.sola.town` already
  resolves — verified, not assumed. The one-label limit is a property of TLS
  wildcards, not of DNS wildcards, and conflating the two is the usual mistake here.
* **DNS API.** The Cloudflare token in `/opt/traefik/dns01.env` was verified against
  the live API to create, update and delete records in the `sola.town` zone (a probe
  TXT record was written and removed). That is enough for both DNS-01 and the
  `_atproto.<handle>` TXT records the handle-resolution tests need.
* **Proxy.** Not Caddy: the box already runs Traefik v3.7.7 (`ginger-traefik`) on
  :80/:443 in front of unrelated applications, with two ACME resolvers configured —
  `letsencrypt` (HTTP-01) and `letsencrypt-dns` (DNS-01 via Cloudflare). aerox reuses
  it rather than contending for the ports.
* **Certificate.** A `sola.town` + `*.sola.town` wildcard already existed; it does
  **not** cover `alice.aerox.sola.town`, one label too deep. A second certificate,
  `aerox.sola.town` + `*.aerox.sola.town`, was obtained via DNS-01 on 2026-09-09 and
  covers every aerox service name and every handle.
* **Routing.** `ops/traefik/aerox.dynamic.yml` holds aerox's routers and is spliced
  into Traefik's hand-maintained `dynamic.yml` by `ops/traefik/install.sh` — the
  shared Traefik uses `--providers.file.filename`, a single file, so aerox cannot
  drop in a file of its own. The splice is delimited, idempotent and backed up on
  every write; the file provider hot-reloads, so no container is restarted.
* **Upstream.** Traefik forwards to the Phoenix dev server on the host at
  `172.18.0.1:4000`, the `multica` bridge gateway. The box has **no host firewall**
  (`ufw` inactive, `iptables -P INPUT ACCEPT`), so binding the dev server to
  `0.0.0.0` would publish it on the public interface; the bridge address is reachable
  from the Traefik container and nowhere else. `AEROX_BIND_IP` and `PHX_HOST` in
  `.envrc` carry this, and both default to loopback so a plain checkout stays local.
* **Verified end to end.** `https://pds.aerox.sola.town/` and
  `https://alice.aerox.sola.town/` both return 200 with a valid chain, a WebSocket
  upgrade returns `101` (the firehose depends on it), and the pre-existing
  applications on `sola.town` were re-checked afterwards and are unaffected.

Two environments coexist on the box, distinguished by port ranges and database
names: **`dev`** (the loop you are typing in) and **`demo`** (a release, restarted on
merge to `main`, what `ouranos`/`bulletin` point at by default).

### 1.3 Security posture of a public dev box

The server is exposed and will hold real-looking data during migration drills. Rules:

- `ufw`: inbound 22, 80, 443 only. Postgres, Erlang distribution, Docker-published
  ports and every aerox port are loopback-only; Caddy is the only listener on 443.
- SSH keys only, `PermitRootLogin no`, `fail2ban` on sshd. Use **SSH connection
  multiplexing** (`ControlMaster auto`, `ControlPersist 10m`) from every workstation —
  OpenSSH's per-source-IP penalty has already broken parallel builds once; fix it in
  `~/.ssh/config`, do not disable the penalty on the server.
- Secrets live in `/etc/aerox/<env>.env` (`0600`, owned by the service user), loaded by
  systemd; never in the repo, never in shell history.
- **The production PLC rotation key never touches this server.** Nor does any
  production secret. The migration drill (VERIFICATION §10.4) runs against a snapshot
  whose rotation key has been *replaced* by a dev key at snapshot-preparation time, and
  the dev PLC is a separate directory; the tool never submits PLC ops anyway (DESIGN §13.5).
- Production snapshots contain real users' emails and password hashes. They are copied
  to the server **encrypted**, decrypted only into the drill's working directory, and
  that directory is wiped when the drill ends. A drill is logged like an infra change.
- Erlang distribution is not enabled (DESIGN §21.10): no cookie to leak, no epmd exposed.
- Every infrastructure change to the box is logged in an ops changelog in the deploy
  repository, per the existing house rule.

### 1.4 Repository and CI on the same box

- Git hosting: GitHub (the existing organisation). Trunk-based: short-lived branches,
  PRs into `main`, squash merges, conventional commit messages.
- **CI runs on the server itself** as a self-hosted GitHub Actions runner. The interop
  and network stages need Postgres, Docker and real hostnames — exactly what this box
  has and hosted runners do not. The runner user is separate from the service user.
- CI databases (`aerox_pds_test`, `aerox_core_test`) are created once; the test helper
  refuses to start if either is missing (VERIFICATION §11).
- `npm` installs for `ouranos`/`bulletin`/harness: if the box sits behind a registry
  mirror that is unreachable, use `--replace-registry-host=always` — a known trap.

---

## 2. How we work

### 2.1 Documents are upstream of code

- A kernel-level or cross-service decision is written into `DESIGN.md` (with a decision
  log row) **before** the code that depends on it. If implementation reveals the
  design was wrong, the doc changes first, in the same PR.
- Every PR names the VERIFICATION items it satisfies or adds. A PR that adds a route
  adds the row in `test/parity/ENDPOINTS.md` (VERIFICATION §7.1).
- Golden files change only through the generators, with the manifest updated and a
  reviewer who checks the upstream commit the change follows (VERIFICATION §2.2).

### 2.2 The loop

1. Branch from `main`; write or update the tests for the layer you are in (kernel
   layers: goldens and properties first, then code).
2. `mix test` locally on the box against the sandboxed `_test` databases; `mix format`,
   `credo`, `dialyzer` (cached PLT) before pushing.
3. PR → CI **fast** and **services** stages must pass; **integration** runs on PRs to
   `main`; **interop** and **network** run nightly and on release branches.
4. Review focuses on the boundary rules: kernel does no I/O, services do not share a
   database, every account-scoped query is `did`-prefixed, no process where a function
   or ETS will do (DESIGN §21).
5. Merge → the `demo` release is rebuilt and restarted by CI; `ouranos` and `bulletin`
   point at it, so the standing environment always reflects `main`.

### 2.3 Cadence and hygiene

- Nightly: interop + network stages; a failing nightly is the first item the next day.
- Weekly: golden-provenance check (upstream drift), dependency updates, a look at
  LiveDashboard on `demo` for growth in mailbox sizes, ETS tables, DB pool waits.
- Per milestone: the definition-of-done checklist in VERIFICATION §12, a written
  retrospective appended to this file (§5), and re-baselining of any benchmarks.
- Data on `demo` is throwaway and is reset whenever a migration requires it; nobody
  treats it as durable.

### 2.4 Working with the reference implementations

`../../bsky/` is the reading room, not a dependency: `atproto/` (TS), `indigo/` (Go),
`did-method-plc/`, `bulletin/`, and the alpha `permissioned-data` branch. When a
behaviour question arises, the answer is looked up there and the file and commit are
cited in the DESIGN or in a code comment. Golden generators live in `tools/golden/`
and run inside the pinned upstream containers so results do not depend on local
toolchains.

---

## 3. Milestones

Order follows DESIGN §9 (falsifiability first); exit criteria are VERIFICATION §12's
definitions of done, restated with the concrete deliverables. Sizes are relative
(S < M < L < XL) for one engineer working with an AI pair; no calendar dates are
promised, and the order is more important than the durations.

### M0 — Foundation (S)

Deliverables: repository, `mix phx.new aerox --no-assets --no-live`, the two-database
Ecto setup and sandbox, `MIX_ENV=tool` profile, CI fast stage on the self-hosted
runner, Traefik routing + DNS for the hostnames in §1.2, `mise` toolchain, LiveDashboard
reachable on `dev`. The golden corpus directory with `MANIFEST.json` and the
provenance check. The Node harness skeleton with `@atproto/api`.

Exit: a green empty CI run; `https://pds.<dev-domain>/` answers from the dev stack.

### M1 — Kernel (L)

`Aerox.ATProto.{Syntax, Bytes, CID, DagCBOR, Data, Blockstore, MST, CAR, Crypto, Repo, Identity(parse), Lexicon}`
in the order Syntax → DagCBOR/CID → Data → MST read-only → CAR → MST write/diff →
Crypto → Repo (produce + verify) → Lexicon interpreter with the `com.atproto.*`
registry. Goldens generated for each as it lands; property suites from DESIGN §21.11.

Exit: VERIFICATION §12 "Kernel" — all L0–L4 suites green with committed manifests; a
real CAR exported from the reference PDS loads and its root recomputes; strict-decoder
mutations rejected. **No service code has been written yet.**

### M2 — PLC directory (M)

`Aerox.PLC`: operation validation, log, audit, `/export`, priority/72-hour rules,
`removeInvalidOps` audited. `Aerox.Identity` resolver with the two-layer cache.

Exit: official `did-method-plc` vectors green; interop row "PLC" (our directory ↔
reference directory) green over real hostnames.

### M3 — PDS core (XL)

Accounts and lifecycle (DESIGN §18.3), scrypt-compatible passwords, legacy sessions,
record CRUD and `applyWrites`, per-account row-lock serialisation, sequencer with
coalescing, firehose `subscribeRepos` with cursor replay, blob upload with the Disk
adapter and reaper, `Aerox.Identity` on the PDS, email (Swoosh, five purposes), rate
limits (Hammer), admin API subset, `describeServer` and the `.well-known` routes.
Oban wired in. Instance PLC rotation key behind the `Signer` behaviour (`Local` in dev).

Exit: §5 PDS tests; §6 scenarios 1–2; interop rows "indigo relay accepts our PDS" and
"`@atproto/api` client" green; `ouranos` can log in against `pds.<dev-domain>` (it
will not see a timeline yet — that needs M6).

### M4 — OAuth (L)

Authorization server per DESIGN §11.2: PAR, PKCE, DPoP with nonces, client-metadata
documents, confidential clients, consent pages on the `:browser` pipeline, scope
grammar and `Aerox.Auth.Scopes` including `include:` and `space:`. Service-JWT issuing
(`getServiceAuth`) and the shared verifier (DESIGN §20.2).

Exit: §6 scenario 6; a confidential and a public test client complete the flow;
`bulletin`'s login step succeeds (its data steps wait for M8).

### M5 — Bundle and migration tooling (M)

`Aerox.Interop.Bundle.{Postgres, ReferencePds}`, `mix aerox.bundle.*` and
`mix aerox.interop.*`, `state.json`, manifest hashing, progress table, verification
report, the bundle-encryption decision (DESIGN §13.0 Option A/B) made and implemented.

Exit: VERIFICATION §8 round-trips green, including boot-the-stock-image; the migration
drill (§10.4) executed once against a prepared snapshot on this server, with its
reconciliation report archived.

### M6 — Relay (M)

Per-host consumers, inductive verification, re-sequencing, retention window,
`requestCrawl`/`listHosts`/`getHostStatus`/`listRepos`/`getRepoStatus`, slow-subscriber
protection, host limits.

Exit: §5 Relay tests; interop row "Reference PDS" (we ingest it) green; the network
suite's "being crawled / crawling / cursor durability" rows green across restarts.

### M7 — AppView and image CDN (XL)

Broadway ingest with persisted cursor and backfill; the 19 plugins; hydration and
views; timeline / author feed / thread / likes / quotes / custom feeds via feedgen;
notifications (no push delivery); label consumption; private state write path;
Postgres search with the CJK trigram path; `Aerox.ImageServer` with `vix`.

Exit: §6 scenarios 1–5; interop row "bsky AppView" parity on counts; **`ouranos`
renders a timeline with images against the demo environment** — the first
end-to-end milestone a user can see. Endpoint parity table populated for every route.

### M8 — Labeler and moderation backend (M)

Labeler service (an account on our PDS), signed labels, `subscribeLabels`, report
intake, `mod_event` log, `Actions` behaviour, takedown propagation to PDS/AppView/CDN,
minimal admin API. Ozone compatibility deferred.

Exit: §6 scenario 7.

### M9 — Spaces (L, alpha-tracking)

Kernel additions (`LtHash`, `SpaceCommit`, `OpLog`, two-root CAR) golden-tested against
the alpha image first; then the three roles' endpoints, `simplespace`, the three JWTs
over the shared DPoP verifier, Oban-driven sync and `notifyWrite`. Behind a feature flag.

Exit: §6 scenario 9 — `bulletin` works end to end against `pds.<dev-domain>`.

### M10 — Hardening and release readiness (M)

Load baselines (VERIFICATION §10.1), process and network fault injection (§10.2–§10.3),
restore drill, rotation-key drill, the `Kms`/`Remote` signer implementations, production
release packaging (systemd units or the existing `ginger` flow), telemetry export
decision.

Exit: VERIFICATION §12 "Release (any)" satisfied; a release candidate deployed to a
second, clean host from the documented procedure.

### Parallelism

Strictly sequential: M0 → M1 → M2 → M3. After M3, two tracks can proceed in parallel:
**M4 → M5** (auth and portability, mostly PDS-internal) and **M6 → M7** (the read
path). M8 needs M7; M9 needs M4 and M7 (for `bulletin`'s `getRelationships`); M10 needs
everything. With one engineer the recommended order is M4, M6, M7, M5, M8, M9, M10 —
`ouranos` rendering (M7) is the earliest visible proof and should not wait behind M5.

---

## 4. Risk buffers and stop conditions

| Risk (DESIGN §10) | Where it is retired | Stop condition if it is not |
|---|---|---|
| R1 DAG-CBOR not bit-exact | M1 exit | M2 does not start until every L1 golden is green |
| R2 pure-Elixir performance | first measured at M3 (service-JWT signing) and M7 (ingest) | if p99 targets are missed by more than 3×, schedule the Rustler swap for DAG-CBOR (DESIGN §3.9) as its own milestone before M10 |
| R3 sequencer across nodes | not needed before a multi-node PDS; decided at M10 at the latest | no second PDS node before the decision |
| R7 Spaces wire format changes | M9 is flagged and isolated | a breaking alpha change re-runs M9's golden generation; public path unaffected |
| R10 OAuth underestimated | M4 is sized L on purpose | if M4 overruns, `ouranos` (legacy sessions) still proceeds; only `bulletin` waits |

---

## 5. Milestone retrospectives

Appended as each milestone closes: what the definition of done actually took, what
the design got wrong, which VERIFICATION items were added, and any decision-log rows
written during the milestone.

### M0 — Foundation (closed 2026-09-09)

- **What done took.** Two databases and four repos with per-service Postgres
  roles (the REVOKE matrix is a runtime test, `test/aerox/repo_boundary_test.exs`),
  `boundary` on every band with the kernel at `deps: []`, the `tool` env and
  `lib_tool/`, the golden corpus (120 files, all with provenance) and
  `mix aerox.golden.verify`, the Node harness skeleton, the CI workflow, and the
  dev domain `aerox.sola.town` behind the box's Traefik with a DNS-01 wildcard.
- **What the design got wrong.** §1.1 named Caddy; the box already runs Traefik on
  :80/:443, so aerox splices its routers into it (`ops/traefik/`). STRUCTURE §10's
  Ecto question resolved the other way than planned: `migration_default_prefix`
  does not place `schema_migrations`, which follows `search_path`, so the
  per-service schema must pre-exist (created by the bootstrap script, re-asserted
  by each repo's first migration).
- **Decision-log rows.** None new; the §4.6 rows were applied as written.

### M1 — Kernel (closed 2026-09-09)

- **What done took.** Syntax, Bytes, CID, DagCBOR, Data, Blockstore (Memory,
  Layered), MST (with covering proofs and the structural verifier), CAR, TID,
  Crypto (K256 via NIF, P-256 via OTP), Identity parse, Repo (format and verify,
  inductive check), Frame, and the lexicon interpreter over 131 vendored
  documents. Every L0–L4 golden is green: 16 syntax files, 43 generated DAG-CBOR
  vectors, indigo's data-model and lexicon verdicts, the MST interop roots and
  commit-proof inversions in every permutation, the crypto fixtures including
  the high-S and DER negatives, and a real reference-PDS CAR whose root recomputes.
- **What the design got wrong.** §3.5's "MST over an explicit Blockstore" is right
  but the walker-based diff has to start on the root *node* (upstream's
  `MstWalker`), not on its first entry — the round-trip test caught the missing
  root block. §6.6 anticipated `type: "space"`; the vendored branch also carries
  a `space-uri` string format, added to `Syntax`. The kernel is process-free, so
  TID monotonicity is a pure `next/3` and the clock lives in the PDS (§3.7).
- **VERIFICATION items added.** The real-CAR exit test (`Aerox.ATProto.RealCarTest`)
  with the account's PLC document in the corpus; twelve hand-written non-canonical
  DAG-CBOR mutations (§3.3).

### M2 — PLC directory (closed 2026-09-09)

- **What done took.** `Aerox.PLC.Operations` (all twenty did-method-plc audit-log
  vectors, replayed through the admission rule with nullification flags compared),
  `Aerox.PLC.Directory` over the `plc` schema with the per-DID row lock, rate
  limits, both export cursors and the audited `removeInvalidOps`; the REST
  surface route for route with the reference server; `Aerox.Identity` (hardened
  HTTP, DNS behaviour, resolver, two-layer single-flight cache per service); and
  the interop row "PLC": the reference directory (`ref-plc.aerox.sola.town`, built
  from the reading-room checkout, `tools/interop/compose.yaml`) accepts operations
  we sign, we accept its, both answer identically, and our resolver resolves
  through either over real TLS (`test/interop/plc_interop_test.exs`, `--only interop`).
- **What the design got wrong.** §14.2 point 5 places the single `Signer.sign`
  call site in `Aerox.PLC.Ops`, but STRUCTURE §6 forbids the PDS from depending on
  `Aerox.PLC`; the signing call site and `plc_op_audit` therefore belong to the PDS
  (M3), and the directory has no signing path at all. The reference server's
  `seq` export cursor is a Postgres sequence assigned at insert, so it carries the
  §5.3 caveat; it is kept only because the reference has the same behaviour.
- **VERIFICATION items added.** `validate_audit_log` (full replay with timestamps)
  beyond upstream's timestamp-free `validateOperationLog`; the `:interop` tag,
  excluded by default.

### M3 — PDS core (closed 2026-09-09, two rows carried)

- **What done took.** Everything in the milestone text: `Aerox.PDS.Records` with
  the per-account `repo_root FOR UPDATE` write path and three-state validation,
  the coalescing sequencer with its own connection, `Accounts`/`Sessions`
  (scrypt vectors from Node, HS256 `at+jwt`/`refresh+jwt` with rotation grace),
  the signup saga with `PlcOps` as the only `Signer.sign` call site and the
  `plc_op_audit` count invariant, blobs with the Disk adapter and reaper, five
  email purposes over Oban, Hammer rate limits, and the whole XRPC surface —
  64 routes over `server`, `identity`, `repo`, `sync`, the admin subset,
  `app.bsky.actor.*Preferences`, the `.well-known` pair, and `subscribeRepos`
  as a raw WebSock handler with cursor replay, `FutureCursor`, `OutdatedCursor`
  and the slow-consumer close. `test/parity/ENDPOINTS.md` is generated from the
  router and a router test keeps them equal. The Node harness
  (`test/harness/smoke.mjs`, `@atproto/api` 0.18) creates an account, logs in,
  posts, reads, fetches preferences and the repo CAR, and reads its own commit
  off the firehose over TLS through Traefik: the "`@atproto/api` client" row.
- **What the design got wrong.** Two things. (1) Lexicon vendoring "per
  endpoint" (DESIGN §6.6) does not survive contact with record validation: a
  PDS must know `app.bsky.feed.post` to say `valid`, and knowing it means
  knowing everything it references, so the whole `app.bsky` and `chat.bsky`
  trees are vendored at once (336 documents) and the per-endpoint rule now
  applies to *implementing*, not vendoring. A side effect worth knowing: once
  a record lexicon is present its key rule applies, so `app.bsky.feed.post`
  keys must be TIDs. (2) Token errors: upstream answers a bad or expired access
  token with **400** `InvalidToken`/`ExpiredToken` (an `InvalidRequestError`),
  not 401; only `AuthMissing` and the service-JWT family are 401. The auth plug
  follows upstream, and this is now an error-parity row (VERIFICATION §7.1
  item 5).
- **Carried into M6/M7.** The interop row "indigo relay accepts our PDS" needs
  the reference relay container, which M6 brings up anyway; it is scheduled
  there rather than built twice. `ouranos` can log in against
  `pds.aerox.sola.town` only through the PDS's `app.bsky.*` proxy, because the
  client sets no `atproto-proxy` header and calls everything on its service
  URL; the proxy is M7's first deliverable and the login row closes with it.
- **VERIFICATION items added.** The HTTP flow test (`test/aerox_web/pds/pds_flow_test.exs`)
  verifies the exported CAR against the signing key from the DID document, and
  checks the creation event order `#identity, #account, #commit, #sync`.

### M6 — Relay (closed 2026-09-09)

- **What done took.** `Aerox.Sequencer` (the PDS's coalescing single writer,
  extracted so the Relay re-sequences on its own `relay.repo_seq` with its own
  topic), the firehose socket generalised over a `Source`, and the Relay
  itself as indigo's relay in Elixir: `Hosts` (hostname rules, new-host
  defaults, trusted domains, per-day admission, domain bans, error counting
  with a pause threshold), `Accounts` (DID-document host binding with one
  re-resolve, host-throttled status past the account limit, upstream status
  re-checked against the PDS's `getRepoStatus`), `Ingest` (strict commit
  verification with lenient mode, `#sync` signature checks, `#identity`
  handle validation, `#account` status recording), one `Consumer` GenServer
  per host over Mint.WebSocket with cursor persistence, back-off, keepalive
  pings and offline/idle/throttled transitions, and the sync API dispatched by
  hostname (`AeroxWeb.Dispatch`) route for route with `handlers.go`, including
  the non-archival answers. Interop: the indigo relay (built from the reading
  room, `ref-relay.aerox.sola.town`) crawls our PDS over TLS and lists our
  commits; our Relay crawls the reference PDS (`ghcr.io/bluesky-social/pds:0.4`
  at `ref-pds.aerox.sola.town`) and lists its commits
  (`test/interop/relay_interop_test.exs`). The M3-carried row "indigo relay
  accepts our PDS" closes here.
- **What the design got wrong.** Nothing structural; two operational facts
  were missing. (1) A firehose connection is idle for hours between events:
  Bandit's default 60 s WebSocket idle timeout closed every relay with 1002,
  so the socket's timeout is a day and the consumer pings every 30 s. (2) A
  relay connects *without* a cursor on first subscription (indigo too), so
  nothing flows until the host's next event; "no events yet" is not a
  failure, and `listHosts` hides hosts until their first event. (3) Every
  service must resolve `did:plc` through *our* directory — `config :aerox,
  :plc_url` — or the Relay rejects every commit with `identity not_found`
  while the reference relay, configured correctly, accepts them.
- **VERIFICATION items added.** The consumer test's fake host (Bandit
  in-process) honours the cursor, so "reconnect with cursor yields no gap and
  no duplicate" is asserted on seq continuity, not assumed.

### M7 — AppView and image CDN (closed 2026-09-09; parity rows open)

- **What done took.** The `appview` schema mirroring upstream's bsky tables,
  `Aerox.AppView.Indexing` (RecordProcessor semantics: generic `record`
  row, plugin dispatch, duplicates, notifications in the index transaction,
  promotion on delete) and all nineteen plugins with upstream's aggregates,
  reply/thread-gate/embedding validation and notification reasons; the
  Broadway ingest off our Relay (Mint.WebSocket producer with an acked-cursor
  persisted to `subscription`, disconnect-on-high-water back-pressure,
  `partition_by hash(did)`); Oban backfill via `getRepo` on first sight; the
  hydration/views layers; and the read path — feeds, threads, profiles,
  graph, search (pg_trgm substring, CJK included), notifications, labeler
  services, mutes — every response validated against the vendored lexicon in
  tests. `Aerox.ImageServer` (vix/libvips) serves upstream's URL shape under
  `/img` on the AppView host. The PDS proxies `app.bsky.*` to it with
  service JWTs; browser clients need CORS, which upstream has and we lacked.
  `test/harness/ouranos.mjs` drives the real ouranos build in headless
  Chromium: login, home timeline, a post with an image from the CDN — the
  milestone's exit criterion, green.
- **What the design got wrong.** (1) The AppView must subscribe *with a
  cursor* from the start: a live-only tail never sees repos that already
  exist, and `cursor=0` is exactly "everything you retain" (OutdatedCursor
  + replay). (2) Upstream's `getTimeline` has no server-side reply filter;
  §15.4's filter is implemented anyway as one query. (3) `TimeCidKeyset`
  cursors are millisecond-precision while our `sort_at` is microsecond:
  the keyset compares on `date_trunc('milliseconds', …)`. (4) Clients send
  `cursor=` (empty) for the first page; an empty cursor is no cursor, not
  a "clearly bad" one. (5) Two `mix test` runs against one test database
  race the PDS sequencer (`repo_seq_pkey` duplicates): the unboxed insert
  path is single-writer per VM, not per database — never run the suite
  twice concurrently.
- **Carried.** VERIFICATION §7.1 parity diffs against the reference
  AppView (`bsky-standalone`) are not yet run: the reference AppView
  container is not up. The `ENDPOINTS.md` rows for the AppView stay
  `pending` until they are. Feed generators receive a JWT signed by the
  AppView's own key (`iss` = our service DID) rather than upstream's
  pass-through of the PDS-minted viewer JWT.

### M4 — OAuth (closed 2026-09-09)

- **What done took.** `Aerox.Auth.Scopes` (the whole `oauth-scopes`
  grammar incl. `include:` expansion against the vendored permission sets
  and the permissioned-data branch's `space:` scope, upstream vectors
  transcribed), `Aerox.Auth.DPoP` (the one verifier OAuth and Spaces share:
  rotating HMAC nonces, `htm`/`htu`/`ath`/`jti`, jkt thumbprints), and the
  authorization server in the PDS: `Clients` (loopback and discoverable
  client-metadata documents validated rule for rule, `none` and
  `private_key_jwt`), `Requests` (PAR, five-minute expiry, inactivity
  timeout, device binding, single-use codes), `Tokens` (ES256 `at+jwt`
  bound to `cnf.jkt`, refresh rotation with replay revocation, upstream's
  session/refresh lifetimes), the metadata documents, `/oauth/{par,token,
  revoke,jwks,authorize}` with the consent pages on the `:browser`
  pipeline, and the Auth plug's OAuth path with `DPoP-Nonce` on every
  response. Granular scopes are enforced where they bite: repo writes,
  blob uploads, the `app.bsky.*` proxy (`rpc`), `updateHandle`, and the
  email on `getSession`. Interop: `@atproto/oauth-client-node` 0.5.4 as a
  loopback client runs the full flow through our consent page in headless
  Chromium and then calls XRPC through the DPoP session
  (`test/harness/oauth.mjs`) — the "@atproto/api logs in (OAuth)" row.
- **What the design got wrong.** Nothing structural. Two upstream
  behaviours worth recording: a replayed authorization code revokes the
  tokens it produced (so a client that double-submits loses its session, by
  design), and the first proof of every exchange is refused with
  `use_dpop_nonce` — clients must expect a 400/401 round trip before the
  real one. Access tokens are verified statefully (the token row must still
  exist) rather than upstream's stateless mode, so revocation is immediate.
- **Carried.** `bulletin`'s login (its data steps wait for M8/M9) is not
  yet exercised; JAR (`request` objects) is not supported (metadata says so).

### M8 — Labeler and moderation backend (closed 2026-09-09)

- **What done took.** A labeler that is an ordinary account on our PDS
  (`mix aerox.labeler.setup` creates it, publishes `#atproto_labeler` and
  the label key in its DID document, and persists `did`/key in
  `labeler.setting`), signed labels with their own sequencer feeding
  `subscribeLabels`, `queryLabels`, report intake with the reporter's
  service JWT, an append-only `mod_event` log with the `Actions` behaviour
  (`Actions.Default`: label, takedown, acknowledge; replayable through
  `applied_at`), takedown propagation to the PDS through its admin API and
  in-node to the AppView, and the minimal admin API under our own
  `aerox.moderation.*` lexicons. The AppView subscribes to the configured
  labelers and applies their labels by default (DESIGN §15.6); the PDS
  proxies `createReport` to `mod_service`. Verified end to end on the dev
  stack: the labeler's DID document resolves, `queryLabels` answers on
  `labeler.<dev-domain>`.
- **What the design got wrong.** §17's separate labeler signing key: the
  PDS verifies the labeler's service JWTs against the DID document's
  `#atproto` key, so the label key *is* the account's repo signing key
  (ozone does the same). Labels are upserted per `(src, uri, cid, val)`
  (ozone's `createLabels` semantics) rather than one row per emission.
- **Carried.** Moderator e-mail notices; a remote AppView learns takedowns
  only from `#account`; Ozone compatibility, as planned.

### M9 — Spaces (closed 2026-09-09, alpha-tracking)

- **What done took.** The finding that drove everything: `bulletin` pins
  the *published* alpha package (`@atproto/space@0.0.0-spaces-alpha-20260818163953`),
  and that package differs from the `permissioned-data` branch in four
  wire-level ways — JWT model (delegation / credential / client-attestation,
  exactly DESIGN §12.4), set-hash element (`collection/rkey/cid`), the
  signed commit (`atproto-space-v1` context, HKDF-Expand, `ver: 1`) and
  canonical CAR block order, plus `at://did/space/type/skey` URIs. The
  goldens were regenerated from the real package
  (`test/golden/space/alpha.json`: our CAR export is byte-identical to
  `serializeRepo`, MACs and signatures cross-verify). Then the PDS side:
  space tables keyed by `did`, `Spaces`/`Records`/`Credentials`/`Policy`/
  `Notify`, 25 `com.atproto.space.*`/`simplespace.*` routes behind
  `enabled: true`, `space:` scopes enforced, DPoP-bound credentials over
  the shared verifier, Oban fan-out for `notifyWrite`, and scenario 9 as a
  flow test.
- **What the design got wrong.** The design (and the kernel's first
  `Commit`) followed the branch; the alpha is the oracle. §12.5's
  `checkUserAccess` is served by the managing app, not the PDS (the PDS
  calls it). Branch-only `notifyMembership` does not exist in the alpha.
- **Carried.** `bulletin` end to end (needs the Next.js app on a loopback
  origin with its `did:web:localhost%3A3000` resolvable by our PDS and
  `getRelationships` on the AppView); DPoP nonces are not required on
  space-credential proofs because the alpha client sends none.

### M5 — Bundle and migration tooling (closed 2026-09-09)

- **What done took.** Bundle format v1 (`docs/BUNDLE.md`) with the
  encryption decision made as **Option A**: one content key per bundle
  wrapped per recipient (`ECDH-ES+A256KW` to P-256/X25519, or
  `PBES2-HS512+A256KW` for an operator passphrase), AES-256-GCM chunked
  file bodies with path-bound AAD, and the manifest as an ES256K JWS by the
  instance signer (works with the KMS/Remote signers). `Bundle.Postgres`
  in both directions with `interop_progress`, `Verify` for the §13.3
  report, `mix aerox.bundle.{export,import}`, and in `lib_tool/` the
  reference-PDS 0.4 SQLite adapter with `aerox.interop.{from_pds,to_pds}`.
  The round trip was proven the hard way: fixture → bundle → data dir →
  the stock `ghcr.io/bluesky-social/pds:0.4` image boots on it, serves the
  same repo root and block set, and `createSession` succeeds.
- **What the design got wrong.** `state.json` needs a per-block `rev` map
  (not in the CAR) to reproduce `repo_block` rows byte for byte. `pds:0.4`
  actually ships `@atproto/pds` 0.5.27; the adapter is pinned to that.
  jose 1.11 cannot mint ECDH-ES ephemeral keys and hangs on cross-curve
  unwraps, so recipients are matched by `kid` thumbprint first.
- **Carried.** The §10.4 migration drill against a real production
  snapshot (no snapshot on this box, by §1.3); `Sequencer.reload/0` so a
  takeover import can run with the PDS up.

### M10 — Hardening and release readiness (closed 2026-09-09; rows carried)

- **What done took.** `Signer.Remote` (pinned `did:key`, refuses
  signatures that do not verify) and `Signer.Kms` (SigV4 against the KMS
  JSON API, DER → raw low-S, upstream-compatible key spec) with
  fake-service tests; `config :aerox, :env` so `Signer.Local` is genuinely
  refused in prod; the full production runtime config from
  `/etc/aerox/<env>.env` (`ops/aerox.env.example`), `mix release` +
  `Aerox.Release.migrate/0` + the systemd unit, age-encrypted
  `ops/backup.sh` / `ops/restore.sh` (refuses non-empty targets),
  `docs/OPS.md`; the in-process fault suite (§10.2: sequencer kill,
  starvation, slow subscriber); the rotation-key drill on the dev PLC
  (`test/harness/rotation-drill.mjs`: an instance-key hijack nullified by
  the recovery key, `nullified: 1`); the first load baseline
  (`bench/RESULTS.md`) and the CI `network` / `release-config` jobs.
- **What the baseline found.** Two real defects under 32 concurrent
  writers: the sequencer's flush queued behind request connections
  (priority inversion — it now owns a one-connection pool), and hot-account
  writers held connections while waiting on the row lock (a FIFO
  `Aerox.PDS.RepoLock` is now taken before the transaction). And the R2
  answer: the read path is bounded by 21 sequential AppView queries per
  timeline, not by pure-Elixir crypto/CBOR — the Rustler swap is not
  warranted; concurrent hydration is the scheduled optimisation.
- **Decisions.** R3 (sequencer across nodes): single PDS node; the repo
  lock and sequencer are per node and both have a cluster-lock seam.
  Telemetry export: Prometheus on a private port when the first release is
  cut. Reverse proxy: Traefik (the box's), not Caddy.
- **Closed on 2026-09-10 (after the first retrospective).** `bulletin` end
  to end (`test/harness/bulletin.mjs`, scenario 9) — which required two
  fixes: `space:` scopes follow the *published* alpha grammar
  (`authority`, `manage`, `read_self`) and tokens carry granular scopes
  (upstream `buildTokenScope`), plus the vendored `my.bulletin.*` lexicons;
  the restore drill (`docs/OPS.md` §3: found that `--no-owner` restores
  lock every service role out); the §10.3 network faults with Toxiproxy
  (`test/network/faults.sh`, `RESULTS.md`: found that neither firehose
  consumer detected half-open links — both now have a 75 s pong deadline);
  and concurrent AppView hydration (`Hydration.parallel/2`).
- **Still carried (need resources this box does not have).** A release
  candidate deployed to a clean second host from `docs/OPS.md`; the §10.4
  migration drill against a real production snapshot (§1.3 forbids one
  here); the reference AppView parity rows from M7 (no reference AppView
  container); the relay fan-out / ingest / image CDN rows of §10.1.
