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
(`Aerox.Release.migrate/0`) and writes only under `/var/lib/aerox`. It is
sandboxed to `systemd-analyze security` 1.3 — no capabilities, no devices, a
read-only OS, a syscall filter and only TCP and unix address families — with one
deliberate omission: `MemoryDenyWriteExecute` would stop the BEAM's JIT from
allocating executable pages and the VM would not start at all.

The reverse proxy terminates TLS and must set `x-forwarded-for` and
`x-forwarded-proto`; list its peer addresses in `TRUSTED_PROXIES`. Set `BIND_IP`
to the address the proxy dials: the default binds every interface, and on a host
with no packet filter that publishes the plaintext port beside the proxy, which
also makes `TRUSTED_PROXIES` moot because clients reach Phoenix directly. One release
serves every hostname: `AeroxWeb.Dispatch` routes by `Host` to the PDS+PLC
router, the Relay, the AppView, the Labeler or Jetstream; `AEROX_SERVICES` (e.g.
`pds,plc,relay,appview`) limits which run. Hostnames default to
`<service>.<PHX_HOST>` and can be overridden with `PLC_HOST`, `RELAY_HOST`,
`APPVIEW_HOST`, `LABELER_HOST`, `JETSTREAM_HOST`.

Jetstream keeps its archive as segment files under `JETSTREAM_DATA_DIR`
(`/var/lib/aerox/jetstream`, inside the unit's writable path). On first start it
backfills every repo the Relay lists before it serves (`/_health` reports the
`phase`); subscribers get 503 until then. `JETSTREAM_IMPORT_TOKEN` enables the
operator timestamp import, staged under `<data dir>/imports`.

## 2. Secrets and the rotation key

`config/runtime.exs` raises at boot for every missing secret. `SIGNER` selects
the rotation-key signer: `remote` (`Aerox.Crypto.Signer.Remote`, a separate host
that answers `GET /key` and `POST /sign` behind a bearer secret) or `kms`
(`Aerox.Crypto.Signer.Kms`, an AWS KMS `ECC_SECG_P256K1` key, compatible with
upstream's `@atproto/aws` keypair). `Aerox.PDS.Config.signer/0` refuses
`Signer.Local` when `config :aerox, :env` is `:prod`, so a dev key cannot be
promoted by accident. A staging deployment may set `SIGNER=local` with
`SIGNER_PRIVATE_KEY_HEX`, only together with `AEROX_DEPLOYMENT=staging`, which marks
the node `:staging`; the key then lives in the node's environment, so it must never
be one that rotates a production DID. The offline recovery key (`RECOVERY_DID_KEY`) is only ever
a public `did:key` on the server.

**Dev secrets are not in the repo either.** `config/dev.exs` reads its keys and
admin passwords from the environment, or from `tmp/dev.env`, which
`tools/dev/devserver.sh` generates on first run (`.gitignore` keeps both out).
The reference containers do the same through `tools/interop/.env` (see
`.env.example` beside it). The dev endpoint's `secret_key_base` is in there too, because
`Aerox.PDS.Config.jwt_secret/0` falls back to it: that one string mints every
access and refresh token the PDS issues. Only `config/test.exs` carries
literals, and they are deliberately fake (`String.duplicate("42", 32)`): a key that runs anywhere must
never double as a fixture — on 2026-09-16 this dev box's PLC rotation key turned
out to be the first entry of the W3C `did:key` test vectors in
`test/golden/crypto/`, i.e. a key anyone could look up, and it was rotated
across every dev DID.

**Admin passwords.** Three services take HTTP Basic `admin:<password>`, each
instance-wide with no per-operator identity: the PDS (`PDS_ADMIN_PASSWORD`,
optional — unset means only the moderation service's JWT reaches
`com.atproto.admin.*`), the relay (`RELAY_ADMIN_PASSWORD`, required, for
`admin.subscribeHost`, `setHostStatus`, `setHostAccountLimit`, `banDomain`) and
the labeler (`LABELER_ADMIN_PASSWORD`, required, for `aerox.moderation.*`). The labeler's own account is
created once with `PORT=<free port> bin/aerox eval 'Aerox.Release.setup_labeler("<handle>", "<password>")'`
(the release form of `mix aerox.labeler.setup`); export the DID it prints as `LABELER_DID`.
They authorise every action of their service, so they belong in
`/etc/aerox/<env>.env` (`0600`) like any other secret and are rotated the same
way. The aero client's `/admin` and `/moderation` consoles ask for them per tab
and keep them in `sessionStorage` only.

## 3. Backup and restore

`ops/backup.sh <dest> <age-recipient>` dumps `aerox_pds` and `aerox_core`,
tars the Jetstream segment directory when `JETSTREAM_DATA_DIR` is set, and
tars the blob store with numeric ownership and xattrs, then encrypts each file
with `age` to the operator's public key and writes `SHA256SUMS`. Run it from a
timer at the cadence in DESIGN §14.5; copy the directory off-host.

`ops/restore.sh <backup-dir> <age-identity>` is the restore drill
(VERIFICATION §10.4). It verifies the checksums, refuses non-empty target
databases or a non-empty blob root, restores both dumps and the blobs, and
prints the commit the backup was taken at. Then run the release's migrations
and VERIFICATION §6 scenario 1 against the restored stack.

Drill record (2026-09-10, commit 3b5180d): backup of the dev stack →
restore into empty `aerox_pds_drill`/`aerox_core_drill` and a fresh blob
root → a second server (`AEROX_DB_SUFFIX=_drill AEROX_POOL_SIZE=3 PORT=4001`)
→ `test/harness/restore-check.mjs`: restored login, records visible, a new
commit on top, CAR served (`RESTORE OK`). Two things the drill found: a
`--no-owner` restore silently locks every service role out of its schema
(the schemas are role-owned), so ownership is now dumped and restored; and
two full stacks on one Postgres exceed the default 100 connections — budget
`pool_size` × repos + one per sequencer + Oban per instance.

A PLC directory moves with `Aerox.PLC.Import` (`mix aerox.plc.import --from
<url|file>`, or `bin/aerox eval 'Aerox.Release.import_plc("<url>")'`): it
pages through the source's `/export`, validates every DID's log, and writes
the rows verbatim — `cid`, `createdAt`, `nullified` — in the source's order,
all or nothing. It only reads the source and never signs or submits an
operation; rerunning it adds what the source has gained since.

The per-account logical backup is the bundle (`mix aerox.bundle.export`,
DESIGN §13.0); it is the only format users can take elsewhere.

## 4. Health and telemetry

`GET /xrpc/_health` answers on the PDS, the relay, the AppView and the
labeler (Jetstream answers `GET /_health` with its phase) (the PDS returns the release version; upstream's PDS answers at the same
path). The PLC directory is route-for-route did-method-plc, which puts its
liveness check at `GET /_health`, and the relay, AppView and labeler answer
there as well. Telemetry events are
emitted by Phoenix, Ecto, Oban and Broadway; the export decision (M10) is
**Prometheus via `telemetry_metrics_prometheus_core`** on a private port, to
be wired when the first release is cut. Until then `Aerox.Telemetry` only
logs.

## 5. Tuning

Three knobs decide throughput and all three have defaults chosen for a small
box; `bench/RESULTS.md` has the measurements behind these.

| Variable | Default | What it costs to get it wrong |
|---|---|---|
| `IMAGE_CONCURRENCY` | 4 | The libvips bound (DESIGN §21.8). Cold-image throughput scales almost linearly up to the core count and flat after, so 4 on an 8-core image host leaves a third of the machine idle. Set it to the core count. |
| `INGEST_CONCURRENCY` | 4 | AppView ingest partitions. Events of one repo stay in one partition, so this only helps when many repos are active; on the drill host it doubled throughput at 8 and gained nothing after. |
| `POOL_SIZE` | 10 | Per repo, and there are six. `POOL_SIZE` × 6 + one per sequencer + Oban must stay under the database's `max_connections`; past it, throughput *falls* and boot takes minutes as connections are retried. |

## 6. Drills

| Drill | How | Cadence |
|---|---|---|
| Restore | §3 on a clean VM, then scenario 1 | before launch, quarterly |
| Migration | `mix aerox.bundle.*` against an encrypted production snapshot in a wiped working directory (DEV_PLAN §1.3) | before any cutover |
| Rotation key | with the offline recovery key, nullify a test PLC operation on the dev directory within its 72 h window | before launch |
| Faults | `mix test test/pds/faults_test.exs` (in-process, VERIFICATION §10.2) on every release branch; the network faults of §10.3 with Toxiproxy on the multi-container topology | release branches |
