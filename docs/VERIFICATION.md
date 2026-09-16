# aerox — Verification plan

Companion to `DESIGN.md`, `DEV_PLAN.md` and `STRUCTURE.md`. Drafted 2026-09-09.

`DESIGN.md` says what aerox is and why. This document says **how we will know it is
correct**, at every layer, before and after it ships. It is organised by the question
each layer answers, not by tool.

The governing constraint comes from DESIGN §1: the encoding layer is bit-exact against
the reference implementations even though the network is not federated. Therefore
**the reference implementations are the oracle**, and most of this plan is about
getting their answers into our test suite and keeping them there.

The plan must be sufficient to establish four things about aerox. Each maps to
sections below; a release is not made unless all four have green evidence:

| Goal | Meaning | Where it is verified |
|---|---|---|
| **Consistency with Bluesky** | same bytes, same CIDs, same validation verdicts, and **the same API responses** for the same data | §3 (kernel goldens), §7.1 (endpoint parity) |
| **Interoperability** | upstream's servers accept our output and we accept theirs; upstream's clients work against us unmodified | §7.2 (upstream counterparts), §8 (portability) |
| **Network connectability** | a node can be reached, discovered, crawled and joined over real DNS/TLS/WebSocket semantics, and reconnects correctly | §7.3 (connectivity and federation readiness) |
| **Fault tolerance** | processes, databases, networks and dependencies fail and the system degrades predictably and recovers without loss or duplication | §10.2 (process faults), §10.3 (network faults), §10.4 (drills) |

---

## 0. Principles

1. **Oracle over opinion.** Wherever an upstream implementation can produce the expected
   value, the test compares against that value, not against what we believe is right.
2. **A failure must name the layer.** A broken CID must fail a CID test, not surface as
   "relay rejected commit" three layers up. Layers are tested bottom-up and each layer's
   tests assume the layer below is green.
3. **Silence is failure.** "0 accounts, 0 records, 0 failures" is a failing result
   (DESIGN §13.3). Every bulk process asserts it did non-trivial work.
4. **Every incident becomes a test.** The traps recorded in the deployment notes (insert-
   only imports, handle churn, SSRF on loopback, did-map survival) each have a named
   regression test in §9 of this document.
5. **Tests run against real Postgres, never a substitute.** Two databases (DESIGN §4.6),
   Ecto sandbox for isolation. No SQLite in the test suite either.

---

## 1. The layers

| # | Layer | Question it answers | Primary technique | Oracle |
|---|---|---|---|---|
| L0 | Syntax & primitives | Do we parse/format identifiers exactly as the spec? | golden vectors | `interop-test-files/syntax/` (16 files) |
| L1 | Encoding (DAG-CBOR, CID, TID) | Are our bytes identical to upstream's? | golden + property | `@ipld/dag-cbor`, indigo `atdata` fixtures |
| L2 | Repo structures (MST, CAR, commit, Space LtHash) | Do we compute the same roots and verify the same proofs? | golden + property | `packages/repo/tests` fixtures, indigo `mst/testdata`, real CARs, Spaces alpha image |
| L3 | Crypto & identity | Do we sign/verify like everyone else, and parse DID docs correctly? | golden + negative cases | `interop-test-files/crypto/`, W3C did:key vectors |
| L4 | Lexicon & data model | Do we accept what upstream accepts and reject what it rejects? | golden + property | indigo `lexicon/testdata`, `atdata/testdata` |
| L5 | Storage & adapters | Do the behaviours hold their contracts on every implementation? | contract suites | ours |
| L6 | Service logic | Do the PDS / PLC / Relay / AppView / Labeler do the right thing in isolation? | ExUnit with sandboxed DBs, `Mox` for behaviours, `Req.Test`/`Bypass` for HTTP | ours + upstream behaviour |
| L7 | Cross-service | Does the self-contained network hold together (PDS→Relay→AppView, proxy, service JWTs, OAuth)? | integration tests on the all-in-one stack | ours |
| L8 | Interoperability | Do upstream's *clients and servers* accept us? | differential tests against upstream containers | reference PDS, indigo relay, bsky AppView, PLC, Spaces alpha image, `@atproto/api` |
| L9 | Portability | Do bundles and reference-PDS imports round-trip losslessly? | round-trip + boot-the-stock-image | reference PDS image |
| L10 | Operational | Does it survive load, faults, upgrades, restores? | load, fault injection, drills | SLOs we set |

Layers L0–L4 are the kernel (DESIGN §3, §12.2) and are **the acceptance gate for the
kernel phase**: nothing above them starts until they are green and their goldens are
committed.

---

## 2. The golden corpus

### 2.1 Layout

```
test/golden/
  README.md                 provenance rules (below)
  MANIFEST.json             one entry per file: source repo, commit/tag or image digest,
                            generator command, sha256, date
  syntax/                   copied verbatim from interop-test-files/syntax/
  crypto/                   copied verbatim from interop-test-files/crypto/
  dagcbor/                  {name}.json (input as JSON with $link/$bytes) + {name}.cbor (expected bytes)
  cid/                      block bytes + expected CID strings
  mst/                      key sets + expected roots (from mst.test.ts and indigo testdata)
  car/                      real repo CARs + expected commit/root/record counts
  data-model/               indigo atdata valid/invalid
  lexicon/                  indigo lexicon valid/invalid + record-data valid/invalid
  firehose/                 captured subscribeRepos frames (bytes) + decoded expectations
  plc/                      did-method-plc operation vectors, audit logs incl. nullified
  oauth/                    DPoP proofs, PAR requests, client metadata docs, token responses
  spaces/                   LtHash vectors, signed commits, listRepoOps sequences (from the alpha image)
  bundle/                   reference bundles at each bundle_version
```

### 2.2 Provenance rules

- Every file in `test/golden/` is listed in `MANIFEST.json` with **where it came from and
  how to regenerate it**. A file without a manifest entry fails a CI check.
- Files copied from upstream are byte-identical to the source at the recorded commit;
  a script (`mix aerox.golden.verify`) re-fetches and diffs them.
- Files *generated* by running upstream code record the exact command and container
  image digest. Regeneration is a deliberate, reviewed change — a golden that changes
  is either an upstream change we must follow or a bug in the generator; never edit
  a golden by hand to make a test pass.
- Spaces goldens (`spaces/`) are expected to churn while the alpha moves (DESIGN §12.1);
  their manifest entries carry the `permissioned-data` branch commit.

### 2.3 Generators

A `tools/golden/` directory holds small upstream-side scripts (TypeScript against
`bsky/atproto`, Go against `bsky/indigo`) that emit vectors: encode this JSON with
`@ipld/dag-cbor`; build an MST from these keys and print the root; sign this commit
with this key; run `assertValidRecord` on these records. They are run inside the
pinned upstream containers so results do not depend on a developer's local toolchain.

---

## 3. Kernel tests (L0–L4)

### 3.1 Golden tests

One test module per golden directory. Each is table-driven over the directory: for
every vector, compute and compare. Failures print the vector name, expected and actual
as hex, and — for DAG-CBOR — the first differing byte offset.

Acceptance criteria (from DESIGN §7, made mechanical):

| Layer | Passes when |
|---|---|
| Syntax | all 16 valid/invalid files agree line by line |
| DAG-CBOR | encoding every input yields bytes identical to the golden; decoding every golden yields the input; **decoding every non-canonical vector is an error** |
| CID | every golden block yields the golden CID string and binary form (with the tag-42 `0x00` prefix) |
| MST | every key set yields the golden root; loading every golden CAR and recomputing the root equals its commit's `data` |
| Commit / signing | every golden commit's signature verifies; every high-S vector **fails**; our signatures over golden payloads verify under the TS implementation (checked by a generator round-trip) |
| Data model | every `valid` vector is accepted, every `invalid` vector is rejected with the expected error class |
| Lexicon | same, against indigo's lexicon and record-data vectors |
| LtHash / Space commit | vectors from the alpha image match |

### 3.2 Property tests (`stream_data`)

Invariants that goldens cannot enumerate (DESIGN §21.11):

- `decode(encode(term)) == term` and `encode(decode(bytes)) == bytes` for generated
  atproto-data-model terms (no floats, string keys, `%Bytes{}`/`%CID{}` wrappers).
- MST: any permutation of insertions of a random key set yields the same root; insert
  then delete returns to the previous root; `diff(a, b)` applied to `a` yields `b`.
- CAR: write then read returns the same block set and roots.
- TID: strictly increasing across `next/0` calls including simulated clock regression.
- Syntax: every generated valid handle/NSID/at-uri parses and re-formats identically.
- LtHash: add/remove commute; `remove(add(s, x), x) == s`.
- Signatures: every produced signature is low-S.

### 3.3 Mutation checks on the strict decoder

A small set of **deliberately corrupted** vectors (non-shortest ints, unsorted map keys,
missing `0x00` in tag 42, a float, an indefinite-length string) must each be rejected.
These are hand-written, not generated, and live in `dagcbor/invalid/`.

---

## 4. Storage and adapter contracts (L5)

Every behaviour in DESIGN has a shared contract suite run against every implementation:

| Behaviour | Suite | Implementations under test |
|---|---|---|
| `Aerox.ATProto.Blockstore` | get/put/get_many semantics, missing keys, idempotent puts | Memory, Postgres (`repo_block`), CAR reader |
| `Aerox.Blob.Store` (DESIGN §4.4) | two-phase write, idempotent delete, stream = get, quarantine round-trip, `list`, `delete_all` | Disk; S3 (against MinIO in CI) when built; Migrating (from/to Disk pairs) |
| `Aerox.Crypto.Signer` (DESIGN §14.2) | sign/verify, `did_key`, refusal of `Local` in prod config | Local; Kms (against LocalStack in CI); Remote (against a test signer) |
| `Aerox.AppView.Search` (DESIGN §15.8) | CJK substring queries, typeahead prefix, ranking stability | Postgres |
| Lexicon registry | known?/lookup, ref resolution across files, merge of dynamic docs | compile-time registry, extended registry |

The Postgres-backed suites run inside the Ecto sandbox against the two real databases.

---

## 5. Service tests (L6)

ExUnit per service, with the service's own Repo in sandbox mode. External behaviours
are `Mox`-mocked (HTTP resolver, mailer adapter, Signer); outbound HTTP that must be
exercised for real uses `Req.Test` / `Bypass` with recorded upstream responses.

What each service must prove in isolation:

**PDS**
- Record write path: `createRecord`/`putRecord`/`deleteRecord`/`applyWrites` produce a
  commit whose CAR round-trips through the kernel; `repo_root` advances; the sequencer
  emits exactly one event per commit with the correct ops and `prevData`.
- Per-account serialisation: N concurrent writes to one DID produce N sequential commits
  (row lock, DESIGN §21.3); writes to different DIDs interleave.
- Sequencer: seq strictly monotonic under concurrency; batches flushed by size and by
  time; `last_seq` restored after a simulated crash; **no gap or duplicate** across restart.
- Unknown-lexicon admission (DESIGN §6.3): three-state `validate` behaves as upstream.
- Blob upload: temp → permanent; CID mismatch rejected; `record_blob` refs; reaper
  removes orphans and alerts on missing objects.
- Auth: legacy sessions; OAuth PAR→authorize→token→refresh with DPoP; nonce rotation;
  scope evaluation including `include:` and `space:` grammar; every rule in DESIGN §20.2
  for inbound service JWTs (wrong `aud`, wrong `lxm`, replayed `jti`, expired, high-S,
  future `iat`) rejected.
- Proxying (§11.1): `app.bsky.*` forwarded with a correct service JWT; the local
  exceptions (preferences, registerPush) served locally.
- Account lifecycle (§18.3): every transition and its firehose events; deletion purges
  rows and blobs; takedown hides.
- Rate limits (§18.2): each declared limit trips at its threshold with correct headers;
  proxy-trust rule for `x-forwarded-for`.
- Email (§18.1): tokens single-use, expiring, one outstanding per purpose; mail rendered
  for each purpose (Swoosh test adapter).

**PLC**
- The official `did-method-plc` vectors; priority-by-index nullification within 72 h and
  refusal after; `/export` streaming; `removeInvalidOps` is audited and alerting.
- Accepts `#atproto_space` / `#atproto_space_host` (DESIGN §8 item 7).

**Relay**
- Per-host consumer: verifies inductively, drops invalid commits, counts errors, pauses
  the host past the threshold, resumes from `host.cursor`.
- Re-sequencing: output seq monotonic; retention window enforced; `OutdatedCursor` info
  frame for stale cursors.
- Slow subscriber: a subscriber that stops reading is disconnected before the node's
  memory grows (assert on `message_queue_len` threshold, DESIGN §21.4).

**AppView**
- Each of the 19 plugins: insert, delete, aggregates, and the notifications it emits,
  from recorded real records (goldens in `firehose/`).
- Ingest: Broadway partitioning keeps per-DID order under parallelism; the cursor is
  persisted and resumed; `#identity` replay **does not** null a good handle (the
  regression test for the handle-churn incident).
- Read path: skeleton→hydrate→present for timeline, author feed (all filters), thread
  (gates, blocked/not-found placeholders), likes/reposts/quotes, notifications
  (reasons, unread count, seen), custom feed via a mocked feedgen.
- Labels: subscription cursor, self-labels, `atproto-accept-labelers`, takedown hiding.
- Search: CJK substring queries return expected posts; typeahead prefix.
- Private state: writes accepted only for `iss` = row DID.

**Labeler / moderation**
- Label signing and `subscribeLabels` replay; `mod_event` append-only; every `Actions`
  operation idempotent and replayable from the log; takedown propagation calls the PDS
  admin API and the CDN purge.

**Image CDN**
- URL parsing for all presets and formats; origin fetch only from resolved DID docs;
  loopback allowed only when configured; libvips concurrency bound respected under
  load; cache LRU and purge.

---

## 6. Cross-service integration (L7)

Runs the **all-in-one stack** (`config :aerox, :services, [:pds, :plc, :relay, :appview, :labeler]`)
against a fresh pair of databases, then drives it through the public API with the
TypeScript `@atproto/api` client (the same client `ouranos` uses) from a small Node
harness. Scenarios:

1. Sign up → confirm email (test mailbox) → create post → the post appears in the
   author's own timeline via PDS→Relay→AppView within N seconds.
2. Follow, like, reply, repost, quote → correct notifications and counts on both sides.
3. Block and mute → placeholders and filtering in thread and timeline.
4. Custom feed → a stub feedgen receives a valid service JWT and its skeleton is hydrated.
5. Profile with avatar → `/img/avatar/...` serves a resized image; takedown purges it.
6. OAuth: a confidential test client completes PAR/PKCE/DPoP, calls the PDS, refreshes,
   is revoked.
7. Labeler applies a label → the AppView shows it under the accepted-labelers header;
   a report round-trips; a takedown hides the subject everywhere.
8. Account migration between two aerox PDS instances in the same stack via Layer A
   (DESIGN §13.1) — identity, repo, blobs, prefs, activation.
9. Spaces (when built): `bulletin`'s flows — create a `simplespace`, mint a delegation
   token and a space credential with DPoP, write and incrementally sync a repo,
   `notifyWrite` delivered by Oban.

Each scenario asserts on **both** API responses and database state, and every
scenario ends with a reconciliation query (counts in PDS tables vs AppView tables).

---

## 7. Consistency, interoperability and connectability against upstream (L8)

### 7.1 Endpoint parity: the same data, the same answers

Byte-level goldens (§3) prove the kernel; they do not prove that `getPostThread`
returns what a client expects. Parity testing does:

1. **Seed identical data into two stacks** — the upstream reference stack (PDS + indigo
   relay + `bsky-standalone` AppView + PLC, from pinned containers) and the aerox
   all-in-one stack — by replaying one recorded scenario script through `@atproto/api`
   against each (accounts, follows, posts with embeds and facets, replies, quotes,
   likes, reposts, blocks, mutes, lists, gates, labels, profile updates).
2. **Call every implemented XRPC endpoint on both** with the same parameters and the
   same authenticated user, and **diff the normalised JSON**. Normalisation strips only
   what legitimately differs: `indexedAt` timestamps, cursor opaque strings (compared
   for equivalence of the page they yield, not their text), image CDN hostnames.
3. **Coverage is enumerated**: a table `test/parity/ENDPOINTS.md` lists every endpoint
   aerox serves, whether it is under parity test, and any documented deviation
   (e.g. `getSuggestions` returns empty by design, DESIGN §15.4). An endpoint absent
   from the table cannot be routed — the router test reads the table.
4. **Firehose parity**: the sequence of `subscribeRepos` frames produced by the two
   PDSs for the same scenario is compared op-by-op (`prevData`, ops, block sets,
   `#account`/`#identity` events), and the two relays' outputs likewise.
5. **Error parity**: the same invalid requests (bad params, unknown lexicon with
   `validate=true`, unauthenticated write, rate-limited, blocked interaction) yield the
   same XRPC `error` names.

Deviations are allowed only when listed in `ENDPOINTS.md` with a DESIGN reference.

**How it is run.** The reference stack is `tools/interop/compose.yaml`: upstream's
PDS distribution, `did-method-plc`, the indigo relay, and `ref-appview` — the
bsky AppView built from the reading-room checkout of `bluesky-social/atproto`
with `tools/interop/bsky-standalone` as its entrypoint (the data plane, a bsync,
the AppView and both subscriptions in one process, wired the way upstream's own
`packages/dev-env` wires them). The driver is `test/harness/parity.mjs`: it
replays one scenario through `@atproto/api` against each stack's PDS and diffs
the normalised JSON of every call, as the same authenticated user on both. Both
seeds use one fixed `createdAt`, so a record whose bytes mention no DID must come
out with the same CID on both sides — the run refuses to compare anything if that
fails, because then the two seeds are not the same data.

### 7.2 Upstream servers and clients as counterparts

CI pins upstream containers and runs aerox against them in both directions:

| Counterpart | What is proven |
|---|---|
| **Reference PDS** (`ghcr.io/bluesky-social/pds:0.4`) | our Relay ingests its firehose and verifies every commit; our AppView indexes it; an account migrates from it into aerox and back via Layer A |
| **indigo relay** | it accepts our PDS (`requestCrawl` → it consumes our `subscribeRepos`, lists our repos, passes our commits through its inductive verification); our Relay accepts *it* as an upstream host |
| **bsky AppView** (`services/bsky-standalone`) | indexes our PDS's output via the indigo relay; counts and views agree with our AppView (7.1) |
| **PLC** (`did-method-plc`) | operations we sign are accepted by the reference directory; our directory accepts theirs; `/export` streams agree; a DID created on one resolves identically on the other |
| **`@atproto/api` client** | logs in (legacy and OAuth), reads and writes through our PDS exactly as against upstream; `ouranos` renders |
| **Spaces alpha image** (`ghcr.io/bluesky-social/atproto:pds-spaces-alpha`) | LtHash/commit vectors; `bulletin` runs against our PDS; our credentials are accepted by the alpha PDS as repo host and vice versa |

The interop suite is the **release gate**: a change that breaks any row does not ship,
whatever the unit tests say. It runs nightly and on release branches.

### 7.3 Network connectability and federation readiness

The network is not federated (DESIGN §1), but every mechanism federation relies on is
verified now, over real protocols rather than in-process shortcuts:

| Mechanism | Test |
|---|---|
| **Discovery of a PDS** | `describeServer`, `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource`, `/.well-known/did.json` (service DID) are served over real TLS on a test domain and parsed by upstream's client and by our resolver |
| **Handle resolution** | for a test domain, both paths work end to end: `_atproto` DNS TXT (a real resolver against a test zone) and HTTPS `/.well-known/atproto-did`; mismatch yields `handle.invalid` |
| **DID resolution** | `did:plc` via our directory and via the reference directory; `did:web` from a test host; caching TTLs and invalidation on `#identity` observed |
| **Being crawled** | the indigo relay's `requestCrawl` against our PDS over TLS; our PDS appears in its `listHosts`; its consumer stays connected across our PDS restart and resumes from cursor |
| **Crawling** | our Relay's `requestCrawl` for a reference PDS host; validation of the host; consumer reconnect with back-off after the host restarts; `OutdatedCursor` path when the host's window is exceeded |
| **WebSocket semantics** | keepalive/ping handling, clean close codes, reconnect with `cursor` yielding no gap and no duplicate (asserted by seq continuity on both sides), behaviour when a client presents a future cursor |
| **Cursor durability across restarts** | PDS, Relay and AppView each restarted mid-stream; downstream resumes with exactly-once delivery of every event (verified against the sequencer's event tables) |
| **Proxy path over the network** | `app.bsky.*` through a PDS on one host to an AppView on another, with service-JWT verification requiring a real DID resolution round trip |
| **Inter-service auth under DNS/TLS** | the AppView verifies a service JWT whose `iss` resolves through the real PLC; certificate errors and DNS failures produce the intended XRPC errors, not timeouts |
| **Clock skew** | ±60 s skew between hosts is tolerated for JWTs; larger skew rejected with a clear error |
| **Two aerox instances** | two PDS instances behind different hostnames, one Relay: both crawled, both indexed; Layer A migration between them over the network; a `did:web` account brought to one of them |

These run on a small multi-container topology (separate network namespaces per
service, a real DNS server for the test zone, real certificates from a test CA) so that
"connectable" means connectable, not "works in one BEAM node".

### 7.4 Other PDS implementations on one network

The upstream containers of §7.2 prove agreement with Bluesky's own code. They
cannot show how aerox behaves among implementations that read the specs
differently. For that, aerox joins the multi-implementation lab network on
generic.dev as an eighth member: seven PDSes (reference TypeScript, atproto-crates,
tranquil, pegasus, zds, cocoon, rsky), one PLC directory, an indigo relay and a
bsky AppView.

The aerox side is a second dev server, `tools/interop/lab-devserver.sh`, on
`lab.aerox.sola.town`. It registers and resolves DIDs on the lab's PLC. The
driver is `test/harness/lab.mjs`, and it checks in both directions:

| Area | What is proven |
|---|---|
| Crawl and index | each relay crawls every PDS, including the other's; each AppView indexes every implementation's posts |
| Proxy | `app.bsky.*` through every PDS to both AppViews, with viewer-authenticated service JWTs |
| Social graph | follows, likes, replies and images across all eight; counts, threads, thumbnails and notifications agree |
| Lifecycle | `#identity`, deletions, `#account` deactivation and reactivation from each implementation |
| Migration | the standard account-migration flow to and from aerox for each implementation, with control pairs between lab PDSes to tell a counterpart's fault from aerox's |

Results, the aerox defects the run found and fixed, and the counterparts'
deviations are in `INTEROP_LAB.md`.

### 7.5 Our own browser client as a counterpart

`aero` (`../aero-app`, https://aero.sola.town) exercises the services the way a
client actually does: real browser, real CORS, real WebSockets, real DPoP, no
in-process shortcuts. Its Playwright suite is part of the gate for anything it
covers — each run signs up throwaway accounts on the dev stack and cleans up
after itself.

| Suite | What it proves about aerox |
|---|---|
| `test/e2e.mjs` | sign-up, posting with facets and blobs, follows, likes, replies, notifications, threadgates/postgates, lists, starter packs, muted words, app passwords, account deletion |
| `test/oauth.mjs` | the OAuth authorization server end to end from a discoverable browser client (DESIGN §11.2): client-metadata fetch, PAR, consent, code exchange, a DPoP-bound token writing to the repo, restore after reload, revoke |
| `test/admin.mjs` | `com.atproto.admin.*` behind HTTP Basic (takedown/restore, handle, email and password changes, `temp.revokeAccountCredentials`, `deleteAccount`, invite codes) and the relay's `admin.*` host controls (`subscribeHost`, `setHostStatus`, `setHostAccountLimit`, `banDomain`) |
| `test/labels.mjs` | `com.atproto.label.subscribeLabels` framing (header + body DAG-CBOR), replay from a sequence, and **label signatures verified in the browser** against the labeler's key from its DID document; `queryLabels` and `temp.fetchLabels` |
| `test/batch.mjs` | the batch lexicons answer for a page of subjects: it counts the browser's XRPC calls and fails if `getPosts`/`getProfiles` are called more than once, or if anything is fetched per item |
| `test/spaces.mjs` | Spaces (DESIGN §12) across two accounts: delegation token → space credential (DPoP, `cnf.jkt`), cross-repo reads, oplog and LtHash commit, mint policies |
| `test/migrate.mjs` | the account-migration flow between two aerox instances on one PLC directory, driven from the UI |
| `test/custody.mjs` | self-custody of `did:plc` identities (SELF_CUSTODY.md), also against the reference PDS + `did-method-plc` |
| `test/archive.mjs` | Jetstream's sealed segments (DESIGN §22): `listSegments`, a block decoded in the browser (zstd → columnar layout → DAG-CBOR), and `planSnapshot` executed client-side |
| `test/moderation.mjs` | the labeler's admin API (DESIGN §17.3) and the label's effect on what a reader sees |

## 8. Portability (L9)

From DESIGN §13.3, as executable tests:

- **PG → bundle → PG**: byte-identical `repo_block`, equal rows in every table, blobs
  bit-identical, login with a known password still works.
- **PG → bundle → reference-PDS dir → boot the stock image → `getRepo`** returns the
  same block set and commit; `checkAccountStatus` fields equal.
- **Reference-PDS dir → bundle → PG**: MST root recomputed from `repo.car` equals the
  source `repo_root.cid`; counts equal the snapshot's own baseline; `max(seq)` equal in
  takeover mode.
- Bundle manifest tampering (any hash altered) is detected before any DB write.
- Encrypted bundles decrypt only with the intended recipient key / passphrase
  (whichever scheme DESIGN §13.0 settles on).
- **The did-map regression**: an import whose progress table says "done" for every DID
  against an empty target must fail loudly, not report success.

---

## 9. Regression tests named after incidents

Each of these is a single, named test that must exist and stay green:

| Test name | Incident (deployment notes) | Assertion |
|---|---|---|
| `handle_churn_identity_replay` | `#identity` replay nulled handles (2026-08-24) | replaying identity events after a resolver timeout never overwrites a resolved handle with NULL |
| `import_is_rerunnable` | rice insert-only import | importing the same bundle twice with changed mutable fields converges to the second version |
| `import_reports_zero_work_as_failure` | did-map survived destroy (2026-08-23) | non-empty source + zero imported ⇒ non-zero exit |
| `image_origin_loopback_dev_only` | AppView SSRF blocked loopback PDS (images 502, counts green) | loopback origin allowed iff configured; integration test on the dev stack renders an image |
| `blob_reaper_never_deletes_referenced` | yatch orphan blobs | reaper deletes only CIDs unknown to Postgres and alerts on missing referenced objects |
| `handle_domains_survive_migration` | rice login by handle | imported accounts keep their handle domain; `createSession` by handle succeeds |
| `sequencer_no_gap_on_restart` | (design, §5.3) | kill the sequencer mid-batch; after restart, seq continues with no gap or duplicate and no event lost |
| `slow_subscriber_is_disconnected` | (design, §21.4) | a non-reading subscriber is dropped before its mailbox exceeds the threshold |
| `plc_op_count_invariant` | production rotation-key safeguard | any code path that signs a PLC op records before/after counts and fails on mismatch |
| `host_status_survives_cursor_persist` | a throttled host resurrected itself (2026-09-16) | terminating a consumer persists its cursor without overwriting a status an operator set; `test/relay/consumer_test.exs` |
| `reconcile_resubscribes_orphaned_host` | same incident, the invisible half | an `active` host with no consumer is re-subscribed by `Consumers.reconcile/0` rather than waiting for a restart |

---

## 10. Operational verification (L10)

### 10.1 Load baselines

Measured on a fixed reference machine before launch and re-measured per release:

- PDS: record writes/s for one hot account and for 1 000 accounts; p99 latency of
  `createRecord`, `getRecord`, proxied `getTimeline`; service-JWT signing cost per
  proxied request (the first place pure-Elixir crypto will be felt, DESIGN §11.3).
- Sequencer: events/s with coalescing on vs off.
- Relay: fan-out to 1, 100, 1 000 subscribers; memory per subscriber.
- AppView: ingest events/s by partition count; timeline p99 under concurrent readers.
- Image CDN: images/s at the libvips concurrency bound; cache hit ratio.

Numbers are recorded in `bench/RESULTS.md` with the commit; a regression beyond a set
percentage fails the release checklist.

### 10.2 Process and dependency faults (BEAM-specific)

Run on the all-in-one stack with the API under light load. Every case asserts three
things: **no lost event, no duplicated event, recovery without operator action**.

- Kill the sequencer, a Relay host consumer, the Broadway pipeline, Oban, an image
  worker — each restarts per its supervision strategy; sequence numbers stay gap-free.
- Kill the whole PDS VM mid-batch — on restart `last_seq` is correct and subscribers
  resume from their cursors with exactly-once delivery.
- Stop Postgres for 30 s — services return errors, do not crash-loop, recover when it
  returns (DESIGN §21.9); Oban jobs enqueued before the outage run after it.
- Stop the PLC directory — resolution continues from cache within TTL; new-account
  creation fails cleanly; recovery re-validates.
- Stop the mail provider — tokens are issued, mails queue in Oban with back-off and
  are delivered when it returns; the API never waits on mail.
- Stop a blob origin PDS — the image CDN serves cached variants and returns a clean
  error for uncached ones; no request pile-up.
- Saturate dirty schedulers with image requests — signature latency stays bounded
  (DESIGN §21.8).
- Fill a subscriber's mailbox — it is disconnected; the node's memory stays flat.
- Exhaust the DB pool — requests fail fast with a clear error rather than queueing
  without bound.

### 10.3 Network faults

The multi-container topology of §7.3 with **Toxiproxy** (or `tc netem`) on every
inter-service link: PDS↔Relay, Relay↔AppView, AppView↔PDS (`getBlob`, `getRepo`),
every service↔PLC, PDS↔mail, PDS↔client-metadata hosts.

| Fault | Expected behaviour |
|---|---|
| Partition PDS↔Relay for 1, 10, 60 min | the Relay's consumer backs off and reconnects with its cursor; the PDS's `repo_seq` window covers the gap; after reconnection seq continuity holds; beyond the window `OutdatedCursor` is emitted and the AppView backfills the affected repos |
| Partition Relay↔AppView | Broadway stops demanding; the producer stops reading; on heal the cursor resumes with no duplicates |
| Added latency (200 ms, 2 s) and 5 % packet loss on all links | timelines still render within SLO; no request exceeds its timeout budget silently; retries are bounded |
| Half-open connections (drop ACKs) | WebSocket keepalive detects the dead peer within the configured interval and reconnects |
| DNS failure for the PLC or a PDS host | cached identities keep working within TTL; uncached resolution fails with the intended error; negative cache bounds retry storms |
| TLS certificate rotation on a peer mid-stream | reconnect succeeds; no stale-cert pinning |
| Slow client on the firehose (bandwidth capped) | that subscriber alone is throttled/disconnected; other subscribers unaffected |
| Flapping link (connect/disconnect every few seconds) | back-off grows; host is paused after the threshold and resumes on manual/automatic probe |

### 10.4 Drills

- **Restore drill**: from the physical backup (pg_dump + blob store) to a fresh host;
  and separately from bundles. Both must produce a stack that passes §6 scenario 1.
  Run before launch and quarterly.
- **Migration drill**: the reference-PDS takeover (DESIGN §13) against a snapshot of
  the real production data directory, on a target machine, with the reconciliation
  report — the thing that must be green before any real cutover.
- **Rotation-key drill**: with the offline recovery key (DESIGN §14.2), nullify a test
  operation within the 72-hour window on the dev PLC.

---

## 11. CI matrix

| Stage | Trigger | Contents | Time budget |
|---|---|---|---|
| fast | every push | `mix compile --warnings-as-errors`, `mix format --check-formatted`, credo, dialyzer (cached), L0–L5 unit/property/contract tests against Postgres | < 10 min |
| services | every push | L6 per-service suites | < 15 min |
| integration | PRs to main, nightly | L7 all-in-one scenarios via the Node harness | < 30 min |
| interop | nightly, release branches | §7.1 endpoint parity, §7.2 upstream containers, L9 round-trips including boot-the-stock-image | < 90 min |
| network | nightly, release branches | §7.3 multi-container connectability, §10.3 network faults | < 60 min |
| golden-provenance | weekly | re-fetch upstream goldens at pinned commits and diff; report upstream drift | — |
| bench | release branches | §10.1 baselines | — |

Test databases are created per job (`aerox_pds_test`, `aerox_core_test`); the test
helper refuses to run if either is missing, and the sandbox is enabled on both repos.

---

## 12. Definition of done, per build phase (DESIGN §9)

| Phase | Done when |
|---|---|
| Kernel | L0–L4 golden suites green with committed manifests; property suites green; a real CAR from the reference PDS loads and its root recomputes; strict-decoder mutations rejected |
| PLC | official vectors green; §5 PLC tests; interop row "PLC" green |
| PDS (public repo + OAuth + mail + limits + bundle) | §5 PDS tests; §6 scenarios 1–2, 6; interop rows "indigo relay" and "`@atproto/api`" green; §8 PG→bundle→PG round-trip green |
| Relay | §5 Relay tests; interop row "Reference PDS" (ingest) green; slow-subscriber test green |
| AppView + image CDN | all 19 plugin suites; §6 scenarios 1–5; interop row "bsky AppView" parity on counts; `ouranos` logs in and renders a timeline with images |
| Labeler / moderation | §6 scenario 7 |
| Spaces | LtHash/commit goldens from the alpha image; §6 scenario 9 with `bulletin` |
| Migration readiness | §10.4 migration drill green against a real snapshot; every §9 regression test present |
| Release (any) | §7.1 parity table has no unlisted deviation; §7.2 and §7.3 green; §10.2 and §10.3 run on the release branch with no lost/duplicated event |

---

## 13. What we do not test

- Upstream's own correctness. Goldens are taken as truth; if a golden looks wrong, the
  action is to check upstream's newer commits, not to "fix" the vector.
- Client UI behaviour. `ouranos` and `bulletin` are used as black-box drivers of our
  API; their rendering is not our test subject.
- Performance of pure-Elixir kernel code before it is correct (DESIGN §3.9). Benchmarks
  begin at the PDS phase, not the kernel phase.
