#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' "usage: check-subprocess-shutdown.sh SHUTDOWN_TEST FIXTURE" >&2
  exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_root/build/tests"
pid_file=$(mktemp "$project_root/build/tests/subprocess-shutdown.XXXXXX")
child_pid=

cleanup () {
  if [ -n "$child_pid" ]; then
    python3 - "$child_pid" <<'PY'
import os
import signal
import sys

try:
    os.killpg(int(sys.argv[1]), signal.SIGKILL)
except ProcessLookupError:
    pass
PY
  fi
  rm -f -- "$pid_file"
}
trap cleanup EXIT HUP INT TERM

if ! "$project_root/scripts/run-with-timeout.sh" 3 "$1" "$2" >"$pid_file"; then
  child_pid=$(awk 'NR == 1 { print $1 }' "$pid_file")
  printf '%s\n' "Ada shutdown waited for an abandoned subprocess reaper" >&2
  exit 1
fi

child_pid=$(awk 'NR == 1 { print $1 }' "$pid_file")
case "$child_pid" in
  ''|*[!0-9]*)
    printf '%s\n' "shutdown test did not report a child PID" >&2
    exit 1
    ;;
esac
if [ "$child_pid" -le 0 ]; then
  printf '%s\n' "shutdown test reported an invalid child PID" >&2
  exit 1
fi
if ! kill -0 "$child_pid" 2>/dev/null; then
  printf '%s\n' "shutdown test child did not survive failed finalization kill" >&2
  exit 1
fi
