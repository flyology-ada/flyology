#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$crate_root/../scripts/find-alr.sh")

cd "$crate_root/tests"
"$alr" -n test
