#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
rounds=${1:-200000}

case "$rounds" in
  ''|*[!0-9]*|0)
    printf '%s\n' "rounds must be a positive integer" >&2
    exit 2
    ;;
esac

"$project_root/showcases/prepare-alire.sh" release >/dev/null
FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=16 \
  "$project_root/showcases/prepare-rts.sh" >/dev/null
(
  cd "$project_root"
  FLYOLOGY_SOCKET_TEST_HOOKS=true \
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -q -f -p -P showcases/socket_preparation_benchmark.gpr
)
"$project_root/showcases/bin/socket_preparation_benchmark" "$rounds"
