#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$comparison_root/scripts/test_kubernetes_overlay.py"
HTTP_BENCH_VERIFY_ONLY=1 HTTP_BENCH_TRIALS=1 HTTP_BENCH_COOLDOWN=0 \
   "$comparison_root/scripts/run.sh"
HTTP_HYBRID_VERIFY_ONLY=1 HTTP_HYBRID_TRIALS=1 HTTP_HYBRID_COOLDOWN=0 \
HTTP_HYBRID_TARGETS_US=500 HTTP_HYBRID_WORKERS=1 \
   "$comparison_root/scripts/run_hybrid.sh"
