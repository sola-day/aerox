# The reference AppView of VERIFICATION §7.1. Built from the reading-room
# checkout of bluesky-social/atproto (which stays untouched) with this
# directory spliced in as the entrypoint:
#
#   docker build -f tools/interop/bsky-standalone/Dockerfile \
#     --build-context standalone=tools/interop/bsky-standalone \
#     -t aerox-ref-appview:<atproto-sha> /home/ubuntu/aero/bsky/atproto
#
# Everything that answers a request is upstream's code; only the wiring of the
# processes into one container is ours (see server.ts).
FROM node:24.15-alpine3.23 AS build

RUN npm install -g pnpm@11.5.2

WORKDIR /app

COPY ./.npmrc ./
COPY ./.nvmrc ./
COPY ./package.json ./
COPY ./pnpm-lock.yaml ./
COPY ./pnpm-workspace.yaml ./
COPY ./tsconfig ./tsconfig
COPY ./lexicons ./lexicons
COPY ./packages/internal ./packages/internal
COPY ./packages/lex ./packages/lex

# bsky's transitive dependencies
COPY ./packages/api ./packages/api
COPY ./packages/aws ./packages/aws
COPY ./packages/common-web ./packages/common-web
COPY ./packages/common ./packages/common
COPY ./packages/crypto ./packages/crypto
COPY ./packages/did ./packages/did
COPY ./packages/identity ./packages/identity
COPY ./packages/lex-cli ./packages/lex-cli
COPY ./packages/lexicon ./packages/lexicon
COPY ./packages/oauth/jwk-jose ./packages/oauth/jwk-jose
COPY ./packages/oauth/jwk-webcrypto ./packages/oauth/jwk-webcrypto
COPY ./packages/oauth/jwk ./packages/oauth/jwk
COPY ./packages/oauth/oauth-client-browser-example ./packages/oauth/oauth-client-browser-example
COPY ./packages/oauth/oauth-client-browser ./packages/oauth/oauth-client-browser
COPY ./packages/oauth/oauth-client ./packages/oauth/oauth-client
COPY ./packages/oauth/oauth-provider-api ./packages/oauth/oauth-provider-api
COPY ./packages/oauth/oauth-provider-ui ./packages/oauth/oauth-provider-ui
COPY ./packages/oauth/oauth-provider ./packages/oauth/oauth-provider
COPY ./packages/oauth/oauth-scopes ./packages/oauth/oauth-scopes
COPY ./packages/oauth/oauth-types ./packages/oauth/oauth-types
COPY ./packages/pds ./packages/pds
COPY ./packages/repo ./packages/repo
COPY ./packages/sync ./packages/sync
COPY ./packages/syntax ./packages/syntax
COPY ./packages/ws-client ./packages/ws-client
COPY ./packages/xrpc-server ./packages/xrpc-server
COPY ./packages/xrpc ./packages/xrpc
COPY ./packages/bsky ./packages/bsky
COPY ./packages/bsync ./packages/bsync

COPY --from=standalone . ./services/bsky-standalone

# Not --frozen-lockfile: this entrypoint declares one dependency the checked-in
# lockfile does not carry (@atproto/bsync). Workspace packages still resolve to
# the checkout, so nothing upstream changes version. Re-resolving does make
# pnpm read the workspace root's own dependencies, and the root dev-dependency
# @atproto/dev-env is a workspace package this image deliberately does not
# copy (it drags in the whole test harness), so drop that one line first.
RUN sed -i '/"@atproto\/dev-env": "workspace:\^",/d' ./package.json
RUN PUPPETEER_SKIP_DOWNLOAD=true pnpm install --no-frozen-lockfile
RUN pnpm run --recursive --stream --filter '@atproto/crypto...' build
RUN pnpm run --recursive --stream --filter '@atproto/bsky...' build
RUN pnpm run --recursive --stream --filter '@atproto/bsync...' build
RUN pnpm install --prod --shamefully-hoist --no-frozen-lockfile --prefer-offline --config.confirmModulesPurge=false

FROM node:24.15-alpine3.23

RUN apk add --update dumb-init

ENTRYPOINT ["dumb-init", "--"]

COPY --from=build /app /app
WORKDIR /app/services/bsky-standalone

EXPOSE 3000
ENV PORT=3000
ENV BSKY_PORT=3000
ENV NODE_ENV=production

# The data directory has to exist in the image and belong to the runtime user:
# Docker creates a missing bind target root-owned, and this image runs as node.
RUN mkdir -p /home/node/data && chown node:node /home/node/data
VOLUME /home/node/data

USER node
CMD ["node", "--enable-source-maps", "server.ts"]

LABEL org.opencontainers.image.description="Bluesky AppView (standalone: dataplane + bsync + appview)"
