#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
rts_root=$project_root/build/alire-rts
ada_object_dir=$spike_root/build/ada-obj
rust_target_dir=$spike_root/build/rust-target
result_dir=$spike_root/build/results
repetitions=${FLYOLOGY_RUST_INGRESS_REPETITIONS:-10}

mkdir -p "$result_dir"

cd "$project_root"
"$alr" build

allocator_root=$(
  "$alr" exec -- sh -c 'printf "%s\n" "$FLYOLOGY_ALLOCATORS_ALIRE_PREFIX"'
)
if [ -z "$allocator_root" ] || [ ! -d "$allocator_root/lib" ]; then
  printf '%s\n' "cannot locate the resolved flyology_allocators dependency" >&2
  exit 1
fi

"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$rts_root" \
  -c -p \
  -P "$spike_root/ada/rust_ingress_probe.gpr" \
  "$spike_root/ada/rust_ingress_probe.adb" \
  "$spike_root/ada/lifecycle_failure.adb"

(
  cd "$ada_object_dir"
  "$alr" exec -- gnatbind \
    --RTS="$rts_root" \
    -n -Es \
    -aO"$project_root/lib" \
    -aO"$allocator_root/lib" \
    -o b__rust_ingress_probe.adb \
    rust_ingress_probe.ali
  "$alr" exec -- gcc \
    --RTS="$rts_root" \
    -c -gnat2022 -I. \
    b__rust_ingress_probe.adb

  "$alr" exec -- gnatbind \
    --RTS="$rts_root" \
    -n -Es \
    -o b__lifecycle_failure.adb \
    lifecycle_failure.ali
  "$alr" exec -- gcc \
    --RTS="$rts_root" \
    -c -gnat2022 -I. \
    b__lifecycle_failure.adb
)

cargo fmt --manifest-path "$spike_root/rust/Cargo.toml" --check
cargo test \
  --manifest-path "$spike_root/rust/Cargo.toml" \
  --target-dir "$rust_target_dir" \
  --locked --offline --lib
cargo clippy \
  --manifest-path "$spike_root/rust/Cargo.toml" \
  --target-dir "$rust_target_dir" \
  --locked --offline --lib --bins -- -D warnings

link_bin() {
  bin=$1
  binder=$2
  ada_object=$3

  set -- \
    -C "link-arg=$binder" \
    -C "link-arg=$ada_object" \
    -C "link-arg=$project_root/lib/libFlyology.a" \
    -C "link-arg=$allocator_root/lib/libflyology_allocators.a" \
    -C "link-arg=$rts_root/adalib/libgnarl.a" \
    -C "link-arg=$rts_root/adalib/libgnat.a"

  libgcc=$("$alr" exec -- gcc -print-libgcc-file-name)
  toolchain_library_dir=$(dirname -- "$libgcc")

  case $(uname -s) in
    Darwin)
      deployment_target=$(sw_vers -productVersion | awk -F. '{ print $1 "." $2 }')
      MACOSX_DEPLOYMENT_TARGET=$deployment_target
      export MACOSX_DEPLOYMENT_TARGET
      for support_library in libemutls_w.a libheapt_w.a; do
        support_path=$toolchain_library_dir/$support_library
        if [ ! -f "$support_path" ]; then
          printf '%s\n' "missing GNAT support archive: $support_path" >&2
          exit 1
        fi
        set -- "$@" -C "link-arg=$support_path"
      done
      ;;
    Linux)
      set -- "$@" -C link-arg=-ldl -C link-arg=-pthread
      ;;
    *)
      printf '%s\n' "unsupported spike host: $(uname -s)" >&2
      exit 1
      ;;
  esac

  set -- "$@" -C "link-arg=$libgcc"
  cargo rustc \
    --manifest-path "$spike_root/rust/Cargo.toml" \
    --target-dir "$rust_target_dir" \
    --locked --offline --bin "$bin" -- "$@"
}

link_bin \
  flyology-rust-ingress-spike \
  "$ada_object_dir/b__rust_ingress_probe.o" \
  "$ada_object_dir/rust_ingress_probe.o"
link_bin \
  flyology-binder-failure-probe \
  "$ada_object_dir/b__lifecycle_failure.o" \
  "$ada_object_dir/lifecycle_failure.o"

ingress_executable=$rust_target_dir/debug/flyology-rust-ingress-spike
failure_executable=$rust_target_dir/debug/flyology-binder-failure-probe

case $(uname -s) in
  Darwin)
    if otool -L "$ingress_executable" | grep -E 'libgnat|libgnarl' >/dev/null; then
      printf '%s\n' "Rust executable unexpectedly depends on a shared GNAT runtime" >&2
      exit 1
    fi
    ;;
  Linux)
    if ldd "$ingress_executable" | grep -E 'libgnat|libgnarl' >/dev/null; then
      printf '%s\n' "Rust executable unexpectedly depends on a shared GNAT runtime" >&2
      exit 1
    fi
    ;;
esac

iteration=1
while [ "$iteration" -le "$repetitions" ]; do
  FLYOLOGY_LOOP_POOL_SIZE=2 \
    "$project_root/scripts/run-with-timeout.sh" 30 "$ingress_executable"
  iteration=$((iteration + 1))
done

"$project_root/scripts/run-with-timeout.sh" 10 "$failure_executable" \
  >"$result_dir/binder-success.txt" 2>&1
grep -q '^BINDER_INIT_RETURNED$' "$result_dir/binder-success.txt"
grep -q '^BINDER_FINAL_RETURNED$' "$result_dir/binder-success.txt"

ulimit -c 0
set +e
FLYOLOGY_SPIKE_FAIL_INITIALIZE=1 \
  "$project_root/scripts/run-with-timeout.sh" 10 "$failure_executable" \
  >"$result_dir/binder-init-failure.txt" 2>&1
init_status=$?
FLYOLOGY_SPIKE_FAIL_FINALIZE=1 \
  "$project_root/scripts/run-with-timeout.sh" 10 "$failure_executable" \
  >"$result_dir/binder-final-failure.txt" 2>&1
final_status=$?
set -e

if [ "$init_status" -eq 0 ] || grep -q '^BINDER_INIT_RETURNED$' "$result_dir/binder-init-failure.txt"; then
  printf '%s\n' "binder initialization failure unexpectedly returned to Rust" >&2
  exit 1
fi
if [ "$final_status" -eq 0 ]; then
  printf '%s\n' "binder finalization failure unexpectedly returned success" >&2
  exit 1
fi
grep -q '^BINDER_INIT_RETURNED$' "$result_dir/binder-final-failure.txt"
if grep -q '^BINDER_FINAL_RETURNED$' "$result_dir/binder-final-failure.txt"; then
  printf '%s\n' "binder finalization failure unexpectedly returned to Rust" >&2
  exit 1
fi

printf '%s\n' "PASS binder init/final failure probes were process-fatal and did not return"
printf '%s\n' "PASS $repetitions process-level close/admission race repetitions"
