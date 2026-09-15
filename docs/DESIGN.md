# aerox — an AT Protocol implementation in Elixir/Phoenix

Design document. Drafted 2026-09-09.

This document records **trade-offs and the reasons behind them**, not implementation
detail. Every "why not the other way" lives here so the code does not have to repeat it.
Reference material for the 18 atproto implementations we studied is in `../../bsky/index.md`.

---

## 1. Goals and non-goals

### Goals

A complete AT Protocol backend in Elixir/Phoenix: **PDS, PLC directory, Relay, AppView,
Labeler/moderation backend and an image CDN**,
including **atproto OAuth** as the client authentication model (§11) and **permissioned
data / Spaces** per proposal 0016 (§12). No frontend — the existing `ouranos` client
tests the public read path and `bulletin` tests Spaces.

**Data portability is a core requirement**, not a feature: every account on an aerox
instance can be exported and imported **between aerox service providers**, and
**to and from the Bluesky reference PDS**, losslessly (§13).

This is a **serious production implementation**, not a learning exercise. It may
eventually replace the TypeScript + Go stack behind greenfield/xjdao. Correctness
therefore takes priority over speed of delivery.

### Key decision: bit-exact encoding, no federation

The original requirement was "self-consistent first, keep the door open for interop".
That was **translated** into a more precise form:

> **The encoding layer is bit-exact from day one. Federation is switched off from day one.**

The two halves have wildly asymmetric costs:

| | Cost | When it must be done |
|---|---|---|
| Bit-exact encoding | Kernel layer only. A correct encoder and a sloppy one differ in tests, not in implementation effort | **Day one. Cannot be retrofitted** |
| Actual federation | Relay peering, PLC directory registration, moderation, abuse handling, operations | Whenever we choose to switch it on |

"Self-consistent" can only save the second column, and the second column was always
deferrable. The first column cannot be saved, because:

**Encoding bugs in a self-consistent system never surface.** Our encoder and our
decoder will agree with each other forever; the test suite stays green for a year.
The day we peer with an official relay, every commit signature fails verification —
and **it cannot be fixed retroactively**: the signatures were computed over the old
encoding, re-encoding changes every CID, and the entire repo history is void.

Bit-exactness also makes development **faster**, because it provides an oracle: the
output of `bsky/atproto` (TS) and `bsky/indigo` (Go) serves as golden files and every
step is immediately checkable. A self-consistent implementation has no oracle;
debugging is guesswork.

### Non-goals (current phase)

- **Not a peer of the public atproto network.** No registration with plc.directory, no
  peering with official relays. (Outbound fetches still happen: OAuth client-metadata
  documents, `resolveLexicon`, DID resolution — those are not federation.)
- **No moderation frontend.** The moderation *backend* — a labeler service, report
  intake, takedowns, an audit log and an Ozone-shaped interface — is in scope (§17);
  the operator UI (Ozone's web app or our own) is a separate frontend project.
- **No frontend.** `ouranos` validates the read path.
- **No video, no chat.** Both are large lexicon surfaces orthogonal to the core protocol.
- **No read-after-write patching** in the PDS proxy (§11.3); pure pass-through in v1.

### Migration is a goal (decided 2026-09-09)

aerox **is designed to migrate an existing Bluesky reference PDS — its accounts, user
repos, blobs and secrets — into aerox** (§13). This replaces the earlier "keep the door
open" stance. What remains open is only *when* the specific production deployment
(the 2008 identities in `did-method-plc`) is moved, not whether the design supports it.
§8 keeps the choices that would have foreclosed it.

---

## 2. Service boundaries and deployment shape

### Five components

```
   ┌─ Kernel library (lib/aerox/atproto) ───┐
   │ DAG-CBOR · CID · MST · CAR · signing   │
   │ TID · Lexicon · DID/handle parsing     │
   └──────────────────┬─────────────────────┘
                      │
        ┌─────────────┼──────────────┐
      PLC           PDS ──firehose──→ Relay ──→ AppView ──→ ouranos
  (identity dir)  (repos/sign/blob)  (fan-out)  (index/read)
```

The kernel is not a service; it is a pure-function layer shared by the other four.

### Code organisation: a single Mix app, no umbrella

**No umbrella.** The Elixir community has largely moved away from umbrellas (José Valim
has said so repeatedly). They provide exactly two things: compile-time module
boundaries, and multiple releases from one codebase. A plain app can do the second;
directory conventions plus the `boundary` library cover the first. The costs are
real: config only at the root, path deps referencing each other, duplicated deps,
extra dialyzer/test/CI setup.

**The decisive reason is that atproto needs to run in one process.** Upstream built
`services/bsky-standalone/` and resurrected `MockBsync` (see `../../bsky/index.md`, trap #1)
purely to cram DataPlane + bsync + AppView + RepoSubscription into a single process.
A single Elixir app with a config-driven supervision tree *is* that shape natively:

```elixir
# config :aerox, :services, [:pds, :plc, :relay, :appview, :labeler]   # dev: everything on
# config :aerox, :services, [:pds]                            # prod: one per release

def start(_type, _args) do
  children = base_children() ++ Enum.flat_map(services(), &children_for/1)
  Supervisor.start_link(children, strategy: :one_for_one, name: Aerox.Supervisor)
end
```

**An umbrella cannot do this** — its releases are cut per OTP app; you cannot express
"start half of one app's supervision tree".

In dev, one `mix phx.server` brings up a self-contained atproto network whose only
external dependency is a Postgres server holding two databases (§4.6). The effect on development velocity is hard to overstate.

### When and how to split

Split when a service needs its own release cadence, or when the team splits.
**Single app → multiple repos is an easy split; umbrella → separate repos is harder**
(config and path deps must be redone). The "poncho" shape (independent apps linked by
path deps) is an available intermediate step.

### HTTP layer

One Phoenix Endpoint. XRPC routes are declared explicitly per NSID (in `/xrpc/<nsid>`
the NSID is a single path segment, so one lexicon = one route). A plug checks whether
the owning service is enabled on this node and returns 404 otherwise. No need for
multiple ports — in production each service sits behind its own domain and proxy anyway.

**XRPC uses its own pipeline, not `:browser`.** It is a pure JSON/CBOR API and needs
no session, CSRF or flash. Not everything is XRPC, though: the PLC directory is plain
REST (`/:did`, `/:did/log`, `/export`), `/.well-known/*` (DID, OAuth metadata,
`atproto-did` for hosted handles) and `/oauth/{par,token,revoke,introspect,jwks}` are
API routes on their own pipelines. The `:browser` pipeline (session + CSRF) serves
LiveDashboard and the **OAuth login/consent pages** (`/oauth/authorize`, logout,
change-password) — server-rendered HTML with forms, not static pages.

Generator invocation (verified against Phoenix 1.8.13):

```sh
mix phx.new aerox --no-assets --no-live
```

- `--no-assets` = `--no-esbuild --no-tailwind`: no `assets/`, no JS/CSS build chain
- `--no-live` only comments out the LiveView socket in the Endpoint; **the HTML layer stays**
- **Do not use `--no-html`** — it removes the whole HTML layer (views, layouts, the
  `:browser` pipeline, error_html); you could not render a single page

Two verified details:

1. ~~`--no-assets` does not clean up the root layout; it still references three files
   that do not exist.~~ **Corrected 2026-09-09 against Phoenix 1.8.13 as generated:**
   the root layout does reference `/assets/css/app.css`, `/assets/default.css` and
   `/assets/js/app.js`, but the generator now ships all three under
   `priv/static/assets/`. No cleanup is needed.
2. **Keep LiveDashboard; it is itself a LiveView application.** Verified: the generator
   only comments out the live socket when given `--no-dashboard`; otherwise it keeps it,
   because the dashboard needs it. The `phoenix_live_view` dependency stays either way
   (1.8 layouts use `<.live_title>`). Unused, its runtime cost is ~zero, and its value
   to this project is high (§5).

### MIME registration

`application/cbor`, `application/vnd.ipld.car` and `application/jsonl` must be
registered under `config :mime, :types`, or `plug :accepts` will answer 406.

---

## 3. Kernel layer design

**This is the foundation of the project and the only layer where a mistake cannot be
repaired.** Settled in discussion on 2026-09-09.

### 3.0 The kernel does no I/O

The kernel (`Aerox.ATProto.*`) **makes no HTTP calls, no DNS lookups, starts no
processes, and does not reference Phoenix or Ecto**. This is a precondition for
differential testing: a golden case must be a pure "bytes in → bytes out" comparison.

The concrete boundary case is DID/handle resolution — one word in Chinese, two in English:
- **parse** (pure): given a DID document as JSON, extract the signing key, PDS endpoint,
  handle aliases → kernel.
- **resolve** (impure): DNS TXT, `/.well-known/atproto-did`, PLC requests →
  `Aerox.Identity`, outside the kernel, with HTTP/DNS clients injected as behaviours
  and a cache in front.

Extracting the kernel into a standalone hex package later costs nothing; not extracting
it costs nothing either.

### 3.1 In-memory data model — the choice that determines everything else

Before any algorithm, decide "what does a decoded atproto value look like in Elixir".
DAG-CBOR, JSON conversion, the MST and lexicon validation all operate on this representation.

**Elixir has a problem other languages lack: a binary is both bytes and string.**
CBOR major type 2 (bytes) and type 3 (text) are distinct and must round-trip. JS has
`Uint8Array` vs `string`, Go has `[]byte` vs `string`; we have neither, so one side must
be wrapped.

**Decision: wrap bytes.** They are rare in atproto data (a commit's `sig`, MST node
keys `k`, JSON `$bytes`); text is everywhere, and wrapping it would deface all the code.

| atproto type | Elixir representation |
|---|---|
| null / bool / integer | native |
| string | binary |
| **bytes** | **`%Aerox.ATProto.Bytes{}`** (the only wrapper) |
| **cid-link** | **`%Aerox.ATProto.CID{}`** |
| array | list |
| object | **map with string keys — never atoms** |
| float | **does not exist** — forbidden by the data model; the decoder errors on it |

No atom keys: lexicons have thousands of field names, and `String.to_atom` on external
input lets anyone fill the atom table. The lexicon layer converts when it builds structs (§6).

**One in-memory model, two codecs** (CBOR and JSON; in JSON a CID is `{"$link": …}`
and bytes are `{"$bytes": base64}`). No direct JSON→CBOR conversion. Upstream TS
(`jsonToLex` / `lexToJson`) and indigo's `atdata` share this structure.

### 3.2 Three validation layers, kept apart

```
① CBOR syntax        canonical? (shortest ints, key order, 0x00 prefix in tag 42)  → DagCBOR
② atproto data model  no floats, integer range, CID codec ∈ {0x71, 0x55}, nesting depth → Data
③ lexicon schema     field types, required, maxLength, enums…                       → §6
```

① and ② live in the kernel; ③ in the lexicon layer. **The Relay performs ① and ②
only, never ③** — it must not drop a subscription because some PDS emitted a record
whose lexicon it does not know. The AppView performs ③. A single `validate/1` that
merges all three would leave the Relay unable to ask for just the first two.
Boundary values for ② come from indigo's `atdata/testdata/data-model-*.json`, not
from our own judgement.

### 3.3 DAG-CBOR: must be written in-house

There is **no DAG-CBOR implementation on hex** (checked: neither `dag_cbor` nor
`ex_cbor` exists; `cbor` 2.0.0-rc1 is plain RFC 8949). DAG-CBOR additionally requires:

1. **Deterministic encoding.** Shortest integer form; map keys sorted by length, then
   bytewise. Elixir maps are unordered, so the encoder must sort and the strict decoder
   must **verify** the order.
2. **CIDs as tag 42**, with a leading `0x00` byte (multibase identity). **The most
   common source of interop bugs.**
3. **Forbidden**: NaN/Infinity floats, non-string map keys, undefined tags.

Decoding is strict: non-canonical input is an error, not tolerated. Tolerance means
accepting data others reject, producing repos that are valid only on our network.
Golden targets are `@ipld/dag-cbor` (TS) and `go-ipld-cbor` (Go).

### 3.4 CID

Only two codecs are used: `dag-cbor` (0x71, records and commits) and `raw` (0x55, blobs).
Hash is always sha256. String form is base32 multibase (prefix `b`).

### 3.5 MST: pure functions over an explicit Blockstore

Keys are `collection/rkey`; values are record CIDs. A key's layer is **the number of
leading zero bits in sha256(key), divided by 2**. Tree shape depends only on the key
set, never on insertion order — which is why two implementations arrive at the same root.

**The MST does not touch storage directly.** Where nodes come from differs by context:
a PDS reads `repo_block` in Postgres; import reads a CAR; the Relay validating one commit has only the
few dozen blocks that commit carries, in memory; unit tests use a map. So MST operations
run over a behaviour:

```elixir
@callback get(cid) :: {:ok, binary} | :error
@callback get_many([cid]) :: %{cid => binary}
@callback put_many([{cid, binary}]) :: :ok
```

Every MST function **takes the blockstore explicitly** — no process state, no
`Process.put`. This is what makes the Relay's inductive validation fall out naturally:
hand it a MemoryBlockstore holding only those few dozen blocks.

Node encoding is `{l, e: [{p, k, v, t}]}`, where `p` is the prefix-compression length
and **`k` is bytes, not a string**. This is a second reason the bytes wrapper exists —
encode `k` as text and every root CID is wrong.

**Implementation order:**
1. **Read-only**: load from CAR, look up, traverse; verify the computed root equals the
   commit's on real repos. **Passing this proves DagCBOR, CID and MST are all correct.**
2. **Writes**: insert / update / delete with node split and merge.
3. **Diff**: each commit yields its changed block set and ops list.

Do not skip step 1 — it is the zero-dependency, mechanically checkable proof of correctness.

### 3.6 Repo: the write path belongs in the kernel, and it must also verify

A commit is `{did, version: 3, data: <MST root>, rev: <TID>, prev: null, sig}`.
"Write a record" = new root + new commit + signature + **the changed block set and ops
list for this change** (the firehose emits these). That chain is pure computation and
lives in `Aerox.ATProto.Repo`; the PDS only persists, sequences and broadcasts.

**The kernel must not only produce commits but verify other people's.** Under sync v1.1
each commit event carries `prevData` (the previous root) and ops (update/delete carry
a `prev` CID), and the Relay must verify — without the full tree — that applying the
ops to `prevData` does yield `data` (indigo's `mst/verify.go`). A write-only kernel
cannot support a Relay.

**Only repo v3 + sync v1.1 are supported**; no compatibility with the old `prev` chain.
The live network has fully migrated; compatibility would only add surface area.

### 3.7 TID

64 bits: top bit always 0, 53 bits of microseconds, 10 bits of clock id. base32-sortable
into 13 characters; **lexical order is time order**. In-process monotonicity is enforced:
on clock regression or repeated calls within one microsecond, add 1 µs — a duplicated
key makes the MST **silently overwrite** the previous record.

### 3.8 Signing: a behaviour plus two hard rules

`did:key` multicodec prefixes: secp256k1 `0xe7`, P-256 `0x1200`, compressed points.
Signatures are raw `r‖s`, 64 bytes, **not DER**.

1. **Force low-S when signing.**
2. **Reject high-S when verifying.** Network-wide requirement since 2023;
   `signature-fixtures.json` contains high-S cases that must fail. Tolerance would make
   the same data valid on one network and invalid on another.

`Crypto.Keypair` is a behaviour with K256 and P256 implementations, backed by
`ex_secp256k1` (0.8.0, Rust NIF — **never hand-rolled**) and Erlang `:crypto`.
The verification path must handle both curves.

### 3.9 Performance: pure Elixir first, replaceable interface

**Elixir's weak spot here:** DAG-CBOR codec work and MST hashing are CPU-bound, and pure
Elixir will be an order of magnitude slower than Go/Rust. But **do not start with a NIF**.
Write it in Elixir, pin correctness with golden tests, keep the interface swappable;
if performance is insufficient, replace with a Rustler wrapper around `serde_ipld_dagcbor`.
Starting in Rust entangles the hardest correctness problem with the most annoying
toolchain problem.

### 3.10 Module inventory

```
Aerox.ATProto.Syntax      handle/nsid/did/at-uri/tid/rkey/datetime parsing and validation
                          ← all 16 files in interop-test-files/syntax/ become tests directly
Aerox.ATProto.CID
Aerox.ATProto.Bytes       the only wrapper type
Aerox.ATProto.DagCBOR     layer ①
Aerox.ATProto.Data        layer ② + the two JSON⇄model codecs
Aerox.ATProto.Blockstore  behaviour + Memory implementation (others live in each service)
Aerox.ATProto.MST         pure functions, explicit blockstore
Aerox.ATProto.CAR         streaming read/write (Stream); repo exports can be large
Aerox.ATProto.Crypto      Keypair behaviour, did:key, K256/P256
Aerox.ATProto.Repo        commit production and verification, ops/diff
Aerox.ATProto.Identity    DID document parse (pure); resolve lives outside the kernel
```

The test tree mirrors this. The golden corpus lives at **`test/golden/`**, not under
`test/atproto/` — it also holds PLC, OAuth, Spaces and bundle vectors, which are not
kernel material (VERIFICATION §2.1, `STRUCTURE.md` §8).

---

## 4. Storage

Settled in discussion on 2026-09-09. **This section reverses an earlier decision**
(one SQLite per account); see 4.1 and the decision log.

### 4.1 One Postgres for the whole PDS; all accounts in shared tables

The PDS keeps **everything except blob bytes in a single Postgres database**: accounts,
sessions, tokens, invites, the sequencer's event log, and every account's repo (blocks,
records, blob metadata) in shared tables keyed by `did`. There is no per-account
SQLite file.

**SQLite is not used anywhere in aerox's runtime** — not for accounts, repos, the
sequencer, the DID cache, or dev/test. Postgres is the only database; the only other
persistent store is the blob store (§4.4). The single exception is the **interop tool**
(§13), which reads and writes the *reference PDS's* SQLite files; it carries `exqlite`
as a tool-only dependency that is excluded from production releases.

**Correction of an earlier claim.** §4.1 previously said all seven independent
implementations use one SQLite per account "without exception". That was wrong.
Verified against the sources: six do (upstream `atproto`, `atproto-crates`, `rsky`
via `rusqlite`, `pegasus`, `zds`, `cocoon`); **`tranquil-pds` — the most
feature-complete of them — uses Postgres via sqlx as its default and only
production-recommended backend**, with its embedded engine explicitly marked
experimental. `../../bsky/index.md` has been corrected accordingly. The decision below
therefore has a direct precedent.

**What the per-account-SQLite camp buys, and how we get it instead.** Their argument is
that a repo must be migratable as a unit. In atproto the unit of migration is not a
file but a **CAR export** (`com.atproto.sync.getRepo`) plus the PLC operation that
re-points the DID — that is how account migration between PDSes works regardless of
storage. CAR import/export is already on the no-regret list (§8, item 4). File-level
portability (`mv` a directory) is lost; protocol-level portability is unaffected.

**What Postgres buys:**
- One engine and one Ecto adapter across all four services (but not one database — see 4.6).
- Cross-account queries (`listRepos`, `getLatestCommit` for many DIDs, admin views) are
  plain SQL — no central `repo_root` copy, no opening N files.
- The PDS can run on more than one node against the same database — **conditional on
  the cluster-unique sequencer in §5.3 (R3)**; until that is decided, one PDS node.
- No `put_dynamic_repo/1` process-local trap; no open-per-request or pool policy to design.

**Costs, acknowledged:**
- The PDS is no longer "a directory": physical backup must cover Postgres and the
  blob store together (4.4); the per-account logical backup is the bundle (§8 item 6, §13.0).
- The dev full stack requires a Postgres; §2's "no external dependencies" is now
  "Postgres only".
- `repo_block` becomes one very large table across all accounts (see 4.2 and R4).

### 4.2 Table shape: borrow upstream's per-account schema, add `did`

Upstream's per-account `store.sqlite` tables translate directly, each gaining a `did`
column and a composite key:

| Table | Key | Columns (beyond key) | Role |
|---|---|---|---|
| `repo_root` | `did` | `cid`, `rev` | current commit per account |
| `repo_block` | `(did, cid)` | `rev`, `size`, `content bytea` | **raw DAG-CBOR bytes of MST nodes and records — the Postgres implementation of the §3.5 Blockstore** |
| `record` | `(did, collection, rkey)` | `uri`, `cid`, `rev`, `indexed_at`, `takedown_ref` | record index |
| `blob` | `(did, cid)` | `mime_type`, `size`, `temp_key`, `created_at`, `takedown_ref` | blob metadata |
| `record_blob` | `(did, blob_cid, record_uri)` | | **record↔blob references — the lifecycle mechanism §4.4 needs** |
| `backlink` | `(did, uri, path)` | `link_to` | reverse links (who liked/followed what) |
| `account_pref` | `(did, name)` | `value jsonb` | client preferences |

Central tables (upstream's `account.sqlite`) map one-to-one: `account`, `actor`,
`session`/`refresh_token`, `app_password`, `invite_code`, `email_token`, OAuth tables.
Upstream's duplicated `repo_root` in the central DB becomes unnecessary — it is the
same table.

**Every query on account-scoped tables is `did`-prefixed.** Enforce this in the data
layer (a `for_account(query, did)` helper, never bare `Repo.all/1` on these tables)
so one account's data cannot leak into another's response.

**Account deletion** = `DELETE … WHERE did = $1` across these tables inside one
transaction, plus `Aerox.Blob.Store.delete_all(did)` (4.4). Foreign keys with
`ON DELETE CASCADE` from `did` make this one statement per root table.

`repo_block` is the table to watch. Options if it grows past comfort, in order of
preference: (1) `content` on TOAST with `EXTERNAL` storage; (2) declarative
partitioning by hash of `did`; (3) moving cold blocks to a CAR archive per account.
None is needed for launch; R4 tracks it.

### 4.3 Ecto shape

One `Aerox.PDS.Repo` (Postgres). No dynamic repos. Account-scoped schemas carry
`did` as part of their primary key. The Blockstore behaviour's Postgres implementation
is a thin module over `repo_block`; `put_many/1` is a single multi-row insert with
`ON CONFLICT DO NOTHING` (blocks are content-addressed and immutable).

### 4.4 Blobs: a storage adapter, disk first, S3 later

Blob **bytes** never live in Postgres. They live behind one behaviour,
`Aerox.Blob.Store`, with pluggable adapters. Postgres (`blob`, `record_blob`,
`space_blob`) remains the **only source of truth** for what exists and who references
it; the adapter is dumb, content-addressed byte storage with no knowledge of Ecto.

#### The behaviour

Modelled on upstream's `BlobStore` interface, made Elixir-idiomatic. Every call is
scoped by `did` (upstream instantiates one store per actor; we pass the DID instead,
so one adapter process/config serves all accounts):

```elixir
@type key  :: String.t()          # opaque temp key, adapter-defined
@type body :: iodata | Enumerable.t   # binary or a stream of chunks

# two-phase write: stream to temp while the caller hashes; then commit under the CID
@callback put_temp(did, body)                   :: {:ok, key} | {:error, term}
@callback make_permanent(did, key, cid)         :: :ok | {:error, term}
@callback put_permanent(did, cid, body)         :: :ok | {:error, term}   # imports, migrations
@callback has_temp?(did, key)                   :: boolean
@callback has_stored?(did, cid)                 :: boolean
@callback get(did, cid)                         :: {:ok, binary} | {:error, :not_found | term}
@callback stream(did, cid)                      :: {:ok, Enumerable.t} | {:error, term}
@callback quarantine(did, cid)                  :: :ok | {:error, term}   # takedown without deletion
@callback unquarantine(did, cid)                :: :ok | {:error, term}
@callback delete(did, cid)                      :: :ok | {:error, term}   # idempotent: missing = :ok
@callback delete_many(did, [cid])               :: :ok | {:error, term}
@callback delete_all(did)                       :: :ok | {:error, term}   # account deletion
@callback list(did, opts)                       :: Enumerable.t           # for the reaper: cids on the store
@callback presigned_url(did, cid, ttl)          :: {:ok, url} | :unsupported
@optional_callbacks presigned_url: 3
```

Rules every adapter must satisfy (enforced by a shared contract test suite,
`Aerox.Blob.StoreCase`, run against every adapter):

1. **Idempotent.** `put_permanent` of an existing CID is a no-op; `delete` of a missing
   CID is `:ok`. Content addressing makes this safe and it makes the reaper trivial.
2. **Streaming both ways.** `put_temp` consumes a stream so the caller can hash for the
   CID and sniff the mime type in the same pass; `stream/2` returns chunks so
   `getBlob` never buffers a video in memory.
3. **Temp is not durable.** Anything under temp may be swept after a TTL; only
   `make_permanent` promises persistence.
4. **Key layout is `<did>/<cid>`** under three roots: permanent, temp, quarantine.
   Same layout on every adapter so a migration is a key-for-key copy.
5. **No metadata.** Mime type, size, references and takedown state live in Postgres.
   The adapter stores bytes and answers "do I have these bytes".

#### Adapters

| Adapter | Roots | `make_permanent` | `quarantine` | Notes |
|---|---|---|---|---|
| `Aerox.Blob.Disk` (v1) | `blobs/`, `tmp/`, `quarantine/` under one data dir | `File.rename` (same filesystem, atomic) | rename between roots | The whole store is one directory; backup = the directory **with ownership bits** (rice-storage lesson). `presigned_url` → `:unsupported`; the PDS streams |
| `Aerox.Blob.S3` (later) | three key prefixes in one bucket | server-side `CopyObject` to the permanent key, then delete temp (S3 has no rename; multipart copy above 5 GB) | copy between prefixes + delete | S3-compatible (AWS, R2, MinIO); internal traffic on native endpoints, never Cloudflare-fronted. `presigned_url` supported so `getBlob` can redirect instead of proxying |
| `Aerox.Blob.Migrating` | wraps `{from, to}` | writes go to `to`; reads try `to` then `from` | on `to` | Zero-downtime disk→S3 move: switch config to `Migrating`, run a backfill that `put_permanent`s every Postgres-known CID into `to`, then switch to `to`. Never a second source of truth — Postgres decides what should exist |

Libraries for S3 (all current on hex as of 2026-09): `req_s3` 0.2.5 (Req plugin, fits
the existing `req` dependency) or `ex_aws` 2.7.0 + `ex_aws_s3` 2.5.9; `aws_signature`
0.4.3 underneath either. Decide when the S3 adapter is built; the behaviour hides it.

Configuration selects one adapter per PDS instance:

```elixir
config :aerox, Aerox.Blob.Store, adapter: Aerox.Blob.Disk, root: "/var/lib/aerox/blobs"
# config :aerox, Aerox.Blob.Store, adapter: Aerox.Blob.S3, bucket: "...", endpoint: "..."
```

#### Lifecycle: Postgres decides, the adapter obeys, the reaper reconciles

- **Upload** (`com.atproto.repo.uploadBlob`): stream → `put_temp` while hashing →
  insert `blob` row with `temp_key` → `make_permanent(did, key, cid)` → clear
  `temp_key`. A crash between steps leaves either an orphan temp object (swept by TTL)
  or a row with `temp_key` set (retried or expired); never a permanent object Postgres
  does not know about.
- **Reference**: writing a record that embeds the blob inserts `record_blob`. A blob
  with no `record_blob` rows after a grace period is deletable.
- **Delete**: the row goes first (transaction), then `delete/2`. If the adapter call
  fails the reaper retries — the row is already gone, so a retry is idempotent.
- **Reaper** (periodic): `list/2` on the adapter minus CIDs known to Postgres →
  delete orphans; rows whose object is missing → alert (that is data loss, not cleanup).
- **Account deletion**: rows cascade in one transaction, then `delete_all(did)`.
- **Spaces** (§12.3) use the same store and layout; their different lifecycle
  (`space_blob`, `space_record_blob`) is entirely a Postgres matter. Two references
  to the same CID from the public repo and a space share one object — content
  addressing makes that correct.

The yatch failure mode (index on one machine, bytes in S3, machine deleted → unowned
objects) is excluded structurally: the bytes are never authoritative, and the reaper
can always answer "what should exist" from Postgres.

**Two backups, with distinct jobs.** (1) The **physical** backup — Postgres dump plus
the blob store, taken by one script — exists for whole-instance disaster recovery
speed; a dump without the blob store, or the directory without ownership bits, is not a
backup. (2) The **logical** backup is the per-account bundle (§13.0), which is the only
form that is portable and whose restore is drilled (§8 item 6). Both are taken; only
the bundle proves the data can leave.

### 4.5 Signing keys

Each account's secp256k1 private key is stored in the `account` table (`bytea`), not
as a file — with Postgres central there is no per-account directory to put it in.
**Stored in plaintext. Decided 2026-09-09; not an open item.** Rationale: this matches
upstream's at-rest posture (plaintext key files); commit signing and service-JWT
signing (§11.3) are hot paths where per-signature decryption or a KMS round trip
costs latency on every write and every proxied request; and the database's own access
control, disk encryption and backup encryption are the boundary. The column is still
isolated so wrapping it later is a local change.

This is deliberately a different posture from the bundle (§13.0), which is encrypted:
a bundle *travels* between operators and machines; the database does not.

Per-account signing keys are distinct from the instance's **PLC rotation key**, which
is the actually dangerous secret — see §14.

### 4.6 Database topology: the PDS is its own database

**The PDS database is separate from the database used by the other services.**
Minimum topology is two Postgres databases (they may live on one server in dev and
small deployments):

| Database | Ecto repo(s) | Holds |
|---|---|---|
| `aerox_pds` | `Aerox.PDS.Repo` | everything in 4.2–4.5 and the `repo_seq` log (4.7) — user-owned, per-instance data |
| `aerox_core` | `Aerox.PLC.Repo`, `Aerox.Relay.Repo`, `Aerox.AppView.Repo` | network-wide indexes and the identity directory; one Postgres schema per service (`plc`, `relay`, `appview`) so they can be split into separate databases later without code changes |

Reasons for the split, in order of weight (**reordered 2026-09-09** after the
rationale was re-examined; the decision is unchanged, its justification is not):

1. **The cost of getting it wrong is asymmetric, and that is what settles it.**
   Splitting now and merging later is restoring two dumps into one database;
   merging now and splitting later is moving schemas with live data — downtime or
   logical replication. Cheap now, expensive later, exactly the shape of the
   argument in §1 for bit-exact encoding. The remaining reasons are why the option
   is worth holding at all; this is why it is taken *now*.
2. **The two halves have different recovery units.** PDS data is user-owned and
   **not reproducible**; it must be restorable per account. Index data — everything
   in `aerox_core` except the private slice of §8 — is **derivable by replaying the
   firehose**. Separate databases make "restore the PDS, rebuild the index" an
   ordinary operation rather than surgery, and they match the backup story already
   chosen elsewhere: the per-account bundle (§13.0) for the PDS, a physical dump for
   the private slice (§8). Backup cadence, retention and restore drills differ
   accordingly.
3. **The PDS can move to its own server** (or several PDS instances can run, each
   with its own database) without touching the rest. This is the only reason that
   also buys **resource isolation** — see the caveat below.
4. **It enforces §2's service boundaries at the storage layer.** With one shared
   database the tempting shortcut is a SQL join from the AppView into the PDS's
   `record` table. Separate databases make that impossible; the only path between
   services is XRPC (or the firehose), exactly as in a real federated deployment.
   An AppView that only works against *our* PDS's tables is not an AppView. This
   catches what `boundary` (§2) cannot: the compile-time check stops
   `Aerox.AppView` naming `Aerox.PDS.Repo`, but not raw SQL issued through the
   AppView's own repo. It is listed last because it is the reason a cheaper
   mechanism could also have served — see roles, below.

**Two caveats, stated so they are not rediscovered during an incident:**

- **Separate databases on one server buy almost no resource isolation.** They share
  `shared_buffers`, WAL, the checkpointer, autovacuum workers, connection slots, CPU
  and disk. A runaway AppView query on a co-located cluster *can* starve PDS writes.
  Only reason 3 — separate servers — removes that, and until then the mitigation is
  pool sizing and statement timeouts, not the database boundary.
- **Inside `aerox_core` the three schemas are separated by convention only.** The
  same shortcut reason 4 forbids across the PDS boundary (an AppView query joining
  into `relay.*`) is available there, because the three repos connect as one role.
  **Therefore: each service connects as its own Postgres role, with `REVOKE` on every
  schema it does not own.** Applied to all four services, this makes the boundary a
  runtime permission error everywhere, not just at the database edge, and it is the
  cheap complement to the split rather than an alternative to it.

Nothing in the kernel or in service code may assume the two databases are co-located.

**Consequence for Oban (§21.6):** "a job is enqueued in the same transaction as the
business write" is a per-database property, so there are **two Oban instances**, one
per repo, each with its own queues and cron. Enqueuing to the wrong instance silently
gives up the only property Oban was chosen for.

### 4.7 Sequencer storage

The sequencer (§5) needs an **event table** in the same Postgres: `repo_seq(seq
bigint primary key, did, event_type, event bytea, invalidated bool, sequenced_at)`,
indexed by `seq`. Firehose subscribers reconnect with a cursor and replay from it;
`last_seq` is restored from `max(seq)` on start. Assignment of `seq` stays with the
GenServer (§5.2); the table only stores. See §5.3 for why a Postgres `SEQUENCE` must
not replace the GenServer.

---

## 5. Firehose and sequencer

### 5.1 BEAM's biggest structural advantage

The Relay broadcasts events to N subscribers. indigo **wrote a dedicated `splitter`
package for this and deploys it as a separate service, `rainbow`**. In Elixir,
Phoenix.PubSub gives it away for free.

The firehose (`com.atproto.sync.subscribeRepos`) is **a raw WebSocket carrying DAG-CBOR
frames**, not Phoenix Channels. Upgrade directly with `WebSockAdapter` and handle frames
ourselves.

### 5.2 Sequencer: globally unique, strictly monotonic

Every implementation we studied enforces this somewhere — `atproto-crates` even pins
its sequencer backend with a `compile_error!` to guarantee a single writer. Other
languages need an external single point for this; **on BEAM a GenServer is a natural
sequence point**.

### 5.3 Uniqueness across a cluster — and why a Postgres SEQUENCE is not the answer

With Postgres now central (§4.1) the tempting shortcut is `seq BIGSERIAL` and no
GenServer. **Do not.** A Postgres sequence is unique and increasing at *assignment*
time, not at *commit* time: transaction A takes seq 100, B takes 101, B commits first,
a subscriber reads up to 101 and moves its cursor past 100 — then A commits and seq
100 is never delivered. Upstream avoids this only because SQLite has a single writer,
so assignment order equals commit order.

The GenServer therefore stays the sole assigner **and** the sole writer of `repo_seq`
(assign, insert, commit, then broadcast — serialised). Multi-node uniqueness is then
the question of which node hosts that process: `:global` registration (simple; merges
on split-brain) or Horde (controllable; heavier). **Decide before writing any
multi-node code.** A duplicated or regressed seq makes downstream relays and AppViews
**silently drop events**, and reconciliation rarely catches it.

`last_seq` is restored from `max(seq)` in `repo_seq` on start, never from 0.

---

## 6. Lexicon strategy

Settled in discussion on 2026-09-09, superseding an earlier, under-specified
"compile-time code generation" decision (see the decision log).

**Scope rule, stated first: only the generic protocol core (`com.atproto.*`). The
394-schema corpus is not bundled.** The mechanism below is schema-count-agnostic; what changes over time is
the contents of the registry, and that starts small.

### 6.0 What the full corpus looks like (measured, for reference only)

Against `bsky/atproto/lexicons` at commit `f6409dbce` (2026-07-01): 394 files, 841
defs; `app` 157 · `com` 96 · `tools` 76 · `chat` 58 · `site` 6 · `internal` 1. Of the
841 defs only **25 are record types**. 577 refs, **536 cross-file**. 98 unions,
**96 open**. 43 `unknown` positions. String `format`s dominate validation work
(did 214 · datetime 205 · at-uri 111 · cid 56 …), all of which land on
`Aerox.ATProto.Syntax` (§3.10).

Three protocol facts confirmed in upstream code:

1. **`com.atproto.lexicon.schema` exists.** Lexicons can be published as atproto
   records, with a companion `resolveLexicon`. Schemas unseen at compile time are a
   formal protocol feature.
2. **The PDS admits unknown lexicons by default.** `prepare.ts` has a three-state
   `validate`: `false` skips; `true` fails on an unknown lexicon; **unset (default)
   validates known ones and writes unknown ones tagged `validationStatus: unknown`**.
   The whole third-party ecosystem depends on this.
3. **Legacy blobs `{cid, mimeType}` are still accepted on read** (`blob-refs.ts`,
   `untypedJsonBlobRef`, size = -1).

### 6.1 What is in scope

The registry ships with the **whole `com.atproto` namespace — 96 files** — vendored as
one unit. It is the generic protocol layer every service speaks, and it is small enough
that partial inclusion would cost more in bookkeeping than it saves:

| Sub-namespace | Files | Used by |
|---|---|---|
| `com.atproto.server` | 26 | PDS: accounts, sessions, `describeServer` |
| `com.atproto.sync` | 17 | Relay's entire surface; PDS: CAR export, `subscribeRepos` |
| `com.atproto.admin` | 16 | PDS admin endpoints |
| `com.atproto.repo` | 12 | PDS: record CRUD, `applyWrites`, blob upload |
| `com.atproto.identity` | 10 | PDS/PLC: handle and DID resolution and updates |
| `com.atproto.temp` | 7 | transitional endpoints; present for completeness |
| `com.atproto.label` | 3 | label schema and `subscribeLabels` |
| `com.atproto.moderation` | 2 | report creation |
| `com.atproto.lexicon` | 2 | `schema` record type, `resolveLexicon` |

Having a schema in the registry does not obligate an endpoint: routes are declared
explicitly (§2), so `temp`/`admin` schemas can sit unused until needed.

**Spaces adds two more sub-namespaces that are not in our fork or in upstream `main`:**
`com.atproto.space` (20 files) and `com.atproto.simplespace` (8 endpoints), which live
only on upstream's `permissioned-data` branch (PR #5187). They are vendored from that
branch with the branch commit recorded, and re-vendored when the branch moves (§12.6).
The ten `permission-set` lexicons (`app.bsky.auth*`, `chat.bsky.authFullChatClient`)
are also needed for scope evaluation even though `app.bsky.*` is otherwise deferred.

`app.bsky.*` (157 files) is **not** part of this phase. When AppView work begins, only
the subset `ouranos` actually calls is added, one endpoint at a time. `chat.*`,
`tools.ozone.*`, `site.*` and video stay out of scope.

Fact 2 above is what makes the `com.atproto`-only registry viable: a PDS that knows no
`app.bsky.*` schema still accepts and stores every `app.bsky.feed.post` a client writes —
it just tags it `unknown` rather than validating it.

### 6.2 Core decision: an interpreter, not a code generator

Separate **what is generated** from what is not:

- **Validators — not generated.** A runtime interpreter walks the schema data structure.
- **Schema data — embedded at compile time** (`@external_resource` reads each JSON into
  Elixir terms), one module per schema file.
- **Conveniences** (route table, parameter coercion, client functions) — generated as
  thin shells over the interpreter.

Reasons, in order of weight:

1. **Both upstreams do it this way.** TS `@atproto/lexicon` is a runtime `Lexicons`
   class; `lex-cli` only generates types and client methods. indigo's `lexicon` package
   is a runtime `Catalog` + `ValidateRecord`; `lexgen` only generates Go structs and XRPC
   calls. Validation is an interpreter on both sides.
2. **Cross-file refs must not become compile dependencies.** The interpreter resolves
   refs **at runtime by NSID through a registry**; each module depends only on its own
   JSON, and only a changed file recompiles.
3. **Runtime lexicons are a protocol feature** (fact 1). An interpreter takes schemas fed
   in at runtime for free.
4. **Open unions and `unknown` positions make static typing low-yield.** Code handling
   this data faces bare maps regardless.

### 6.3 The registry is an explicit argument — the Blockstore pattern again

```elixir
Lexicon.validate(registry, "com.atproto.repo.strongRef", value)
```

Same reasoning as the MST taking its blockstore explicitly (§3.5): the kernel does no
I/O and is purely testable. The compile-time core forms the default registry; docs
obtained later (by `resolveLexicon`, or by adding `app.bsky.*` files) are merged into
an extended registry outside the kernel and passed in. The kernel never knows where a
doc came from.

**The PDS's three-state `validate` falls straight out of a registry lookup:**
`known?(registry, nsid)` false and `validate != true` → admit and tag unknown.

### 6.4 Each service's stance is fixed

| Service | Stance |
|---|---|
| **Relay** | **Never touches lexicons** (§3.2). CBOR syntax + data model only |
| **PDS** | Validates known, admits unknown with a tag; honours `validate`. **Never rejects a write for an unknown lexicon by default** |
| **AppView** | Validates and indexes known; ignores unknown |
| **PLC** | Not involved — the PLC API is plain HTTP JSON, **not XRPC** |

### 6.5 Value shape: consistent with §3.1, no structs

A validated record is still a **string-keyed map with `$type` as an ordinary field**.
Structs would force map⇄struct conversion and leave open-union branches with no struct
to convert to — two shapes coexisting. Pattern matching on string-keyed maps is adequate.
If a handful of record types prove painful, thin structs for those can be added
**afterwards** at low cost. Tokens are string constants; nothing is generated for them.

### 6.6 Smaller settled points

- **Vendoring is per namespace.** `com.atproto/` is copied into `priv/lexicons/` whole,
  with its source commit recorded; `app.bsky.*` files are copied individually as their
  endpoints are implemented. Copies come from upstream's latest snapshot, not our fork
  (176 commits behind).
- **Legacy blob accepted on read, never produced on write.** Consistent with §8.
- **Validation errors carry a JSON-pointer path**; the XRPC layer maps them to
  `InvalidRequest`.
- **`permission-set` and the `space` def kind are required** (reversed on 2026-09-09):
  OAuth scope evaluation (§11.2) and Spaces (§12) both depend on them. The interpreter
  must understand `type: "permission-set"`, `type: "permission"` with
  `resource: "space"`, and `type: "space"` declarations.
- The interpreter is `Aerox.ATProto.Lexicon`, inside the kernel; **fetching** dynamic
  registries lives outside it.

---

## 7. Correctness verification

**Differential testing is first-class infrastructure, not a supplement.**

Build the golden corpus from day one; every kernel function ships with a set of vectors.

**The corpus must be assembled by hand — the official vectors are thinner than expected.**
Verified: `bsky/atproto/interop-test-files/` holds only 21 files in two categories
(crypto signature / did:key vectors, and valid/invalid syntax for each identifier kind).
**There are no DAG-CBOR, MST or CAR vectors.** Goldens for those three are scattered:

| To verify | Golden source |
|---|---|
| MST determinism (known key set → known root) | `atproto/packages/repo/tests/mst.test.ts`, 8 hard-coded `bafyrei…` roots (e.g. `bafyreie5cvv4h45feadgeuwhbcutmh6t2ceseocckahdoe6uat64zmz454`) |
| CAR read/write, commit proofs | same directory: `car-file-fixtures.json`, `commit-proof-fixtures.json` |
| Data-model valid/invalid values | `indigo/atproto/atdata/testdata/data-model-{valid,invalid,fixtures}.json` + a real `feedpost_record.cbor` |
| Real firehose commits | `indigo/atproto/repo/testdata/firehose_commit_46213*.json` ×3 |
| MST interop | `indigo/atproto/repo/mst/mst_interop_test.go` + `testdata/` |
| Signatures / did:key | `interop-test-files/crypto/` (includes high-S negatives) |
| Identifier syntax | `interop-test-files/syntax/` (16 files) |

Plus real CAR files exported from the `bsky/atproto` dev-env.

**This corpus will be worth more than most of the implementation code** — it is the
only thing that proves we got it right. The full test and verification plan — layers,
oracles, corpus management, CI, drills — is `VERIFICATION.md`.

Acceptance per layer:

| Layer | Acceptance criterion |
|---|---|
| DAG-CBOR | Encoding golden inputs yields bytes identical to `@ipld/dag-cbor` |
| CID | CID strings for golden blocks match exactly |
| MST | Loading a real repo's CAR and recomputing the root equals the commit's value |
| Signing | Golden commit signatures verify; our signatures verify under the TS implementation |
| PLC | All official `did-method-plc` test vectors pass |
| Spaces | LtHash / SpaceCommit vectors from the alpha image match (§12.1) |
| Bundle | Round-trips in §13.3 are byte-identical in `repo_block` |

---

## 8. The no-regret list

Migration from the reference PDS is a goal (§1, §13). The following choices, if made
wrongly, **foreclose it**, and the right choice costs no more — so make it now:

1. **Use the real did:plc algorithm for DIDs.** Do not invent an identifier format.
   Invented DIDs cannot be resolved by any external implementation, nor merged with
   the existing 2008 identities.
2. **Decouple handle domains from the PDS hostname** (cf. `PDS_SERVICE_HANDLE_DOMAINS`).
   Couple them and a domain change means every handle changes; rice logs in via
   `users.handle`, so that is **everyone locked out**. DNS TXT resolution takes
   precedence over HTTPS and removes the need for a wildcard certificate.
3. **Address everything by DID.** Never let an internal auto-increment ID carry meaning.
   Migrated accounts arrive with their own DIDs; the sequence numbers will not line up.
4. **CAR import/export exists from day one.** It is simultaneously the migration tool,
   the backup tool and the differential-test input — three uses, one code path, no extra cost.
5. **Signature algorithms (secp256k1 / P-256) and did:key encoding are irrevocable** — see §3.8.
6. **Every account is exportable as a bundle from day one** (§13.0), and the bundle is
   the format backups are taken in. A backup that is not an importable bundle is not
   a backup.
7. **The PLC and DID-document code must not hard-code the set of verification methods
   and services.** Spaces adds `#atproto_space` (key) and `#atproto_space_host`
   (service) alongside `#atproto` / `#atproto_pds` (§12.4); a PLC that only knows the
   original two cannot host a space authority.

### One fact to know now

**The AppView's private data cannot be rebuilt from PDS repos.**

Upstream `MockBsync`'s `scanMuteOperations` / `scanNotifOperations` / `scanOperations`
all `throw new Error('not implemented')` — it is write-only, with no replayable
operation log. Mutes, bookmarks, drafts, notification priority, activity subscriptions
and age assurance therefore live only in the AppView's own Postgres.

Decided 2026-09-09: **the AppView is rebuildable except for this private slice, and the
private slice is covered by the physical backup of `aerox_core` — no separate export
format.** Restoring an AppView = restore its private tables from the dump, rebuild the
public index by replaying the firehose / `getRepo`. Protocol-level account migration
(Layer A, §13.1) never carried these either, so nothing is lost relative to upstream.

Longer term, **only the subset that is genuinely user-owned private data** (bookmarks,
drafts, per-user mutes) is a candidate for moving into a private Space on the user's
PDS (§12) once Spaces stabilises; operational state such as notification read cursors
stays in the AppView. That is a later evaluation, not a v1 commitment.

---

## 9. Build order

```
kernel → PLC → PDS (public repo + OAuth + mail + rate limits + bundle) → Relay → AppView (+ image CDN) → ouranos
                                            └─ reference-PDS adapter (§13.2)      └─ Labeler / moderation (§17) → PDS Spaces (§12) → bulletin
```

The order is driven by **falsifiability**, not by dependencies:

- **Kernel** first, because it is the only part that can verify itself with zero
  dependencies (§3.5 step 1). Skipping it to write the PDS defers the hardest
  correctness problem to the hardest place to debug.
- **PLC** second: small, self-contained, with official test vectors to diff against.
  The lowest-risk first "complete service".
- **PDS** is the hardest and most central. By then the kernel is proven, and effort
  goes to accounts, storage and the firehose egress.
- **Relay** plays to BEAM's strengths; comparatively light.
- **AppView** is the largest amount of work (most of the 394 lexicons are its read
  path), but its mistakes only mis-render — they never corrupt data. Last.

**ouranos is only meaningful once the AppView runs** — it is a read-only client and sees
nothing until then — **and once the PDS proxy plus service JWTs plus the AppView's DID
and verification are in place (§11)**. `bulletin` additionally needs OAuth and Spaces.

Known issue when wiring ouranos in: `getService()`
(`src/app/api/auth/identity/actions.ts`) discards the handle argument and hard-codes
`https://pds.greenfield.town` (machine decommissioned 2026-08-22). The real
handle→DID→PDS resolution code still exists but only the Atmosphere page uses it;
authentication does not.

---

## 10. Known risks and open questions

### Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **DAG-CBOR encoding not bit-exact**, and the bug never surfaces on a self-consistent network | Golden-file differential tests from day one (§7) |
| R2 | **Pure-Elixir CBOR/hash performance** an order of magnitude behind Go/Rust | Swappable interface; correctness first, performance later (§3.9) |
| R3 | **Sequencer duplicates or regresses across nodes**, downstream silently drops events | Decide the scheme before any multi-node code (§5.3) |
| R4 | **`repo_block` grows into one very large shared table**; hot-account contention and vacuum cost | TOAST `EXTERNAL`, then hash-partition by `did`, then cold-block CAR archive; all deferred until measured (§4.2) |
| R5 | **Blob and index lifecycles diverge**, producing orphans | Deletion must reconcile both sides (§4.3) |
| R7 | **Spaces wire formats change** (alpha, PR #5187 unmerged) and invalidate stored permissioned repos | Own module tree + feature flag; goldens regenerated from the alpha image per re-vendor; public path never depends on Spaces (§12.1) |
| R8 | **Unbounded `space_op` log** while compaction policy is unspecified | Keep everything; measure; revisit when the proposal settles (§12.3) |
| R9 | **Outbound notification delivery** (`notifyWrite`) fails silently or floods | Queue with retry and dead-letter; best-effort by spec, but observable (§12.5) |
| R10 | **OAuth provider is ~13k lines upstream with no Elixir library**; underestimated | Build only the atproto profile (PAR+PKCE+DPoP, client-metadata clients), not general OAuth; consent UI is the only HTML (§11.2) |
| R6 | Lexicon scope creeps toward the full 394-file corpus | Registry holds `com.atproto.*` (96 files) plus the Spaces sub-namespaces from the `permissioned-data` branch and the ten `permission-set` schemas; everything else in `app.bsky.*` is added per endpoint, never in bulk (§6.1) |

### Open

- **When** the existing production deployment is migrated (the design supports it, §13).
- **Cluster uniqueness scheme for the sequencer** (`:global` vs Horde).
- **When to add the S3 blob backend** (only with multi-node PDS, §4.4).
- **Bundle encryption: Option A (`jose` + `:crypto`) vs Option B (Go `age` CLI)** (§13.0).
- **Whether to ultimately replace the greenfield/xjdao stack**, and under what conditions.
- **Metrics and alerting** (LiveDashboard covers dev; production telemetry export is undesigned).
- **Push notification delivery** (tokens stored, no delivery worker; §15.5).
- **Ozone-compatible `tools.ozone.*` API** on the Labeler (§17.3).
- **Automating `_atproto` DNS TXT publication** for hosted handles (§20.1).
- **Which AppView private state moves into a private Space** once Spaces stabilises (§8).

---

## 11. The PDS as the client's single entrypoint: proxying and authentication

Settled in discussion on 2026-09-09.

### 11.1 Clients talk only to the PDS; `app.bsky.*` is proxied

Clients never connect to the AppView directly. Every request goes to the user's PDS,
which either handles it (`com.atproto.*`) or **forwards it** (upstream: `pipethrough`)
to the AppView and returns the response verbatim. The target comes from the
`atproto-proxy: <did>#<serviceId>` header, defaulting to the configured AppView
(`<appview did>#bsky_appview`). Forwarding is by NSID and needs no schema — consistent
with §6's `com.atproto`-only registry.

**Exceptions — `app.bsky.*` endpoints the PDS must serve itself**, because their state
lives in the PDS, not the AppView (upstream does the same):

| Endpoint | Why local |
|---|---|
| `app.bsky.actor.getPreferences` / `putPreferences` | preferences are in `account_pref` (§4.2); Layer A migration step 4 (§13.1) depends on them |
| `app.bsky.notification.registerPush` | push tokens are per device and per PDS |

These few schemas join the registry (§6.1) as explicit exceptions; everything else
under `app.bsky.*` is forwarded.

Consequences already settled elsewhere but restated because they bite here:
- **The AppView must have its own DID** (`did:web:<host>`) and signing key; without
  them nothing can address it (`aud`) or verify it. The greenfield stack died on exactly
  this (`../../bsky/index.md`).
- **The AppView must resolve DIDs** (to verify service JWTs) — the out-of-kernel
  `Aerox.Identity` resolver with cache is a hard dependency of the AppView, not a
  convenience.

### 11.2 Client authentication: atproto OAuth from day one, plus legacy sessions for `ouranos`

**Decision: implement atproto OAuth in v1.** Not optional, because Spaces (§12) is built
on OAuth `space:` scopes, DPoP and client-metadata documents; there is no
app-password path into permissioned data.

What atproto OAuth requires of the PDS as authorization server (from the spec at
`atproto-website/.../specs/oauth` and upstream `@atproto/oauth-provider`, ~13.3k lines TS):

| Requirement | Note |
|---|---|
| `client_id` is a URL to a **client metadata document**; no client secrets | PDS fetches it (hardened HTTP client, cached, short TTL) — I/O outside the kernel |
| **PAR and PKCE required** for all clients | `POST /oauth/par` |
| **DPoP with mandatory server-issued nonces** on token and resource requests | Verification shared with Spaces credentials (§12.4) |
| Confidential clients authenticate with `private_key_jwt` against their published JWKS | Longer token lifetimes than public clients |
| Consent UI | **This is the "one or two HTML pages" the `:browser` pipeline exists for (§2)** |
| HTTP surface | `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource`, `/oauth/{par,authorize,token,revoke,introspect,jwks,logout}` |
| Scope grammar | `atproto`, transitional `transition:{generic,chat.bsky,email}`, granular `repo:`/`rpc:`/`blob:`/`account:`/`identity:` scopes, `include:<permission-set nsid>`, and `space:<type>?authority=&skey=&collection=&action=&manage=` (§12) |
| Storage | authorization requests, device/session records, tokens, used refresh tokens, authorized clients — upstream's `account-manager` tables map one-to-one into `aerox_pds` |

**No Elixir library covers this.** Checked on hex: `boruta` (3.0.0-beta, OIDC provider),
`ex_oauth2_provider`, `authable` — none implement DPoP, PAR-only flows or client-metadata
documents. Use `joken`/`jose` for JWT and JWK primitives and build the provider.

**Scope evaluation is its own module** (`Aerox.Auth.Scopes`), mirroring upstream's
`@atproto/oauth-scopes`: parse the granted scope string, resolve `include:` against
`permission-set` lexicons in the registry, and answer "may this token do X on Y".
It is pure and belongs in or next to the kernel; §12 depends on it.

**Legacy sessions stay.** `ouranos` logs in with `agent.login()` =
`com.atproto.server.createSession` (identifier + password → access/refresh JWT), and
has no OAuth client. So `createSession` / `refreshSession` / `deleteSession` and app
passwords are implemented too — they are small, and `ouranos` is the public-read-path
test client. Upstream's `AuthScope` set (`access`, `refresh`, `appPass`,
`appPassPrivileged`, `signupQueued`, `takendown`) is adopted as-is.

### 11.3 Inter-service auth: service JWTs

When proxying, the PDS proves "user X initiated this" by signing a short-lived JWT
with **that user's repo signing key** (§4.5): `iss` = user DID, `aud` = AppView DID,
`lxm` = the NSID being called, ~1 minute validity. The AppView resolves `iss` and
verifies. The same mechanism carries Spaces notifications (`notifyWrite`) and
managing-app callbacks.

Two consequences:
- **§3.8 signing is on the request hot path**, far more often than commit signing.
  This is the first place the pure-Elixir-first policy (§3.9) will be tested.
- **No read-after-write.** Upstream implements a few `app.bsky.*` routes locally only
  to patch AppView responses with not-yet-indexed local writes
  (`pipethroughReadAfterWrite`). v1 is pure pass-through; on a single-host stack the
  indexing lag is milliseconds.

---

## 12. Permissioned data (Spaces, proposal 0016)

**Requirement added 2026-09-09: aerox must support Spaces.** Sources: the proposal
(`github.com/bluesky-social/proposals/tree/main/0016-permissioned-data`), the alpha
announcement (`atproto.com/blog/atproto-spaces-alpha`), upstream branch
`permissioned-data` (PR #5187), and the local reference app `../../bsky/bulletin`.

### 12.1 Status, and what it means for a "production" implementation

The alpha announcement says, verbatim, **"THIS IS ALPHA SOFTWARE DO NOT USE IT IN
PRODUCTION"** and that data "may be deleted without warning". PR #5187 is unmerged;
the proposal lists open questions (oplog compaction, notification delivery guarantees,
blob GC, `applyWrites` atomicity, credential caching, quotas). **Wire formats may still
change.**

This collides with §1's bit-exact rule only in appearance: bit-exactness is about
matching *whatever the reference emits*, and the reference exists — the alpha image
`ghcr.io/bluesky-social/atproto:pds-spaces-alpha` is the oracle. The consequences are
operational, not architectural:

- Spaces lives in its **own module tree** (`Aerox.ATProto.Space.*`, `Aerox.PDS.Space.*`)
  and behind a **feature flag**, so a spec change is contained.
- Golden files for Spaces are regenerated from the alpha image on each re-vendor; they
  are expected to churn.
- The public-repo path (§3–§5) must never depend on Spaces code.

### 12.2 A second repository format — not the MST

A permissioned repo is one per `(user, space)`, stored on the user's PDS, and is
**not** part of the public MST repo. Its integrity model is different:

| | Public repo | Permissioned repo |
|---|---|---|
| Digest | MST root CID | **LtHash**: 2048-byte state (1024 × uint16 lanes), element key `{collection}/{rkey}/{cid}` expanded with BLAKE3-XOF, add/remove mod 2¹⁶ — commutative, order-independent |
| Commit | `{did, version, data, rev, prev, sig}` | `com.atproto.space.defs#signedCommit`: `{ver: 1, hash, ikm, sig, mac, rev}` — `sig` over space/author/rev/ikm, `mac` = HMAC-SHA256(HKDF-Expand(ikm, context), hash). **Deniable**: a rebroadcast proves nothing |
| Index | MST nodes | DRISL: a DAG-CBOR map `path → CID` |
| Serialisation | CAR, one root | CAR with two roots (commit, index) + record blocks |
| Sync | firehose | `listRepoOps` since `rev` (incremental) / `getRepo` (full recovery) |
| Public visibility | firehose | **excluded from `subscribeRepos` entirely** |

Kernel additions (pure, golden-tested like everything else in §3):
`Aerox.ATProto.Space.LtHash`, `.SpaceCommit` (sign/verify/mac), `.OpLog`, and a CAR
variant with two roots. BLAKE3 on hex: `b3` 0.2.1 (pure Elixir) and `blake3` 1.0.2
(Rust NIF) — same policy as §3.9, pure first; `hkdf` 0.3.0 for the MAC key.

### 12.3 Storage: separate tables in `aerox_pds`, never in `repo_seq`

Per `(did, space_uri)`: `space_repo` (current signed commit, LtHash state, `rev`),
`space_record` (`(did, space, collection, rkey) → cid`, content), `space_op` (the
operation log `{rev, collection, rkey, cid|null, prev}` for `listRepoOps`),
`space_blob` / `space_record_blob` (same lifecycle rules as §4.4), plus the space
authority's tables for `simplespace` (space config, policy, member list, app-access
list, notify registrations).

**Permissioned writes must never enter `repo_seq`** or reach the firehose. Enforce this
structurally: the Space write path has no reference to the sequencer.

Oplog retention (compaction) is an open question in the proposal; we keep everything
until it is settled (R8).

Space **sync** on the consuming side (`listRepoOps` incremental, `getRepo` recovery,
`notifyWrite` triggers) is pull-based work keyed by `(space, repo)`: it is modelled as
Oban jobs with per-key uniqueness and retry (§21.6), not as a stream pipeline.

### 12.4 Authentication: three JWTs and DPoP, shared with OAuth

| Token | Issuer → holder | Key | Lifetime |
|---|---|---|---|
| Delegation token (`atproto-space-delegation+jwt`) | user's PDS → app | user's `#atproto` key (§4.5) | single use, ~60 s; `sub` = space URI, `aud` = authority's `#atproto_space_host` |
| Client attestation (`atproto-client-attestation+jwt`) | app → space authority | app's published JWKS (`private_key_jwt` shape) | only when the space gates on app identity |
| Space credential (`atproto-space-credential+jwt`) | space authority → app | authority's `#atproto_space` key (fallback `#atproto`) | multi-use, ~2 h, **no `aud`**, `cnf.jkt` bound to the app's ephemeral DPoP key |

Every repo-host request then carries a DPoP proof (`ath`, `htm`, `htu`, `jti`
uniqueness). **The DPoP verifier is one module shared by OAuth (§11.2) and Spaces** —
the single strongest reason OAuth and Spaces are designed together.

The authority's DID document needs `#atproto_space` and `#atproto_space_host`; our PLC
must accept them (§8 item 6).

### 12.5 Endpoints: three roles, all inside the PDS

The proposal splits ~34 endpoints across roles; a PDS plays all three:

- **PDS role** (the user's home): `getDelegationToken`, `createRecord`, `putRecord`,
  `deleteRecord`, `applyWrites`, `listSpaces`.
- **Repo-host role** (serving one user's permissioned repo): `getRecord`,
  `listRecords`, `getBlob`, `listBlobs`, `getLatestCommit`, `getRepo`, `listRepoOps`.
- **Space-host role** (the authority's PDS): `getSpaceCredential`, `listRepos`,
  `registerNotify`, `unregisterNotify`, `notifyWrite`, `notifySpaceDeleted`.
- **`com.atproto.simplespace`** (mandatory management handler): `createSpace`,
  `updateSpace`, `deleteSpace`, `getSpace`, `addMember`, `removeMember`, `listMembers`,
  `checkUserAccess` (defers to a managing app).

Policies: `member-list` (default), `public`, `managing-app`; app access: `#open` or
`#allowList`. Both must pass before a credential is issued.

**Notifications are outbound HTTP from the PDS** (`notifyWrite` to registered
endpoints, best effort, signed with a service JWT). That is a new kind of side effect
for the PDS — it needs a queue with retry and a dead-letter policy (R9).

### 12.6 Lexicons and test client

The `com.atproto.space` (20) and `com.atproto.simplespace` schemas exist only on the
`permissioned-data` branch; `bulletin` vendors a partial subset (10 + 3). Vendor the
full set from the branch with the commit recorded (§6.1). Scope grammar and
`permission-set` handling follow `@atproto/oauth-scopes` at the alpha version
`bulletin` pins (`0.0.0-spaces-alpha-20260818163953`).

**`bulletin` is the Spaces test client** — the counterpart of `ouranos` for the public
path. It requires an OAuth login (`@atproto/oauth-client-node`, scope
`atproto blob?… include:my.bulletin.permissions`) and calls
`app.bsky.graph.getRelationships` on an AppView to decide follower/mutual access. So
running `bulletin` end-to-end needs OAuth (§11.2), Spaces (this section) **and** at
least that one AppView endpoint.

### 12.7 Effect on the build order (§9)

Spaces is a **second phase of the PDS**, after the public-repo PDS and its OAuth
provider work, and before or alongside the AppView. Its kernel pieces (LtHash,
SpaceCommit) are golden-tested against the alpha image before any endpoint is written,
exactly as the MST was (§3.5 step 1).

---

## 13. Data portability: import and export

Settled in discussion on 2026-09-09. **Core requirement:** an account's data moves
losslessly (a) between aerox service providers, (b) from a Bluesky reference PDS into
aerox, and (c) from aerox back to a reference PDS. The protocol-level flow (13.1) is
what users can do on their own; everything else is built around one interchange
format (13.0) with adapters.

### 13.0 The portable account bundle — one format, every direction

Rather than N×N converters (aerox↔aerox, aerox↔bsky-SQLite, aerox↔protocol), there is
**one canonical interchange format** and every storage is an adapter to and from it:

```
                 ┌──────────────────────┐
  aerox PG  ───▶ │                      │ ◀───  reference-PDS SQLite dir
            ◀─── │   account bundle     │ ───▶
                 │  (directory or tar)  │
  protocol  ───▶ │                      │        (Layer A produces a *partial* bundle:
  (Layer A)      └──────────────────────┘         repo + blobs + prefs, no secrets)
```

Bundle layout, one per account (an instance export is a directory of bundles plus an
instance manifest):

```
<did>/
  manifest.json      bundle_version, did, handle, source {impl, version, host},
                     created_at, counts {records, blocks, blobs, seq_events},
                     hashes {repo_car sha256, per-blob CID list, account.json sha256}
  account.json       email, email_confirmed_at, password_scrypt, invites_disabled,
                     created_at, takedown_ref, deactivated_at, delete_after,
                     app_passwords[], invite_codes[], preferences[]
  signing.key        raw 32-byte secp256k1 private key
  repo.car           the repo exactly as `com.atproto.sync.getRepo` returns it —
                     commit + every block, bit-exact, the same CAR a stranger's PDS accepts
  state.json         what the CAR cannot express: per-record {takedown_ref, indexed_at},
                     per-blob {mime_type, size, takedown_ref, created_at}
  blobs/<cid>        blob bytes; quarantine/<cid> for taken-down blobs
  seq.car            optional: the account's firehose events (DAG-CBOR frames) for
                     cursor continuity on takeover
  spaces/            reserved (§12); empty until the reference Spaces storage stabilises
```

Design rules:

1. **`repo.car` is the repo.** Not a table dump — the CAR is already the protocol's
   own portable, verifiable, bit-exact representation, and any PDS anywhere can
   ingest it via `importRepo`. `repo_root`, `repo_block`, `record`, `record_blob` and
   `backlink` are all *re-derived* from it on import (block bytes stay verbatim because
   the CAR carries them verbatim); only the per-record and per-blob state the CAR
   cannot express travels in `state.json`. Importing a bundle therefore exercises the
   kernel's CAR reader and MST verifier (§3.5 step 1) on every account — the import is
   a test. Repos must be `version: 3` (§3.6); the importer refuses anything else.
2. **Everything Layer A loses is in `account.json` and `signing.key`.** Secrets are
   carried verbatim so that neither passwords nor DID documents change on migration.
3. **Secrets mean the bundle is sensitive.** It contains password hashes and private
   keys, so bundles are written **encrypted at rest**, and the tool refuses to write a
   plaintext bundle outside an explicit `--insecure-plaintext` flag for air-gapped hosts.

   **The encryption scheme is not yet decided.** Two candidates are on the table;
   evaluation is deferred until the bundle format itself is implemented. Both must
   satisfy the same contract: recipient-public-key and passphrase modes, streaming
   for multi-GB files, authentication that fails on truncation or reordering.

   **Option A — in-process, standard primitives from libraries we already carry**
   (surveyed hex 2026-09-09: the only Elixir `age` port is a single 2023 release with
   17k downloads and is not considered established):
   - One random 256-bit **content key per bundle**.
   - The content key is wrapped as a **JWE** using `jose` (1.11.12, 112M downloads,
     already required by OAuth §11.2): `ECDH-ES+A256KW` to one or more recipient
     X25519/P-256 public keys (provider-to-provider transfer), and/or
     `PBES2-HS512+A256KW` for a passphrase (operator backups). Multiple recipients =
     multiple JWE recipients; the wrapped key lives in `manifest.json`.
   - Each file body is encrypted **in chunks with OTP `:crypto` AES-256-GCM** under the
     content key (per-chunk nonce = file id ‖ chunk counter, chunk index and file id
     bound as AAD), so multi-GB `repo.car` and video blobs stream without buffering
     and any truncation or reordering fails authentication.
   - The manifest itself is signed (JWS, same `jose`) with the exporting instance's
     key, so a receiver can verify origin before decrypting anything.

   In Option A, JWE only ever protects the 32-byte content key (and JWS the manifest);
   large files never pass through JWE, which is neither streaming nor chunk-authenticated.

   **Option B — shell out to the Go `age` CLI.** The bundle is written by `age`
   (`-r` recipients / `-p` passphrase, streaming, chunked STREAM authentication built
   in) and read the same way. Pros: a widely audited format that any operator can
   decrypt without aerox, zero crypto code of our own. Cons: a required external
   binary on every host that exports or imports, version drift between hosts, and
   process-management around a pipe for multi-GB streams.

   Whichever is chosen, the bundle layout (13.0) and the verification suite (13.3)
   do not change; only the wrapper around file bodies does. `kcl` 1.5.1 (pure-Elixir
   NaCl) remains a fallback for Option A if a libsodium-shaped API is preferred.
4. **Versioned.** `bundle_version` starts at 1; readers reject unknown major versions
   and tolerate unknown files. Adding `spaces/` later is a minor bump.
5. **Verifiable without trust.** Every hash in the manifest can be recomputed by the
   receiver before anything touches the database; the checks in 13.3 run against the
   bundle first, then against the imported result.
6. **Same DID, same key, same handle** by default. A provider-to-provider move with the
   hostname changing still needs one PLC op per account (`#atproto_pds`), which the tool
   lists and never submits (13.5). With the hostname kept (DNS or proxy moved to the
   new provider) there is no PLC op at all.

Adapters:

| Adapter | Direction | Notes |
|---|---|---|
| `Aerox.Interop.Bundle.Postgres` | aerox PG ⇄ bundle | the native one; exports stream `repo.car` from `repo_block` via the kernel's CAR writer |
| `Aerox.Interop.Bundle.ReferencePds` | reference-PDS `<data>` dir ⇄ bundle | reads/writes `account.sqlite` + `actors/*/store.sqlite` + `key` + `blobs/`; tool-only `exqlite` dependency (13.2) |
| `Aerox.Interop.Bundle.Protocol` | live PDS → partial bundle | Layer A over the network for any third-party PDS; produces a bundle without secrets that imports as a *deactivated* account awaiting the user's PLC step |

**aerox → aerox** is therefore `export` on one provider, transfer the encrypted bundle
directory, `import --takeover` on the other. **bsky → aerox** is the `ReferencePds`
adapter feeding the same import. **aerox → bsky** is the same bundle written out by
the `ReferencePds` adapter. There is exactly one import path and one verification
suite, whatever the source.


### 13.1 Layer A — protocol-level account migration (what the protocol already provides)

The protocol defines account migration between *any* two PDSes. It is what a user (or
an operator holding the user's credentials) runs; it needs no access to either PDS's
storage. Steps and endpoints, from `atproto-website/.../guides/account-migration`:

| Step | Endpoints | Moves |
|---|---|---|
| 1. Create the account on the new PDS **with the existing DID** | `getServiceAuth` (old PDS, `aud` = new PDS) → `createAccount` (new PDS, deactivated) | identity |
| 2. Repo | `sync.getRepo` (old) → `repo.importRepo` (new, CAR body) | all records, MST, commit history |
| 3. Blobs | `sync.listBlobs` / `repo.listMissingBlobs` (new) → `sync.getBlob` (old) → `repo.uploadBlob` (new) | blob bytes, one by one |
| 4. Preferences | `app.bsky.actor.getPreferences` → `putPreferences` | client prefs |
| 5. Identity | `identity.getRecommendedDidCredentials` (new) → `requestPlcOperationSignature` / `signPlcOperation` (old) → `submitPlcOperation` (new) | PLC op: new PDS endpoint, **new signing key**, new rotation keys |
| 6. Finalise | `server.activateAccount` (new) → `deactivateAccount` (old); `checkAccountStatus` to compare `repoCommit/repoRev/repoBlocks/indexedRecords/expectedBlobs/importedBlobs` | |

**What Layer A does not move — and why the bundle (13.0) and its adapters exist:**
password hash, email and confirmation state, app passwords, invite codes, sessions,
takedown / deactivation state, the sequencer history (`repo_seq`), the original signing
key (a new one is minted), backlinks (derived). It also requires the user's password
or a per-account service token, touches PLC once per account (which for our 2008
production identities means the sole rotation key — see below), and is slow for blobs.

**Existing greenfield tooling, all Layer-A-shaped or file-copy-shaped**
(from the deployment notes, not from this repo):
- `xjdao-deploy/scripts/`: `plc_claim.js → mirror_account.sh → backfill_appview.js`,
  driven by `mirror_all.sh` — copies actor directories and the 32-byte `key` file,
  then forces the AppView to index (`indexRepo` + `indexHandle` + `updateActorStatus`).
  2027 accounts in ~5 minutes on 2026-08-21.
- The `xjdao.generic.dev` loader — replays every record through `createRecord` on the
  target (3 accounts/s when run *on the target machine*; 300× slower driven over SSH).
- `pdsadmin account.sh` — create / delete / takedown / reset-password / list.
- The only authoritative source for handles and DIDs is the PDS's own
  `account.sqlite` (`select did, handle from actor`), not any downstream copy.

Lessons already paid for and binding on §13.3:
1. **Insert-only import cannot be re-run.** Mutable rows must upsert, or a re-import
   must start from a cleared target.
2. **Progress state must live in the target database**, not in a file that survives
   a `destroy` (the `did-map.json` incident: 2027 accounts silently skipped).
3. **Reconcile against the snapshot's own numbers**, never against live production.
4. **Stop the source or take a consistent snapshot** before copying SQLite files
   (WAL); copying live files risks torn reads and "accounts still there after rm -rf".
5. **Handle domains must stay identical** (`PDS_SERVICE_HANDLE_DOMAINS`), or nothing
   downstream that logs in via handle works.
6. **Run the loop on the target machine.**

### 13.2 The reference-PDS adapter: SQLite `<data>` directory ⇄ bundle

Purpose: read a reference-PDS deployment into bundles (take-over) or write bundles
out as a reference-PDS `<data>` directory (hand-back), offline, moving *everything* —
including secrets and firehose history — without a PLC operation when the hostname is
kept, and without any per-user credential. The mapping below is between the reference
layout and the bundle; the Postgres side is the bundle import in 13.0.

The reference PDS's on-disk layout (upstream `packages/pds`):

```
<data>/
  account.sqlite                          account, actor, app_password, invite_code,
                                          invite_code_use, email_token, refresh_token,
                                          token, device, authorization_request, …
  sequencer.sqlite                        repo_seq(seq, did, eventType, event, invalidated, sequencedAt)
  did_cache.sqlite                        (skip)
  actors/<sha256(did)[0:2]>/<did>/store.sqlite   repo_root, repo_block, record, blob,
                                                 record_blob, backlink, account_pref
  actors/<…>/<did>/key                    32-byte secp256k1 private key
  blobs/<did>/<cid>   tempt/   quarantine/
```

#### Mapping (reference layout → bundle; the Postgres side is the bundle import, 13.0)

| Reference PDS | Bundle | Notes |
|---|---|---|
| `account` (`did, email, passwordScrypt, emailConfirmedAt, invitesDisabled`) | `account.json` | **`passwordScrypt` copied verbatim.** aerox implements the same verifier (Node `crypto.scrypt(password, salt, 64)`, default N=16384/r=8/p=1, upstream's `salt:hash` encoding) so no one changes a password. Settled: §13.4 |
| `actor` (`handle, createdAt, takedownRef, deactivatedAt, deleteAfter`) | `account.json` | verbatim |
| `app_password` | `account.json` | scrypt, verbatim |
| `invite_code`, `invite_code_use` | `account.json` | verbatim |
| `refresh_token`, `token`, `device`, `authorization_request`, `authorized_client`, `used_refresh_token` | **not imported** | Sessions are invalidated; users log in again. Copying live OAuth/DPoP state across implementations is not worth the risk |
| `email_token` | not imported | ephemeral |
| `repo_seq` | `seq.car` | **imported in takeover mode**, `event` bytes verbatim (they are DAG-CBOR frames); downstream relay/AppView cursors then continue unbroken. Optional otherwise — a fresh sequencer means relays re-crawl |
| `actors/…/key` | `signing.key` | raw 32 bytes → same DID document, **no PLC op needed** |
| `store.sqlite` `repo_root` + `repo_block` | `repo.car` | written by the kernel's CAR writer from the **verbatim block bytes**; the reader then re-derives every table (13.0 rule 1). Recomputing the MST root from those blocks must equal `repo_root.cid` — the takeover is bit-exact and a kernel test at once |
| `record.takedownRef/indexedAt`, `blob.*` metadata | `state.json` | the only per-record/per-blob state not in the CAR |
| `record_blob`, `backlink` | *(not carried)* | re-derived from the records on import |
| `account_pref` (`name, valueJson`) | `account.json` `preferences[]` | |
| `blobs/<did>/<cid>` | `blobs/<cid>` | `quarantine/<did>/<cid>` → `quarantine/<cid>`; the import feeds `Aerox.Blob.Store.put_permanent/3`, adapter-agnostic (§4.4) |
| `tempt/`, `did_cache.sqlite` | skipped | |

Export is the exact inverse, producing a `<data>` directory a **stock reference PDS
image** (`ghcr.io/bluesky-social/pds:0.4`) boots from. The one non-obvious part:
each SQLite file carries upstream's Kysely migration table, and the rows must match
the target PDS version's expected migration names or it will try to re-migrate.
The exporter is therefore **pinned to one upstream version** and refuses others.

#### Tooling shape

- Mix tasks: `mix aerox.bundle.export` / `mix aerox.bundle.import [--takeover]` (bundle
  ⇄ Postgres, always available) and `mix aerox.interop.from_pds --data <dir>` /
  `mix aerox.interop.to_pds --data <dir> --pds-version 0.4.x` (bundle ⇄ reference
  layout). The latter two live in the same codebase but behind `MIX_ENV=tool`: `{:exqlite, "~> 0.40", only: [:dev, :test, :tool]}`
  so production releases (`MIX_ENV=prod`) never contain a SQLite driver. (Shelling out
  to the `sqlite3` CLI was rejected: `bytea` round-tripping through text is exactly the
  kind of silent corruption we are trying to exclude.)
- **Runs on the target machine**, reading the source directory from a consistent
  snapshot (`sqlite3 <db> ".backup <copy>"` or a stopped source).
- **Resumable and idempotent.** Progress in an `interop_progress(did, phase, done_at,
  error)` table *in `aerox_pds`*; the bundle import upserts every mutable row
  (`repo_root`, `actor`, `account`, `account_pref`) with `ON CONFLICT DO UPDATE` and
  inserts blocks with `ON CONFLICT DO NOTHING`. A re-run converges; it never silently
  keeps stale rows.
- **Per-account transaction.** An account is imported atomically or not at all; a
  half-imported account cannot be observed by the running PDS.
- **Permissioned repos (§12) are not yet carried by the bundle** (`spaces/` is
  reserved) until the reference implementation's Spaces storage stabilises. Until
  then portability is lossless for the public repo and account state only — a known
  gap against the §1 requirement.

### 13.3 Verification — the part that is not optional

Per account, after import (and symmetrically after export, by booting the stock image
on the exported directory):

| Check | Passes when |
|---|---|
| MST root | root recomputed from the blocks in `repo.car` == the CAR's commit `data`, and after import == `repo_root.cid` |
| Counts | records, blocks, blobs, `record_blob` rows equal the snapshot's own counts (recorded at snapshot time) |
| `checkAccountStatus` | every field equal between source snapshot and aerox |
| `getRepo` | block *set* and commit identical (block order in CAR may legitimately differ) |
| Blob bytes | sha256 of each stored object == its CID multihash |
| Login | `createSession` with a known test password succeeds (scrypt compatibility) |
| Sequencer (takeover) | `max(seq)` and the last event's bytes equal the source |

A whole-run summary is compared to the snapshot baseline; any account failing any
check is listed by DID. **"0 accounts, 0 records, 0 failures, completed in 2 minutes"
is a failure signature, not a success** (the did-map incident) — the tool refuses to
exit 0 when it imported nothing from a non-empty source.

**Round-trip tests are part of CI:** PG → bundle → PG must be byte-identical in
`repo_block` and equal in every table; PG → bundle → reference-PDS dir → boot the
stock image → `getRepo` must return the same block set and commit; and the reverse.

### 13.4 Two things this design forces on the rest of aerox

1. **Password hashing must be scrypt-compatible with upstream** (§13.2). aerox may
   hash *new* passwords however it likes only if it can still verify upstream's format;
   the simplest correct choice is to adopt upstream's scheme outright.
2. **Downstream is not migrated by a bundle import.** After a storage-level takeover the
   AppView has indexed nothing. Either the imported `repo_seq` is replayed to it
   (takeover mode), or an AppView backfill (the equivalent of upstream's
   `indexRepo` + `indexHandle` + `updateActorStatus`) is run per account. The timeline
   being empty after a "successful" migration was the first thing that went wrong last
   time; it is a listed step here, not an afterthought.

### 13.5 Where the danger is: PLC

Layer B with the **same hostname** needs no PLC operation at all — same DID document,
same signing key, same service endpoint. That is the recommended takeover shape.

With a **different hostname**, each account needs one PLC op changing
`#atproto_pds`, signed by a rotation key. For the existing production identities that
is the single rotation key controlling all 2008 DIDs, and PLC is append-only: one
operation sent to the wrong directory re-points every identity at once and cannot be
deleted. The interop tool therefore **never submits PLC operations**; it emits the list
of accounts needing one, and that step is run separately with the safeguards already
established (hard-coded target, pre-flight assertion, operation-count check before and
after).

---

## 14. Identity: PLC rotation keys, recovery, and `did:web`

Settled in discussion on 2026-09-09. Designed from upstream's behaviour
(`packages/pds`: `createAccount.ts`, `getRecommendedDidCredentials.ts`,
`signPlcOperation.ts`, `config/secrets.ts`, and `@atproto/aws` `KmsKeypair`).

### 14.1 What upstream does, and the single point it creates

When a reference PDS creates a `did:plc` account it writes the DID document's
`rotationKeys` as, in priority order (index 0 strongest):

```
[ user recoveryKey (optional, from createAccount input),
  instance recovery did:key (optional, PDS_RECOVERY_DID_KEY),
  instance PLC rotation key (always, PDS_PLC_ROTATION_KEY_*) ]
```

and signs the genesis operation with the **instance rotation key**. The same key is
what `getRecommendedDidCredentials` recommends when an account migrates *in*, and it
is what upstream uses to tombstone a DID on failed signup. Upstream can hold that key
either as a raw hex secret (`PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX`) or in **AWS
KMS** (`PDS_PLC_ROTATION_KEY_KMS_KEY_ID`, `KmsKeypair`, secp256k1, `ECDSA_SHA_256`).

User-initiated PLC changes (`identity.signPlcOperation`) are gated by an **email
token** with purpose `plc_operation`, and the PDS signs them with the instance key.

Consequence: **one instance key can re-point every identity the instance ever created.**
That is exactly the position of the current production deployment (one rotation key
over 2008 DIDs, PLC append-only, 72-hour recovery window; see `../../bsky/index.md`).
This is the most dangerous secret in the system — far more than per-account signing
keys (§4.5), which each control one repo.

### 14.2 aerox's design

1. **Same key layout as upstream — it is protocol-visible and migration depends on it.**
   Imported accounts arrive with upstream's `rotationKeys` in their DID documents; if
   aerox is to sign PLC operations for them it must hold *that* instance key
   (`bundle`/takeover imports it as an instance secret, not per account). New accounts
   get the same three-slot layout so behaviour is uniform.

2. **The instance rotation key is never a plaintext column or env var in production.**
   It lives behind a `Aerox.Crypto.Signer` behaviour with three implementations:
   `Local` (raw key; dev and test only), `Kms` (AWS KMS asymmetric secp256k1, matching
   upstream so a migrated deployment can keep its existing KMS key), and `Remote` (a
   separate tiny signing service holding the key on another host, for non-AWS
   deployments). Production configuration refuses `Local`. The signer exposes
   `sign/2` and `did_key/1` only — the private key never enters the PDS process.

3. **A separate instance recovery key at index 1, kept offline.** Upstream supports it
   (`PDS_RECOVERY_DID_KEY`); we make it mandatory in production. It never touches a
   server: generated on an air-gapped machine, public `did:key` configured, private
   half in cold storage. Its only job is the 72-hour window: if the online rotation
   key is misused, the offline key (higher priority) nullifies the bad operations.
   This is the control the current production deployment lacks.

4. **Users may add their own recovery key at index 0** (upstream's `recoveryKey`
   input), and the OAuth consent/account pages expose it. Recommended, not required.

5. **PLC operations are signed only through two paths**: the user's email-token-gated
   `signPlcOperation` flow, and the migration tool's *listing* (§13.5) executed by an
   operator with the pre-flight checks. No other code path may call `Signer.sign/2`
   with a PLC operation; this is enforced by a single `Aerox.PLC.Ops` module being the
   only caller, and by an audit table `plc_op_audit(did, cid, purpose, actor, at)`
   written in the same transaction.

6. **Operation-count invariant.** Any batch that signs PLC operations records the
   target directory's operation count before and after and fails loudly on any
   mismatch other than its own additions — the safeguard already used in production.

7. **Our own PLC directory** (§2) honours the standard semantics: priority by index,
   72-hour nullification window, `nullified` visible in `/log/audit`, and
   `removeInvalidOps` as an admin-only, audited, alerting operation — never routine.

### 14.3 `did:web` accounts — supported

Decided: aerox supports `did:web` accounts as well as `did:plc`. Upstream's model is
adopted: a user *brings* a `did:web` (there is no creation flow — the user controls the
web host), and `createAccount` with an existing DID validates the resolved DID document
against the PDS: handle matches, `#atproto_pds` service equals this PDS, signing key
equals the key this PDS holds for the account (`validateAtprotoData` in upstream).

What differs from `did:plc`, and must be handled explicitly:

| Concern | `did:plc` | `did:web` |
|---|---|---|
| Who edits the DID document | PDS via PLC ops (§14.2) | **the user**, on their web host; the PDS only tells them what to put there (`getRecommendedDidCredentials`) |
| `updateHandle`, key rotation, migration step 5 | PLC op | return the recommended document and wait; the PDS re-resolves and verifies |
| Rotation keys / recovery window | yes | **none** — no 72-hour safety net; loss of the domain is loss of the identity. Documented in the signup UI |
| Resolution | PLC directory (§2) | HTTPS `/.well-known/did.json` via `Aerox.Identity` (outside the kernel, §3.0), cached with short TTL |
| Migration (§13) | needs a PLC op only if the hostname changes | never needs a PLC op; needs the user to update `did.json` instead — the bundle import marks the account *pending identity update* until resolution matches |

Services (PDS, AppView, Relay, PLC itself) identify as `did:web` as before (§11.1).

---

## 15. AppView design

Decided 2026-09-09: everything upstream's AppView does for the `ouranos` read path is
in scope, at a minimal but complete level. The AppView is the largest component; this
section is its work list.

### 15.1 Ingest: verified firehose consumer with a persisted cursor

- Subscribes to the Relay's `subscribeRepos` (in the all-in-one dev stack too — no
  "AppView reads the PDS directly" shortcut; cursor semantics must be the real ones).
- Every commit is **inductively verified by the kernel** (§3.6) before indexing; invalid
  commits are logged and skipped, never indexed.
- **The cursor is persisted** in `appview.subscription(host, cursor, updated_at)` and
  resumed on restart. Upstream's reference AppView does not persist it and re-subscribes
  live; that is exactly what produced the handle-churn incident (`#identity` replay
  overwriting good handles with NULL). We do not repeat it.
- `#identity` → re-resolve handle and DID document (§20) and update `actor`;
  `#account` → status (active / deactivated / takendown / deleted) on `actor`;
  `#sync` → a reset if it names a commit other than the one held (below).
- **Record-level sync state** (Sync spec, "Reliable Repository Synchronization";
  `Aerox.AppView.RepoSync`). `actor_sync` holds each repo's last applied `rev`,
  commit CID and `data` root, and a status. A commit is applied only when its
  `since` and `prevData` follow on from that state; otherwise the repo becomes
  `desynchronized`, its events are dropped and a backfill is requested. While the
  backfill runs (`in_progress`) events queue in `actor_sync_pending` and replay in
  order afterwards. Events at or below the last `rev`, with a future `rev`, or for
  an account whose upstream status is not active are ignored; an account with no
  resolvable signing key is ignored too. State transitions take a per-DID lock
  shared by the live path and the backfill job.
- **Backfill** per repo: `getRepo` from the owning PDS, walk the CAR with the kernel,
  and reconcile it with the index record by record — only in the CAR: indexed;
  different CID: re-indexed; only in the index: deleted. Triggered on first sight of a DID, on
  `#sync`, and by an admin task (this is the `indexRepo + indexHandle +
  updateActorStatus` sequence that had to be run by hand last time, made one command).
- **`tap` evaluated and not adopted as a dependency.** indigo's `tap` (with the
  `@atproto/tap` client) bundles exactly the above — verified events plus backfill plus
  filtering — as a separate Go service. Our kernel already verifies and our ingest
  already backfills, so running tap would duplicate it and add a Go binary. Its event
  *shape* (identity / account / record events with the full record) is adopted as the
  internal boundary between ingest and indexing, so a tap instance could be plugged in
  later if ever wanted.

### 15.2 Indexing: the nineteen record plugins

One plugin per record type, mirroring upstream's `indexing/plugins/`. Each plugin owns
its table, its `insert` / `delete` handling, the notifications it emits (15.5) and the
aggregates it maintains. Table names live in the `appview` schema of `aerox_core`.

| # | Record (lexicon) | Table | Aggregates / side effects | Notifications emitted |
|---|---|---|---|---|
| 1 | `app.bsky.feed.post` | `post` (+ `post_embed_*`, `post_agg`) | reply/quote counts on parent and quoted post; facets → mentions; `sortAt` = min(createdAt, indexedAt) | `reply`, `mention`, `quote` |
| 2 | `app.bsky.feed.like` | `like` | `post_agg.like_count` | `like`, `like-via-repost` |
| 3 | `app.bsky.feed.repost` | `repost` | `post_agg.repost_count`; feed item | `repost`, `repost-via-repost` |
| 4 | `app.bsky.graph.follow` | `follow` | `profile_agg.followers/follows` | `follow` |
| 5 | `app.bsky.graph.block` | `actor_block` | — | — |
| 6 | `app.bsky.graph.list` | `list` | — | — |
| 7 | `app.bsky.graph.listitem` | `list_item` | | — |
| 8 | `app.bsky.graph.listblock` | `list_block` | | — |
| 9 | `app.bsky.actor.profile` | `profile` | avatar/banner blob refs → image CDN URLs (§16) | — |
| 10 | `app.bsky.feed.generator` | `feed_generator` | | — |
| 11 | `app.bsky.labeler.service` | `labeler` | label definitions for hydration (15.6) | — |
| 12 | `app.bsky.graph.starterpack` | `starter_pack` | | `starterpack-joined` |
| 13 | `app.bsky.feed.threadgate` | `thread_gate` | reply permission checks | — |
| 14 | `app.bsky.feed.postgate` | `post_gate` | quote/embedding rules | — |
| 15 | `app.bsky.graph.verification` | `verification` | | `verified`, `unverified` |
| 16 | `app.bsky.actor.status` | `actor_status` | live status | — |
| 17 | `chat.bsky.actor.declaration` | `chat_declaration` | indexed for profile hydration only (chat itself is out of scope) | — |
| 18 | `app.bsky.notification.declaration` | `notif_declaration` | who may notify whom | — |
| 19 | `app.bsky.germ.declaration` (upstream's germ-declaration plugin) | `germ_declaration` | indexed as-is; semantics follow upstream | — |

Adding a record type = adding a plugin; nothing else in the pipeline changes.
Only the schemas of these nineteen (plus the read endpoints `ouranos` calls) are added
to the lexicon registry (§6.1) — still per endpoint, never in bulk.

### 15.3 Read path: skeleton → hydrate → present

Upstream's three-stage pipeline is adopted unchanged in shape: a **skeleton** (a list of
URIs/DIDs from a query), **hydration** (batch-load posts, actors, aggregates, labels,
viewer state — one round trip per entity type, never per item), **presentation**
(build the `#postView` / `#profileView*` records). Viewer state (liked?, reposted?,
following?, muted?, blocked?) is computed in hydration from the authenticated DID.

Blocks and mutes are applied in presentation as upstream does: blocked content is
replaced with `#blockedPost`, muted content flagged, never silently dropped from
threads (clients rely on the placeholders).

### 15.4 Feeds

| Feed | Algorithm |
|---|---|
| **Following timeline** (`getTimeline`) | posts and reposts by followed accounts, reverse-chronological by `sortAt`, with upstream's default filters (hide replies to accounts the viewer does not follow unless the viewer follows the replier; respect thread gates; drop blocked/muted). Cursor = `sortAt‖cid`. |
| **Author feed** (`getAuthorFeed`) | one author's posts with the `filter` param (`posts_with_replies`, `posts_no_replies`, `posts_with_media`, `posts_and_author_threads`, `posts_with_video`) |
| **Thread** (`getPostThread`) | parent chain + reply tree with `depth` / `parentHeight`; thread gate enforcement; `#blockedPost` / `#notFoundPost` placeholders |
| **Likes / quotes / reposts of a post**, **actor likes** | direct table reads |
| **Custom feeds** (`getFeed`) | resolve the feed generator's DID → `#bsky_fg` service endpoint (§20) → call `app.bsky.feed.getFeedSkeleton` with a service JWT for the viewer (`aud` = feedgen DID, `lxm` = `getFeedSkeleton`) → hydrate the returned URIs. `describeFeedGenerator` is proxied. |
| Discover / suggestions / "what's hot" | **not in v1**. `getSuggestions` returns an empty list; `ouranos` tolerates it. |

### 15.5 Notifications

- Table `notification(did, record_uri, record_cid, author, reason, reason_subject, sort_at)`
  with the eleven upstream reasons (15.2), written **in the same transaction** as the
  index write so the two cannot diverge.
- `actor_state(did, last_seen_notifs)` backs `getUnreadCount` and `updateSeen`.
- `listNotifications` hydrates through 15.3; muted/blocked authors are filtered per
  upstream's `notif_declaration` and mute rules; `priority` filtering uses the
  notification preferences in the private state (15.7).
- **Push delivery is not in v1.** `registerPush` / `unregisterPush` store device tokens
  on the PDS (§11.1) so nothing is lost; the delivery worker (upstream's `courier`,
  APNs/FCM/web push) is a later addition. `ouranos` is a web client and does not need it.

### 15.6 Labels: consumed here, produced in §17

- `label(src, uri, cid, val, neg, cts, exp, sig)` — upstream's table and the lexicon's
  fields exactly. Written from two sources: **subscriptions** to configured labelers'
  `com.atproto.label.subscribeLabels` (cursor persisted like 15.1) and **self-labels**
  embedded in records, extracted by the plugins.
- Hydration attaches labels for the labelers the request accepts
  (`atproto-accept-labelers` header, defaulting to the instance's configured set,
  which includes our own labeler §17 when enabled) and applies the labeler's
  definitions from plugin 11 (severity, blur, default setting).
- Takedowns (`actor.takedown_ref`, `record.takedown_ref`) are enforced in hydration:
  taken-down subjects are omitted or placeholdered before presentation.

### 15.7 Private state (the bsync role) and its write path

Mutes (actor, list, words), bookmarks, drafts, notification preferences and activity
subscriptions live in `appview` tables, as decided in §8. The **write path** is the
client → PDS proxy → AppView with a service JWT for the user (§11.3); the AppView
authorises on `iss` = the row's DID. There is no separate bsync service and no
operation log: rows are the state, and the `aerox_core` physical backup carries them.

### 15.8 Search

- `Aerox.AppView.Search` is a **behaviour** (`search_posts`, `search_actors`,
  `typeahead`) so an external engine (upstream's palomar/OpenSearch) can replace the
  default without touching the read path.
- **Default backend: Postgres.** Actors: `pg_trgm` GIN on handle and display name
  (`typeahead` is a prefix/trigram query). Posts: a generated `tsvector` column.
- **CJK caveat, stated up front:** Postgres' default text search configurations do not
  segment Chinese/Japanese/Korean — `to_tsvector('simple', …)` treats a run of CJK
  characters as one token, so word search fails. For CJK content the Postgres backend
  uses **`pg_trgm` (or `pg_bigm`) on post text** for substring matching, and a proper
  segmenting extension (`zhparser`) or an external engine is the upgrade path. Given
  the existing user base is Chinese-language, the trigram path is the v1 default, not
  an afterthought.

---

## 16. Image CDN

Decided 2026-09-09. Without it every avatar and image in `ouranos` is broken; clients
hard-code the URL shape.

- **URL shape and presets are upstream's**, verbatim: `/img/<preset>/plain/<did>/<cid>@<jpeg|webp>`
  with presets `avatar`, `banner`, `feed_thumbnail`, `feed_fullsize` (dimensions and
  `fit: cover | inside` per upstream's `presets` map in `bsky/src/image/uri.ts`; copy
  the exact values when implementing). The AppView emits these URLs in profile and
  embed views; the PDS emits them for its locally served `getProfile` (upstream's
  `image-url-builder`).
- **Runs inside the AppView service** (as upstream), as `Aerox.ImageServer`, on the same
  endpoint under `/img`. It may be split out later; nothing depends on co-location.
- **Origin fetch**: resolve the DID → PDS endpoint (§20) → `com.atproto.sync.getBlob`.
  Only URLs derived from a resolved DID document are ever fetched — no client-supplied
  hosts (SSRF). The resolver's loopback/private-address block is **configurable** for
  the all-in-one dev stack, where the PDS *is* on loopback; this is the exact failure
  that produced "all images 502 while every count reconciles" last time.
- **Processing: `vix` (libvips NIF, 0.41, 1.9M downloads).** This is a deliberate
  exception to §3.9's pure-Elixir-first rule: image decoding is not a correctness
  problem with a golden oracle, it is raw throughput, and there is no realistic pure
  Elixir decoder. libvips also gives decompression-bomb limits, EXIF stripping and
  streaming resize for free. `image` (0.72) is the higher-level wrapper over `vix` and
  is acceptable; the choice is made at implementation.
- **Cache**: processed outputs on local disk under a size-bounded LRU
  (`<cache>/<preset>/<did>/<cid>.<fmt>`), with `Cache-Control: public, max-age` and
  `ETag` = cid‖preset so an edge CDN (Cloudflare) can sit in front. Originals are not
  cached beyond processing.
- **Invalidation**: a takedown (§17) or blob deletion purges the local cache entries
  for that `did`/`cid` and, when configured, issues the edge-CDN purge (upstream's
  `invalidator`, CloudFront/Bunny; ours is a behaviour with a Cloudflare implementation).
- Limits: max source bytes, max pixel count, request timeout, per-IP rate limit (§18).

---

## 17. Moderation and labeling: backend in scope, frontend separate

Decided 2026-09-09: the labeler service, report intake, takedowns and an audit log are
built; the operator UI is a separate frontend. Interfaces are shaped so that Ozone's
web UI (which speaks `tools.ozone.*`) can be pointed at aerox later.

### 17.1 The Labeler service

A fifth service in `config :aerox, :services` (`:labeler`), and **also an account**: a
labeler is an atproto account whose repo holds an `app.bsky.labeler.service` record
(label definitions, policies) and whose DID document carries an `#atproto_labeler`
service and a labeler signing key. aerox's labeler runs on aerox's own PDS.

- Table `labeler.label` with the lexicon's fields plus a `seq`; labels are **signed**
  (`sig`, labeler key, §3.8) on creation.
- Emits `com.atproto.label.subscribeLabels` — the same sequencer/GenServer/event-table
  pattern as the firehose (§5), including cursor replay — and serves `queryLabels`.
- Consumers (our AppView §15.6, any external AppView) subscribe like any other labeler.

### 17.2 Reports and actions

- `com.atproto.moderation.createReport` arrives at the PDS and is proxied (§11.1) to the
  configured moderation service DID (`#atproto_labeler`); the Labeler service stores it
  in `mod_report(id, subject, reason_type, reason, reported_by, created_at)`.
- Actions are recorded in an append-only `mod_event(id, action, subject, created_by,
  comment, meta, created_at)` **before** they are applied, and applied by
  `Aerox.Moderation.Actions`, a behaviour with exactly these operations: `label` /
  `unlabel` (subject, val), `takedown` / `restore` (account, record or blob),
  `acknowledge` (report), `comment`. Every application is idempotent and re-runnable
  from the event log.
- **Takedown propagation**: account/record/blob takedowns call the PDS admin API
  (`com.atproto.admin.updateSubjectStatus`, service-authenticated) which sets
  `takedown_ref` (§4.2) — the PDS then 404s `getRecord`/`getBlob`, excludes the repo
  from `listRepos`, and emits `#account` status; the AppView applies its own
  `takedown_ref` in hydration (§15.6); the image CDN purges (§16).
- Moderator notifications by email (upstream `mailer/moderation.ts`) use §18.

### 17.3 The interface for a frontend

- v1 exposes the actions above through a small service-authenticated admin API on the
  Labeler (`aerox.moderation.*` NSIDs, our own lexicons) plus the standard
  `com.atproto.admin.*` on the PDS. That is enough for a purpose-built UI.
- **Ozone compatibility is the later target, not v1**: `tools.ozone.moderation.emitEvent`,
  `queryEvents`, `queryStatuses`, `getRecord`, `getRepo` map onto `mod_event` /
  `mod_report` / the read path; when implemented, Ozone's own web UI runs unmodified
  against aerox. The `Actions` behaviour and the event-log shape are chosen now so that
  mapping is mechanical (the `tools.ozone.*` schemas — 76 files — are *not* vendored
  until then, per §6.1).

---

## 18. Email, rate limiting (no Redis), and the account lifecycle

Decided 2026-09-09: **no Redis anywhere.** Upstream uses Redis for rate limits, DPoP
nonces, hydration caches and some queues; each use is replaced below.

### 18.1 Email

- `swoosh` (1.28, already a Phoenix dependency) with a configurable adapter: SMTP via
  `gen_smtp`/`mua`, or API adapters (SES, Postmark, Resend, Mailgun). Dev uses Swoosh's
  local mailbox — the `/dev/mailbox` route the generator already emits.
- Templates for the five token purposes upstream defines — `confirm_email`,
  `update_email`, `reset_password`, `delete_account`, `plc_operation` — plus moderation
  notices (§17.2). Plain-text and HTML variants, localisable.
- `email_token(did, purpose, token, requested_at)` (upstream's table): tokens are
  random, single-use, expire after 15 minutes, one outstanding token per
  `(did, purpose)`, and issuing them is rate-limited (18.2). **§14.2's PLC-operation
  gate depends on this** — without mail, users cannot sign PLC operations.
- Delivery is asynchronous (a supervised task with retry); the API response never waits
  on the mail provider.

### 18.2 Rate limiting without Redis

- **`hammer` (7.5, 2026-09, 31M downloads) with its ETS backend.** Per node. That is
  correct for the PDS, which is single-node until the §5.3 sequencer decision (R3); when
  multi-node arrives, Hammer's Mnesia backend or a small Postgres-backed backend is the
  swap, behind Hammer's pluggable backend interface. Never Redis.
- **Limits mirror upstream's** so behaviour is familiar to operators and clients:
  global per-IP 3000 / 5 min; repo writes points-based (create = 3, put = 2, delete = 1)
  5000 / hour and 35 000 / day per DID; `createAccount` 100 / 5 min per IP;
  `uploadBlob` 1000 / day per DID; plus per-route limits on `createSession`,
  `updateHandle`, password reset and email-token requests. Declared per route next to
  the handler, keyed by IP or by DID (`calcKey`).
- Responses carry `RateLimit-Limit/Remaining/Reset` headers and the XRPC error
  `RateLimitExceeded` (HTTP 429).
- Client IP is taken from `x-forwarded-for` **only when the peer is a configured
  trusted proxy**; otherwise the socket address. Getting this wrong makes every user
  share one bucket.
- Other Redis-shaped state, all ETS with TTL and the same per-node caveat: OAuth DPoP
  nonces and used-`jti` sets (§11.2), service-JWT `jti` replay set (§20.2), the
  hydration cache (§15.3, optional). None of these need cross-node consistency on a
  single-node PDS; each is listed under R3 for the multi-node day.

### 18.3 Account lifecycle

States on `actor`: **active**, **deactivated** (`deactivated_at`, optional
`delete_after`), **taken down** (`takedown_ref`), **deleted** (rows gone, DID
tombstoned for `did:plc`). Transitions:

| Flow | Steps |
|---|---|
| Sign-up | invite code (optional per config, `invite_code` tables), handle availability (§8 item 2 domains, reserved words such as `visitor`), password → scrypt (§13.4), then a **saga, not one transaction** — the account and its signing key are committed to `aerox_pds` first, *deactivated*; the PLC genesis op (§14.2) is submitted second; the account is activated third. There is no cross-database transaction to be had (§4.6), and in a real deployment the PLC directory is another operator entirely, so signup is inherently a network call. Each step is idempotent and resumable: a crash after step 1 leaves a deactivated account a retry completes, and an orphaned account with no PLC op is reaped. Then `confirm_email` mail, `#account` + `#identity` events. **No `signupQueued` waitlist** — upstream's queue is dropped; the scope value stays recognised for imported tokens only |
| Inbound migration (Account spec) | `reserveSigningKey` (optionally for the DID) → `createAccount` with `did` and a service JWT from that DID → account created **deactivated** with the reserved key, no PLC op, not reaped → the old PDS re-points the DID document (`getRecommendedDidCredentials`) → `importRepo` / blobs → `activateAccount` checks the document names this PDS and the key, then emits `#identity`, `#account`, `#sync` |
| Deactivate / reactivate | `deactivateAccount` (optional `deleteAfter`) → `#account inactive`; repo hidden from `listRepos`, writes refused, reads 404; `activateAccount` reverses |
| Delete | `requestAccountDelete` mail token → `deleteAccount` → `did:plc` tombstone via the Signer (§14.2, audited) → `#account deleted` → rows purged after the grace period; blobs via `delete_all(did)` (§4.4) |
| Take down / restore | admin only (`updateSubjectStatus`), §17.2 |
| Email / handle / password change | email-token gated where upstream gates them; handle change emits `#identity` and, for `did:plc`, a PLC op |

**`com.atproto.temp.*`**: `checkSignupQueue` (always activated — there is no queue),
`checkHandleAvailability` (suggestions from the email, birth year and digits),
`addReservedHandle` (whole handles, on top of `priv/reserved_handles.txt`),
`revokeAccountCredentials` (sessions, OAuth tokens, app passwords, and the password
until a reset), `requestPhoneVerification` (off unless an SMS adapter — `Log` or
`Twilio` — is configured; then `describeServer` says `phoneVerificationRequired` and
signup needs the code), and `dereferenceScope` (an OAuth token scope over 1 KiB is
carried in the access token as `ref:<cid>`). `fetchLabels` is the labeler's.

**Admin API** (`com.atproto.admin.*`): the subset `pdsadmin` and §17 need —
`getAccountInfo(s)`, `getSubjectStatus`, `updateSubjectStatus`, `updateAccountEmail`,
`updateAccountHandle`, `updateAccountPassword`, `updateAccountSigningKey`, `searchAccounts`,
`deleteAccount`, `getInviteCodes`, `createInviteCodes`,
`disableInviteCodes`, `disable/enableAccountInvites`, `sendEmail`. Authenticated as
upstream does: HTTP Basic with the admin password for operators, service JWT from the
moderation service DID for §17.

---

## 19. Relay design

Decided 2026-09-09. The Relay is **non-archival** (as upstream's relays have been since
2025): it verifies, sequences and fans out; it does not mirror repos.

- Tables (`relay` schema): `host(hostname, status, account_limit, cursor, last_event_at,
  error_count)`, `repo(did, host, rev, status)`, and the Relay's own `repo_seq` with its
  own sequencer GenServer (§5.2) and a **retention window** (default 72 h); a consumer
  whose cursor is older receives `#info OutdatedCursor`, as upstream.
- **One consumer process per host**, supervised, connecting to
  `subscribeRepos?cursor=<host cursor>`; every commit is inductively verified (§3.6);
  invalid commits increment the host's error count and are dropped; hosts past a
  threshold are paused. `#sync`, `#account`, `#identity` are validated and re-emitted.
- **Endpoints**: `subscribeRepos` (the fan-out via PubSub, §5.1), `requestCrawl`
  (validates the host by fetching `describeServer`, applies new-host defaults and
  limits, then starts a consumer), `listHosts`, `getHostStatus`, `listRepos`,
  `getRepoStatus`, `getLatestCommit`. `getRepo` / `getRecord` / `getBlocks` /
  `getBlob` / `listBlobs` are **not served** (non-archival): they answer `302` to the
  same method on the hosting PDS, query intact (the Sync spec's "the upstream may
  instead simply use an HTTP redirect", and indigo's `getRepo`); an account the relay
  has taken down is refused with `RepoTakendown` instead. `listReposByCollection` is served from a collection
  directory (`relay.repo_collection`, as indigo's `collectiondir`): commits add the
  collections of their creates, a `describeRepo` crawl completes each account once
  and again after `#sync`, deleted accounts leave it. `getCheckout`/`getHead`/`notifyOfUpdate` are deprecated and return
  `MethodNotImplemented`.
- Limits: per-host account limit (new hosts start low), per-host event rate, host
  ban list — the relay account-limit Slack alert our indigo fork added is the model.
- In the all-in-one dev stack the Relay runs too; the AppView never bypasses it (§15.1).
- **Not Broadway.** Each host is one strictly ordered stream and the write side is already
  batched by the sequencer's call coalescing (§21.2); a GenServer per host is the right
  size. If a single host's volume ever outgrows one process, the upgrade is GenStage,
  not Broadway (§21.5 applies to the AppView only).

---

## 20. Identity resolution and service-JWT verification

### 20.1 `Aerox.Identity` — the impure half of §3.0

- **Handle → DID**: DNS TXT `_atproto.<handle>` first, then HTTPS
  `/.well-known/atproto-did` (spec order); both must agree with the DID document's
  `alsoKnownAs` or the handle is `handle.invalid`.
- **DID → document**: `did:plc` via the configured PLC directory (our own §2 in the
  self-contained network); `did:web` via HTTPS `/.well-known/did.json`. Parsing is the
  kernel's (`Aerox.ATProto.Identity`).
- **Hosting our own handles**: the PDS answers `/.well-known/atproto-did` for every
  handle domain it serves (`PDS_SERVICE_HANDLE_DOMAINS`, §8 item 2); publishing
  `_atproto` TXT records is an operator/DNS-provider step documented, not automated, in
  v1.
- **Cache**: two layers, per service, never shared across the database boundary (§4.6):
  an ETS table per node (documents 1 h TTL, handles 10 min, negative results 1 min;
  **auth flows use ≤ 10 min per the OAuth spec**) and a persistent
  `identity_cache(did, doc, handle, fetched_at)` in the service's own schema for warm
  restarts. Stale-while-revalidate on read; **explicit invalidation** on `#identity`
  events in the Relay and AppView.
- Outbound HTTP is a hardened client: resolved-address checks (loopback/private
  blocked unless configured for dev, §16), size and time limits, no redirects across
  hosts.

### 20.2 Service JWTs — the receiving side

Every service that accepts inter-service calls (AppView, Labeler, feed generators we
call, Spaces hosts) verifies inbound service JWTs identically:

1. Parse; `alg` must be ES256K or ES256; reject others.
2. `iss` → resolve the DID's signing key (20.1); verify the signature; **reject high-S**
   (§3.8).
3. `aud` must equal *this* service's DID.
4. `exp` in the future with ≤ 60 s skew, `iat` not in the future; total lifetime ≤ 1 h.
5. `lxm`, when present, must equal the NSID being called; **required** for all methods
   except the migration bootstrap `com.atproto.server.createAccount`.
6. `jti` must be unseen: an ETS replay set keyed by `jti` with TTL = remaining lifetime
   (per node; R3 caveat).

Issuing side on the PDS (`getServiceAuth`): default `exp` 60 s, hard cap 1 h; `lxm`
required except for the createAccount bootstrap. The same verifier module is used for
Spaces' delegation and credential tokens (§12.4) with their distinct `typ` values.

---

## 21. OTP usage and the concurrency model

Decided 2026-09-09. BEAM's most common failure is not "not using OTP" but using
processes in the wrong places. This section says where a process is the right tool in
aerox, where it is not, and which failure modes must be designed against explicitly.

### 21.1 The rule

**A process is a fault domain, a unit of concurrency, or a serialisation point — not an
object.** Something becomes a process only if it needs to crash independently, run
concurrently, or serialise a class of operations. Otherwise it is a pure function
(the whole kernel, §3.0) or an ETS table (every read-heavy cache).

### 21.2 Sequencer: one process, with call coalescing

The sequencer stays a single GenServer (§5.2), but not the naïve one-INSERT-per-call
version, which would cap the PDS's write rate at "commits per second". `handle_call`
enqueues and returns `{:noreply, …}`; a batch is flushed every N events or T ms as one
transaction (one INSERT of many rows, one commit), then every caller gets
`GenServer.reply` and the batch is broadcast. Throughput becomes rows-per-transaction.
Supervised `:rest_for_one` ahead of the fan-out: if the sequencer dies, fan-out
restarts after it (subscribers reconnect with persisted cursors); if fan-out dies the
sequencer is untouched.

### 21.3 Per-account write serialisation: a Postgres row lock, not a process per account

Two writes to the same repo must be serial (MST). "One GenServer per DID" looks like
the actor-model answer; **it is not the v1 answer.** `SELECT … FROM repo_root WHERE did
= $1 FOR UPDATE` gives the same serialisation, is correct across nodes without the
unresolved §5.3 scheme, and needs no start/idle-stop/Registry/lock-release code.
A per-account process is kept as a later **optimisation** — write coalescing for hot
accounts (ten `createRecord`s into one commit) — to be added only when measured.

### 21.4 Relay: one consumer per host, bounded fan-out

- One GenServer per upstream host under a `DynamicSupervisor`, Registry-keyed by
  hostname. A host emitting garbage crashes only its own consumer, which restarts from
  `host.cursor`; `max_restarts` with back-off, and persistent offenders are **paused**,
  not restarted every second.
- Fan-out through `Phoenix.PubSub` / `Registry` dispatch; one WebSock process per
  subscriber.
- **BEAM mailboxes are unbounded.** A slow subscriber does not block the sender; it
  grows its own mailbox until the node runs out of memory — the classic BEAM outage.
  Each subscriber process checks its `message_queue_len` and, past a threshold,
  **disconnects itself**; the client reconnects with its cursor and replays from
  `repo_seq`. A slow consumer must never be able to take the Relay down.

### 21.5 AppView ingest: a Broadway pipeline partitioned by DID

**Decision: `broadway` (1.3) for the ingest pipeline** (§15.1):
`firehose producer → verify (CPU, parallel) → index (DB) → notify`.

- Ordering: events of one repo must stay ordered; different repos may proceed in
  parallel. `partition_by: hash(did)` expresses exactly this — serial within a
  partition, parallel across partitions — with no hand-written locking.
- Back-pressure reaches the socket: the firehose is cursor-based, so the producer
  stops reading frames when downstream demand is exhausted instead of piling frames
  into a mailbox (the same problem as 21.4 seen from the consumer side).
- Backfill (§15.1) runs under a `Task.Supervisor` with `async_stream(max_concurrency:)`;
  a Registry key per DID makes backfill and live indexing of the same repo mutually
  exclusive.

### 21.6 Background jobs: Oban — the durable queue that needs no Redis

**Decision: `oban` (2.24) for every durable background job**: email delivery (§18.1),
Spaces `notifyWrite` with retry and dead-letter (§12.5, R9), the blob reaper (§4.4),
backfill tasks, label emission retries, bundle export/import runs, cache purges.

Oban's queue is a table in the service's own Postgres database (`aerox_pds` or
`aerox_core`, respecting §4.6), so **a job is enqueued in the same transaction as the
business write** — "store the record and schedule its notification" commits or rolls
back as one. Retries with back-off, uniqueness constraints, cron, and a LiveDashboard
pane come with it. This replaces upstream's Redis-backed queues without new
infrastructure and removes the temptation to hand-roll queues in GenServers.

### 21.7 Identity resolution: ETS plus request coalescing

- The cache is an ETS table with `read_concurrency: true`, never a GenServer —
  hydration looks up dozens of DIDs per request and a GenServer would serialise them.
- **Single-flight on miss**: a hundred concurrent misses for one DID must produce one
  HTTP fetch. A Registry-registered transient process per in-flight key; latecomers
  monitor it and receive the result. A few lines on BEAM; error-prone elsewhere.
- Expiry by one low-frequency sweeper, not a timer per entry.

### 21.8 NIFs and schedulers

- **`vix`/libvips** (§16) runs on dirty schedulers and takes tens to hundreds of ms per
  image. Dirty schedulers default to one per core; saturate them and *every* NIF call
  queues, including signatures. Image work runs under a bounded `Task.Supervisor`
  (`max_children`) or a semaphore.
- **`ex_secp256k1`** is sub-millisecond but sits on the service-JWT hot path (§11.3);
  confirm it is a dirty NIF or short enough not to stall normal schedulers.
- Pure-Elixir DAG-CBOR and MST hashing (§3.9) are ordinary Elixir code and therefore
  **safe**: pre-emptive scheduling guarantees they cannot starve anything — they are
  only slow. A hidden benefit of pure-Elixir-first.

### 21.9 Supervision tree shape (per service)

```
Aerox.PDS.Supervisor            rest_for_one
├── Aerox.PDS.Repo                 DB pool first
├── Aerox.PDS.Sequencer            depends on Repo
├── Aerox.PDS.Firehose.Fanout      depends on Sequencer
├── DynamicSupervisor              firehose subscribers, one_for_one, independent
└── Oban                           background jobs
```

`rest_for_one` where order is a dependency, `one_for_one` where children are
independent, `DynamicSupervisor` for on-demand children. **Database unavailability is
not a crash**: the pool reconnects on its own; business processes return
`DBConnection.ConnectionError` as an error result. Letting it crash would trip
`max_restarts` and take the whole tree down within seconds.

### 21.10 Distribution: not until R3

The only thing in aerox that truly needs cross-node coordination is the sequencer
(§5.3). Rate limits, DPoP nonces, `jti` sets and caches are correct per node or live in
Postgres. v1 runs no Erlang cluster. When needed: `libcluster` (3.5) for membership,
and `:global` (simple) or `horde` (0.10) for the sequencer only. Clustering early would
turn every ETS cache into a consistency question.

### 21.11 Property-based tests alongside the goldens

`stream_data` (1.4) complements §7's goldens ("is it right") with invariants ("when does
it break"): random key sets inserted in any order → identical MST root; random terms →
DAG-CBOR encode/decode round-trip with byte-identical re-encoding; random operation
sequences → LtHash add/remove commute. Each is a few lines and reaches corners the
corpus cannot.

### 21.12 Anti-patterns this project will actually meet

| Anti-pattern | Where it would appear | Do instead |
|---|---|---|
| GenServer as a cache | identity cache, lexicon registry | ETS |
| A process per entity "because actors" | per-account processes | PG row lock; process later as an optimisation (21.3) |
| Unbounded mailbox | Relay subscribers, AppView ingest | monitor `message_queue_len`; back-pressure to the socket (21.4, 21.5) |
| Crashing on DB errors | every service | return the error; the pool reconnects (21.9) |
| Unbounded NIF concurrency | image processing | bounded Task.Supervisor (21.8) |
| Hand-rolled queues | mail, notifications, backfill | Oban (21.6) |
| Early distribution | everything | single node; cluster only at R3 (21.10) |
| `Agent` for hot shared state | sequencer state | GenServer with coalescing, or ETS |

---

## Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-09-09 | Project name `aerox` | `aero` collides with Aeron (8.8k★, also network transport) and AeroSpace (23k★); `aerox` is free on hex and its top GitHub namesake has 29★. The only name in the aero-/sky- space that is on-theme and uncontested |
| 2026-09-09 | Single Mix app, no umbrella | Umbrella releases cannot express "start half of one app's tree"; atproto needs the full stack in one process |
| 2026-09-09 | Bit-exact encoding, no federation | Wildly asymmetric costs; bit-exactness cannot be retrofitted and provides a debugging oracle |
| 2026-09-09 | ~~One SQLite per account~~ — **reversed the same day**: one Postgres for the whole PDS, all accounts in shared `did`-keyed tables | Owner decision. The "seven-for-seven" claim was wrong — `tranquil-pds` defaults to Postgres. Protocol-level portability is CAR export, unaffected; file-level portability is given up in exchange for one engine, cross-account SQL and multi-node PDS (§4.1) |
| 2026-09-09 | Hand-written DAG-CBOR, pure Elixir first | Nothing on hex; a NIF would entangle correctness with toolchain problems |
| 2026-09-09 | ~~Compile-time lexicon code generation~~ — **refined the same day** into: schemas embedded at compile time, validation by a runtime interpreter, thin generated conveniences | Matches both upstreams; 536 cross-file refs must not become compile dependencies; `com.atproto.lexicon.schema` makes runtime lexicons a protocol feature (§6.1) |
| 2026-09-09 | Build order kernel→PLC→PDS→Relay→AppView | Ordered by falsifiability, not dependency |
| 2026-09-09 | Repo write path in the kernel, with verification | The Relay's inductive validation must reuse the same diff logic; in the PDS there would be two copies |
| 2026-09-09 | Wrap bytes, not text; string-keyed maps | Bytes are rare in atproto data; atom keys are unsafe on external input |
| 2026-09-09 | Three separate validation layers (CBOR syntax / data model / lexicon) | The Relay needs only the first two; merged, they cannot be requested separately |
| 2026-09-09 | MST over an explicit Blockstore behaviour; kernel does no I/O | Differential tests need pure comparison; inductive validation needs only an in-memory blockstore |
| 2026-09-09 | Repo v3 + sync v1.1 only | The live network has migrated; old `prev`-chain support only adds surface area |
| 2026-09-09 | Lexicon registry is an explicit argument, not global state | Same pattern as the Blockstore; kernel stays I/O-free and dynamic lexicons merge in from outside (§6.2) |
| 2026-09-09 | Validated records stay string-keyed maps; no generated structs | Consistent with §3.1; open unions would force two shapes to coexist; thin structs for a handful of record types can be added later at low cost (§6.4) |
| 2026-09-09 | PDS admits unknown lexicons by default (three-state `validate`) | Upstream behaviour; the third-party ecosystem depends on it (§6.3) |
| 2026-09-09 | Only the generic protocol core is in scope; the 394-schema corpus is not bundled | Registry holds the full `com.atproto` namespace (96 files) as one unit; `app.bsky.*` deferred to AppView work and then only what `ouranos` calls (§6.1) |
| 2026-09-09 | Blobs on local disk behind upstream's `BlobStore`-shaped behaviour; S3 later | Keeps one thing on disk; lifecycle tied to `record_blob` in Postgres (§4.4) |
| 2026-09-09 | Sequencer GenServer remains sole assigner and writer of `repo_seq`; no `BIGSERIAL` | Postgres sequences order at assignment, not commit; cursor-based subscribers would skip events (§5.3) |
| 2026-09-09 | Per-account signing keys in Postgres, plaintext for v1 | No per-account directory remains; matches upstream's at-rest posture; encryption is an open item (§4.5) |
| 2026-09-09 | PDS in its own Postgres database; PLC/Relay/AppView in a separate one (schema per service) | Storage-level enforcement of service boundaries — no SQL joins across services, XRPC/firehose only; different backup and restore profiles; PDS can move or multiply independently (§4.6) |
| 2026-09-09 | atproto OAuth in v1 (PAR + PKCE + DPoP + client-metadata documents); legacy `createSession` kept for `ouranos` | Spaces is built on OAuth scopes and DPoP; `ouranos` has no OAuth client (§11.2) |
| 2026-09-09 | No read-after-write in the PDS proxy; pure pass-through | Per-endpoint patch logic for millisecond lag on a single host is not worth it (§11.3) |
| 2026-09-09 | Support permissioned data / Spaces (proposal 0016) as a second PDS phase behind a feature flag | Owner requirement; alpha status contained by module isolation and alpha-image goldens (§12) |
| 2026-09-09 | `permission-set` and `space` lexicon kinds are required; `com.atproto.space`/`simplespace` vendored from the `permissioned-data` branch | Scope evaluation and Spaces depend on them (§6, §11.2, §12.6) |
| 2026-09-09 | Blob storage behind `Aerox.Blob.Store` behaviour with `Disk` (v1), `S3` (later) and `Migrating` adapters; Postgres is the only source of truth for blob existence | Same key layout on every adapter makes migration a copy; idempotent, metadata-free adapters keep the reaper trivial (§4.4) |
| 2026-09-09 | Bidirectional storage-level import/export against the reference PDS's SQLite layout, as a tool-only Mix task (`MIX_ENV=tool`, `exqlite` excluded from prod) | Protocol-level migration moves neither secrets nor firehose history and needs a PLC op per account; verbatim `repo_block` bytes make takeover bit-exact and double as a kernel test (§13) |
| 2026-09-09 | Password hashing adopts upstream's scrypt scheme | Imported `passwordScrypt` must verify unchanged; nobody resets a password because we migrated (§13.4) |
| 2026-09-09 | The interop tool never submits PLC operations | The production rotation key controls all 2008 DIDs and PLC is append-only (§13.5) |
| 2026-09-09 | Data portability is a core requirement; one encrypted, versioned **account bundle** is the interchange format, with Postgres / reference-PDS / protocol adapters | N×N converters collapse to one import path and one verification suite; `repo.car` reuses the protocol's own bit-exact representation so every import re-verifies the kernel (§13.0) |
| 2026-09-09 | Bundle encryption **deferred**: Option A = per-bundle content key wrapped as JWE via `jose` + chunked AES-256-GCM from OTP `:crypto` (JWE never touches large files); Option B = require the Go `age` CLI locally. Evaluate when the bundle format is implemented | No established `age` port on hex; both options satisfy the same streaming/authentication contract, and the bundle layout is independent of the choice (§13.0) |
| 2026-09-09 | Migration from the reference PDS into aerox is a goal, not an option kept open | Owner decision; §13 is the design (§1) |
| 2026-09-09 | Per-account signing keys stay plaintext in Postgres — closed, not open | Owner decision; matches upstream, hot path, DB boundary; bundles differ because they travel (§4.5) |
| 2026-09-09 | Bundle carries `repo.car` + `state.json`; `record`/`record_blob`/`backlink` are re-derived on import | Resolves the CAR-vs-table-copy contradiction; block bytes remain verbatim inside the CAR (§13.0, §13.2) |
| 2026-09-09 | PDS serves `app.bsky.actor.{get,put}Preferences` and `notification.registerPush` locally; everything else in `app.bsky.*` is proxied | Their state lives in the PDS; upstream does the same (§11.1) |
| 2026-09-09 | Instance PLC rotation key behind a `Signer` behaviour (KMS / remote signer; local only in dev), mandatory offline recovery key at index 1, single audited call site for PLC ops | Upstream's one-key-over-all-identities single point is the production deployment's current exposure; the 72-hour window is only useful with a higher-priority key held offline (§14.2) |
| 2026-09-09 | `did:web` accounts supported, upstream semantics (bring-your-own, validated against the PDS) | Owner decision; no rotation keys, user edits the document (§14.3) |
| 2026-09-09 | AppView private state (mutes, bookmarks, drafts, notification prefs) is covered by the `aerox_core` physical backup; no export format. Only genuinely user-owned items are later candidates for a private Space | The public index is rebuildable from the firehose; Layer A migration never carried the private slice either (§8) |
| 2026-09-09 | AppView in full for the `ouranos` read path: 19 record plugins, skeleton→hydrate→present, following/author/thread/custom feeds, notifications (no push delivery), label consumption, private state, Postgres search behind a behaviour; ingest cursor persisted; `tap` not adopted | Owner scope decision; cursor persistence prevents the handle-churn failure; kernel already does what `tap` would (§15) |
| 2026-09-09 | Image CDN inside the AppView with upstream's URL shape and presets; `vix`/libvips as an explicit NIF exception; disk LRU cache; takedown purge | Clients hard-code the URL shape; image decoding has no pure-Elixir option and no golden-oracle concern (§16) |
| 2026-09-09 | Moderation backend in scope: Labeler service (an account + `subscribeLabels`), report intake, append-only `mod_event`, `Actions` behaviour, takedown propagation; UI is a separate frontend; Ozone `tools.ozone.*` compatibility later | Owner decision; event-log shape chosen so the Ozone mapping is mechanical (§17) |
| 2026-09-09 | No Redis. Rate limiting via `hammer` ETS (Mnesia/Postgres backend when multi-node); DPoP nonces, `jti` replay sets and caches in ETS; limits mirror upstream's numbers | Owner decision; single-node PDS until R3 makes per-node state correct (§18.2) |
| 2026-09-09 | Email via `swoosh` with pluggable adapter; five token purposes as upstream; async delivery | §14.2's PLC gate and the account lifecycle depend on it (§18.1) |
| 2026-09-09 | Account lifecycle and admin API per upstream, minus the `signupQueued` waitlist | Familiar semantics for operators and `pdsadmin`-style tooling (§18.3) |
| 2026-09-09 | Non-archival Relay: verify, sequence, fan out; 72 h retention; per-host consumers and limits; sync read endpoints not served | Matches upstream's current relays; mirroring repos is the AppView's backfill job, not the Relay's (§19) |
| 2026-09-09 | Identity cache per service (ETS + own-schema table), invalidated on `#identity`; service-JWT verification rules fixed (`aud`, `lxm`, `jti`, low-S, ≤ 1 h) | Database-boundary rule (§4.6); the receiving side was undesigned (§20) |
| 2026-09-09 | Search default is Postgres with `pg_trgm` for CJK; behaviour allows an external engine | Existing users are Chinese-language; `tsvector` cannot segment CJK (§15.8) |
| 2026-09-09 | Oban (Postgres-backed) for all durable background jobs: mail, Spaces notifications, reaper, backfill, bundle runs | No Redis; jobs commit in the same transaction as business writes; retries/dead-letter/cron built in (§21.6) |
| 2026-09-09 | Broadway pipeline for AppView ingest, partitioned by `hash(did)`; back-pressure reaches the firehose socket | Per-repo ordering with cross-repo parallelism without hand-written locks; no unbounded mailbox (§21.5) |
| 2026-09-09 | Per-account write serialisation via `repo_root … FOR UPDATE`, not a process per account; sequencer uses call coalescing; no Erlang cluster before R3 | Row lock is multi-node-correct today; per-account processes deferred to a measured optimisation (§21.2, §21.3, §21.10) |
| 2026-09-09 | Postgres 18 is the database version for development and production | Owner decision; one major version everywhere; recorded in DEV_PLAN §1.1 |
| 2026-09-09 | §4.6 rationale reordered: the decisive reason for splitting the PDS database is the **asymmetric cost of reversal**, then differing recovery units, then topology; storage-level boundary enforcement drops to last | Re-examination found the boundary argument partly served by `boundary` and by a cheaper mechanism (roles), while the reversal-cost argument — cheap now, expensive later — was the one actually settling it, and was unstated (§4.6) |
| 2026-09-09 | Each service connects as its own Postgres role with `REVOKE` on schemas it does not own | The three schemas inside `aerox_core` were separated by convention only, so the very shortcut §4.6 forbids across the PDS boundary was available among PLC/Relay/AppView (§4.6) |
| 2026-09-09 | Corrected: separate databases **on one server** provide no resource isolation | The claim that a runaway AppView query cannot starve PDS writes is false on a co-located cluster, which §4.6 itself allows for dev and small deployments (§4.6) |
| 2026-09-09 | Two Oban instances, one per database | "Enqueued in the same transaction as the business write" is a per-database property; one instance cannot serve both repos (§4.6, §21.6) |
| 2026-09-09 | Sign-up is a **saga** — account + signing key (deactivated) → PLC genesis op → activate — not one transaction | PLC lives in `aerox_core` and the PDS in `aerox_pds`, so no such transaction exists; in a real deployment PLC is a different operator and signup is a network call regardless. Owner decision on the ordering (§18.3, §4.6) |
