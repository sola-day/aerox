# Self-custody of `did:plc` identities

How an account on aerox — or on Bluesky's reference PDS — moves control of its
`did:plc` identity to keys the user holds, **using only what the protocol already
provides**, driven from the aero client. No lexicon, PLC or PDS protocol changes.

Status: design, 2026-09-15. Extends DESIGN §14.2 item 4 ("users may add their own
recovery key"). Sources checked: `bsky/atproto` @ `62f944dd6`
(`packages/pds/src/api/com/atproto/identity/*`, `account-manager/account-manager.ts`,
`config/secrets.ts`), `bsky/did-method-plc` (`packages/lib/src/{client,operations,data}.ts`,
`packages/server/src/constraints.ts`), `bsky/bluesky-pds/installer.sh`, and aerox
`lib/aerox/pds/plc_ops.ex`, `lib/aerox_web/controllers/pds/identity_controller.ex`.

---

## 1. Requirements

1. **Protocol only.** Every step is an existing XRPC method or the PLC directory's
   own HTTP API. Nothing the reference PDS or `did-method-plc` would not accept.
2. **Works against both stacks.** The same client flow must succeed with aerox
   (PDS + PLC) and with the reference Bluesky PDS (`ghcr.io/bluesky-social/pds`) and
   `did-method-plc`. aerox may add safety; the client must not depend on it.
3. **Private keys never leave the user's device.** Not to the PDS, not to aero's
   static host.
4. **Reversible** at every level, and the user can always see, from the PLC audit
   log, what happened and what can still be undone.

## 2. Protocol facts the design rests on

| Fact | Where |
|---|---|
| A reference PDS holds one instance rotation key (`PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX` or `…_KMS_KEY_ID`) and puts it last in every new DID's `rotationKeys`; a user `recoveryKey` and `PDS_RECOVERY_DID_KEY` go before it | `config/secrets.ts`, `createAccount.ts` `formatDidAndPlcOp` |
| `rotationKeys` is ordered by priority; an op signed by key *i* can be nullified by an op signed by a key before *i*, forking from an earlier `prev`, **within 72 h** | `did-method-plc` `data.ts` (`RECOVERY_WINDOW = 72 * HOUR`) |
| At most 10 rotation keys; at most 10 ops/hour, 30/day, 100/week per DID | `constraints.ts` |
| Keys are `did:key` K-256 or P-256; the signature is low-S compact ECDSA over the DAG-CBOR of the unsigned op, base64url without padding; `prev` is the CID (dag-cbor, sha-256) of the previous op | `did-method-plc` `operations.ts` |
| `identity.requestPlcOperationSignature` emails a `plc_operation` token | ref PDS |
| `identity.signPlcOperation(token, rotationKeys?, alsoKnownAs?, verificationMethods?, services?)` builds the next op from the last one and **signs it with the instance rotation key** — it only works while that key is still in `rotationKeys` | ref `signPlcOperation.ts` |
| `identity.submitPlcOperation(op)` sends the op to PLC and sequences `#identity`, but **rejects any op whose `rotationKeys` lack the server's key**, and requires `services.atproto_pds` = this PDS, `verificationMethods.atproto` = the account's signing key, `alsoKnownAs[0]` = `at://<current handle>` | ref `submitPlcOperation.ts`; aerox mirrors it (`identity_controller.ex`) |
| `identity.getRecommendedDidCredentials` returns the PDS's rotation key(s), signing key, handle and service — the public way to learn the instance key | ref `getRecommendedDidCredentials.ts` |
| `identity.updateHandle` on a `did:plc` account **always** submits a PLC op signed by the instance key (`plcClient.updateHandle`), and only then updates the PDS's handle | ref `account-manager.ts` `updateHandle` |
| The PLC directory accepts `POST /<did>` from anyone; validity is the signature. `GET /<did>/log/audit` lists every op with its CID and `nullified` flag. `did-method-plc` runs `cors()` | `did-method-plc` server |

The last two rows decide the shape of everything below: once the instance key is
gone, the PDS can neither sign nor submit for the account, and `updateHandle` breaks.

## 3. Custody levels

| Level | `rotationKeys` (priority order) | Who signs routine PLC ops | Reference PDS features |
|---|---|---|---|
| **L0 Custodial** (default) | `[instance recovery?, instance rotation]` | the PDS | all |
| **L1 Recovery key** (recommended) | `[user key, (user backup key), instance recovery?, instance rotation]` | still the PDS | all |
| **L2 Exclusive** | `[user key, (user backup key)]` | the user, in the client | all, except `updateHandle` and anything else that makes the PDS sign — handled by a *grant → act → revoke* sequence (§5.3) |

- **L1** already gives the user final authority. The user's key outranks both
  instance keys, so within 72 h it nullifies anything they sign. It can also sign
  new ops at any time, for example to move the identity to another PDS if this one
  disappears. The PDS keeps working exactly as before.
- **L2** removes the operator's ability to touch the identity at all, including to
  rescue a user who lost their keys.

## 4. Key management in the client

- **Generation**: K-256 via `@atproto/crypto` `Secp256k1Keypair.create({exportable: true})`
  (pure JS on `@noble/curves`, the same code the PDS uses). The `did:key` comes from
  `keypair.did()`.
- **Import**: a hex private key, or a previously exported aero key file. A public
  `did:key` alone is also accepted for L1, when the private half lives in another tool
  (for example `goat` or an air-gapped machine); such a key cannot be used by the
  client to sign later.
- **Backup is mandatory before the key is used**:
  - an encrypted key file: JSON `{did, kdf: PBKDF2-SHA-256 (600 000 iterations),
    salt, iv, AES-GCM ciphertext}`, all through WebCrypto, downloaded by the browser;
  - the user must then re-open the file (upload plus passphrase). The client checks
    that it decrypts to the same `did:key` and signs a test message with it. Only then
    does the flow continue.
  - A second, independent backup key is offered and recommended for L2.
- **On-device copy** (optional, off by default): the same encrypted blob in
  IndexedDB. The passphrase is asked for on every signature.
- **Not supported: passkeys / WebAuthn.** The authenticator signs
  `authenticatorData‖clientDataHash`, not the op bytes, so PLC rejects the signature.
  The UI says so.

## 5. Client flows (aero → Settings → Identity → Rotation keys)

### 5.0 Discover the PLC directory and read the state

- **Find the directory.** The protocol does not tell a client which PLC directory a
  PDS uses. The client tries a configured list, in order:
  1. the aero config (`plc.aerox.sola.town`);
  2. `ref-plc.aerox.sola.town` on the dev box;
  3. `https://plc.directory`.

  It takes the first directory that resolves the DID **and** whose document's
  `#atproto_pds` endpoint equals the session's PDS. A manual override is available.
- **Read the state**:
  - `GET /<did>/log/audit`, which gives the tip op, its CID and nullified ops;
  - `getRecommendedDidCredentials`, which gives the instance rotation key(s).
- **Classify every rotation key** as *yours* (a key the client knows), *this PDS*,
  *operator recovery* (a recommended key that is not the instance key), or *unknown*.
- **Derive the level from the PLC document**, not from any server flag.

### 5.1 L0 → L1: add a user recovery key (PDS-signed, standard flow)

1. Generate or import the key, then back it up (§4).
2. `requestPlcOperationSignature` → the user enters the emailed token.
3. `signPlcOperation({token, rotationKeys: [userKey, backupKey?, ...currentKeys]})`.
   Keys are prepended; nothing else changes.
4. Client pre-flight (§6) on the returned op.
5. `submitPlcOperation({operation})` → the PDS sends it to PLC and emits `#identity`.
6. Re-read `/log/audit`: the new CID is the tip and the document matches.

This works unchanged on the reference PDS and on aerox.

### 5.2 L1 → L2: remove the instance keys (user-signed, direct to PLC)

`submitPlcOperation` would reject this op, so the client submits it to the PLC
directory itself.

1. **Warning screen.** The user acknowledges these points:
   - the operator can no longer recover the identity;
   - `updateHandle` becomes a three-op sequence (§5.3);
   - losing every user key loses the identity for good.
2. **Unlock the user key** (passphrase). It must be in the current `rotationKeys`.
3. **Build the op.** `prev` = the CID of the audit-log tip. Take the normalized tip
   and set `rotationKeys = [userKey, backupKey?]`. Keep `verificationMethods`,
   `services` and `alsoKnownAs` untouched.
4. **Sign** with the user key, then verify the signature locally.
5. **Pre-flight** (§6).
6. **`POST <plc>/<did>`** with the signed op.
7. **Re-read the audit log and confirm.** No `#identity` event is needed: handle,
   PDS endpoint and signing key are unchanged, and no relay or AppView reads
   `rotationKeys`.

**Reverse (L2 → L1):** a user-signed op that appends the keys returned by
`getRecommendedDidCredentials` again.

### 5.3 Routine operations while at L2

**Handle change (grant → act → revoke).** This works on the reference PDS because it
uses only standard calls:

1. The user signs an op appending the instance rotation key (from
   `getRecommendedDidCredentials`) and POSTs it to PLC.
2. The client calls `identity.updateHandle(newHandle)`. The PDS signs its own op,
   which PLC now accepts, updates its handle and emits `#identity`.
3. The user signs an op removing the instance key again and POSTs it to PLC.

Notes:
- The sequence costs 3 of the 10 ops/hour.
- If step 2 fails, step 3 still runs, so the account never stays granted by accident.
  The client shows the recorded state and retries.
- Between steps 1 and 3 the PDS briefly holds authority. The user's key outranks it,
  so anything it did can be nullified within 72 h.

**Migrating to another PDS** (the standard `goat`-style migration):
1. Create the account on the new PDS with the existing DID.
2. Read the new PDS's `getRecommendedDidCredentials`.
3. **The user signs** the op that updates `services`, `verificationMethods` and
   `alsoKnownAs`. At L2 the user signs it; at L1 the old PDS may sign it as usual. The
   op adds the new PDS's rotation key only if the user wants to stay at L1 there.
4. POST it to PLC, then `activateAccount` on the new PDS and `deactivateAccount` on
   the old one.

**Repo signing key rotation:** the new PDS reserves a key (`reserveSigningKey`), and
the user signs an op setting `verificationMethods.atproto`.

**Deleting the account:** `deleteAccount` does not tombstone the DID on either stack.
Before deleting, the client offers to sign `{type: "plc_tombstone", prev}` with the
user key. Otherwise the DID keeps pointing at a PDS that no longer hosts it.

### 5.4 Recovery: nullify an unwanted operation

- **Trigger.** The audit log shows an op signed by a lower-priority key, for example
  the instance key after a PDS compromise, and it is less than 72 h old.
- **Fork.** The user signs an op whose `prev` is the CID of the op *before* the
  unwanted one, restoring the document they want, and POSTs it to PLC.
- **Result.** PLC marks the later ops `nullified`.
- **UI.** The client shows a countdown on every op still inside the window, and
  names the key that signed it.

## 6. Client-side pre-flight (before any op reaches PLC)

At L2 the PDS no longer checks ops, so the client applies the PDS's own rules plus
guards against lock-out:

1. `type == "plc_operation"`, and `prev` equals the current tip CID. This detects a
   race with another client.
2. `verificationMethods.atproto` equals the account's current signing key, unless the
   flow is a signing-key rotation.
3. `services.atproto_pds` is `{type: AtprotoPersonalDataServer, endpoint: <session
   PDS>}`, unless the flow is a migration.
4. `alsoKnownAs[0]` is `at://<current handle>`, unless the flow is a handle change.
5. **Anti-lock-out rules:**
   - at least one key in `rotationKeys` is a key the client can sign with now;
   - or the op keeps the instance key;
   - removing the last user key while also removing the instance keys is refused.
6. `rotationKeys.length ≤ 10`; every entry parses as a K-256 or P-256 `did:key`.
7. The signature verifies locally against a key in the **current** `rotationKeys`.
8. **Rate budget.** Read the ops from the last hour/day/week in the audit log and
   refuse flows that would exceed 10/30/100.

## 7. Compatibility matrix

| Step | Reference PDS + `did-method-plc` | aerox today | aerox change |
|---|---|---|---|
| `getRecommendedDidCredentials` | ✓ | ✓ | — |
| `requestPlcOperationSignature` (email token) | ✓ | ✓ (fixed in `fb78cf1`; the token mail was failing) | — |
| `signPlcOperation` with new `rotationKeys` | ✓ | ✓ | — |
| `submitPlcOperation` checks | ✓ | ✓, same five checks | — |
| Browser `GET` of PLC `/log/audit` | ✓ (`cors()`) | ✓ (`b7f2a4d`) | — |
| Browser `POST <plc>/<did>` (CORS preflight) | ✓ (`OPTIONS` → 204) | ✗ (`OPTIONS` → 404) | **required**: answer `OPTIONS` on the PLC routes |
| PLC 72 h nullification, key priority | ✓ | ✓ (DESIGN §14.2 item 7) | verify via the interop test (§9) |
| PLC rate limits 10/30/100 | ✓ | to verify | match `did-method-plc` if different |
| `updateHandle` at L2 | fails (instance key not accepted) → grant → act → revoke | same | — (deliberately not "fixed" server-side, to keep one client flow) |

## 8. aerox server-side work

**Required, for parity with `did-method-plc`:**
1. `OPTIONS` routes for the PLC scope, so the CORS plug answers preflights.

**Optional hardening.** None of this changes the protocol, and the client must not
depend on it:

2. Treat any `signPlcOperation` that changes `rotationKeys` as high risk:
   - require a password session less than 5 minutes old (not an app password), or
     the OAuth `identity:*` scope;
   - send a notification email with the 72 h window;
   - write a dedicated `plc_op_audit` purpose;
   - alert the operator.
3. **Custody awareness.** `Aerox.PDS.Identity.Custody` derives L0/L1/L2 from the
   resolved document. For L2 accounts:
   - `updateHandle` answers a clear error that points to the client flow, instead of
     a PLC signature failure;
   - account deletion reminds the client to tombstone.
4. **Admin visibility.** The admin API lists the custody level of each account.

## 9. Tests

- **Interop, browser (`aero-app/test/custody.mjs`, Playwright).** One scenario run
  against both stacks:
  - (a) aerox at `pds.` / `plc.aerox.sola.town`;
  - (b) the reference containers `ref-pds` / `ref-plc.aerox.sola.town`, where the
    email token is read from the ref PDS's SQLite `email_token` table (test only).

  Steps: sign up (or use a fixture account) → L1 → check the document → L2 → check
  that `submitPlcOperation` would reject (read-only probe) → handle change via
  grant → act → revoke → nullify a deliberately bad op → L2 → L1 → L0.
- **Unit tests in aero-app.**
  - Op encoding, CID and signature against `@did-plc/lib` in Node, as golden vectors.
  - Every pre-flight rule in §6.
- **aerox.** PLC preflight test; nullification and priority tests against the PLC
  controller; rate-limit parity.

## 10. Implementation order

1. aerox: PLC `OPTIONS` (§8.1).
2. aero-app: `lib/plc.ts` (fetch the log, build, encode, sign, verify, submit) and
   `lib/custodyKeys.ts` (generate, import, encrypted file, IndexedDB), with golden
   tests against `@did-plc/lib`.
3. aero-app UI: Settings → Identity → Rotation keys:
   - key list with roles;
   - L0 → L1;
   - audit log with 72 h countdowns.
4. L1 → L2 and L2 → L1, then grant → act → revoke for handle changes, then the tombstone
   offer on deletion, then nullify.
5. The interop Playwright scenario against aerox and the reference stack, and a
   PARITY.md note.
6. The optional aerox hardening (§8.2–8.4).
