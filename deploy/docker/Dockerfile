# syntax=docker/dockerfile:1
# zalos server image. Runs unprivileged, read-only root, with only the
# tailscale CLI added for doctor/status queries against the sidecar socket.

FROM tailscale/tailscale:v1.104.4@sha256:ed6480b33c6eb67c9cbd203ed42b9fb57e361986725b6856def71b7a3d9e276c AS tailscale

FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS deps
WORKDIR /build
COPY packages/zalo-sdk ./packages/zalo-sdk
COPY server/package.json server/bun.lock ./server/
WORKDIR /build/server
RUN bun install --frozen-lockfile --production

FROM rust:1-bookworm@sha256:75d26c23c24cc6ea1cdabf0714a6bff8fd7bf3248716043fd7ae86dac7f41b94 AS web
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      libssl-dev \
      pkg-config \
      unzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN rustup toolchain install nightly --component rust-src \
    && rustup target add --toolchain nightly wasm32-unknown-unknown
RUN cargo install --locked --version 0.15.1 wasm-pack \
    && cargo install --locked --version 2.12.0 flutter_rust_bridge_codegen
RUN git clone --depth 1 --branch 3.50.1 https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter --version

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY client ./client
WORKDIR /build/client
RUN flutter pub get
RUN flutter_rust_bridge_codegen build-web --wasm-pack-rustflags \
  "-C target-feature=+atomics,+bulk-memory,+mutable-globals \
   -C link-arg=--shared-memory \
   -C link-arg=--import-memory \
   -C link-arg=--max-memory=1073741824 \
   -C link-arg=--export-if-defined=__wasm_init_tls \
   -C link-arg=--export-if-defined=__tls_base \
   -C link-arg=--export-if-defined=__tls_size \
   -C link-arg=--export-if-defined=__tls_align"
RUN flutter build web --release --no-web-resources-cdn

FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d
ENV ZALOS_CONTAINER=1 \
    ZALOS_DATA_DIR=/var/lib/zalos \
    ZALOS_TAILSCALE_SOCKET=/var/run/tailscale/tailscaled.sock \
    ZALOS_WEB_DIR=/opt/zalos/web

RUN groupadd -g 10001 zalos \
    && useradd -u 10001 -g zalos -d /var/lib/zalos -s /usr/sbin/nologin zalos

COPY --from=deps /build/packages/zalo-sdk /opt/packages/zalo-sdk
WORKDIR /opt/zalos
COPY --from=deps /build/server/node_modules ./node_modules
COPY server/package.json server/bun.lock ./
COPY server/src ./src
COPY server/vendor ./vendor
COPY --from=web /build/client/build/web /opt/zalos/web
# The smoke client rides along so deploy/docker/smoke.sh can verify the
# image without publishing any port.
COPY server/test/support ./smoke/support
COPY deploy/docker/smoke ./smoke
COPY deploy/docker/entrypoint.sh /opt/zalos/entrypoint.sh
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale

RUN printf '#!/bin/sh\nexec bun /opt/zalos/src/cli.ts "$@"\n' > /usr/local/bin/zalos \
    && chmod 755 /usr/local/bin/zalos /opt/zalos/entrypoint.sh \
    && mkdir -p /var/lib/zalos \
    && chown -R 10001:10001 /var/lib/zalos \
    && chmod 700 /var/lib/zalos

USER 10001
EXPOSE 7443
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD ["zalos", "health"]
ENTRYPOINT ["/opt/zalos/entrypoint.sh"]
