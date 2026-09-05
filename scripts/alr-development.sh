#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace="$project_root/tests/development"
alr=${FLYOLOGY_BASE_ALR:-${ALR:-$("$project_root/scripts/find-alr.sh")}}
FLYOLOGY_BASE_ALR=$alr
ALR=$alr
export FLYOLOGY_BASE_ALR ALR

if [ "${1:-}" = exec ]; then
  shift
  if [ "${1:-}" = -- ]; then
    shift
  fi
  exec "$alr" --non-interactive --chdir="$workspace" exec -- \
    "$project_root/scripts/run-development-command.sh" "$@"
fi

if [ "${1:-}" = build ]; then
  "$alr" --non-interactive --chdir="$workspace" "$@"
  exec "$project_root/scripts/check-development-profiles.sh"
fi

exec "$alr" --non-interactive --chdir="$workspace" "$@"
