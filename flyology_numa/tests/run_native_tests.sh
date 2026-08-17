#!/bin/sh

set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${ALR:-}" ]
then
   alr_command=$ALR
elif command -v alr >/dev/null 2>&1
then
   alr_command=$(command -v alr)
elif [ -x "${HOME}/alr" ]
then
   alr_command="${HOME}/alr"
elif [ -x "${HOME}/.local/bin/alr" ]
then
   alr_command="${HOME}/.local/bin/alr"
else
   echo "alr was not found; set ALR to its executable path" >&2
   exit 1
fi

cd "$test_directory"
"$alr_command" -n build
"$test_directory/bin/tests"

#  The recorded host descriptions exercise node numbering, processor
#  attachment, distance rows, and control-group restriction on any host,
#  including one that has none of them.
"$alr_command" exec -- gprbuild -p -P fixture_tests.gpr
"$test_directory/bin/flyology_numa-fixture_testing-main" \
  "$test_directory/fixtures"
