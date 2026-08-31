#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../../.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

cd "$project_root"
"$alr" build --stop-after=generation >/dev/null
FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null

cargo fmt --manifest-path "$spike_root/rust/Cargo.toml" -- --check
cargo clippy --manifest-path "$spike_root/rust/Cargo.toml" --all-targets --locked --offline -- -D warnings
cargo test --manifest-path "$spike_root/rust/Cargo.toml" --locked --offline
cargo build --manifest-path "$spike_root/rust/Cargo.toml" --release --locked --offline

case $(uname -s) in
  Darwin)
    rust_library="$spike_root/rust/target/release/libflyology_rust_tokio_io_spike.dylib"
    ;;
  Linux)
    rust_library="$spike_root/rust/target/release/libflyology_rust_tokio_io_spike.so"
    ;;
  *)
    printf '%s\n' "unsupported spike host: $(uname -s)" >&2
    exit 1
    ;;
esac

rust_rpath="-Wl,-rpath,$spike_root/rust/target/release"
RUST_SPIKE_LIBRARY=$rust_library RUST_SPIKE_RPATH=$rust_rpath \
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" -f -P "$spike_root/tokio_io_spike.gpr"

stress_runs=${FLYOLOGY_RUST_STRESS_RUNS:-3}
case $stress_runs in
  ''|*[!0-9]*|0)
    printf '%s\n' "FLYOLOGY_RUST_STRESS_RUNS must be a positive integer" >&2
    exit 1
    ;;
esac

run=1
while [ "$run" -le "$stress_runs" ]; do
  "$project_root/scripts/run-with-timeout.sh" 20 "$spike_root/build/bin/tokio_io_spike"
  run=$((run + 1))
done
