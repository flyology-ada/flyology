#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
test_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-sanitizer.XXXXXX")
normal_rts="$test_root/rts-normal"
asan_rts="$test_root/rts-address"
normal_context="$normal_rts/obj/s-flycon.o"
asan_context="$asan_rts/obj/s-flycon.o"
negative_log="$test_root/negative.log"

cleanup () {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

cd "$project_root"

"$alr" build

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot"
      return
    fi
    "$alr" exec -- gprbuild "$@"
    return
  fi
  "$alr" exec -- gprbuild "$@"
}

# A normal prepared runtime must neither reference the sanitizer interface nor
# retain sanitizer-only TLS. This is stronger than merely leaving libasan out
# of the final link: it verifies the static configuration erased the hot path.
FLYOLOGY_RTS_DIR="$normal_rts" \
FLYOLOGY_SANITIZER=none \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
if nm "$normal_context" | grep -E 'sanitizer|gnaasa|switching_from' >/dev/null
then
  printf '%s\n' "normal context switch retains ASan instrumentation" >&2
  exit 1
fi

FLYOLOGY_RTS_DIR="$asan_rts" \
FLYOLOGY_SANITIZER=address \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
if ! nm "$asan_context" | grep 'flyology__asan__start_switch' >/dev/null
then
  printf '%s\n' "ASan context switch lacks fiber annotations" >&2
  exit 1
fi

run_gprbuild \
  --RTS="$asan_rts" \
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

printf '%s\n' "Flyology ASan fiber-switch tests passed"
