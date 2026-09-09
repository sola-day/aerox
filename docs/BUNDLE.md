# The portable account bundle, format version 1

The interchange format of DESIGN §13.0, as implemented in M5 (`Aerox.Interop.Bundle`).
One directory per account; an instance export is a directory of them. Every adapter
(`Aerox.Interop.Bundle.Postgres`, `Aerox.Interop.ReferencePds`) reads and writes this
and nothing else; there is exactly one import path and one verification suite
(`Aerox.Interop.Verify`).

## Layout

```
<did>/
  manifest.json      plaintext, signed (see below)
  account.json       email, email_confirmed_at, password_scrypt, invites_disabled,
                     created_at, takedown_ref, deactivated_at, delete_after,
                     app_passwords[], invite_codes[] (with uses[]), preferences[]
  signing.key        raw 32-byte secp256k1 private key
  repo.car           the repo as `com.atproto.sync.getRepo` returns it (commit root,
                     commit block, MST nodes, records; block bytes verbatim)
  state.json         what the CAR cannot express — see below
  blobs/<cid>        blob bytes (the file name is the CID, base32 string form)
  quarantine/<cid>   taken-down blob bytes
  seq.car            optional: the account's `repo_seq` rows for takeover
  spaces/            reserved (§12); ignored by readers
```

Unknown files and directories are tolerated; a `bundle_version` other than `1` is
refused. Timestamps are ISO-8601 UTC strings; JSON `null` means "not set".

### state.json

```json
{
  "repo_root": {"cid": "...", "rev": "...", "indexed_at": "..."},
  "records":   {"at://did/collection/rkey": {"cid", "rev", "indexed_at", "takedown_ref"}},
  "blobs":     {"<cid>": {"mime_type", "size", "created_at", "takedown_ref"}},
  "blocks":    {"<cid>": "<rev>"}
}
```

`blocks` is one addition to DESIGN §13.0: the per-block `rev` (`repo_block.rev` /
upstream `repoRev`) is not in the CAR, and both `getRepo?since=` and the
"byte-identical `repo_block` rows" round-trip need it. A reader that lacks a block's
rev uses the commit's rev.

### seq.car

A rootless CAR; each block is one `repo_seq` row as DAG-CBOR
`{seq, did, eventType, event (bytes, verbatim), invalidated, sequencedAt}`. The
`event` bytes are the row's DAG-CBOR event body exactly as the source stored them, so a
takeover import continues relay cursors unbroken.

### manifest.json

```json
{
  "bundle_version": 1,
  "did": "...", "handle": "...",
  "source": {"impl": "aerox" | "reference-pds", "version": "...", "host": "..."},
  "created_at": "...",
  "counts": {"records", "blocks", "blobs", "quarantine", "seq_events"},
  "hashes": {"repo_car", "account_json", "state_json", "seq_car": sha256 hex of the
             plaintext; "blobs": [cid], "quarantine": [cid]},
  "sizes": {"repo_car": bytes},
  "encryption": null | {...},
  "signature": {"jws": "<compact JWS>", "kid": "did:key:..."}
}
```

The readable fields are informational. **The authoritative manifest is the JWS
payload**: the reader verifies the JWS against the `did:key` in its own header
(`ES256K`/`ES256`, raw `r‖s` signature over `base64url(header).base64url(payload)`),
optionally pinned with `expect_signer`, and decodes the payload. Editing the payload
breaks the signature; editing the readable copy changes nothing. Every hash is
recomputed from the files before anything touches a database (§13.0 rule 5), and
every blob's bytes must hash to its CID.

The signer is the exporting instance's `Aerox.Crypto.Signer` (the PLC rotation key
behaviour, `Aerox.PDS.Config.signer/0`); only its `sign/2` is used, so a KMS-backed
signer works unchanged.

## Encryption — DESIGN §13.0 Option A, decided

Option A was chosen (2026-09-09): in-process, standard primitives from libraries the
release already carries (`jose` 1.11.12 and OTP `:crypto`), no external binary on any
host. Option B (`age`) would have added a required binary and a process around a pipe
for multi-GB streams for no gain the verification suite could see.

* **Content key.** One random 256-bit key per bundle.
* **Key wrap.** The content key is wrapped once per recipient as a compact JWE in
  `manifest.encryption.recipients[]`:
  * `ECDH-ES+A256KW` / `A256GCM` to a **P-256 or X25519 public key** (JWK or PEM),
    for provider-to-provider transfer. jose 1.11 cannot mint the ephemeral key itself
    (its `derive_key/1` path is missing), so `Aerox.Interop.Bundle.Crypto` generates
    the ephemeral pair and passes it in; the JWE is standard and carries `epk`.
  * `PBES2-HS512+A256KW` / `A256GCM` under a **passphrase** (from an environment
    variable, never the command line), for operator backups. jose caps PBES2
    iterations at 10 000 by default; the cap is raised at runtime to the iteration
    count used (`p2c` in the JWE header records it).
  A bundle may have several recipients; any one of them opens it.
* **File bodies.** Every file except `manifest.json` is encrypted under a per-file
  subkey `HMAC-SHA256(content_key, "aerox-bundle-v1/file\0" ‖ relative path)` with
  AES-256-GCM in chunks (1 MiB by default):

  ```
  "AXB1" ‖ chunk_size:u32 ‖ chunk*
  chunk = ct_len:u32 ‖ last:u8 ‖ ciphertext ‖ tag:16
  nonce = 0x00×8 ‖ chunk_index:u32
  AAD   = path ‖ 0x00 ‖ chunk_index:u32 ‖ last:u8
  ```

  Every chunk but the last is exactly `chunk_size` bytes of plaintext; an empty file is
  a single empty last chunk. Reading and writing stream; a missing final chunk
  (truncation), a moved chunk (reordering), a chunk from another file (splicing; the
  path is in the AAD and the subkey), a flipped bit or the wrong key all fail
  authentication, and a file with data after its last chunk is rejected.
* **Plaintext** output exists only behind `--insecure-plaintext` (air-gapped hosts);
  the writer refuses otherwise. Hashes in the manifest are always over plaintext.

## Tooling

Always available (`lib/mix/tasks`):

```
mix aerox.bundle.export --did <did>… | --all  --out <dir>
    [--recipient <jwk-or-pem>]… [--passphrase-env VAR] [--takeover] [--insecure-plaintext]
mix aerox.bundle.import --in <bundle-or-dir> [--takeover] [--recipient-key <jwk-or-pem> | --passphrase-env VAR]
    [--only did,…] [--force] [--expect-signer did:key:…] [--password-env VAR]
```

`MIX_ENV=tool` only (`lib_tool/`, needs `exqlite`):

```
MIX_ENV=tool mix aerox.interop.from_pds --data <dir> --out <dir> [--did …]… [--blobs <dir>]
    [--host <source hostname>] [--pds-version 0.4] [--takeover] [encryption flags as above]
MIX_ENV=tool mix aerox.interop.to_pds --in <bundle-or-dir> --data <dir> --pds-version 0.4
    [--blobs <dir>] [--takeover] [--host <target hostname>] [decryption flags as above]
```

Rules the tasks enforce:

* The import verifies each bundle (`Aerox.Interop.Verify.bundle/2`) before writing,
  then the imported account (`Verify.imported/3`), and exits non-zero on any failing
  account **or when nothing was imported from a non-empty source** (the did-map
  regression). Progress lives in `interop_progress` in `aerox_pds`; a `done` row is
  trusted only while the account is actually present.
* Per-account transaction; mutable rows `ON CONFLICT DO UPDATE`, blocks
  `ON CONFLICT DO NOTHING`; `repo_root`, `record`, `backlink`, `record_blob` re-derived
  from the CAR; stale rows of the account deleted; nothing re-signed.
* The bundle tasks start only the PDS repo, never the application: run the import with
  the PDS stopped. In `--takeover` mode this is required — `Aerox.Sequencer` reads
  `max(seq)` only at start, and no firehose events are emitted for imported accounts
  (downstream is migrated separately, DESIGN §13.4 point 2).
* Accounts whose `#atproto_pds` would change are printed as a PLC-operation list. **No
  task ever submits a PLC operation** (DESIGN §13.5).
* Secrets never reach the log: passphrases come from environment variables, and no
  key or hash is ever printed.

Configuration read by the adapters (`config :aerox, Aerox.Interop`, all optional):
`:source_impl`, `:source_version` (what an exported manifest records as `source`).

## Reference-PDS adapter notes (DESIGN §13.2)

* Pinned upstream version `"0.4"` = `ghcr.io/bluesky-social/pds:0.4`, which bundles
  `@atproto/pds` 0.5.27; migrations `001`–`007` (account), `001` (sequencer),
  `001` (actor store). The DDL and Kysely rows are in
  `Aerox.Interop.ReferencePds.Schema`, read back from that image's own files
  (`test/golden/interop/ref-pds-0.4/`). Other versions are refused.
* The blob directory is `PDS_BLOBSTORE_DISK_LOCATION` — `<data>/blocks` in the official
  installer and the dev stack — with `<data>/blobs` tried next and `--blobs` to
  override; quarantined objects are `<blobs>/quarantine/<did>/<cid>`.
* `did_cache.sqlite`, sessions, OAuth state and email tokens are not carried.
* `account_pref` rows live in the actor store upstream and travel in
  `account.json.preferences`.
