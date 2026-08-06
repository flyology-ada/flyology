#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$comparison_root/../.." && pwd)
showcase_root="$project_root/showcases"
alr=$("$project_root/scripts/find-alr.sh")
toolchain_gnat=${HTTP_BENCH_GNAT_VERSION:-15.3.1}
toolchain_gprbuild=${HTTP_BENCH_GPRBUILD_VERSION:-25.0.1}
loops=${HTTP_BENCH_LOOPS:-}
rust_root="$comparison_root/servers/rust"
rust_version=${HTTP_BENCH_RUST_VERSION:-1.97.1}

if [ "$(uname -s)" != Linux ] &&
   [ "${HTTP_BENCH_ALLOW_UNSUPPORTED_HOST:-0}" != 1 ]; then
   printf '%s\n' \
     "the comparative build is supported on Linux; use run-linux-docker.sh on other hosts" >&2
   exit 2
fi

if [ -z "$loops" ]; then
   loops=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s' 1)
fi
if [ "$loops" -gt 128 ]; then
   loops=128
fi

select_toolchain () {
   workspace=$1
   (
      cd "$workspace"
      "$alr" --non-interactive toolchain --select --local \
        "gnat_native=$toolchain_gnat" "gprbuild=$toolchain_gprbuild"
   )
}

select_toolchain "$project_root"
select_toolchain "$showcase_root"

cd "$project_root"
"$alr" --non-interactive build --release
"$showcase_root/prepare-alire.sh" release
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE="$loops" \
   "$project_root/scripts/prepare-rts.sh"

cd "$showcase_root"
FLYOLOGY_SHOWCASE_PROFILE=release "$alr" exec -- env -u GPR_CONFIG gprbuild \
   --RTS="$project_root/build/rts" \
   -f -P showcases.gpr \
   http_plain_benchmark_server.adb http_application_benchmark_server.adb \
   http_benchmark_runtime_probe.adb http_cpu_calibrator.adb \
   http_hybrid_benchmark_server.adb

actual_loops=$("$showcase_root/bin/http_benchmark_runtime_probe" | tr -d '[:space:]')
case "$actual_loops" in
   ''|*[!0-9]*)
      printf '%s\n' \
        "benchmark runtime probe returned an invalid loop count: $actual_loops" >&2
      exit 1
      ;;
esac
if [ "$actual_loops" -ne "$loops" ]; then
   printf '%s\n' \
     "benchmark linked $actual_loops Flyology loops, expected $loops" >&2
   exit 1
fi

for adapter in aws_plain ews_plain servletada_aws_app servletada_ews_app; do
   adapter_root="$comparison_root/servers/$adapter"
   select_toolchain "$adapter_root"
   (
      cd "$adapter_root"
      "$alr" --non-interactive build --release
   )
done

if [ "${HTTP_BENCH_SKIP_RUST_BUILD:-0}" = 1 ]; then
   for binary in hyper_plain axum_app actix_app; do
      test -x "$rust_root/target/release/$binary"
   done
else
   command -v cargo >/dev/null 2>&1 || {
      printf '%s\n' "cargo is required to build the Rust comparison fixtures" >&2
      exit 1
   }
   actual_rust=$(rustc --version | awk '{print $2}')
   if [ "$actual_rust" != "$rust_version" ]; then
      printf '%s\n' \
        "Rust $rust_version is required, found $actual_rust" >&2
      exit 1
   fi
   (
      cd "$rust_root"
      cargo build --locked --release --bins
   )
fi

printf '%s\n' \
  "built HTTP comparison with GNAT $toolchain_gnat, gprbuild $toolchain_gprbuild, Rust $rust_version, and verified $actual_loops Flyology loops"
