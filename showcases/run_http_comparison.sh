#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
comparison_root="$project_root/showcases/http-comparison"

if [ "${HTTP_BENCH_SKIP_BUILD:-0}" != 1 ]; then
   "$comparison_root/scripts/build.sh"
fi
"$comparison_root/scripts/run.sh"
