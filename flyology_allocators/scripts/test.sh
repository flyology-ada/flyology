#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CRATE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ -n "${ALR:-}" ]; then
   ALIRE=$ALR
elif command -v alr >/dev/null 2>&1; then
   ALIRE=$(command -v alr)
elif [ -x "$HOME/alr" ]; then
   ALIRE=$HOME/alr
else
   echo "Alire 2.1 or newer is required" >&2
   exit 1
fi

cd "$CRATE_ROOT"
"$ALIRE" build
"$ALIRE" exec -- gprbuild -P tests/allocator_tests.gpr -p
"$CRATE_ROOT/tests/bin/allocator_smoke"
"$CRATE_ROOT/scripts/check-atomic-store-c-boundary.sh" \
   "$CRATE_ROOT/lib/libflyology_allocators.a"

if nm -g "$CRATE_ROOT/lib/libflyology_allocators.a" |
  awk '{ print $NF }' |
  grep -E '(^_?flyology__|^__flyology_)' >/dev/null 2>&1
then
   echo "standalone archive references Flyology symbols" >&2
   exit 1
fi
