# aerox — Directory structure

Companion to `DESIGN.md` (what and why), `DEV_PLAN.md` (in what order) and
`VERIFICATION.md` (how we know it is right). This document says **where code goes**,
and — more importantly — **which boundaries the directory layout is there to enforce**.
Drafted 2026-09-09.

DESIGN §2 chose a single Mix app over an umbrella, and accepted one consequence: the
module boundaries an umbrella would have given us for free must come from *directory
conventions plus the `boundary` library* instead. That makes this document load-bearing
rather than cosmetic. A layout that lets the AppView call `Aerox.PDS.Repo` compiles
perfectly and silently destroys the property DESIGN §4.6 paid for.

---

## 1. The four rules the layout exists to enforce

Every choice below follows from one of these. They are the same rules DEV_PLAN §2.2
step 4 says review focuses on:

1. **The kernel does no I/O.** `lib/aerox/atproto/` may not reference Ecto, Phoenix,
   Req, `:httpc`, `:inet_res`, or start a process (DESIGN §3.0). It is the only layer
   whose correctness cannot be repaired later, and purity is what makes differential
   testing a bytes-in/bytes-out comparison.
2. **Services do not share a database.** `Aerox.AppView.*` may not name
   `Aerox.PDS.Repo`, and vice versa. The only paths between services are XRPC and the
   firehose (DESIGN §4.6). An AppView that only works against *our* PDS's tables is not
   an AppView.
3. **Shared infrastructure is a behaviour, not a service reaching into another.**
   Blob storage, signing, identity resolution, DPoP and scope evaluation are used by
   several services, so they sit beside the services, never inside one of them.
4. **Tool-only code never reaches a production release.** The reference-PDS interop
   adapter carries `exqlite`; a `MIX_ENV=prod` build must not contain a SQLite driver
   (DESIGN §13.2).

`boundary` declarations make 1–3 compile-time errors rather than review comments; §6
below says how.

---

## 2. Top level

```
aerox/
├── compose.yaml            Postgres 18 on loopback (DEV_PLAN §1.1)
├── docker/                 container support files
│   └── postgres/init/      creates the four databases, enables pg_trgm
├── docs/                   DESIGN · DEV_PLAN · VERIFICATION · STRUCTURE
├── config/                 config.exs · dev · test · prod · runtime
├── lib/                    the application (§3, §4)
├── lib_tool/               MIX_ENV=tool only — never in a prod release (§5)
├── ops/                    host-side operational config, not compiled
│   └── traefik/            routers + TLS for the dev domain (DEV_PLAN §1.2)
├── priv/                   migrations, vendored lexicons, static (§7)
├── test/                   §8
├── tools/                  upstream-side generators and reference stacks (§9)
└── bench/RESULTS.md        load baselines per release (VERIFICATION §10.1)
```

`docs/`, `ops/`, `tools/` and `bench/` are deliberately outside `lib/` — none of them
is compiled into the application. `tools/` in particular holds TypeScript and Go that
runs *inside upstream containers*, not on our BEAM; `ops/` holds configuration that is
applied to services outside the repository, so each file there is paired with the
script that installs it rather than being copied by hand.

---

## 3. `lib/aerox/` — the application

Four bands, in dependency order. Nothing in a band may depend on a band below it in
this list, except through the behaviours in band 2.

```
lib/aerox/
├── application.ex          config-driven supervision tree (DESIGN §2, §21.9)
├── services.ex             which services are enabled on this node
│
│  ── band 1: the kernel — pure, no I/O, no Ecto, no Phoenix (DESIGN §3) ──
├── atproto/
│   ├── syntax.ex               handle/nsid/did/at-uri/tid/rkey/datetime  (§3.10)
│   ├── bytes.ex                the only wrapper type                     (§3.1)
│   ├── cid.ex
│   ├── dag_cbor.ex             validation layer ①                        (§3.2)
│   ├── data.ex                 validation layer ② + the two JSON⇄model codecs
│   ├── blockstore.ex           behaviour + Memory implementation         (§3.5)
│   ├── mst.ex                  pure functions over an explicit blockstore
│   ├── car.ex                  streaming read/write
│   ├── crypto.ex               Keypair behaviour, did:key, K256/P256     (§3.8)
│   ├── tid.ex                                                           (§3.7)
│   ├── repo.ex                 commit production AND verification        (§3.6)
│   ├── identity.ex             DID document *parse* only                 (§3.0)
│   ├── lexicon/                interpreter + registry                    (§6.2)
│   │   ├── registry.ex             an explicit argument, never global state
│   │   ├── validator.ex
│   │   └── schema.ex               one embedded doc per JSON file
│   └── space/                  feature-flagged, alpha (DESIGN §12.2)
│       ├── lt_hash.ex
│       ├── space_commit.ex
│       ├── op_log.ex
│       └── car.ex                  the two-root CAR variant
│
│  ── band 2: shared infrastructure — behaviours used by several services ──
├── identity/               the impure half of §3.0: resolve, cache        (§20.1)
│   ├── resolver.ex             DNS TXT · /.well-known · PLC · did:web
│   ├── cache.ex                ETS + per-service table, single-flight     (§21.7)
│   └── http.ex                 hardened outbound client (SSRF rules)      (§16)
├── crypto/
│   └── signer.ex               behaviour + Local · Kms · Remote           (§14.2)
├── blob/
│   ├── store.ex                behaviour                                  (§4.4)
│   ├── disk.ex · s3.ex · migrating.ex
│   └── reaper.ex
├── auth/
│   ├── scopes.ex               scope grammar, include:, space:            (§11.2)
│   ├── dpop.ex                 ONE verifier, shared by OAuth and Spaces    (§12.4)
│   ├── service_jwt.ex          issue and verify, the §20.2 rules
│   └── scrypt.ex               upstream-compatible password hashing       (§13.4)
│
│  ── band 3: the five services — each owns its Repo and its tables ──
├── pds/
│   ├── repo.ex                 Aerox.PDS.Repo → aerox_pds
│   ├── accounts/               lifecycle, sessions, app passwords         (§18.3)
│   ├── oauth/                  authorization server                        (§11.2)
│   ├── records/                CRUD, applyWrites, row-lock serialisation   (§21.3)
│   ├── blockstore.ex           the Postgres Blockstore over repo_block     (§4.2)
│   ├── sequencer.ex            single writer, call coalescing              (§21.2)
│   ├── firehose/               fan-out over PubSub                         (§5.1)
│   ├── proxy.ex                pipethrough to the AppView                  (§11.1)
│   ├── mailer/                 five token purposes                         (§18.1)
│   ├── plc_ops.ex              THE ONLY caller of Signer.sign for PLC ops  (§14.2),
│   │                           with plc_op_audit in aerox_pds — not in plc/,
│   │                           which the PDS may not depend on (§6)
│   └── space/                  Spaces, feature-flagged                     (§12.3)
├── plc/
│   ├── repo.ex                 Aerox.PLC.Repo → aerox_core, schema `plc`
│   ├── operations.ex           validation, priority, 72-hour nullification
│   └── directory.ex            storage, admission, export, audited removeInvalidOps
├── sequencer.ex               Aerox.Sequencer: the coalescing single writer of a
│                               repo_seq table, shared by PDS and Relay      (§5.2, §21.2)
├── relay/
│   ├── repo.ex                 Aerox.Relay.Repo → aerox_core, schema `relay`
│   ├── consumer.ex             one GenServer per upstream host (Mint.WebSocket,
│   │                           cursor persistence, back-off, keepalive)     (§21.4)
│   ├── consumers.ex            Registry + DynamicSupervisor, resubscribe on boot
│   ├── ingest.ex               verification and re-emission per event type (§19)
│   ├── hosts.ex / accounts.ex  host rules and limits; account↔host binding
│   ├── host_checker.ex         describeServer / getRepoStatus probes
│   ├── sequencer.ex            its own, with the retention window          (§19)
│   └── config.ex
├── appview/
│   ├── repo.ex                 Aerox.AppView.Repo → aerox_core, schema `appview`
│   ├── schema.ex               one Ecto schema per upstream bsky table
│   ├── ingest.ex, ingest/      Broadway; producer (acked cursor), indexer  (§21.5)
│   ├── backfill.ex             Oban job: getRepo → verify → index          (§15.1)
│   ├── indexing.ex             RecordProcessor: record row, plugin, duplicates,
│   │                           notifications in the same transaction       (§15.5)
│   ├── plugin.ex, plugins/     the nineteen record plugins                 (§15.2)
│   ├── thread_gates.ex         thread/post gate rules
│   ├── hydration.ex            batch loaders                               (§15.3)
│   ├── views.ex                presentation: #postView, #profileView*, embeds,
│   │                           threads, notifications
│   ├── cursor.ex               TimeCid keyset cursors
│   ├── feeds.ex                timeline · author · thread · custom skeletons
│   └── config.ex
├── labeler/
│   ├── actions.ex              the Actions behaviour                       (§17.2)
│   ├── labels.ex               signing + subscribeLabels sequencer
│   └── reports.ex              intake, append-only mod_event
├── image_server/              runs inside the AppView but is its own tree   (§16)
│   ├── presets.ex                 upstream's URL shape and presets, verbatim
│   ├── processor.ex               vix/libvips, bounded concurrency          (§21.8)
│   └── cache.ex                   disk LRU + edge purge behaviour
│
│  ── band 4: cross-cutting workflows ──
└── interop/
    └── bundle/                 the account bundle (§13.0)
        ├── manifest.ex
        ├── postgres.ex             aerox PG ⇄ bundle
        └── protocol.ex             live PDS → partial bundle (Layer A)
```

Two placements worth stating explicitly, because the obvious alternative is wrong:

- **`identity/` is not inside `pds/`.** The AppView needs it to verify service JWTs
  (DESIGN §11.1), the Relay needs it to invalidate on `#identity`, the image server
  needs it to find an origin. It is band 2, and each service gets its own cache table
  in its own database — the cache is never shared across the §4.6 boundary.
- **`interop/bundle/` is not inside `pds/`.** It is a workflow *over* the PDS's
  storage, has its own Mix tasks and its own verification suite (VERIFICATION §8), and
  its `ReferencePds` adapter cannot live in `lib/` at all (§5 below).

---

## 4. `lib/aerox_web/` — one endpoint, routes grouped by owning service

DESIGN §2 fixed the HTTP shape: one Phoenix Endpoint; XRPC routes declared explicitly
per NSID; a plug that 404s when the owning service is not enabled on this node; XRPC on
its own pipeline, not `:browser`.

Controllers are therefore grouped by **which service serves the route**, not by NSID
namespace. The alternative — grouping by `com.atproto.*` sub-namespace — cuts across
services (`com.atproto.sync.*` is served by both the PDS and the Relay, differently)
and would make the service-enabled plug unexpressible.

```
lib/aerox_web/
├── endpoint.ex
├── router.ex               every route declared explicitly; the parity table
│                           in test/parity/ENDPOINTS.md is read by a router test
├── telemetry.ex
├── plugs/
│   ├── service_enabled.ex      404 when the owning service is off
│   ├── xrpc_error.ex           maps {:error, …} to XRPC error names
│   ├── auth.ex                 session · app password · OAuth · service JWT
│   └── rate_limit.ex           hammer, declared per route                (§18.2)
├── controllers/
│   ├── pds/                    com.atproto.{server,repo,identity,admin,sync}
│   ├── plc/                    plain REST: /:did, /:did/log, /export     (§6.4)
│   ├── relay/                  com.atproto.sync.* (the relay's subset)
│   ├── appview/                app.bsky.* read path
│   ├── labeler/                com.atproto.label.* + moderation
│   ├── oauth/                  /oauth/{par,token,revoke,introspect,jwks}
│   ├── well_known/             did.json · atproto-did · oauth metadata
│   └── image/                  /img/<preset>/plain/<did>/<cid>@<fmt>
├── sockets/
│   └── firehose.ex             raw WebSocket, DAG-CBOR frames — NOT a
│                               Phoenix Channel (DESIGN §5.1)
└── components/                 layouts + the OAuth login/consent pages, the
                                only HTML in the project (DESIGN §11.2)
```

---

## 5. `lib_tool/` — the `MIX_ENV=tool` island

DESIGN §13.2 requires that a `MIX_ENV=prod` release contain no SQLite driver, while the
reference-PDS adapter needs one. A dependency marked `only: [:dev, :test, :tool]` is not
enough on its own: a module in `lib/` that references `Exqlite` fails to compile in
`prod`. The code must therefore be excluded from the compile path, not just the driver.

```
lib_tool/
├── aerox/interop/reference_pds/    the SQLite <data> directory ⇄ bundle adapter
└── mix/tasks/
    ├── aerox.interop.from_pds.ex
    └── aerox.interop.to_pds.ex
```

```elixir
# mix.exs
defp elixirc_paths(:test), do: ["lib", "lib_tool", "test/support"]
defp elixirc_paths(:dev),  do: ["lib", "lib_tool"]
defp elixirc_paths(:tool), do: ["lib", "lib_tool"]
defp elixirc_paths(_),     do: ["lib"]
```

Everything else — `mix aerox.bundle.export` / `import`, `mix aerox.golden.verify` — is
always available and lives in `lib/mix/tasks/`.

---

## 6. Enforcing the bands with `boundary`

One `use Boundary` per top-level module, checked by `mix compile`. The three that matter:

```elixir
defmodule Aerox.ATProto do            # band 1
  use Boundary, deps: [], exports: :all
end

defmodule Aerox.AppView do            # band 3
  use Boundary, deps: [Aerox.ATProto, Aerox.Identity, Aerox.Auth, Aerox.Blob]
end                                   # note: Aerox.PDS is NOT a dep

defmodule Aerox.PDS do
  use Boundary, deps: [Aerox.ATProto, Aerox.Identity, Aerox.Auth, Aerox.Blob, Aerox.Crypto]
end
```

`deps: []` on the kernel is the mechanical form of rule 1: it cannot reference Ecto,
Phoenix or any service even by accident. Rule 2 is the absence of `Aerox.PDS` from the
AppView's deps and vice versa.

---

## 7. `priv/`

```
priv/
├── pds_repo/migrations/         Aerox.PDS.Repo      → aerox_pds
├── plc_repo/migrations/         Aerox.PLC.Repo      → aerox_core, schema plc
├── relay_repo/migrations/       Aerox.Relay.Repo    → aerox_core, schema relay
├── appview_repo/migrations/     Aerox.AppView.Repo  → aerox_core, schema appview
├── lexicons/
│   ├── SOURCE.json                  upstream repo + commit per namespace (§6.6)
│   └── com/atproto/…                the 96 vendored files, plus space/simplespace
├── static/                      favicon, robots.txt, the three generated asset files
└── gettext/
```

Four migration directories because DESIGN §4.6 chose four repos: one per service, three
of them sharing the `aerox_core` database through separate Postgres schemas. Each of
those three needs its own `search_path` (`after_connect`) and its own
`migration_source`, or they will fight over one `schema_migrations` table. Keeping the
migrations physically separate is what makes "split `aerox_core` into three databases
later" a config change and nothing else.

Each repo also connects as **its own Postgres role**, with `REVOKE` on every schema it
does not own (DESIGN §4.6). Without that, the three `aerox_core` schemas are separated
by convention only and an AppView query can join straight into `relay.*` — the very
shortcut the database split exists to forbid. The role grants belong in the first
migration of each repo, not in a hand-run script, so a fresh database is correct by
construction.

Two consequences for the tree above: there are **two Oban instances**, one per database
(DESIGN §21.6's "same transaction as the business write" is a per-database property), so
`pds/jobs/` and a core-side equivalent each configure their own queues; and the
combined pool budget is four repos wide, which needs explicit `pool_size` on a small
box rather than the default 10 apiece.

---

## 8. `test/`

The tree mirrors `lib/`, with four additions that do not.

```
test/
├── test_helper.exs             refuses to start if either _test database is
│                               missing (VERIFICATION §11)
├── support/
│   ├── conn_case.ex · data_case.ex
│   ├── golden_case.ex              table-driven golden runner; hex diff with the
│   │                               first differing byte offset (VERIFICATION §3.1)
│   ├── blockstore_case.ex          ┐ shared contract suites run against every
│   ├── blob_store_case.ex          │ implementation of the behaviour
│   ├── signer_case.ex              │ (VERIFICATION §4)
│   └── search_case.ex              ┘
├── golden/                     THE CORPUS + MANIFEST.json (VERIFICATION §2.1)
│   └── syntax/ crypto/ dagcbor/ cid/ mst/ car/ data-model/ lexicon/
│       firehose/ plc/ oauth/ spaces/ bundle/
├── atproto/ identity/ crypto/ blob/ auth/      unit + property suites
├── pds/ plc/ relay/ appview/ labeler/ interop/ L6 service suites
├── aerox_web/
├── integration/                L7 all-in-one scenarios (VERIFICATION §6)
├── parity/
│   ├── ENDPOINTS.md                every route, its parity status, its deviations
│   └── …                           the runner; a router test reads the table
└── harness/                    Node driver using @atproto/api (VERIFICATION §6)
```

**`test/golden/`, not `test/atproto/golden/`.** DESIGN §3.10 said the latter; it is
corrected there. The corpus in VERIFICATION §2.1 includes `oauth/`, `plc/`, `spaces/`
and `bundle/` vectors, none of which are kernel material, so the corpus cannot sit
inside the kernel's test directory.

Property tests live next to the unit tests for the module they constrain
(`test/atproto/mst_property_test.exs`), not in a separate tree — they are assertions
about the same module, and separating them makes it easy to forget one exists.

---

## 9. `tools/`

```
tools/
├── golden/                 upstream-side generators, run INSIDE pinned containers
│   ├── ts/                     @ipld/dag-cbor, @atproto/repo, assertValidRecord
│   ├── go/                     indigo atdata, mst, repo
│   └── README.md               the regeneration commands MANIFEST.json cites
└── interop/                compose files for the reference stacks
    └── …                       ref PDS · indigo relay · bsky-standalone · PLC · spaces alpha
```

These never run on a developer's local toolchain: a golden that depends on which
Node or Go a laptop happens to have is not an oracle (VERIFICATION §2.3).

---

## 10. Open points

- **Three repos on one database — resolved 2026-09-09 (M0a).** Confirmed against
  Ecto SQL 3.14: `migration_default_prefix` only prefixes the tables a migration
  creates; the repo's own `schema_migrations` table is created *unqualified* and
  lands wherever `search_path` points. So the per-service schema must exist,
  owned by the service role, **before** the first migration runs — it is created
  by `docker/postgres/init/01-databases.sh`, and each repo's first migration is
  the in-repo record that re-asserts ownership idempotently. `after_connect`
  sets `search_path TO <schema>, public` (public only for `pg_trgm`'s
  functions; CREATE on it is revoked), and `migration_default_prefix` is kept so
  migration DDL is explicit. Four `schema_migrations` tables, one per schema,
  and the sandbox works on all four repos. `test/aerox/repo_boundary_test.exs`
  proves the REVOKE matrix at runtime.
- **The core-side Oban instance is owned by `Aerox.AppView.Repo`** (prefix
  `appview`). Oban binds to one repo; the AppView is the core service with
  durable jobs (backfill, purges, label subscriptions). PLC and Relay have none
  today; if one appears, it gets its own instance rather than a grant into the
  `appview` schema.
- **`lib_tool/` naming.** Chosen over `tool/lib/` because `elixirc_paths` takes a flat
  list and a sibling of `lib/` reads clearly in that list. Revisit if a second
  environment-scoped source root ever appears.
- **Where `image_server/` ends up** if it is ever split out of the AppView (DESIGN §16
  allows it). It is already its own band-3 tree with no AppView dependency other than
  configuration, so the move is a supervision-tree change.
