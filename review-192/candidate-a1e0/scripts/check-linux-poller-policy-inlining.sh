#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf 'usage: %s S-FLYPOL-OBJECT\n' "$0" >&2
  exit 2
fi

object=$1
if [ ! -f "$object" ]; then
  printf '%s\n' "Linux poller object is missing: $object" >&2
  exit 1
fi
if ! undefined_symbols=$(nm -u "$object"); then
  printf '%s\n' "failed to inspect Linux poller object: $object" >&2
  exit 1
fi

policy_calls=$(printf '%s\n' "$undefined_symbols" | grep -E \
  '(^|[[:space:]])_?system__flyology__poller_policy__(after_batch|after_drain|after_wake|classify_cancel|plan_batch|remaining_budget)$' \
  || true)
if [ -n "$policy_calls" ]; then
  printf '%s\n' \
    "optimized Linux poller retains calls to its batch-policy helpers" >&2
  printf '%s\n' "$policy_calls" >&2
  exit 1
fi
