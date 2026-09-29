#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
profile=${1:-development}

case "$profile" in
  development|validation|release) ;;
  *)
    printf '%s\n' "showcase profile must be development, validation, or release" >&2
    exit 2
    ;;
esac

#  Sync showcase-only dependencies and generate the Alire configuration before
#  direct GPRbuild calls. Stop before the pre-build action because each caller
#  prepares the runtime with its own topology and execution default.
cd "$showcase_root"
"$alr" build "--$profile" --stop-after=generation
