#!/bin/sh
set -u

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: expect-blocked.sh SECONDS COMMAND [ARG ...]" >&2
  exit 2
fi

limit=$1
shift

output=$(mktemp "${TMPDIR:-/tmp}/flyology-expect-blocked.XXXXXX") || exit 1
marker=FLYOLOGY_EXPECT_BLOCKED_REACHED

"$@" >"$output" 2>&1 &
child=$!

cleanup () {
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  rm -f -- "$output"
}
trap cleanup EXIT HUP INT TERM

attempt=0
while ! grep -F "$marker" "$output" >/dev/null 2>&1; do
  if ! kill -0 "$child" 2>/dev/null; then
    wait "$child"
    status=$?
    cat "$output" >&2
    printf '%s\n' \
      "expected blocked-point handshake, but command exited $status: $*" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 200 ]; then
    cat "$output" >&2
    printf '%s\n' "blocked-point handshake was not reached: $*" >&2
    exit 1
  fi
  sleep 0.01
done

sleep "$limit"
if ! kill -0 "$child" 2>/dev/null; then
  wait "$child"
  status=$?
  cat "$output" >&2
  printf '%s\n' \
    "expected command to remain blocked, but it exited $status: $*" >&2
  exit 1
fi

kill -TERM "$child" 2>/dev/null || true
wait "$child" 2>/dev/null || true
rm -f -- "$output"
trap - EXIT HUP INT TERM
