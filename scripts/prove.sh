#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${ALR:-"$HOME/alr"}

cd "$project_root"
"$alr" gnatprove \
  -P gnatevl.gpr \
  --mode=all \
  --level=1 \
  --report=all \
  gnatevl-time_math.adb

"$alr" gnatprove \
  -P proof/runtime_policy.gpr \
  --mode=all \
  --level=1 \
  --report=all \
  s-gnscpo.adb
