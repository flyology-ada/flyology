ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG RUST_VERSION=1.97.1
ARG TARGETARCH

RUN case "${TARGETARCH}" in \
      arm64) rust_arch=aarch64-unknown-linux-gnu ;; \
      amd64) rust_arch=x86_64-unknown-linux-gnu ;; \
      *) echo "unsupported Docker target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL \
      "https://static.rust-lang.org/rustup/dist/${rust_arch}/rustup-init" \
      -o /workspace/build/rustup-init \
    && chmod +x /workspace/build/rustup-init \
    && /workspace/build/rustup-init \
      --default-toolchain "${RUST_VERSION}" \
      --profile minimal \
      --no-modify-path \
      -y \
    && rm /workspace/build/rustup-init

ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_NET_OFFLINE=true

WORKDIR /workspace

# Fetch the only third-party Rust dependency while the image is being built.
# Every actual spike run below remains offline.
RUN CARGO_NET_OFFLINE=false cargo fetch \
      --manifest-path spikes/flyology_rust/ada_hosts/rust/Cargo.toml \
      --locked

CMD ["./spikes/flyology-rust/linux-aarch64/container-run.sh"]
