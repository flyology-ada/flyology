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
  --output=oneline \
  --output-header \
  --report=all \
  flyology-time_math.adb

"$alr" gnatprove \
  -P "$project_root/proof/runtime_policy.gpr" \
  --mode=all \
  --level=1 \
  --output=oneline \
  --output-header \
  --report=all \
  s-flscpo.adb
