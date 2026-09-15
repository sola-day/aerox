#!/bin/bash
# A second aerox dev server that joins the multi-implementation lab network on
# generic.dev (VERIFICATION §7.4): the lab's PDSes (atproto, crates, tranquil,
# pegasus, zds, cocoon, rsky) register their DIDs on plc.xjdao.generic.dev,
# so this instance resolves and registers identities there too. Everything
# else is its own: databases aerox_*_lab, blobs/jetstream under tmp/lab,
# hostnames pds./relay./appview./jetstream.lab.aerox.sola.town, handles
# *.lab.aerox.sola.town, and throwaway keys generated on first start into
# tmp/lab/instance.env (0600, gitignored). The lab PLC holds test identities
# only; never point this at plc.directory.
#
#   docker compose exec -T -e EXTRA_DB_SUFFIXES=_lab db bash < docker/postgres/init/01-databases.sh
#   AEROX_DB_SUFFIX=_lab mix ecto.migrate
#   tools/interop/lab-devserver.sh
set -euo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/../.."
set -a; . ./.envrc; set +a

mkdir -p tmp/lab
if [ ! -e tmp/lab/instance.env ]; then
  umask 077
  {
    echo "AEROX_PLC_ROTATION_KEY_HEX=$(openssl rand -hex 32)"
    echo "AEROX_OAUTH_KEY_HEX=$(openssl rand -hex 32)"
    echo "AEROX_APPVIEW_SIGNING_KEY_HEX=$(openssl rand -hex 32)"
  } > tmp/lab/instance.env
fi
set -a; . tmp/lab/instance.env; set +a

export AEROX_DEV_DOMAIN=lab.aerox.sola.town
export PHX_HOST=lab.aerox.sola.town
export PORT=4002
export AEROX_DB_SUFFIX=_lab
export AEROX_POOL_SIZE=4
export AEROX_PLC_URL=https://plc.xjdao.generic.dev
export AEROX_RELAY_TRUSTED_DOMAINS=lab.aerox.sola.town,generic.dev
export AEROX_BLOB_ROOT=tmp/lab/blobs
export AEROX_IMAGE_CACHE=tmp/lab/image-cache
export AEROX_JETSTREAM_DIR=tmp/lab/jetstream
unset AEROX_LABELER_DID
# no code reloader (the primary dev server owns _build/dev), info logs
export AEROX_BENCH=1
export MIX_BUILD_PATH=_build/lab
exec mix phx.server
