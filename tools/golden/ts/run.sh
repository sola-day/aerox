#!/bin/sh
# Regenerate test/golden/dagcbor/ and test/golden/cid/ inside a pinned Node
# container so the output does not depend on the developer's toolchain.
# Override the image with GOLDEN_NODE_IMAGE if the pinned tag is unavailable.
set -eu
cd "$(dirname "$0")/../../.."
# Pinned by digest: the tag node:24.21.0-alpine does not exist on Docker Hub.
IMAGE="${GOLDEN_NODE_IMAGE:-node:24-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf}"
exec docker run --rm -v "$PWD:/work" -w /work/tools/golden/ts "$IMAGE" \
  sh -c 'npm ci --no-audit --no-fund && node gen-dagcbor.mjs && node gen-cid.mjs'
