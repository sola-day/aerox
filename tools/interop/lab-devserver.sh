#!/bin/bash
# The aerox instance that joins the multi-implementation lab network on
# generic.dev (VERIFICATION §7.4, docs/INTEROP_LAB.md): its DIDs are registered
# and resolved on the lab's PLC directory, so the seven other PDSes there share
# identities with it. Everything else is its own — databases aerox_*_lab, blobs
# and jetstream under tmp/lab, hostnames under lab.aerox.sola.town, throwaway
# keys in tmp/lab/instance.env. The lab PLC holds test identities only; never
# point this at plc.directory.
#
#   docker compose exec -T -e EXTRA_DB_SUFFIXES=_lab db bash < docker/postgres/init/01-databases.sh
#   AEROX_DB_SUFFIX=_lab mix ecto.migrate
#   tools/interop/lab-devserver.sh
set -euo pipefail
exec env \
  NAME=lab \
  DOMAIN=lab.aerox.sola.town \
  PORT=4002 \
  SUFFIX=_lab \
  PLC=https://plc.xjdao.generic.dev \
  TRUSTED_DOMAINS=lab.aerox.sola.town,generic.dev \
  "$(dirname "$0")/extra-devserver.sh"
