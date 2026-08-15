#!/bin/sh
set -eu

benchmark_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$benchmark_root/../.." && pwd)
alr=$("$repository_root/scripts/find-alr.sh")

cd "$benchmark_root"
FLYOLOGY_ALLOCATOR_BENCH_PROFILE=release "$alr" build
exec "$benchmark_root/bin/allocator_benchmark" "$@"
