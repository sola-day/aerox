# Interoperability with seven other PDS implementations

aerox run as an eighth member of the multi-implementation lab network on
generic.dev, and exercised against every other member over real hostnames, TLS,
one shared PLC directory, two relays and two AppViews. VERIFICATION §7.4 is the
plan row this document reports on. Run 2026-09-15.

## 1. Topology

| Role | Implementation | Host |
|---|---|---|
| PDS | Bluesky reference PDS (TypeScript) | `atproto.generic.dev` |
| PDS | ngerakines/atproto-crates `atproto-pds` (Rust) | `crates.generic.dev` |
| PDS | tranquil (Rust, a superset of the reference PDS) | `tranquil.generic.dev` |
| PDS | futur.blue pegasus (OCaml) | `pegasus.generic.dev` |
| PDS | zds (Zig) | `zds.generic.dev` |
| PDS | haileyok/cocoon (Go) | `cocoon.generic.dev` |
| PDS | blacksky rsky-pds (Rust) | `rsky.generic.dev` |
| PLC | did-method-plc | `plc.xjdao.generic.dev` |
| Relay | indigo `relay` at `dfe5578` | `relay.generic.dev` |
| AppView | bsky `services/bsky-standalone` | `appview.generic.dev` |
| **aerox** | PDS, Relay, AppView, Jetstream of one dev server | `pds.` / `relay.` / `appview.lab.aerox.sola.town` |

The lab belongs to the generic.dev host and is not changed by these tests. Test
accounts are created on it through each PDS's public API, and its PLC holds their
DIDs. The only reads outside the public API are the PLC tokens: none of the
seven PDSes can send mail there, so the token is read from the
implementation's own store, for the test account only
(`tools/interop/lab-token.sh`).

The aerox instance is a second dev server beside the primary one on this box:

```sh
docker compose exec -T -e EXTRA_DB_SUFFIXES=_lab db bash < docker/postgres/init/01-databases.sh
AEROX_DB_SUFFIX=_lab mix ecto.migrate
tools/interop/lab-devserver.sh          # :4002, AEROX_DEV_DOMAIN=lab.aerox.sola.town
```

- `AEROX_PLC_URL=https://plc.xjdao.generic.dev` sets both where it registers
  DIDs and where every service resolves them.
- Its keys are throwaway ones, written to `tmp/lab/instance.env` on first start.
- Traefik router `aerox-lab` in `ops/traefik/aerox.dynamic.yml` holds a
  `lab.aerox.sola.town` + `*.lab.aerox.sola.town` certificate.

The driver is `test/harness/lab.mjs`:

```sh
node lab.mjs accounts | crawl | proxy | social | lifecycle | migrate [impl… | a->b…] | all
```

Accounts live in `tmp/lab/accounts.json`. A `migrate a->b` argument runs a
single pair, for example between two lab PDSes. Such control pairs tell a
counterpart's fault apart from aerox's.

## 2. Results

### 2.1 Federation: crawl, index, proxy, interact (8 × 8)

| Check | Result |
|---|---|
| Account creation, a post, DID document on the shared PLC names the PDS | 8/8 |
| **aerox relay** crawls each PDS, holds its latest commit | 8/8 |
| **indigo relay** crawls aerox's PDS | yes (§3.4) |
| **aerox AppView** indexes a post from each implementation | 8/8 |
| **bsky AppView** indexes a post from aerox | yes |
| `app.bsky.*` through each PDS to the aerox AppView and to the bsky AppView (`getProfile`, viewer-authenticated `getTimeline`) | 32/32 |
| Every account follows, likes and replies to every other; each posts an image | 56 follows, 56 likes, 56 replies, 8 images |
| aerox AppView: follower, like and reply counts, full threads, image thumbnails for all eight | 24/24 after the §3.1 fix |
| aerox notifications list a follow, like and reply from each of the seven | yes |
| bsky AppView, same checks | 13/24 (§4: missing events from rsky and pegasus, and aerox's pre-crawl post, which the bsky AppView never backfills) |

### 2.2 Lifecycle events from each implementation

| Check | Result |
|---|---|
| `updateHandle` reaches both AppViews | 7/8: crates does not emit `#identity`, and neither AppView sees its change |
| A deleted post leaves both AppViews | 8/8 |
| `deactivateAccount` reaches the aerox relay and hides the profile | 7/8: rsky does not sequence `#account` on deactivation, and both relays still say active |
| `activateAccount` brings the account back | 7/8: pegasus answers `AccountDeactivated` to its own reactivation |

### 2.3 Account migration, in both directions

Each migration takes a fresh account with three posts, an image, a follow and
preferences through these steps:

1. `getServiceAuth`
2. `createAccount` with the DID on the target
3. `getRepo` → `importRepo`
4. `listMissingBlobs` → `getBlob` → `uploadBlob`
5. Preferences
6. `getRecommendedDidCredentials` → `signPlcOperation` → `submitPlcOperation`
7. `activateAccount` / `deactivateAccount`

It then checks:

- every record and the blob on the target;
- a write on the target;
- both AppViews following the account to its new PDS and handle.

| Counterpart | → aerox | aerox → | Deviations the migration worked around |
|---|---|---|---|
| atproto (reference) | ✓ | ✓ | none |
| crates | ✓ | ✓ | `@atproto/api` rejects its `createAccount` response as invalid; the raw client accepts it |
| tranquil | ✓ | ✓ | refuses a PLC operation that drops its own key from `rotationKeys`: the source's keys were kept |
| pegasus | ✓ | ✓ | `signPlcOperation` asserts its signature against the *new* rotation keys (500); a migrated account starts activated |
| cocoon | ✓ | ✓ | `checkAccountStatus` is a 500 before the repo is imported |
| rsky | ✓ on the aerox side | ✓ after the §3.2 fix | `requestPlcOperationSignature` panics in its mailer; `signPlcOperation` returns the bare operation instead of `{operation}` |
| zds | ✗ | ✗ | outbound: `signPlcOperation` returns invalid JSON. Inbound: `createAccount` answers `DidResolutionFailed` for any foreign issuer. Both reproduce with the reference PDS as the other side. |

Control pairs between the reference PDS and a lab PDS reproduce every
counterpart failure listed above:

- `pegasus->atproto` and `rsky->atproto`, the same signPlcOperation failures;
- `zds->atproto` and `atproto->zds`, the same zds failures.

None of them is aerox-specific.

## 3. What was wrong in aerox, and the fixes

### 3.1 An unverifiable commit left its repo silently stale (AppView)

pegasus emits `#commit` frames without the MST blocks that operation inversion
needs. The indigo relay logs `failed to invert commit MST` for them as well.

The AppView logged such a commit and dropped it, but left the repo marked
`synchronized` at the old rev. Whatever the commit carried was never indexed
until the account wrote again, so pegasus's image post, its last write, stayed
missing.

**Fix:** `RepoSync.on_invalid_commit/3` desynchronises the repo and backfills it
from the PDS's CAR, which is verified on its own terms. During a backfill, the
failure is queued as a marker. The replay resyncs on that marker unless the CAR
already covers its rev. Commit `2381488`; tests in `test/appview/repo_sync_test.exs`.

### 3.2 A status learned by asking the PDS was never announced (Relay, AppView)

This showed up after an aerox → rsky migration. The account was active at rsky
and on both relays, but hidden on the aerox AppView, which dropped every commit
after the migration. The sequence:

1. The migration ends with `deactivateAccount` on the old PDS.
2. That `#account` event arrives downstream after the DID already points at rsky.
3. rsky never announces the activation.
4. The relay's `ensure_active` re-checked `getRepoStatus` at the new host, found
   the account active, and let the commits through without telling downstream.

The reference PDS happens to mask this, because it sequences `#account` on
`activateAccount`.

**Fixes (commit `28889d5`):**

- **Relay:** a status change learned from the PDS is emitted as `#account`,
  before the event that prompted the check.
- **AppView:** it may sit behind an indigo relay, which does not announce such
  a change either. So before dropping an event for an account it holds as
  inactive, it asks the account's current PDS, at most once a minute per DID.

Tests in `test/relay/ingest_test.exs` and `test/appview/repo_sync_test.exs`.

### 3.3 Not changed

- **rsky's broken `since` chains.** rsky emits commits whose `since` skips a rev
  and whose `prevData` does not match. The aerox AppView desynchronises the repo
  and backfills it, and ends up with the right counts. The bsky AppView loses
  those events.
- **Relay dials after `requestCrawl` returns.** Both relays answer
  `requestCrawl` before they dial the host, and a new host is subscribed without
  a cursor. A write made in that gap is not seen by either relay, which matches
  indigo; the harness writes again until the relay has it.
- **Tolerance of the counterparts' deviations.** aerox accepts:
  - commits from all seven implementations, including pegasus's partial frames
    (relay: lenient, like indigo);
  - their CARs on `importRepo`;
  - PLC operations signed by any of them.

### 3.4 One harness bug

`AtpAgent` dispatches to whatever PDS the DID document names. During a
migration that is still the source, so the target's calls went to the wrong
host. The migration now uses a raw XRPC client pinned to each host.

## 4. Counterpart findings (not aerox)

Recorded for the lab's owners. Each item is reproducible with the harness and
does not involve aerox.

| Implementation | Finding |
|---|---|
| pegasus | `#commit` frames lack the blocks needed for MST inversion. `signPlcOperation` asserts the signature against the new operation's `rotationKeys` (`lib/plc.ml`, `sign_operation`), so every migration to a PDS that does not keep pegasus's key fails with a 500. `activateAccount` after `deactivateAccount` answers `AccountDeactivated`. |
| rsky | Commits skip revs (`since`/`prevData` mismatches on the indigo relay too). No `#account` on deactivation. `requestPlcOperationSignature` panics without SMTP (`mailer/mod.rs:46`). `signPlcOperation` returns the operation unwrapped. |
| zds | `requestPlcOperationSignature` fails without a mail provider. `signPlcOperation` returns malformed JSON. A migration `createAccount` cannot resolve the issuer of any service JWT (`DidResolutionFailed`). |
| crates | No `#identity` after `updateHandle`. Its `createAccount` response fails `@atproto/api`'s lexicon validation. |
| cocoon | `checkAccountStatus` is a 500 (`error casting cid`) for an account with no repo yet. |
| tranquil | Refuses PLC operations that drop the account's own key from `rotationKeys`. This is a design choice (its per-account signing key is a rotation key), but it blocks the standard migration flow to any other PDS. |

Side effects on the lab:

- The test accounts listed in `tmp/lab/accounts.json` remain.
- pegasus's interop account is left deactivated, because pegasus cannot
  reactivate it.
