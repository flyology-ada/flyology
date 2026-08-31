#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../../.." && pwd)
build_root="$project_root/build/spikes/direct_futures"
rust_target="$build_root/cargo"
rts_root="$build_root/rts"

mkdir -p "$build_root"
GPR_PROJECT_PATH="$project_root/flyology_allocators"
export GPR_PROJECT_PATH
CARGO_TARGET_DIR="$rust_target" cargo build \
  --manifest-path "$spike_root/rust/Cargo.toml" --offline --release

cd "$project_root"
alr exec -- gprbuild -p -P "$project_root/flyology.gpr"
FLYOLOGY_RTS_DIR="$rts_root" ./scripts/prepare-rts.sh

FLYOLOGY_RUST_FUTURE_LIBRARY="$rust_target/release/libflyology_direct_future_spike.a"
export FLYOLOGY_RUST_FUTURE_LIBRARY
alr exec -- gprbuild \
  --RTS="$rts_root" -f -p -P "$spike_root/direct_futures_spike.gpr"

"$build_root/bin/direct_futures_spike"

probe_panic () {
  lane=$1
  program=$2
  panic_log="$build_root/$lane-panic.log"
  set +e
  "$program" >"$panic_log" 2>&1
  panic_status=$?
  set -e
  if [ "$panic_status" -eq 0 ]; then
    printf '%s\n' "$lane Rust panic containment: PASS"
  elif grep -F "failed to initiate panic" "$panic_log" >/dev/null; then
    printf '%s\n' "$lane Rust panic containment: UNSUPPORTED (isolated child status $panic_status)"
  else
    printf '%s\n' "unexpected $lane panic child failure; see $panic_log" >&2
    exit 1
  fi
}

probe_panic native "$build_root/bin/direct_futures_native_panic_child"
probe_panic lightweight "$build_root/bin/direct_futures_panic_child"
