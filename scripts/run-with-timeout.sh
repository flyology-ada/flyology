#!/bin/sh
set -u

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: run-with-timeout.sh SECONDS COMMAND [ARG ...]" >&2
  exit 2
fi

limit=$1
shift

"$@" &
child=$!

(
  sleep "$limit"
  printf '%s\n' \
    "timeout: $limit seconds elapsed for pid $child: $*" >&2
  if [ "$(uname -s)" = Darwin ] && command -v sample >/dev/null 2>&1; then
    #  Preserve the blocked thread stacks in hosted macOS logs before the
    #  watchdog terminates the process. This runs only on a failed test.
    sample "$child" 1 1 >&2 || true
  fi
  if kill -TERM "$child" 2>/dev/null; then
    sleep 1
    kill -KILL "$child" 2>/dev/null || true
  fi
) &
watchdog=$!

trap 'kill -TERM "$child" "$watchdog" 2>/dev/null || true' INT TERM HUP

wait "$child"
status=$?
kill -TERM "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
exit "$status"
