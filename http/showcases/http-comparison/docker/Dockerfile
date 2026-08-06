FROM rust:1.97.1-bookworm AS rust-fixtures

WORKDIR /fixtures
COPY showcases/http-comparison/servers/rust/ ./
RUN cargo build --locked --release --bins

FROM ubuntu:24.04

ARG ALIRE_VERSION=2.1.1
ARG OHA_VERSION=1.7.0
ARG TARGETARCH
ARG FLYOLOGY_GIT_REVISION=unavailable
ARG FLYOLOGY_GIT_DIRTY=0
ARG HTTP_BENCH_LOOPS=
ARG RUST_VERSION=1.97.1

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       git \
       libssl-dev \
       pkg-config \
       procps \
       python3 \
       ripgrep \
       unzip \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      arm64) \
        alire_arch=aarch64; \
        alire_sha=d76c93ad3dc631826144e10bdabc6b3bf98783805bebfd5e4a0e852dd524d812; \
        oha_arch=arm64; \
        oha_sha=d62dc196b9b7114c70c4b60cc255646de21aa6afa630fa37f72177c0c7832ae9 ;; \
      amd64) \
        alire_arch=x86_64; \
        alire_sha=09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7; \
        oha_arch=amd64; \
        oha_sha=36e081a31b80136cb35ac9385d1252dc30696378281c9c400abd3fee32929231 ;; \
      *) echo "unsupported Docker target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL \
      "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-${alire_arch}-linux.zip" \
      -o /tmp/alire.zip \
    && echo "${alire_sha}  /tmp/alire.zip" | sha256sum --check - \
    && unzip -q /tmp/alire.zip -d /opt/alire \
    && ln -s /opt/alire/bin/alr /usr/local/bin/alr \
    && curl -fsSL \
      "https://github.com/hatoo/oha/releases/download/v${OHA_VERSION}/oha-linux-${oha_arch}" \
      -o /usr/local/bin/oha \
    && echo "${oha_sha}  /usr/local/bin/oha" | sha256sum --check - \
    && chmod +x /usr/local/bin/oha \
    && rm /tmp/alire.zip

ENV ALR=/usr/local/bin/alr
ENV HTTP_BENCH_GNAT_VERSION=15.3.1
ENV HTTP_BENCH_GPRBUILD_VERSION=25.0.1
ENV HTTP_BENCH_GIT_REVISION=${FLYOLOGY_GIT_REVISION}
ENV HTTP_BENCH_GIT_DIRTY=${FLYOLOGY_GIT_DIRTY}
ENV HTTP_BENCH_LOOPS=${HTTP_BENCH_LOOPS}
ENV HTTP_BENCH_RUST_VERSION=${RUST_VERSION}
ENV HTTP_BENCH_CARGO_VERSION=${RUST_VERSION}
ENV HTTP_BENCH_SKIP_RUST_BUILD=1

WORKDIR /toolchain
RUN alr --non-interactive toolchain --select \
      gnat_native=${HTTP_BENCH_GNAT_VERSION} \
      gprbuild=${HTTP_BENCH_GPRBUILD_VERSION}

WORKDIR /workspace
COPY . .
COPY --from=rust-fixtures /fixtures/target/release/hyper_plain /workspace/showcases/http-comparison/servers/rust/target/release/hyper_plain
COPY --from=rust-fixtures /fixtures/target/release/axum_app /workspace/showcases/http-comparison/servers/rust/target/release/axum_app
COPY --from=rust-fixtures /fixtures/target/release/actix_app /workspace/showcases/http-comparison/servers/rust/target/release/actix_app
RUN ./showcases/http-comparison/scripts/build.sh

ENV HTTP_BENCH_MODE=docker-loopback
ENV HTTP_BENCH_OUTPUT_ROOT=/results
ENV HTTP_BENCH_SKIP_BUILD=1
CMD ["./showcases/http-comparison/scripts/run.sh"]
