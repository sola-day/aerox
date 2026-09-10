# Endpoint parity table


VERIFICATION §7.1 item 3: every XRPC endpoint aerox routes is listed here with its
service, parity status and any documented deviation. The router test
(`test/aerox_web/router_parity_test.exs`) fails if any of the four routers (PDS,
Relay, AppView, Labeler — dispatched by hostname, `AeroxWeb.Dispatch`) serves a method this
table does not list for that service, or lists one it does not serve.

Every other `/xrpc/<nsid>` on the PDS host is the proxy catch-all (DESIGN §11.1):
forwarded to the `atproto-proxy` target or the default service for the NSID, else 501
(`com.atproto.moderation.createReport` goes to the configured mod service, DESIGN §17.2).

Status: `flow` = exercised by the HTTP flow tests against our own stack;
`parity` = diffed against the reference stack (§7.1 items 1–2, from M7);
`pending` = routed and covered by unit tests only.

**Parity run of 2026-09-10** (`test/harness/parity.mjs`, aerox release candidate
on the second host against upstream's PDS + `ref-appview` on the dev box):
**21 of 21 endpoints identical** after normalisation. What the first run found,
all of it now fixed:

| What | Endpoints it broke |
|---|---|
| Repeated query parameters (`actors=a&actors=b`) collapsed to the last value, so every array-valued call answered about one item | `getProfiles`, `getRelationships`, `getPosts`, `getFeedGenerators` |
| `associated.activitySubscription` was never emitted (upstream resolves `app.bsky.notification.declaration`, defaulting to `followers`) | 13 |
| `$type` on `#postView`/`#feedViewPost` in positions the lexicon has already typed; upstream emits it only where the value sits in a union (`#replyRef`) | 9 |
| `viewer.knownFollowers` emitted as `{count: 0, followers: []}` where upstream omits it | 2 |
| `creator.viewer` missing from list, feed-generator and labeler views — the creator's actor was hydrated without the viewer's relationship to them | 2 |

One endpoint, `listNotifications`, differs *intermittently and on the reference
side*: a reply nested two deep should notify both the parent's and the root's
author (upstream's own `REPLY_NOTIF_DEPTH` is 5), and the reference AppView
produced that second notification in two runs out of four of the identical
scenario — an indexing race between the reply and its parent. aerox produces it
every time.

| Method | Verb | Service | Status | Deviation |
|---|---|---|---|---|
| `_health` | GET | pds | flow | not a lexicon method; upstream's PDS answers here and docs/OPS.md §4 monitors it |
| `_health` | GET | relay | flow |  |
| `_health` | GET | appview | flow |  |
| `_health` | GET | labeler | flow |  |
| `com.atproto.server.describeServer` | GET | pds | flow |  |
| `com.atproto.server.createAccount` | POST | pds | flow | no `plcOp` input (DESIGN §18.3: signup mints the DID here) |
| `com.atproto.server.createSession` | POST | pds | flow |  |
| `com.atproto.server.refreshSession` | POST | pds | flow |  |
| `com.atproto.server.deleteSession` | POST | pds | pending |  |
| `com.atproto.server.getSession` | GET | pds | flow |  |
| `com.atproto.server.getServiceAuth` | GET | pds | pending | M4 finishes DPoP-bound issuance |
| `com.atproto.server.deactivateAccount` | POST | pds | pending |  |
| `com.atproto.server.activateAccount` | POST | pds | pending |  |
| `com.atproto.server.checkAccountStatus` | GET | pds | pending |  |
| `com.atproto.server.createAppPassword` | POST | pds | pending |  |
| `com.atproto.server.listAppPasswords` | GET | pds | pending |  |
| `com.atproto.server.revokeAppPassword` | POST | pds | pending |  |
| `com.atproto.server.requestEmailConfirmation` | POST | pds | pending |  |
| `com.atproto.server.confirmEmail` | POST | pds | pending |  |
| `com.atproto.server.requestEmailUpdate` | POST | pds | pending |  |
| `com.atproto.server.updateEmail` | POST | pds | pending |  |
| `com.atproto.server.requestPasswordReset` | POST | pds | pending |  |
| `com.atproto.server.resetPassword` | POST | pds | pending |  |
| `com.atproto.server.requestAccountDelete` | POST | pds | pending |  |
| `com.atproto.server.deleteAccount` | POST | pds | pending |  |
| `com.atproto.server.createInviteCode` | POST | pds | pending |  |
| `com.atproto.server.getAccountInviteCodes` | GET | pds | pending |  |
| `com.atproto.identity.resolveHandle` | GET | pds | pending |  |
| `com.atproto.identity.updateHandle` | POST | pds | pending |  |
| `com.atproto.identity.getRecommendedDidCredentials` | GET | pds | pending |  |
| `com.atproto.identity.requestPlcOperationSignature` | POST | pds | pending |  |
| `com.atproto.identity.signPlcOperation` | POST | pds | pending |  |
| `com.atproto.identity.submitPlcOperation` | POST | pds | pending |  |
| `com.atproto.repo.createRecord` | POST | pds | flow |  |
| `com.atproto.repo.putRecord` | POST | pds | flow |  |
| `com.atproto.repo.deleteRecord` | POST | pds | flow |  |
| `com.atproto.repo.applyWrites` | POST | pds | pending |  |
| `com.atproto.repo.getRecord` | GET | pds | flow |  |
| `com.atproto.repo.listRecords` | GET | pds | flow |  |
| `com.atproto.repo.describeRepo` | GET | pds | flow |  |
| `com.atproto.repo.uploadBlob` | POST | pds | pending |  |
| `com.atproto.repo.listMissingBlobs` | GET | pds | pending |  |
| `com.atproto.repo.importRepo` | POST | pds | pending |  |
| `com.atproto.sync.getRepo` | GET | pds | flow | relay: non-archival, 404 naming the hosting PDS (DESIGN §19) |
| `com.atproto.sync.getRecord` | GET | pds | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.getBlocks` | GET | pds | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.getLatestCommit` | GET | pds | flow |  |
| `com.atproto.sync.getRepoStatus` | GET | pds | flow |  |
| `com.atproto.sync.listRepos` | GET | pds | flow |  |
| `com.atproto.sync.getBlob` | GET | pds | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.listBlobs` | GET | pds | pending | relay: non-archival (DESIGN §19) |
| `app.bsky.actor.getPreferences` | GET | pds | flow | served by the PDS, not proxied (DESIGN §11.1) |
| `app.bsky.actor.putPreferences` | POST | pds | flow | served by the PDS, not proxied (DESIGN §11.1) |
| `com.atproto.admin.getAccountInfo` | GET | pds | pending |  |
| `com.atproto.admin.getAccountInfos` | GET | pds | pending |  |
| `com.atproto.admin.getSubjectStatus` | GET | pds | pending |  |
| `com.atproto.admin.updateSubjectStatus` | POST | pds | pending |  |
| `com.atproto.admin.updateAccountEmail` | POST | pds | pending |  |
| `com.atproto.admin.updateAccountHandle` | POST | pds | pending |  |
| `com.atproto.admin.updateAccountPassword` | POST | pds | pending |  |
| `com.atproto.admin.deleteAccount` | POST | pds | pending |  |
| `com.atproto.admin.sendEmail` | POST | pds | pending |  |
| `com.atproto.admin.getInviteCodes` | GET | pds | pending | returns an empty list; invite codes are per-account only (DESIGN §18.3) |
| `com.atproto.admin.disableInviteCodes` | POST | pds | pending |  |
| `com.atproto.admin.disableAccountInvites` | POST | pds | pending |  |
| `com.atproto.admin.enableAccountInvites` | POST | pds | pending |  |
| `com.atproto.space.getDelegationToken` | GET | pds | flow | the published alpha's `atproto-space-delegation+jwt` (`sub` = space, `aud` = `<did>#atproto_space_host`, 60 s, single use) |
| `com.atproto.space.createRecord` | POST | pds | flow |  |
| `com.atproto.space.putRecord` | POST | pds | flow |  |
| `com.atproto.space.deleteRecord` | POST | pds | flow |  |
| `com.atproto.space.applyWrites` | POST | pds | flow |  |
| `com.atproto.space.listSpaces` | GET | pds | flow |  |
| `com.atproto.space.getRecord` | GET | pds | flow | session or space credential |
| `com.atproto.space.listRecords` | GET | pds | flow | session or space credential |
| `com.atproto.space.getRepoState` | GET | pds | flow | commit carries the alpha's `ver: 1` |
| `com.atproto.space.listRepoOps` | GET | pds | flow | alpha additions: `cursor`, `excludeValues`, inlined `value` |
| `com.atproto.space.getRepo` | GET | pds | flow | not in the vendored lexicons (DESIGN §12.5, bulletin): two-root CAR |
| `com.atproto.space.getBlob` | GET | pds | flow | session or space credential |
| `com.atproto.space.getSpaceCredential` | POST | pds | flow | delegation token + DPoP proof (credential `cnf.jkt`-bound, `atproto-space-credential+jwt`); `clientAttestation` verified against the client's OAuth JWKS |
| `com.atproto.space.getSpace` | GET | pds | flow |  |
| `com.atproto.space.listRepos` | GET | pds | flow | writer set from notifyWrite; `rev`/`hash` per the alpha lexicon |
| `com.atproto.space.registerNotify` | POST | pds | flow | accepts the alpha's `service` identifier or the vendored `endpoint` |
| `com.atproto.space.notifyWrite` | POST | pds | flow | service auth addressed to the owner DID; fan-out via Oban |
| `com.atproto.space.notifySpaceDeleted` | POST | pds | flow | service auth addressed to the member DID |
| `com.atproto.simplespace.createSpace` | POST | pds | flow | accepts the vendored (`did`, `config`) and alpha (`policy`, `appAccess`) shapes |
| `com.atproto.simplespace.updateSpace` | POST | pds | flow |  |
| `com.atproto.simplespace.deleteSpace` | POST | pds | flow |  |
| `com.atproto.simplespace.getSpace` | GET | pds | flow | alpha lexicon (bulletin), not vendored: `policy`/`appAccess` unions |
| `com.atproto.simplespace.addMember` | POST | pds | flow |  |
| `com.atproto.simplespace.removeMember` | POST | pds | flow |  |
| `com.atproto.simplespace.listMembers` | GET | pds | flow |  |
| `com.atproto.sync.subscribeRepos` | GET | pds | pending | frame-by-frame parity is VERIFICATION §7.1 item 4 |
| `com.atproto.sync.subscribeRepos` | GET | relay | pending | frame-by-frame parity is VERIFICATION §7.1 item 4 |
| `com.atproto.sync.requestCrawl` | POST | relay | flow |  |
| `com.atproto.sync.listHosts` | GET | relay | flow |  |
| `com.atproto.sync.getHostStatus` | GET | relay | flow |  |
| `com.atproto.sync.listRepos` | GET | relay | flow |  |
| `com.atproto.sync.getRepoStatus` | GET | relay | flow |  |
| `com.atproto.sync.getLatestCommit` | GET | relay | flow |  |
| `com.atproto.sync.getRepo` | GET | relay | flow | relay: non-archival, 404 naming the hosting PDS (DESIGN §19) |
| `com.atproto.sync.getRecord` | GET | relay | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.getBlocks` | GET | relay | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.getBlob` | GET | relay | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.listBlobs` | GET | relay | pending | relay: non-archival (DESIGN §19) |
| `com.atproto.sync.listReposByCollection` | GET | relay | pending | deferred: needs a collection index (DESIGN §19) |
| `com.atproto.sync.getCheckout` | GET | relay | pending | deprecated upstream; 501 |
| `com.atproto.sync.getHead` | GET | relay | pending | deprecated upstream; 501 |
| `com.atproto.sync.notifyOfUpdate` | POST | relay | pending | deprecated upstream; 501 |
| `admin.subscribeHost` | POST | relay | pending |  |
| `admin.setHostAccountLimit` | POST | relay | pending |  |
| `admin.banDomain` | POST | relay | pending |  |
| `admin.setHostStatus` | POST | relay | pending |  |
| `app.bsky.actor.getProfile` | GET | appview | parity |  |
| `app.bsky.actor.getProfiles` | GET | appview | parity |  |
| `app.bsky.actor.getSuggestions` | GET | appview | parity | empty by design (DESIGN §15.4) |
| `app.bsky.actor.searchActors` | GET | appview | parity |  |
| `app.bsky.actor.searchActorsTypeahead` | GET | appview | pending |  |
| `app.bsky.feed.getTimeline` | GET | appview | parity |  |
| `app.bsky.feed.getAuthorFeed` | GET | appview | parity |  |
| `app.bsky.feed.getPostThread` | GET | appview | parity |  |
| `app.bsky.feed.getPosts` | GET | appview | parity |  |
| `app.bsky.feed.getLikes` | GET | appview | parity |  |
| `app.bsky.feed.getRepostedBy` | GET | appview | parity |  |
| `app.bsky.feed.getQuotes` | GET | appview | parity |  |
| `app.bsky.feed.getActorLikes` | GET | appview | parity |  |
| `app.bsky.feed.getFeed` | GET | appview | pending |  |
| `app.bsky.feed.getFeedGenerator` | GET | appview | pending |  |
| `app.bsky.feed.getFeedGenerators` | GET | appview | parity |  |
| `app.bsky.feed.getActorFeeds` | GET | appview | pending |  |
| `app.bsky.feed.getListFeed` | GET | appview | pending |  |
| `app.bsky.feed.searchPosts` | GET | appview | pending |  |
| `app.bsky.feed.describeFeedGenerator` | GET | appview | pending | feedgen-side method; 501 here |
| `app.bsky.graph.getFollows` | GET | appview | parity |  |
| `app.bsky.graph.getFollowers` | GET | appview | parity |  |
| `app.bsky.graph.getKnownFollowers` | GET | appview | parity |  |
| `app.bsky.graph.getBlocks` | GET | appview | pending |  |
| `app.bsky.graph.getMutes` | GET | appview | parity |  |
| `app.bsky.graph.getList` | GET | appview | parity |  |
| `app.bsky.graph.getLists` | GET | appview | parity |  |
| `app.bsky.graph.getListMutes` | GET | appview | pending |  |
| `app.bsky.graph.getListBlocks` | GET | appview | pending |  |
| `app.bsky.graph.getRelationships` | GET | appview | parity |  |
| `app.bsky.graph.getStarterPack` | GET | appview | pending |  |
| `app.bsky.graph.getStarterPacks` | GET | appview | pending |  |
| `app.bsky.graph.getActorStarterPacks` | GET | appview | pending |  |
| `app.bsky.graph.muteActor` | POST | appview | pending |  |
| `app.bsky.graph.unmuteActor` | POST | appview | pending |  |
| `app.bsky.graph.muteActorList` | POST | appview | pending |  |
| `app.bsky.graph.unmuteActorList` | POST | appview | pending |  |
| `app.bsky.graph.muteThread` | POST | appview | pending |  |
| `app.bsky.graph.unmuteThread` | POST | appview | pending |  |
| `app.bsky.notification.listNotifications` | GET | appview | parity |  |
| `app.bsky.notification.getUnreadCount` | GET | appview | pending |  |
| `app.bsky.notification.updateSeen` | POST | appview | pending |  |
| `app.bsky.labeler.getServices` | GET | appview | pending |  |
| `app.bsky.unspecced.getPopularFeedGenerators` | GET | appview | pending | empty by design (DESIGN §15.4) |
| `app.bsky.unspecced.getConfig` | GET | appview | pending |  |
| `com.atproto.label.queryLabels` | GET | labeler | flow |  |
| `com.atproto.label.subscribeLabels` | GET | labeler | flow | WebSocket, `#labels`/`#info` frames (DESIGN §17.1) |
| `com.atproto.moderation.createReport` | POST | labeler | flow | reached through the PDS proxy with a service JWT (DESIGN §17.2) |
| `aerox.moderation.emitEvent` | POST | labeler | flow | aerox's own admin API (DESIGN §17.3); `tools.ozone.*` is the later target |
| `aerox.moderation.queryEvents` | GET | labeler | flow | aerox's own admin API (DESIGN §17.3) |
| `aerox.moderation.queryReports` | GET | labeler | flow | aerox's own admin API (DESIGN §17.3) |
