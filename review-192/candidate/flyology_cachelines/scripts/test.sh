#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$crate_root/../scripts/find-alr.sh")
test_log="$crate_root/tests/alire/alr_test_local.log"

cd "$crate_root/tests"
rm -f -- "$test_log"
"$alr" -n test
if ! grep -F 'all flyology_cachelines tests passed' "$test_log" >/dev/null; then
  printf '%s\n' "flyology_cachelines test actions did not run" >&2
  exit 1
fi
