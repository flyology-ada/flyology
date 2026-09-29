#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: $0 GNATDOC_LOG" >&2
  exit 2
fi

log=$1
if grep -E -q 'internal error:|LANGKIT_SUPPORT\.ERRORS\.' "$log"; then
  printf '%s\n' "GNATdoc reported an internal analysis error" >&2
  grep -E 'internal error:|LANGKIT_SUPPORT\.ERRORS\.' "$log" >&2
  exit 1
fi
