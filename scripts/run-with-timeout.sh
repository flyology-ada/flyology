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
