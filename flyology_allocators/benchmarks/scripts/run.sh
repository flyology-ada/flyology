#!/bin/sh
set -eu

benchmark_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$benchmark_root/../.." && pwd)
allocator_root="$repository_root/flyology_allocators"
alr=$("$repository_root/scripts/find-alr.sh")

cd "$benchmark_root"
"$alr" exec -- "$allocator_root/scripts/configure-atomic-store-family.sh"
FLYOLOGY_ALLOCATOR_BENCH_PROFILE=release \
   "$alr" exec -- gprbuild \
   -f \
   -P "$benchmark_root/flyology_allocator_benchmarks.gpr" \
   -XFLYOLOGY_ALLOCATOR_BENCH_PROFILE=release \
   -cargs:Ada -O3 -g -gnat2022 -gnatwa -gnatVa
exec "$benchmark_root/bin/allocator_benchmark" "$@"
