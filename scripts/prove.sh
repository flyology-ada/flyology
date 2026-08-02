#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

cd "$project_root/proof"
"$alr" gnatprove \
  -P "$project_root/gnatevl.gpr" \
  --mode=all \
  --level=1 \
  --output=oneline \
  --output-header \
  --report=all \
  gnatevl-time_math.adb

"$alr" gnatprove \
  -P "$project_root/proof/runtime_policy.gpr" \
  --mode=all \
  --level=1 \
  --output=oneline \
  --output-header \
  --report=all \
  s-gnscpo.adb
