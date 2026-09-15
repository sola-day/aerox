# aerox — Parity with upstream and coverage of the protocol specs

Two questions, answered against pinned sources so the answers can be re-checked:

1. **What does aerox do differently from Bluesky's reference implementation?**
   Upstream is the reading room's `bsky/atproto` at `62f944dd6` (2026-07-01:
   `packages/pds`, `packages/bsky`, `packages/ozone`) and `bsky/indigo` at
   `dfe5578f` (the relay). aerox's side is `test/parity/ENDPOINTS.md`, which
   `test/aerox_web/router_parity_test.exs` keeps in step with the routers.
2. **Which parts of the protocol specification does aerox not implement?**
   The specs are `bsky/atproto-website` at `da79e7a4` (2026-09-09),
   `src/app/[locale]/specs/*/en.mdx` — nineteen documents.

Written 2026-09-15. Endpoint lists were produced by diffing upstream's
`src/api/**` file trees and every `query`/`procedure`/`subscription` in
`lexicons/com/atproto` against `ENDPOINTS.md`; behavioural claims marked
*verified* were checked against the running dev stack and the release host.

---

## Part 1. aerox and the reference implementation

### 1.1 Architecture

| | Upstream | aerox |
|---|---|---|
| Process model | PDS, AppView, data plane (gRPC), bsync, Ozone and the Go relay are separate services; a single-process AppView needed `bsky-standalone` and a resurrected `MockBsync` | One Mix app; `config :aerox, :services` picks what runs; `AeroxWeb.Dispatch` routes by `Host` (DESIGN §2) |
| AppView data access | AppView ↔ data plane over gRPC | AppView reads Postgres directly; no data-plane layer |
| PDS storage | One SQLite per account | One Postgres, all accounts in shared tables keyed by `did`; blob bytes in the blob store (DESIGN §4.1) |
| Search | palomar / OpenSearch | `Aerox.AppView.Search` behaviour; default Postgres `tsvector` + `pg_trgm` for CJK (DESIGN §15.8) |
| AppView firehose cursor | Not persisted; re-subscribes live (the `#identity`-replay handle-churn incident) | Persisted in `appview.subscription` and resumed (DESIGN §15.1) |
| PLC directory | Separate repository, `did-method-plc` | In-tree, route for route with `did-method-plc`'s server |
| Federation | A public network participant | Deliberately off: no plc.directory registration, no peering with official relays. The encoding layer is bit-exact regardless (DESIGN §1) |

### 1.2 What aerox has that upstream does not

- **Spaces / permissioned data (proposal 0016).** `com.atproto.space.*` (21 methods)
  and `com.atproto.simplespace.*` (7), all exercised end to end by `bulletin`.
  The reference PDS at this commit has no `com.atproto.space` handlers at all;
  upstream ships only the client-side alpha package `@atproto/space`.
- **Bulk migration from a reference PDS.** Accounts, repos, blobs and secrets move
  as an encrypted bundle (DESIGN §13, `docs/BUNDLE.md`). Upstream offers
  per-account migration (`goat`) only.
- **Relay operations in the same stack.** `listHosts`, `getHostStatus` and the
  `admin.*` host controls exist in indigo but not in the TypeScript stack.

### 1.3 What upstream has that aerox does not

**AppView — 48 methods.**

| Area | Methods | Why absent |
|---|---|---|
| `app.bsky.unspecced.*` | 15: trends, trending topics, suggested users / feeds / starter packs, onboarding, age assurance state, `getPostThreadV2`, `getPostThreadOtherV2`, `getTaggedSuggestions` | Discovery is not in v1 (DESIGN §15.4); `getSuggestions` answers an empty list |
| `app.bsky.contact.*` | 8: contact import, phone verification, matches | Product feature, not planned |
| `app.bsky.notification.*` | 7: `getPreferences`, `putPreferences`, `putPreferencesV2`, `listActivitySubscriptions`, `putActivitySubscription`, `registerPush`, `unregisterPush` | Push delivery (upstream's courier, APNs/FCM) is not in v1 (DESIGN §15.5) |
| `app.bsky.draft.*` | 4 | Product feature |
| `app.bsky.bookmark.*` | 3 | Product feature |
| `app.bsky.ageassurance.*` | 3 | Product / jurisdictional feature |
| Other | `feed.searchPostsV2`, `feed.getSuggestedFeeds`, `graph.getSuggestedFollowsByActor`, `graph.searchStarterPacks`, `graph.getListsWithMembership`, `graph.getStarterPacksWithMembership`, `embed.getEmbedExternalView`, `com.atproto.temp.fetchLabels` | Not yet needed by `ouranos` |

**Moderation — the largest gap.** Ozone serves about seventy `tools.ozone.*`
methods: queues (`queue.*`), the report workflow (`report.*`), safelink rules,
communication templates, scheduled actions, reporter statistics, sets,
verification, and moderator views of chat. aerox serves three
`aerox.moderation.*` methods (`emitEvent`, `queryEvents`, `queryReports`) on the
labeler plus the standard `com.atproto.admin.*` on the PDS. This is deliberate
(DESIGN §17.3): the `Actions` behaviour and the event log are shaped so that the
`tools.ozone.*` mapping is mechanical, but until it is built **Ozone's web UI
cannot be pointed at aerox**.

**PDS — 5 methods.** `app.bsky.notification.registerPush` / `unregisterPush`,
`com.atproto.server.createInviteCodes` (bulk; aerox has per-account invites
only), `com.atproto.server.reserveSigningKey`, `com.atproto.temp.checkSignupQueue`.

**Jetstream — not implemented.** `bsky/jetstream` (at `58c4d7f`, 2026-09-04) is a
separate Go service in front of a relay: a JSON firehose filterable by DID and
collection (the frozen v1 `/subscribe` wire, and the v2
`network.bsky.jetstream.subscribeEvents` on proposal 0015's `xrpc.v1.json`
framing with dictionary zstd), plus a full-network columnar archive with
`planSnapshot` backfill and cut-over to the live tail. aerox has none of it:
no JSON subscription on any host, no collection filtering on a stream, no
archive (the relay is non-archival). A consumer that wants JSON has to decode
DRISL-CBOR `subscribeRepos` itself — or run upstream's jetstream against aerox's
relay, which speaks the standard `subscribeRepos` it consumes (not yet tried).
The design has not yet ruled on whether to build it.

**Neither side.** Video (`app.bsky.video.*`) and chat (`chat.bsky.*`) have
lexicons upstream but no open-source server; aerox lists both as non-goals.

### 1.4 What has been shown identical

The parity run of 2026-09-10 (`test/harness/parity.mjs`) diffed **21 AppView
endpoints against upstream's own stack: 21 identical** after normalisation.
Details, and the one endpoint where the *reference* side is nondeterministic
(`listNotifications`), are in `test/parity/ENDPOINTS.md`.

### 1.5 Deliberate behavioural deviations

- The relay is **non-archival**: `getRepo`, `getRecord`, `getBlocks`, `getBlob`,
  `listBlobs` answer 404 naming the hosting PDS (DESIGN §19).
- `createAccount` takes no `plcOp` input; the DID is minted on the PDS (DESIGN §18.3).
- The PDS proxy is pure pass-through, with no read-after-write patching (DESIGN §11.3).
- `com.atproto.admin.getInviteCodes` returns an empty list; invite codes exist per
  account only.

---

## Part 2. Coverage of the protocol specs

### 2.1 Implemented

| Spec | Coverage |
|---|---|
| Data Model, CID, TID, NSID, Record Key, AT URI | Kernel (`lib/aerox/atproto`), checked against the golden corpus (VERIFICATION §2–3) |
| Cryptography | P-256 and K-256, low-S signatures enforced, multibase `did:key` encoding |
| Repository | MST, signed commits, diffs, record-operation inversion (`Repo.verify_commit_message`) |
| DID | `did:plc` minted on signup; `did:web` accounts brought by the user and validated (DESIGN §14.3); services identify as `did:web` |
| Handle | Syntax, reserved/slur checks, DNS TXT and HTTPS well-known resolution |
| XRPC | Error shapes, pagination, legacy sessions, app passwords, admin Basic auth, inter-service JWTs with `lxm`, `atproto-proxy` service proxying |
| Event Stream | DRISL-CBOR framing, cursor semantics including `FutureCursor`, `OutdatedCursor` and `ConsumerTooSlow` — *except the HTTP status codes in 2.2* |
| Sync | `#commit` / `#sync` / `#identity` / `#account`; relay verifies signatures, rejects future revs (5-minute window), enforces the 2 MB / 200-op limits, checks the account's host — *except the items in 2.2* |
| Blob | Temp upload → tethered by a record → orphan collection; takedowns 404 |
| Account | All five hosting statuses, propagation over `#account`, the full migration endpoint set (`getRecommendedDidCredentials`, PLC signing, `importRepo`, `listMissingBlobs`, `activateAccount`) |
| OAuth | Client metadata documents, loopback clients, PAR, PKCE, DPoP with nonces, `private_key_jwt`, server metadata, a consent interface |
| Permission | `repo`, `rpc`, `blob`, `account`, `identity` resources, `transition:*` scopes, `include:` expansion — *expansion only from the vendored registry, see 2.2* |
| Label | Signed labels with `ver`, negation, expiry, self-labels, `queryLabels`, `subscribeLabels`, the `atproto-accept-labelers` / `atproto-content-labelers` headers |

### 2.2 Not implemented, or not to spec

Ordered by consequence.

1. **Lexicon publication and resolution** (Lexicon spec). Nothing resolves
   `_lexicon.<authority>` DNS TXT records to a `com.atproto.lexicon.schema`
   record, and `com.atproto.lexicon.resolveLexicon` is not served. The visible
   consequence is in the **Permission** spec: authorization servers are to
   "resolve, authenticate, and process permission-sets dynamically", but
   `Aerox.Auth.Scopes.grant/2` looks `include:` NSIDs up only in the vendored
   registry. A third-party app that requests `include:<its own permission set>`
   has that scope expand to **no permissions** — its consent screen shows nothing
   and its token grants nothing.

2. **`Atproto-Repo-Rev` response header** (Sync spec). The AppView never sets it,
   although `actor_sync.repo_rev` holds the value. Clients cannot tell
   whether their own latest write has been indexed. *Verified:* `getProfile`
   through the PDS proxy returns no such header. (The PDS proxy and CORS
   configuration already pass it through.)

3. **Stream endpoint HTTP errors** (Event Stream spec). A `GET` without
   `Upgrade` should be `426` and a non-`GET` `405`, both with an XRPC JSON error
   body. aerox answers **500** (a `WebSockAdapter.UpgradeError`) and **501**.
   *Verified* on `subscribeRepos` (PDS, relay) and `subscribeLabels`, on both the
   dev host and the release host.

4. **Record-level sync state in the AppView** (Sync spec, "Reliable Repository
   Synchronization" and "Record-Level Synchronization"). The indexer verifies each
   commit in isolation but does not check `since` against the last `rev` or
   `prevData` against the last `data`, does not drop events with a `rev` at or
   below the last processed one, does not ignore commits for inactive accounts,
   and has no `desynchronized` / `in-progress` / `synchronized` state with events
   queued during a resync. A broken chain therefore goes unnoticed until the next
   `#sync` or a manual backfill. The relay compares `prevData` but only logs a
   mismatch (as indigo does).

5. **`com.atproto.sync.listReposByCollection`** — routed on the relay, answers
   `MethodNotImplemented`; it needs a collection index (DESIGN §19). The Sync spec
   names it as the way to backfill previously-active accounts.

6. **Identity resolution endpoints** — `com.atproto.identity.resolveDid`,
   `resolveIdentity`, `refreshIdentity` are not served by any aerox service.

7. **Remaining `com.atproto` methods** — `admin.searchAccounts`,
   `admin.updateAccountSigningKey`, `server.createInviteCodes`,
   `server.reserveSigningKey`, and seven `com.atproto.temp.*` methods (mostly
   Bluesky-operational: signup queue, phone verification, reserved handles,
   `checkHandleAvailability`, `dereferenceScope`, `revokeAccountCredentials`,
   `fetchLabels`).

8. **Streamable CAR block ordering** (Repository spec; marked work in progress,
   "not included in popular implementations"). `Repo.export_car/2` writes the
   commit, then every MST node, then every record, and builds the file in memory.
   The streamable order interleaves records after the node that lists them.

9. **Minor.** The Sync spec says consumers should *ignore* the deprecated
   `tooBig` flag; the relay rejects commits carrying `tooBig: true`. The spec also
   suggests a relay may redirect `getRepo` to the PDS; aerox answers 404 naming it.
