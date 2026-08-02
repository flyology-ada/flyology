#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
expected_gnat=${GNATEVL_EXPECTED_GNAT:-}

cd "$project_root"
actual_gnat=$("$project_root/scripts/gnat-native-release.sh" "$alr")
if [ -n "$expected_gnat" ] && [ "$actual_gnat" != "$expected_gnat" ]; then
  printf '%s\n' \
    "expected GNAT $expected_gnat, but Alire selected $actual_gnat" >&2
  exit 1
fi

"$alr" --non-interactive build --release
ALR="$alr" "$project_root/scripts/test-external-consumer.sh"
