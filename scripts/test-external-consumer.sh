#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_root="$project_root/tests/external_consumer"
alr=$("$project_root/scripts/find-alr.sh")
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-consumer.XXXXXX")

cleanup () {
  rm -rf -- "$consumer_root"
}
trap cleanup EXIT HUP INT TERM

cp -R "$fixture_root/." "$consumer_root/"
cd "$consumer_root"

"$alr" --non-interactive with flyology --use="$project_root"

#  Verify that an ordinary Alire build runs the dependency's post-fetch action
#  and selects the generated native-default RTS through GPR_CONFIG.
"$alr" build
"$consumer_root/build/bin/external_consumer" native

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- env -u GPR_CONFIG gprbuild "$@"
}

for execution_default in lightweight; do
  rts_root="$consumer_root/build/rts-$execution_default"
  ALR="$alr" \
  FLYOLOGY_CONSUMER_RTS="$rts_root" \
  FLYOLOGY_CONSUMER_DEFAULT="$execution_default" \
    "$alr" exec -- ./prepare-rts.sh

  run_gprbuild \
    --RTS="$rts_root" \
    -f \
    -P external_consumer.gpr
  "$consumer_root/build/bin/external_consumer" "$execution_default"
done

# Preparing a consumer-owned RTS must never leave runtime objects in the
# dependency checkout. A compiler invoked after changing directories must be
# resolved before that change; this check makes regressions fail visibly.
leaked_objects=$(find "$project_root" -maxdepth 1 -type f \
  \( -name 's-*.o' -o -name 's-*.ali' \) -print)
if [ -n "$leaked_objects" ]; then
  printf '%s\n' \
    'runtime preparation leaked generated objects into the Flyology root:' \
    "$leaked_objects" >&2
  exit 1
fi
