#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HTTP_BENCH_VERIFY_ONLY=1 HTTP_BENCH_TRIALS=1 HTTP_BENCH_COOLDOWN=0 \
   "$comparison_root/scripts/run.sh"
