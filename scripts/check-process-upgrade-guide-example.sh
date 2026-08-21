#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
mkdir -p "$project_root/build"
mini_root=$(mktemp -d "$project_root/build/guide-upgrade.XXXXXX")

cleanup () {
  rm -rf -- "$mini_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

"$project_root/scripts/compose-process-upgrade-guide-example.sh" \
  "$project_root" "$mini_root"

if [ "${FLYOLOGY_GUIDE_EXAMPLE_REUSE_BUILD:-0}" != 1 ]; then
  (
    cd "$project_root"
    "$alr" build >/dev/null
  )
  FLYOLOGY_DEFAULT=native \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
fi

if [ ! -f "$project_root/build/rts/adalib/libgnarl.a" ]; then
  printf '%s\n' "process-upgrade guide check requires a prepared Flyology RTS" >&2
  exit 1
fi

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
      -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- env -u GPR_CONFIG gprbuild "$@"
}

run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f -p -j0 \
  -P "$mini_root/process_upgrade_guide.gpr"

promote_output=$(
  "$project_root/scripts/run-with-timeout.sh" 20 \
    "$mini_root/bin/guide_process_upgrade" promote
)
case "$promote_output" in
  *"promotion: generation 18 served"*) ;;
  *)
    printf '%s\n' "extracted guide example did not confirm promotion" >&2
    exit 1
    ;;
esac

cancel_output=$(
  "$project_root/scripts/run-with-timeout.sh" 20 \
    "$mini_root/bin/guide_process_upgrade" cancel
)
case "$cancel_output" in
  *"cancellation: generation 17 remained active"*) ;;
  *)
    printf '%s\n' "extracted guide example did not confirm cancellation" >&2
    exit 1
    ;;
esac

printf '%s\n' \
  "process-upgrade guide example: extracted, composed, promoted, cancelled"
