#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: check-subprocess-c-boundary.sh ARCHIVE" >&2
  exit 2
fi

archive=$1
symbols=$(nm -g "$archive" | awk '
  /_?flyology_subprocess_/ && $(NF - 1) != "U" {
    name=$NF
    sub(/^_/, "", name)
    print name
  }
' | sort -u)

for symbol in $symbols; do
  case "$symbol" in
    flyology_subprocess_pipe|\
    flyology_subprocess_duplicate_above|\
    flyology_subprocess_set_nonblocking|\
    flyology_subprocess_set_no_sigpipe|\
    flyology_subprocess_spawn|\
    flyology_subprocess_observe_exit|\
    flyology_subprocess_write_no_sigpipe|\
    flyology_subprocess_signal_interrupt|\
    flyology_subprocess_signal_terminate|\
    flyology_subprocess_signal_kill|\
    flyology_subprocess_errno_interrupted|\
    flyology_subprocess_errno_would_block|\
    flyology_subprocess_errno_no_such_process|\
    flyology_subprocess_errno_permission|\
    flyology_subprocess_status_exited|\
    flyology_subprocess_status_exit_code|\
    flyology_subprocess_status_signaled|\
    flyology_subprocess_status_signal|\
    flyology_subprocess_status_core_dumped)
      ;;
    *)
      printf '%s\n' "unexpected subprocess C symbol: $symbol" >&2
      exit 1
      ;;
  esac
done

for required in \
  flyology_subprocess_pipe \
  flyology_subprocess_duplicate_above \
  flyology_subprocess_set_nonblocking \
  flyology_subprocess_set_no_sigpipe \
  flyology_subprocess_spawn \
  flyology_subprocess_observe_exit \
  flyology_subprocess_write_no_sigpipe \
  flyology_subprocess_signal_interrupt \
  flyology_subprocess_signal_terminate \
  flyology_subprocess_signal_kill \
  flyology_subprocess_errno_interrupted \
  flyology_subprocess_errno_would_block \
  flyology_subprocess_errno_no_such_process \
  flyology_subprocess_errno_permission \
  flyology_subprocess_status_exited \
  flyology_subprocess_status_exit_code \
  flyology_subprocess_status_signaled \
  flyology_subprocess_status_signal \
  flyology_subprocess_status_core_dumped
do
  if ! printf '%s\n' "$symbols" | grep -Fx "$required" >/dev/null; then
    printf '%s\n' "missing subprocess C symbol: $required" >&2
    exit 1
  fi
done
