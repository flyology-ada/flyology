#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' \
    "usage: check-controlled-subpool-selection.sh COMPILER_RELEASE COMPILER_FAMILY" >&2
  exit 2
fi

compiler_release=$1
compiler_family=$2
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_file="$project_root/config/flyology_atomic_store_config.gpr"
affected_body="$project_root/tests/controlled_subpools/affected/memory_regions_controlled_allocations.adb"
corrected_body="$project_root/tests/controlled_subpools/corrected/memory_regions_controlled_allocations.adb"

case "$compiler_family" in
  affected)
    expected=/tests/controlled_subpools/affected
    unexpected=/tests/controlled_subpools/corrected
    ;;
  corrected)
    expected=/tests/controlled_subpools/corrected
    unexpected=/tests/controlled_subpools/affected
    ;;
  *)
    printf '%s\n' "unknown controlled-subpool compiler family: $compiler_family" >&2
    exit 2
    ;;
esac

if ! grep -F "Compiler_Release := \"$compiler_release\";" "$config_file" >/dev/null; then
  printf '%s\n' "controlled-subpool selection used the wrong compiler release" >&2
  exit 1
fi

inspection=$(gprinspect \
  -P "$project_root/tests/runtime_smoke.gpr" \
  --attributes --display=textual --views=runtime_smoke)
if ! printf '%s\n' "$inspection" | grep -F "$expected" >/dev/null; then
  printf '%s\n' "controlled-subpool selection omitted $expected" >&2
  exit 1
fi
if printf '%s\n' "$inspection" | grep -F "$unexpected" >/dev/null; then
  printf '%s\n' "controlled-subpool selection included $unexpected" >&2
  exit 1
fi

if ! grep -F 'new (Region) Tracked;' "$affected_body" >/dev/null \
  || ! grep -F 'Object.Value := Value;' "$affected_body" >/dev/null \
  || ! grep -F 'new (Region) Byte_Array (First .. Last);' "$affected_body" >/dev/null \
  || ! grep -F 'Object.all := (others => Value);' "$affected_body" >/dev/null \
  || grep -F "Tracked'(Ada.Finalization.Controlled with Value)" "$affected_body" >/dev/null \
  || grep -F "Byte_Array'(First .. Last => Value)" "$affected_body" >/dev/null
then
  printf '%s\n' "affected controlled-subpool implementation lost its compatibility form" >&2
  exit 1
fi

if ! grep -F "new (Region) Tracked'(Ada.Finalization.Controlled with Value)" \
  "$corrected_body" >/dev/null \
  || ! grep -F "new (Region) Byte_Array'(First .. Last => Value)" \
  "$corrected_body" >/dev/null \
  || grep -F 'Object.Value := Value;' "$corrected_body" >/dev/null \
  || grep -F 'new (Region) Byte_Array (First .. Last);' "$corrected_body" >/dev/null
then
  printf '%s\n' "corrected controlled-subpool implementation lost its aggregate allocator" >&2
  exit 1
fi

printf '%s\n' "controlled-subpool compiler selection: PASS"
