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
runner, Caddy + DNS for the hostnames in §1.2, `mise` toolchain, LiveDashboard
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

*(none yet)*
