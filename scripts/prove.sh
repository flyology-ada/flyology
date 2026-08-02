#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${ALR:-"$HOME/alr"}

cd "$project_root"
"$alr" gnatprove \
  -P gnatevl.gpr \
  --mode=all \
  --level=1 \
  --output-header \
  --report=all \
  gnatevl-time_math.adb

"$alr" gnatprove \
  -P proof/runtime_policy.gpr \
  --mode=all \
  --level=1 \
  --output-header \
  --report=all \
  s-gnscpo.adb
