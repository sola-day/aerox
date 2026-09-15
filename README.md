# aerox

An AT Protocol implementation in Elixir/Phoenix: PDS, PLC directory, Relay,
AppView, Labeler and Jetstream in one application. Each service has its own
router, repo and database role, and they can run together or be split across
nodes.

## Documents

| Document | What it answers |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | what aerox is, and the trade-offs behind every choice |
| [`docs/DEV_PLAN.md`](docs/DEV_PLAN.md) | build order, milestones and retrospectives, how we work, secrets rules |
| [`docs/STRUCTURE.md`](docs/STRUCTURE.md) | where code goes, and which boundaries the layout enforces |
| [`docs/VERIFICATION.md`](docs/VERIFICATION.md) | how we know it is right, layer by layer |
| [`docs/PARITY.md`](docs/PARITY.md) | differences from Bluesky's reference implementation; spec coverage |
| [`docs/BUNDLE.md`](docs/BUNDLE.md) | the portable account bundle format |
| [`docs/OPS.md`](docs/OPS.md) | release build, configuration, backups, restore drill |
| [`docs/SELF_CUSTODY.md`](docs/SELF_CUSTODY.md) | moving a `did:plc` to keys the user holds, with existing protocol calls only (implemented in aero, verified on aerox and on the reference PDS + PLC) |
| [`docs/INTEROP_LAB.md`](docs/INTEROP_LAB.md) | aerox among seven other PDS implementations: federation, lifecycle and migration results, fixes, counterpart findings |

## Running it

```sh
docker compose up -d db                  # Postgres 18 on 127.0.0.1:5433
mix setup
mix phx.server                           # all services; hostnames from PHX_HOST / AEROX_DEV_DOMAIN
mix test                                 # one run at a time: runs share the test databases
```

The environment files are `.envrc.example` (dev) and `/etc/aerox/<env>.env`
(production; see OPS.md). Secrets never go in the repo.

## Instances

| Instance | Where | Notes |
|---|---|---|
| Dev | `pds.` / `plc.` / `relay.` / `appview.` / `labeler.` / `jetstream.aerox.sola.town` | `mix phx.server` on 172.18.0.1:4000 behind Traefik (`ops/traefik`) |
| Lab-network dev | `pds.` / `relay.` / `appview.lab.aerox.sola.town` | `tools/interop/lab-devserver.sh` on :4002, joined to the generic.dev lab's PLC (INTEROP_LAB.md) |
| Release candidate | `aerox.generic.dev` and `plc.` / `relay.` / `appview.` / `labeler.aerox.generic.dev` | systemd release; the PLC rotation key lives on a separate signer (OPS.md) |
| Reference oracles | `ref-plc.` / `ref-relay.` / `ref-pds.` / `ref-pds2.` / `ref-appview.aerox.sola.town` | `tools/interop/compose.yaml` (VERIFICATION §7.1–7.2) |

## Clients run against it

- **aero** (`../aero-app`, https://aero.sola.town): React 19 + Astryx social client
  covering most of the protocol surface, including the self-custody flows of
  SELF_CUSTODY.md.
- **ouranos** (https://ouranos.aerox.sola.town) is an unmodified upstream client.
- **bulletin** (https://bulletin.aerox.sola.town) is the permissioned-spaces demo.

## Harness

`test/harness` drives the running stacks through `@atproto/api`:

| Script | Covers |
|---|---|
| `smoke.mjs` | PDS writes and the firehose |
| `parity.mjs` | endpoint parity with the reference AppView |
| `oauth.mjs` | the OAuth flow |
| `ouranos.mjs`, `bulletin.mjs` | the ouranos and bulletin clients (Playwright) |
| `rotation-drill.mjs` | the PLC rotation-key drill |
| `lab.mjs` | multi-implementation interop (INTEROP_LAB.md) |
