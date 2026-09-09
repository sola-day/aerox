# Operations

How a release of aerox is built, configured, backed up and restored. The design
constraints it implements are DESIGN §4.6 (one database URL per repo), §14.2
(the rotation key never lives in the application host), §14.5 (backups) and
DEV_PLAN §1.3 (secrets).

## 1. Build and install

```
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release aerox           # → _build/prod/rel/aerox
```

Install the release to `/opt/aerox` as the `aerox` user, the env file to
`/etc/aerox/prod.env` (`0600`; template in `ops/aerox.env.example`) and the unit
`ops/systemd/aerox.service`. The unit migrates every repo before start
(`Aerox.Release.migrate/0`) and writes only under `/var/lib/aerox`.

The reverse proxy terminates TLS and must set `x-forwarded-for` and
`x-forwarded-proto`; list its peer addresses in `TRUSTED_PROXIES`. One release
serves every hostname: `AeroxWeb.Dispatch` routes by `Host` to the PDS+PLC
router, the Relay, the AppView or the Labeler. Hostnames default to
`<service>.<PHX_HOST>` and can be overridden with `PLC_HOST`, `RELAY_HOST`,
`APPVIEW_HOST`, `LABELER_HOST`.

## 2. Secrets and the rotation key

`config/runtime.exs` raises at boot for every missing secret. `SIGNER` selects
the rotation-key signer: `remote` (`Aerox.Crypto.Signer.Remote`, a separate host
that answers `GET /key` and `POST /sign` behind a bearer secret) or `kms`
(`Aerox.Crypto.Signer.Kms`, an AWS KMS `ECC_SECG_P256K1` key, compatible with
upstream's `@atproto/aws` keypair). `Aerox.PDS.Config.signer/0` refuses
`Signer.Local` when `config :aerox, :env` is `:prod`, so a dev key cannot be
promoted by accident. The offline recovery key (`RECOVERY_DID_KEY`) is only ever
a public `did:key` on the server.

## 3. Backup and restore

`ops/backup.sh <dest> <age-recipient>` dumps `aerox_pds` and `aerox_core` and
tars the blob store with numeric ownership and xattrs, then encrypts each file
with `age` to the operator's public key and writes `SHA256SUMS`. Run it from a
timer at the cadence in DESIGN §14.5; copy the directory off-host.

`ops/restore.sh <backup-dir> <age-identity>` is the restore drill
(VERIFICATION §10.4). It verifies the checksums, refuses non-empty target
databases or a non-empty blob root, restores both dumps and the blobs, and
prints the commit the backup was taken at. Then run the release's migrations
and VERIFICATION §6 scenario 1 against the restored stack.

The per-account logical backup is the bundle (`mix aerox.bundle.export`,
DESIGN §13.0); it is the only format users can take elsewhere.

## 4. Health and telemetry

`GET /xrpc/_health` on every host returns the version. Telemetry events are
emitted by Phoenix, Ecto, Oban and Broadway; the export decision (M10) is
**Prometheus via `telemetry_metrics_prometheus_core`** on a private port, to
be wired when the first release is cut. Until then `Aerox.Telemetry` only
logs.

## 5. Drills

| Drill | How | Cadence |
|---|---|---|
| Restore | §3 on a clean VM, then scenario 1 | before launch, quarterly |
| Migration | `mix aerox.bundle.*` against an encrypted production snapshot in a wiped working directory (DEV_PLAN §1.3) | before any cutover |
| Rotation key | with the offline recovery key, nullify a test PLC operation on the dev directory within its 72 h window | before launch |
| Faults | `mix test test/pds/faults_test.exs` (in-process, VERIFICATION §10.2) on every release branch; the network faults of §10.3 with Toxiproxy on the multi-container topology | release branches |
