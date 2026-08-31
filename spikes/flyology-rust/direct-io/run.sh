#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../../.." && pwd)
build_root="$project_root/build/spikes/direct_io"
rust_target="$build_root/cargo"
rts_root="$build_root/rts"
repeats=${FLYOLOGY_RUST_INTEREST_REPEATS:-10}

mkdir -p "$build_root"
GPR_PROJECT_PATH="$project_root/flyology_allocators"
export GPR_PROJECT_PATH
CARGO_TARGET_DIR="$rust_target" cargo fmt \
  --manifest-path "$spike_root/rust/Cargo.toml" --check
CARGO_TARGET_DIR="$rust_target" cargo test \
  --manifest-path "$spike_root/rust/Cargo.toml" --offline
CARGO_TARGET_DIR="$rust_target" cargo clippy \
  --manifest-path "$spike_root/rust/Cargo.toml" --offline --all-targets -- -D warnings
CARGO_TARGET_DIR="$rust_target" cargo build \
  --manifest-path "$spike_root/rust/Cargo.toml" --offline --release

cd "$project_root"
alr build --stop-after=generation
alr exec -- gprbuild -p -P "$project_root/flyology.gpr"
FLYOLOGY_RTS_DIR="$rts_root" ./scripts/prepare-rts.sh

FLYOLOGY_RUST_INTEREST_LIBRARY="$rust_target/release/libflyology_direct_io_future_spike.a"
export FLYOLOGY_RUST_INTEREST_LIBRARY
alr exec -- gprbuild \
  --RTS="$rts_root" -f -p -P "$spike_root/direct_io_futures_spike.gpr"

iteration=1
while [ "$iteration" -le "$repeats" ]; do
  "$build_root/bin/direct_io_futures_spike"
  iteration=$((iteration + 1))
done
