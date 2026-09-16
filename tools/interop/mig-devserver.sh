#!/bin/bash
# A migration target on the *same* PLC directory as the primary dev server:
# account migration moves the service endpoint in one DID document, so both
# hosts must resolve that document from the same directory (aero-app
# test/migrate.mjs, docs/INTEROP_LAB.md §2.3). Handles live under
# mig.aerox.sola.town.
#
#   docker compose exec -T -e EXTRA_DB_SUFFIXES=_mig db bash < docker/postgres/init/01-databases.sh
#   AEROX_DB_SUFFIX=_mig mix ecto.migrate
#   tools/interop/mig-devserver.sh
set -euo pipefail
exec env \
  NAME=mig \
  DOMAIN=mig.aerox.sola.town \
  PORT=4003 \
  SUFFIX=_mig \
  PLC=https://plc.aerox.sola.town \
  TRUSTED_DOMAINS=aerox.sola.town \
  "$(dirname "$0")/extra-devserver.sh"
