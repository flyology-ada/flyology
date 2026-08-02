FROM ubuntu:24.04

ARG ALIRE_VERSION=2.1.0

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       git \
       unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
      "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-x86_64-linux.zip" \
      -o /tmp/alire.zip \
    && unzip -q /tmp/alire.zip -d /opt/alire \
    && ln -s "/opt/alire/bin/alr" /usr/local/bin/alr \
    && rm /tmp/alire.zip

ENV ALR=/usr/local/bin/alr

# Keep the compiler download independent of source changes.
WORKDIR /toolchain
RUN alr --non-interactive toolchain \
      --select gnat_native=16.1.0 gprbuild=26.0.1

WORKDIR /workspace
COPY . .

# Resolve project dependencies and catch public-library portability failures.
RUN alr --non-interactive build

CMD ["./scripts/test.sh"]
