#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${ALR:-"$HOME/alr"}
normal_context="$project_root/build/rts/obj/s-gnacon.o"
asan_context="$project_root/build/rts/obj/s-gnacon.o"
negative_log="$project_root/build/sanitizer-negative.log"

cd "$project_root"

"$alr" build

# A normal prepared runtime must neither reference the sanitizer interface nor
# retain sanitizer-only TLS. This is stronger than merely leaving libasan out
# of the final link: it verifies the static configuration erased the hot path.
GNATEVL_SANITIZER=none "$project_root/scripts/prepare-rts.sh" >/dev/null
if nm "$normal_context" | grep -E 'sanitizer|gnaasa|switching_from' >/dev/null
then
  printf '%s\n' "normal context switch retains ASan instrumentation" >&2
  exit 1
fi

GNATEVL_SANITIZER=address "$project_root/scripts/prepare-rts.sh" >/dev/null
if ! nm "$asan_context" | grep 'gnatevl__asan__start_switch' >/dev/null
then
  printf '%s\n' "ASan context switch lacks fiber annotations" >&2
  exit 1
fi

"$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -f -P tests/sanitizer_smoke.gpr

# Fake stacks are deliberately unsupported across pthread migration. The
# runtime still reports each real fiber stack exactly to ASan.
asan_options=detect_stack_use_after_return=0:detect_leaks=0:halt_on_error=1:use_sigaltstack=0
ASAN_OPTIONS=$asan_options "$project_root/tests/bin/sanitizer_fiber_smoke"
ASAN_OPTIONS=$asan_options "$project_root/tests/bin/lifecycle_smoke"

set +e
ASAN_OPTIONS=$asan_options \
  "$project_root/tests/bin/sanitizer_stack_violation" \
  >"$negative_log" 2>&1
negative_status=$?
set -e
if [ "$negative_status" -eq 0 ]; then
  printf '%s\n' "ASan did not reject the intentional fiber-stack write" >&2
  exit 1
fi
if ! grep 'stack-buffer-overflow' "$negative_log" >/dev/null; then
  printf '%s\n' "ASan failure lacked the expected stack-buffer-overflow report" >&2
  sed -n '1,120p' "$negative_log" >&2
  exit 1
fi

printf '%s\n' "GNATEVL ASan fiber-switch tests passed"
