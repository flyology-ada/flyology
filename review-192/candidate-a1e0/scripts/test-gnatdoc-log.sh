#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-gnatdoc-log.XXXXXX")

cleanup () {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' 'flyology.ads:1:1: warning: example' >"$test_root/valid.log"
"$project_root/scripts/check-gnatdoc-log.sh" "$test_root/valid.log"

printf '%s\n' 'flyology.ads:1:1: internal error:' >"$test_root/internal.log"
if "$project_root/scripts/check-gnatdoc-log.sh" "$test_root/internal.log" \
  >"$test_root/internal-output.log" 2>&1
then
  printf '%s\n' "GNATdoc internal error was accepted" >&2
  exit 1
fi

printf '%s\n' \
  'raised LANGKIT_SUPPORT.ERRORS.PROPERTY_ERROR : Infinite recursion detected' \
  >"$test_root/property.log"
if "$project_root/scripts/check-gnatdoc-log.sh" "$test_root/property.log" \
  >"$test_root/property-output.log" 2>&1
then
  printf '%s\n' "GNATdoc property error was accepted" >&2
  exit 1
fi
