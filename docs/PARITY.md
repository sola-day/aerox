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

Written 2026-09-15 and updated the same day, after the gaps in Part 2 and
Jetstream were implemented. Endpoint lists were produced by diffing upstream's
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
- **Jetstream in the same release.** Upstream's Jetstream is a separate Go
  service; aerox's (§22 of DESIGN) speaks its v1 and v2 streams and its archive
  API over our Relay, with byte-compatible segment files.
- **Relay operations in the same stack.** `listHosts`, `getHostStatus` and the
  `admin.*` host controls exist in indigo but not in the TypeScript stack.

### 1.3 What upstream has that aerox does not

**AppView — 47 methods.**

| Area | Methods | Why absent |
|---|---|---|
| `app.bsky.unspecced.*` | 15: trends, trending topics, suggested users / feeds / starter packs, onboarding, age assurance state, `getPostThreadV2`, `getPostThreadOtherV2`, `getTaggedSuggestions` | Discovery is not in v1 (DESIGN §15.4); `getSuggestions` answers an empty list |
| `app.bsky.contact.*` | 8: contact import, phone verification, matches | Product feature, not planned |
| `app.bsky.notification.*` | 7: `getPreferences`, `putPreferences`, `putPreferencesV2`, `listActivitySubscriptions`, `putActivitySubscription`, `registerPush`, `unregisterPush` | Push delivery (upstream's courier, APNs/FCM) is not in v1 (DESIGN §15.5) |
| `app.bsky.draft.*` | 4 | Product feature |
| `app.bsky.bookmark.*` | 3 | Product feature |
| `app.bsky.ageassurance.*` | 3 | Product / jurisdictional feature |
| Other | `feed.searchPostsV2`, `feed.getSuggestedFeeds`, `graph.getSuggestedFollowsByActor`, `graph.searchStarterPacks`, `graph.getListsWithMembership`, `graph.getStarterPacksWithMembership`, `embed.getEmbedExternalView` | Not yet needed by `ouranos` (`com.atproto.temp.fetchLabels` is served, by the labeler) |

**Moderation — the largest gap.** Ozone serves about seventy `tools.ozone.*`
methods: queues (`queue.*`), the report workflow (`report.*`), safelink rules,
communication templates, scheduled actions, reporter statistics, sets,
verification, and moderator views of chat. aerox serves three
`aerox.moderation.*` methods (`emitEvent`, `queryEvents`, `queryReports`) on the
labeler plus the standard `com.atproto.admin.*` on the PDS. This is deliberate
(DESIGN §17.3): the `Actions` behaviour and the event log are shaped so that the
`tools.ozone.*` mapping is mechanical, but until it is built **Ozone's web UI
cannot be pointed at aerox**.

**PDS — 2 methods.** `app.bsky.notification.registerPush` / `unregisterPush`
(push delivery is not built, above). `createInviteCodes`, `reserveSigningKey` and
`temp.checkSignupQueue`, listed here before, are now served.

**Jetstream — implemented** (was listed missing). See §1.2 and DESIGN §22; the
one part of upstream not reproduced is its bootstrap's host-by-host crawl of PDSes
(aerox crawls its own Relay's `listRepos`, which lists the same accounts).

**Neither side.** Video (`app.bsky.video.*`) and chat (`chat.bsky.*`) have
lexicons upstream but no open-source server; aerox lists both as non-goals.

### 1.4 What has been shown identical

The parity run of 2026-09-10 (`test/harness/parity.mjs`) diffed **21 AppView
endpoints against upstream's own stack: 21 identical** after normalisation.
Details, and the one endpoint where the *reference* side is nondeterministic
(`listNotifications`), are in `test/parity/ENDPOINTS.md`.

Jetstream was checked with upstream's own clients against the dev stack
(2026-09-15): jetstream@58c4d7f's Go client replayed the whole archive (segments
fetched with `getSegment` and read by its segment reader), took a DID-filtered
plan mixing a whole segment with `getBlock` ranges (314 events, equal to the files
row for row), and cut over from replay to the live v2 stream without a gap;
jetstream-legacy's client read `/subscribe` with legacy-dictionary zstd, a
timestamp cursor and a wildcard collection filter.

### 1.5 Deliberate behavioural deviations

- The relay is **non-archival**: `getRepo`, `getRecord`, `getBlocks`, `getBlob`,
  `listBlobs` redirect (302) to the hosting PDS; a repo the relay has taken down is
  refused instead (DESIGN §19).
- `createAccount` takes no `plcOp` input; a new DID is minted on the PDS, and a
  brought DID (migration) needs a service JWT from that DID (DESIGN §18.3).
- `searchPosts` is Postgres substring search (DESIGN §15.8), always newest first:
  `sort=top` is accepted and ranked as `latest`, and an empty `q` lists every post.
  The `tag`, `mentions`, `author`, `lang`, `since` and `until` filters are served;
  `domain` and `url` are accepted and ignored.
- The PDS proxy is pure pass-through, with no read-after-write patching (DESIGN §11.3).
- Jetstream's zstd frames are libzstd's, not klauspost/compress's: every reader
  decodes them, but a byte-for-byte comparison with an upstream-written segment
  differs inside the frames (the metadata, blooms and collection index do not).

---

## Part 2. Coverage of the protocol specs

### 2.1 Implemented

| Spec | Coverage |
|---|---|
| Data Model, CID, TID, NSID, Record Key, AT URI | Kernel (`lib/aerox/atproto`), checked against the golden corpus (VERIFICATION §2–3) |
| Cryptography | P-256 and K-256, low-S signatures enforced, multibase `did:key` encoding |
| Repository | MST, signed commits, diffs, record-operation inversion (`Repo.verify_commit_message`), record proofs, the streamable CAR block order |
| DID | `did:plc` minted on signup; `did:web` accounts brought by the user and validated (DESIGN §14.3); services identify as `did:web` |
| Handle | Syntax, reserved/slur checks, DNS TXT and HTTPS well-known resolution |
| XRPC | Error shapes, pagination, legacy sessions, app passwords, admin Basic auth, inter-service JWTs with `lxm`, `atproto-proxy` service proxying; every `com.atproto` query and procedure in the lexicons is served by some service |
| Event Stream | DRISL-CBOR framing, cursor semantics including `FutureCursor`, `OutdatedCursor` and `ConsumerTooSlow`, and the connection-time HTTP errors (405, 426) |
| Sync | `#commit` / `#sync` / `#identity` / `#account`; relay verifies signatures, rejects future revs (5-minute window), enforces the 2 MB / 200-op limits, checks the account's host; `Atproto-Repo-Rev`; the AppView's record-level sync state (chain checks, resync, queued replay); `listReposByCollection`; repo-content redirects; `tooBig` ignored |
| Blob | Temp upload → tethered by a record → orphan collection; takedowns 404 |
| Account | All five hosting statuses, propagation over `#account`, and migration in both directions: inbound `createAccount` for a brought DID with a reserved key, `getRecommendedDidCredentials`, PLC signing, `importRepo`, `listMissingBlobs`, `activateAccount` |
| OAuth | Client metadata documents, loopback clients, PAR, PKCE, DPoP with nonces, `private_key_jwt`, server metadata, a consent interface |
| Permission | `repo`, `rpc`, `blob`, `account`, `identity` resources, `transition:*` scopes, `include:` permission sets resolved from the network, scope references (`ref:<cid>`) |
| Label | Signed labels with `ver`, negation, expiry, self-labels, `queryLabels`, `subscribeLabels`, the `atproto-accept-labelers` / `atproto-content-labelers` headers |
| Lexicon | Validation against the vendored registry; publication and resolution (`_lexicon` DNS → DID → verified record proof), `resolveLexicon` |

### 2.2 What this document listed as missing, and where it went

Every item below was open when Part 2 was first written; each is now implemented
and tested, in the commit named.

| # | Gap | Commit |
|---|---|---|
| 1 | Lexicon publication and resolution; `include:` permission sets resolved dynamically (an unresolvable set fails PAR; the consent page shows the set's title); `resolveLexicon` | `8930da2` |
| 2 | `Atproto-Repo-Rev` from the AppView | `c433be9` |
| 3 | Stream endpoints: 405 for non-GET, 426 without an upgrade | `3ed321d` |
| 4 | AppView record-level sync state: `since`/`prevData` chain checks, `desynchronized` / `in_progress` / `synchronized`, queued replay, reconciling backfill | `5782cb9` |
| 5 | `com.atproto.sync.listReposByCollection` on the relay | `c01eff2` |
| 6 | `com.atproto.identity.resolveDid`, `resolveIdentity`, `refreshIdentity` (PDS and AppView) | `34ca1f8` |
| 7 | `admin.searchAccounts`, `admin.updateAccountSigningKey`, `server.createInviteCodes`, `server.reserveSigningKey`, and the seven `temp.*` methods (`checkSignupQueue`, `checkHandleAvailability`, `addReservedHandle`, `revokeAccountCredentials`, `requestPhoneVerification`, `dereferenceScope`, `fetchLabels`) | `346cda1`, `cba52ac` |
| 8 | Streamable CAR block ordering; `getRepo` streamed | `15ca571` |
| 9 | `tooBig` ignored by consumers; relay repo-content redirects | `f33d1bb` |
| — | Found while closing 7: aerox could not *receive* a standard account migration (a brought `did:plc` was refused) | `346cda1` |
| — | Jetstream | `ab2e36b` … `5e21f1c` |

### 2.3 What is still not done

- **Twilio SMS delivery** (`Aerox.PDS.SMS.Twilio`) is written against Twilio's
  Messages API but has not been run against Twilio; phone verification is off
  unless an adapter is configured, and the `Log` adapter is what is tested.
- **Push notifications, Bluesky product features and Ozone** — Part 1.3 — are
  product surface rather than protocol and remain as listed there.
