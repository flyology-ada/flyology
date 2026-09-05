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
compiler_version=$("$ALIRE" exec -- gcc -dumpfullversion)
case "$compiler_version" in
   13.2.0|14.1.0|14.2.0)
      atomic_store_family=gnat-13-14
      ;;
   15.0.1|15.1.0|15.3.0|16.1.0|16.2.0)
      atomic_store_family=gnat-15-plus
      ;;
   *)
      printf '%s\n' "unsupported standalone allocator compiler version: $compiler_version" >&2
      exit 1
      ;;
esac

"$ALIRE" exec -- gprbuild -P tests/allocator_tests.gpr -p
"$CRATE_ROOT/tests/bin/allocator_smoke"
"$CRATE_ROOT/tests/bin/flyology_allocators-atomic_publication_probe"
"$CRATE_ROOT/scripts/check-atomic-store-c-boundary.sh" \
   "$CRATE_ROOT/lib/libflyology_allocators.a" "$atomic_store_family"

if nm -g "$CRATE_ROOT/lib/libflyology_allocators.a" |
  awk '{ print $NF }' |
  grep -E '(^_?flyology__|^__flyology_)' >/dev/null 2>&1
then
   echo "standalone archive references Flyology symbols" >&2
   exit 1
fi
