#!/bin/bash
# A second (or third) aerox dev server beside the primary one, with its own
# databases, blobs, hostnames and throwaway keys. Two uses so far:
#
#   * the multi-implementation lab network (tools/interop/lab-devserver.sh,
#     VERIFICATION §7.4): its own PLC is the lab's, so it shares identities
#     with seven other implementations;
#   * a migration target (tools/interop/mig-devserver.sh): the *same* PLC as
#     the primary dev server, which is what account migration needs — one
#     directory, two hosts.
#
# Configure it with:
#   NAME=<slug>            data under tmp/<slug>, build in _build/<slug>
#   DOMAIN=<host>          service hostnames and the handle domain
#   PORT=<port>            the endpoint's port on AEROX_BIND_IP
#   SUFFIX=<_slug>         database suffix (aerox_pds<suffix>, aerox_core<suffix>)
#   PLC=<url>              the directory it registers and resolves DIDs with
#   TRUSTED_DOMAINS=<list> optional, for the Relay
#
# Before the first start:
#   docker compose exec -T -e EXTRA_DB_SUFFIXES=<suffix> db bash < docker/postgres/init/01-databases.sh
#   AEROX_DB_SUFFIX=<suffix> mix ecto.migrate
set -euo pipefail
: "${NAME:?NAME is required}" "${DOMAIN:?DOMAIN is required}" "${PORT:?PORT is required}"
: "${SUFFIX:?SUFFIX is required}" "${PLC:?PLC is required}"
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/../.."
set -a; . ./.envrc; set +a

mkdir -p "tmp/$NAME"
if [ ! -e "tmp/$NAME/instance.env" ]; then
  umask 077
  {
    echo "AEROX_PLC_ROTATION_KEY_HEX=$(openssl rand -hex 32)"
    echo "AEROX_OAUTH_KEY_HEX=$(openssl rand -hex 32)"
    echo "AEROX_APPVIEW_SIGNING_KEY_HEX=$(openssl rand -hex 32)"
    echo "AEROX_PDS_ADMIN_PASSWORD=$(openssl rand -hex 16)"
    echo "AEROX_RELAY_ADMIN_PASSWORD=$(openssl rand -hex 16)"
    echo "AEROX_LABELER_ADMIN_PASSWORD=$(openssl rand -hex 16)"
  } > "tmp/$NAME/instance.env"
fi
set -a; . "tmp/$NAME/instance.env"; set +a

export AEROX_DEV_DOMAIN="$DOMAIN"
export PHX_HOST="$DOMAIN"
export AEROX_DB_SUFFIX="$SUFFIX"
export AEROX_POOL_SIZE="${AEROX_POOL_SIZE:-4}"
export AEROX_PLC_URL="$PLC"
export AEROX_RELAY_TRUSTED_DOMAINS="${TRUSTED_DOMAINS:-$DOMAIN}"
export AEROX_BLOB_ROOT="tmp/$NAME/blobs"
export AEROX_IMAGE_CACHE="tmp/$NAME/image-cache"
export AEROX_JETSTREAM_DIR="tmp/$NAME/jetstream"
export PORT
unset AEROX_LABELER_DID
# no code reloader (the primary dev server owns _build/dev), info logs
export AEROX_BENCH=1
export MIX_BUILD_PATH="_build/$NAME"
exec mix phx.server
