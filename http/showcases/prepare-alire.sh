#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
http_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
profile=${1:-development}

case "$profile" in
  development|validation|release) ;;
  *)
    printf '%s\n' "showcase profile must be development, validation, or release" >&2
    exit 2
    ;;
esac

cd "$showcase_root"
"$alr" build "--$profile" --stop-after=generation
