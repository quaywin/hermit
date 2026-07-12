# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.11
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# ==========================================
# Development Environment Stage
# ==========================================
FROM ${BUILDER_IMAGE} AS dev

# Install dev & runtime dependencies, download and install Tailscale in a single layer to minimize size
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     libstdc++6 openssl libncurses6 locales ca-certificates \
     iproute2 iptables nftables wireguard-tools wireguard-go curl tar procps openresolv ethtool microsocks tinyproxy python3 git build-essential \
  && ARCH=$(dpkg --print-architecture) \
  && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_1.98.4_${ARCH}.tgz" | tar -xz -C /tmp \
  && cp /tmp/tailscale_1.98.4_${ARCH}/tailscale* /usr/bin/ \
  && rm -rf /tmp/tailscale* \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen
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
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

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
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     libstdc++6 openssl libncurses6 locales ca-certificates \
     iproute2 iptables nftables wireguard-tools wireguard-go curl tar procps openresolv ethtool microsocks tinyproxy python3 \
  && ARCH=$(dpkg --print-architecture) \
  && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_1.98.4_${ARCH}.tgz" | tar -xz -C /tmp \
  && cp /tmp/tailscale_1.98.4_${ARCH}/tailscale* /usr/bin/ \
  && rm -rf /tmp/tailscale* \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# set runner ENV
ENV MIX_ENV="prod"

# Copy the final release
COPY --from=builder /app/hermit_release ./

CMD ["/app/bin/server"]
