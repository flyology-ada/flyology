#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

cd "$project_root"
"$alr" build --stop-after=generation

cd "$project_root/proof"
"$alr" gnatprove \
  -P "$project_root/flyology.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u \
  flyology-capacity_policy.adb \
  flyology-channel_policy.adb \
  flyology-counter_policy.adb \
  flyology-connection_policy.adb \
  flyology-topology_policy.adb \
  flyology-time_math.adb \
  flyology-tls_policy.adb \
  flyology-structured_server_policy.adb \
  flyology-worker_pool_policy.adb \
  flyology-file_open_policy.adb \
  flyology-wait_policy.adb

"$alr" gnatprove \
  -P "$project_root/proof/runtime_policy.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u s-flscpo.adb

printf '%s\n' "Flyology SPARK proof suite passed"
