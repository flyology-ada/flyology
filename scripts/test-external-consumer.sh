#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_root="$project_root/tests/external_consumer"
alr=$("$project_root/scripts/find-alr.sh")
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-consumer.XXXXXX")
pin_root="$consumer_root/flyology-pin"

cleanup () {
  rm -rf -- "$consumer_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$pin_root"
cp -R "$fixture_root/." "$consumer_root/"
cp "$project_root/alire.toml" "$project_root/flyology.gpr" "$pin_root/"
cp -R "$project_root/runtime" "$project_root/scripts" "$project_root/src" \
  "$pin_root/"
cd "$consumer_root"

"$alr" --non-interactive with flyology --use="$pin_root"

#  Verify that an ordinary Alire build runs the dependency's pre-build action,
#  selects a freshly generated native-default RTS through GPR_CONFIG, and does
#  not depend on generated state in the source worktree.
"$alr" build
runtime_archive="$pin_root/build/alire-rts/adalib/libgnarl.a"
runtime_object="$pin_root/build/alire-rts/obj/context_switch.o"
archive_probe="$consumer_root/context_switch.o"
ar -p "$runtime_archive" context_switch.o >"$archive_probe"
case "$(uname -m)" in
  arm64|aarch64)
    case "$(uname -s)" in
      Darwin)
        frame_dump=$(xcrun dwarfdump --eh-frame "$archive_probe")
        ;;
      Linux)
        frame_dump=$(readelf --debug-dump=frames "$archive_probe")
        ;;
      *)
        printf '%s\n' "unsupported unwind-inspection host: $(uname -s)" >&2
        exit 1
        ;;
    esac
    case "$frame_dump" in
      *"DW_CFA_undefined: W30"*|*"DW_CFA_undefined: r30"*) ;;
      *)
        printf '%s\n' \
          "prepared AArch64 context switch lacks an unwind-root FDE" >&2
        exit 1
        ;;
    esac
    ;;
esac
"$consumer_root/build/bin/external_consumer" native

#  An unchanged build must retain the prepared runtime, while a change to a
#  path-pinned runtime input must invalidate it without manual preparation.
noop_sentinel="$consumer_root/noop-sentinel"
touch "$noop_sentinel"
touch -t 200001010000 "$runtime_object"
"$alr" build
if [ "$runtime_object" -nt "$noop_sentinel" ]; then
  printf '%s\n' "unchanged Alire build rebuilt the prepared runtime" >&2
  exit 1
fi

artifact_sentinel="$consumer_root/artifact-sentinel"
touch "$artifact_sentinel"
ar -d "$runtime_archive" context_switch.o
"$alr" build
if ! ar -t "$runtime_archive" | grep '^context_switch[.]o$' >/dev/null; then
  printf '%s\n' "Alire build retained an incomplete runtime archive" >&2
  exit 1
fi
if [ ! "$runtime_object" -nt "$artifact_sentinel" ]; then
  printf '%s\n' "incomplete runtime archive did not force preparation" >&2
  exit 1
fi

source_sentinel="$consumer_root/source-sentinel"
touch "$source_sentinel"
printf '\n' >>"$pin_root/runtime/native/context_switch.S"
"$alr" build
if [ ! "$runtime_object" -nt "$source_sentinel" ]; then
  printf '%s\n' "path-pin source change retained a stale prepared runtime" >&2
  exit 1
fi
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
leaked_objects=$(find "$pin_root" -maxdepth 1 -type f \
  \( -name 's-*.o' -o -name 's-*.ali' \) -print)
if [ -n "$leaked_objects" ]; then
  printf '%s\n' \
    'runtime preparation leaked generated objects into the dependency root:' \
    "$leaked_objects" >&2
  exit 1
fi
