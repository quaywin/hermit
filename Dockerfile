# Find eligible builder and runner images on Docker Hub.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.16
ARG ALPINE_VERSION=3.21.7

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="docker.io/alpine:${ALPINE_VERSION}"

# ==========================================
# Development Environment Stage
# ==========================================
FROM ${BUILDER_IMAGE} AS dev

# Install dev & runtime dependencies, download and install Tailscale in a single layer to minimize size
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
     libstdc++ openssl ncurses-libs ca-certificates \
     iproute2 iptables nftables wireguard-tools curl tar procps openresolv ethtool tinyproxy iputils git build-base \
  && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing microsocks \
  && case $(uname -m) in \
       x86_64) TS_ARCH="amd64" ;; \
       aarch64) TS_ARCH="arm64" ;; \
       *) TS_ARCH=$(uname -m) ;; \
     esac \
  && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_1.98.4_${TS_ARCH}.tgz" | tar -xz -C /tmp \
  && cp /tmp/tailscale_1.98.4_${TS_ARCH}/tailscale* /usr/bin/ \
  && rm -rf /tmp/tailscale*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="dev"

CMD ["mix", "phx.server"]

# ==========================================
# Production Builder Stage
# ==========================================
FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache build-base git

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.mix,sharing=locked \
    mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.mix,sharing=locked \
    mix deps.compile

RUN --mount=type=cache,target=/root/.cache,sharing=locked \
    mix assets.setup

COPY priv priv
COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/
COPY rel rel
RUN mix release && cp -r _build/${MIX_ENV}/rel/hermit /app/hermit_release

# ==========================================
# Production Runner Stage
# ==========================================
FROM ${RUNNER_IMAGE} AS final
ARG TARGETARCH

# Install dependencies, download and install Tailscale in a single layer to minimize size
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
     libstdc++ openssl ncurses-libs ca-certificates \
     iproute2 iptables nftables wireguard-tools curl tar procps openresolv ethtool tinyproxy iputils \
  && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing microsocks \
  && case $(uname -m) in \
       x86_64) TS_ARCH="amd64" ;; \
       aarch64) TS_ARCH="arm64" ;; \
       *) TS_ARCH=$(uname -m) ;; \
     esac \
  && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_1.98.4_${TS_ARCH}.tgz" | tar -xz -C /tmp \
  && cp /tmp/tailscale_1.98.4_${TS_ARCH}/tailscale* /usr/bin/ \
  && rm -rf /tmp/tailscale*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# set runner ENV
ENV MIX_ENV="prod"

# Copy the final release
COPY --from=builder /app/hermit_release ./

CMD ["/app/bin/server"]
