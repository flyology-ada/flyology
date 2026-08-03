FROM ubuntu:24.04

ARG ALIRE_VERSION=2.1.0
ARG TARGETARCH

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       git \
       libssl-dev \
       pkg-config \
       unzip \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      arm64) alire_arch=aarch64 ;; \
      amd64) alire_arch=x86_64 ;; \
      *) echo "unsupported Docker target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL \
      "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-${alire_arch}-linux.zip" \
      -o /tmp/alire.zip \
    && unzip -q /tmp/alire.zip -d /opt/alire \
    && ln -s "/opt/alire/bin/alr" /usr/local/bin/alr \
    && rm /tmp/alire.zip

ENV ALR=/usr/local/bin/alr

# Keep the compiler download independent of source changes.
ARG GNAT_VERSION=16.1.0
ARG GPRBUILD_VERSION=26.0.1
WORKDIR /toolchain
RUN alr --non-interactive toolchain \
      --select gnat_native=${GNAT_VERSION} gprbuild=${GPRBUILD_VERSION}

WORKDIR /workspace
COPY . .

# Resolve project dependencies and catch public-library portability failures.
RUN alr --non-interactive build

CMD ["./scripts/test.sh"]
