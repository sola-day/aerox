# Aerox

**An AT Protocol backend built with Elixir, Phoenix, and PostgreSQL.**

Aerox brings a Personal Data Server, PLC identity directory, Relay, AppView,
Labeler, and Jetstream into a single codebase. Run them together for a
self-hosted network, or enable selected services on separate nodes. Applications
connect through HTTP APIs and WebSocket streams; service boundaries remain the
same in either deployment.

The project focuses on portable accounts, verifiable repositories, and a backend
that operators can understand and run themselves. It includes the protocol
primitives, social indexing, moderation, streaming, and migration tools needed
to build and operate an independent AT Protocol stack.

## What you can build

- **A self-hosted social network:** host accounts and media, index posts and
  relationships, and connect an AT Protocol client.
- **An application on AT Protocol:** store custom Lexicon records in user
  repositories and consume repository changes through the Relay or Jetstream.
- **A permissioned data application:** experiment with Spaces, the feature-flagged
  implementation of the permissioned-data proposal.
- **A migration or interoperability environment:** import existing repositories,
  move accounts, and exercise protocol behavior against other implementations.

Aerox provides backend services. A social client and an operator web console are
separate applications.

## Services

| Service | Responsibility | Included capabilities |
| --- | --- | --- |
| **PDS** | Hosts accounts and signed repositories | Account lifecycle, sessions, OAuth, record CRUD, blobs, repository import/export, sync APIs, and an AppView proxy |
| **PLC directory** | Maintains `did:plc` identities | Signed operation logs, DID document resolution, rotation and recovery operations, and directory export/import |
| **Relay** | Aggregates repository changes | PDS subscriptions, repository verification, a replayable firehose, host discovery, and administrative host controls |
| **AppView** | Turns repository data into social views | Profiles, feeds, threads, likes, reposts, follows, lists, notifications, post/profile search, and an image CDN |
| **Labeler** | Publishes moderation decisions | Signed labels, label subscriptions, report intake, moderation events, takedowns, and an audit log |
| **Jetstream** | Makes repository events easier to consume | JSON WebSocket streams, DID and collection filters, timestamp cursors, and a segment-based replay archive |

## Core capabilities

### Protocol-native repositories

The shared protocol layer implements DAG-CBOR, CIDs, Merkle Search Trees, CAR
archives, repository commits, signatures, TIDs, identity syntax, and Lexicon
validation. It operates on explicit inputs rather than depending on a service's
database or network connections. Golden fixtures, property tests, and differential
checks exercise its encodings against reference implementations.

### Authentication and identity

The PDS supports AT Protocol OAuth and legacy session authentication. Identity
handling includes DID documents, handle resolution, PLC operation validation,
and signing-key rotation. Production rotation-key signing uses a remote signer
or AWS KMS; account repositories and identity operations retain their protocol
formats when moved between providers.

### Account portability

Aerox supports repository and blob transfer, account migration, and encrypted
bulk migration bundles for moving data to and from the reference PDS. The
reference-PDS SQLite adapter lives in a separate tool build and is excluded from
production releases. PLC directory import validates operation logs before
persisting them, while AppView backfill reconstructs indexes from repository data.

### Social indexing and moderation

The AppView consumes the Relay's firehose, persists its subscription cursor, and
builds social views in PostgreSQL. Search uses PostgreSQL full-text indexes and
trigram matching rather than requiring a separate search cluster. Images are
served through a bounded libvips-backed cache.

The Labeler accepts reports, emits signed labels, and records moderation actions.
The AppView consumes configured label streams and applies moderation to its read
paths. Administrative moderation APIs are available, but the complete Ozone API
and Ozone web-console compatibility are outside the current implementation.

### Streaming and permissioned data

The Relay exposes the repository firehose. Jetstream provides JSON-oriented
subscriptions and an on-disk archive for filtered replay and catch-up before
switching to live events.

Spaces adds access-controlled data through `com.atproto.space.*` and
`com.atproto.simplespace.*`. It is an experimental, feature-flagged protocol
extension; applications should treat its interface as subject to change.

## Architecture

```text
                         Clients and applications
                           | HTTP / WebSocket
                           v
                   Phoenix endpoint / host routing
                           |
        +---------+--------+---------+----------+-----------+
        |         |                  |          |           |
       PLC       PDS -- firehose --> Relay --> AppView    Labeler
        |         |                  |          ^           |
        |         |                  +--> Jetstream         |
        |         |                             +-- labels -+
        |         |
   Identity   Repositories
     logs      and blobs

       Shared protocol kernel and infrastructure adapters
         DAG-CBOR / CID / MST / CAR / signing / Lexicon
```

Aerox is one Mix application with compile-time module boundaries. Services
exchange data through protocol APIs and streams rather than reading one another's
tables. Each service has an Ecto repository and a dedicated PostgreSQL role. The
bundled development setup uses a PDS database plus a core database containing
isolated schemas for the other services.

OTP supervision manages the service processes, Oban runs background jobs, and
storage, signing, search, and identity resolution use replaceable interfaces.
The same release can run all six services or a selected subset.

## Getting started

### Requirements

- Elixir **1.20** and Erlang/OTP **29**; exact development pins are in `.tool-versions`.
- Docker with Compose for the bundled PostgreSQL **18** instance.
- OpenSSL and a native build toolchain for dependencies that include NIFs.
- Node.js and Go only if you run the external interoperability harnesses or
  regenerate reference fixtures; they are not application runtime dependencies.

### Start a local development server

Clone the repository and start PostgreSQL:

```sh
git clone https://github.com/sola-day/aerox.git
cd aerox
docker compose up -d --wait db
```

Compose exposes PostgreSQL on `127.0.0.1:5433` and initializes the development
and test databases, roles, and schemas. Its bundled passwords are for local
development only.

Generate development credentials once, before running Mix. `config/dev.exs`
automatically reads the ignored `tmp/dev.env` file:

```sh
mkdir -p tmp
if [ ! -f tmp/dev.env ]; then
  (
    umask 077
    {
      printf 'AEROX_SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 48 | tr -d '\n')"
      for name in PLC_ROTATION_KEY_HEX OAUTH_KEY_HEX APPVIEW_SIGNING_KEY_HEX; do
        printf 'AEROX_%s=%s\n' "$name" "$(openssl rand -hex 32)"
      done
      for name in PDS_ADMIN_PASSWORD RELAY_ADMIN_PASSWORD LABELER_ADMIN_PASSWORD; do
        printf 'AEROX_%s=%s\n' "$name" "$(openssl rand -hex 16)"
      done
    } > tmp/dev.env
  )
fi

mix setup
mix phx.server
```

The HTTP endpoint listens on `127.0.0.1:4000`. In another terminal, check the
PDS API:

```sh
curl http://127.0.0.1:4000/xrpc/com.atproto.server.describeServer
```

This starts the application locally; a complete multi-service network also needs
working service hostnames and HTTPS. Local HTTP alone does not provide the
public URLs required by OAuth, DID resolution, and service-to-service connections.

### Configure service URLs

In development, set `AEROX_DEV_DOMAIN` to a domain you control and `PHX_HOST` to
the public endpoint hostname before starting Mix. Route the following hosts
through a TLS reverse proxy to the Phoenix endpoint, preserving the `Host` header:

| Host | Service |
| --- | --- |
| `pds.<domain>` | PDS |
| `plc.<domain>` | PLC directory |
| `relay.<domain>` | Relay |
| `appview.<domain>` | AppView |
| `labeler.<domain>` | Labeler |
| `jetstream.<domain>` | Jetstream |

`AEROX_BIND_IP` sets the development listener address. When the proxy runs in a
different container or host, use an address it can reach. The default is loopback.
Set individual URL overrides in `config/dev.exs` when connecting to external
services. Labeler identity provisioning is a separate setup step; its DID must
be configured for label publication and AppView label subscriptions.

Keep `tmp/dev.env` between restarts. Replacing its PLC rotation key can leave
existing development identities without their configured signer.

## Deployment

Aerox supports native Erlang releases and a multi-stage Docker build. Provision
the databases and service roles, configure DNS and TLS, and supply runtime
configuration through the environment.

Build a native release:

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release aerox
```

With the runtime environment loaded, migrate and start it:

```sh
_build/prod/rel/aerox/bin/aerox eval 'Aerox.Release.migrate()'
PHX_SERVER=true _build/prod/rel/aerox/bin/aerox start
```

Or build the container targets:

```sh
docker build --target release -t aerox:local .
docker build --target tool -t aerox-tool:local .
```

The `release` image contains the application release; `tool` contains Mix and
migration tooling. The bundled Compose file starts PostgreSQL only. Running the
release image also requires database connectivity, runtime secrets, persistent
storage, and reverse-proxy configuration.

Key production settings:

| Setting | Purpose |
| --- | --- |
| `AEROX_SERVICES` | Comma-separated services to enable, such as `pds,plc,relay,appview`; all are enabled by default |
| `PHX_HOST`, `PDS_PUBLIC_URL`, `*_HOST` | Public endpoint and service hostnames |
| `PDS_DATABASE_URL`, `PLC_DATABASE_URL`, `RELAY_DATABASE_URL`, `APPVIEW_DATABASE_URL`, `LABELER_DATABASE_URL`, `JETSTREAM_DATABASE_URL` | Independent connection configuration for service repositories |
| `SECRET_KEY_BASE`, `JWT_SECRET`, `OAUTH_KEY_HEX`, `APPVIEW_SIGNING_KEY_HEX` | Endpoint, session, and signing secrets |
| `SIGNER` | Production rotation-key signer: `remote` or `kms` |
| `RELAY_ADMIN_PASSWORD`, `LABELER_ADMIN_PASSWORD`, `PDS_ADMIN_PASSWORD` | Service administration credentials; PDS Basic authentication is optional |
| `LABELER_DID`, `LABELER_SIGNING_KEY_HEX` | Labeler identity and signing material |
| `BLOB_ROOT`, `JETSTREAM_DATA_DIR`, `IMAGE_CACHE_DIR` | Blob storage, streaming archive, and image cache paths |
| `BIND_IP`, `PORT`, `TRUSTED_PROXIES` | Listener configuration and trusted reverse-proxy peers |

Use `ops/aerox.env.example` as a configuration template. Service selection controls
which processes run; the current runtime configuration still reads shared
settings and secrets at boot. Back up the databases, blob store, and Jetstream
archive together. The image cache can be rebuilt.

A local rotation-key signer is available only with the explicit staging mode
`AEROX_DEPLOYMENT=staging`; production requires the remote or KMS signer.

## Compatibility and project status

Aerox is under active development. It implements substantial AT Protocol and
Bluesky API surfaces, with interoperability tests against reference stacks and
other implementations. Protocol encoding compatibility and complete product API
coverage are separate concerns: support for one does not imply every client
feature is available.

Current scope and limits:

- The default topology uses its own PLC directory and configured relays. Joining
  the public Bluesky network is not an automatic consequence of starting Aerox;
  it requires appropriate identity, discovery, peering, and operational setup.
- AppView covers core social reads, but some discovery, onboarding, draft,
  bookmark, and push-notification APIs are not implemented.
- Moderation uses the standard labeling interfaces plus Aerox-specific operator
  APIs; it does not implement the full Ozone workflow.
- Chat and video services are outside the current scope.
- Spaces follows an experimental permissioned-data proposal.

## Development and testing

```sh
mix test                  # ExUnit, integration, property, and golden-fixture tests
mix precommit             # Compile checks, formatting, Credo, and tests
mix dialyzer              # Static analysis
```

Run tests with PostgreSQL available. Test runs share the bundled test databases;
run one suite at a time unless you provision separate partition databases.

The repository also contains JavaScript protocol harnesses in `test/harness`,
reference-stack and interoperability tools in `tools/interop`, and benchmarks in
`bench`. These exercise running services in addition to the in-process tests.

### Repository layout

```text
lib/aerox/          Protocol kernel, services, and shared infrastructure
lib/aerox_web/      Host dispatch, service routers, XRPC, and WebSocket endpoints
lib_tool/           Development and migration adapters excluded from prod builds
config/             Environment and runtime configuration
priv/               Service migrations, Lexicons, and static assets
test/               Unit, integration, property, parity, and protocol harnesses
docker/             PostgreSQL initialization and container support
ops/                Deployment configuration, backup, and restore scripts
tools/              Development utilities and interoperability environments
bench/              Performance workloads and recorded results
docs/               Design, operations, compatibility, and verification details
```

### Contributing

Bug reports, interoperability findings, documentation improvements, and focused
pull requests are welcome. Include a reproducible example for protocol issues
and tests for behavioral changes. Keep protocol code independent of I/O, preserve
service data boundaries, and keep tool-only dependencies out of production builds.
Never include real credentials, signing keys, or private account data in issues
or fixtures.

## Further reading

The README covers the project and its basic workflow. For deeper work, see the
[design](docs/DESIGN.md), [operations guide](docs/OPS.md),
[compatibility report](docs/PARITY.md), and
[verification strategy](docs/VERIFICATION.md).

## License

Aerox is licensed under the [Apache License 2.0](LICENSE).
