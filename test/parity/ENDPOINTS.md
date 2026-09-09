# Endpoint parity table


VERIFICATION §7.1 item 3: every XRPC endpoint aerox routes is listed here with its
parity status and any documented deviation. The router test
(`test/aerox_web/router_parity_test.exs`) fails if the router serves a method this
table does not list, or lists one the router does not serve.

Status: `flow` = exercised by the HTTP flow tests against our own stack;
`parity` = diffed against the reference stack (§7.1 items 1–2, from M7);
`pending` = routed and covered by unit tests only.

| Method | Verb | Service | Status | Deviation |
|---|---|---|---|---|
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
| `com.atproto.sync.getRepo` | GET | pds | flow |  |
| `com.atproto.sync.getRecord` | GET | pds | pending |  |
| `com.atproto.sync.getBlocks` | GET | pds | pending |  |
| `com.atproto.sync.getLatestCommit` | GET | pds | flow |  |
| `com.atproto.sync.getRepoStatus` | GET | pds | flow |  |
| `com.atproto.sync.listRepos` | GET | pds | flow |  |
| `com.atproto.sync.getBlob` | GET | pds | pending |  |
| `com.atproto.sync.listBlobs` | GET | pds | pending |  |
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
| `com.atproto.moderation.createReport` | POST | pds | pending | 501 until the labeler (M8) accepts reports |
| `com.atproto.sync.subscribeRepos` | GET | pds | pending | frame-by-frame parity is VERIFICATION §7.1 item 4 |
