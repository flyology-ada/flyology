#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CRATE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CROSS_GPRBUILD=${FLYOLOGY_ALLOCATORS_GPRBUILD:-gprbuild}

: "${FLYOLOGY_ALLOCATORS_OBJECT_DIR:=obj/cross}"
: "${FLYOLOGY_ALLOCATORS_LIBRARY_DIR:=lib/cross}"
export FLYOLOGY_ALLOCATORS_OBJECT_DIR
export FLYOLOGY_ALLOCATORS_LIBRARY_DIR

"$CRATE_ROOT/scripts/configure-atomic-store-family.sh"

set -- -p -P "$CRATE_ROOT/flyology_allocators.gpr"
if [ -n "${FLYOLOGY_ALLOCATORS_TARGET:-}" ]; then
   set -- "$@" "--target=$FLYOLOGY_ALLOCATORS_TARGET"
fi
if [ -n "${FLYOLOGY_ALLOCATORS_RTS:-}" ]; then
   set -- "$@" "--RTS=$FLYOLOGY_ALLOCATORS_RTS"
fi

"$CROSS_GPRBUILD" "$@"
