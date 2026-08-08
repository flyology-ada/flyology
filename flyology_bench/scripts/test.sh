#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if command -v gprbuild >/dev/null 2>&1; then
  build() {
    gprbuild "$@"
  }
elif command -v alr >/dev/null 2>&1; then
  build() {
    alr -C "$crate_root" exec -- gprbuild "$@"
  }
else
  printf '%s\n' "gprbuild is unavailable; run this script through alr test" >&2
  exit 1
fi

build -q -p -P "$crate_root/tests/flyology_bench_tests.gpr"
"$crate_root/tests/bin/flyology_bench_smoke"
build -q -p -P "$crate_root/examples/flyology_bench_examples.gpr"
"$crate_root/examples/bin/basic"
