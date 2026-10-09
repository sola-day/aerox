# syntax=docker/dockerfile:1
# Two targets:
#   release (default)  the `mix release` the node runs; no Mix, no lib_tool
#   tool               MIX_ENV=tool with the source and Mix, for the one-off
#                      migration tasks that are not in a release
#                      (aerox.interop.from_pds needs exqlite, DESIGN §13.2)
#
# libvips comes precompiled with vix; nothing extra is installed for it.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.0.6
ARG DEBIAN_VERSION=trixie-20260918-slim

FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

# --------------------------------------------------------------------- tool
FROM base AS tool
ENV MIX_ENV=tool
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix deps.get
COPY config config
RUN mix deps.compile
COPY priv priv
COPY lib lib
COPY lib_tool lib_tool
RUN mix compile
ENTRYPOINT ["mix"]

# ------------------------------------------------------------------ release
FROM base AS build
ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY priv priv
COPY lib lib
RUN mix compile
COPY config/runtime.exs config/
RUN mix release aerox

FROM docker.io/debian:${DEBIAN_VERSION} AS release
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_SERVER=true
WORKDIR /app
RUN chown nobody /app
COPY --from=build --chown=nobody:root /app/_build/prod/rel/aerox ./
USER nobody
# migrations run as a separate step: bin/aerox eval "Aerox.Release.migrate()"
CMD ["/app/bin/aerox", "start"]
