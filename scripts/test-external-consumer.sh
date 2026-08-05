#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_root="$project_root/tests/external_consumer"
alr=$("$project_root/scripts/find-alr.sh")
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology consumer.XXXXXX")
pin_root="$consumer_root/flyology-pin"
concurrent_root="$consumer_root/concurrent-consumer"

cleanup () {
  rm -rf -- "$consumer_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$pin_root"
cp -R "$fixture_root/." "$consumer_root/"
mkdir -p "$concurrent_root"
cp -R "$fixture_root/." "$concurrent_root/"
cp "$project_root/alire.toml" "$project_root/flyology.gpr" "$pin_root/"
cp -R "$project_root/runtime" "$project_root/scripts" "$project_root/src" \
  "$pin_root/"
cd "$consumer_root"

"$alr" --non-interactive with flyology --use="$pin_root"
(cd "$concurrent_root" &&
  "$alr" --non-interactive with flyology --use="$pin_root")

#  Launch the dependency's exact pre-build command through two clean consumer
#  environments against the same cold path pin. Alire's build and recursive
#  action dispatch both update shared pin metadata before Flyology starts, so
#  they cannot isolate this critical section. The test probe makes overlapping
#  entry into Flyology's section fail.
probe_dir="$consumer_root/preparation-critical-section"
first_log="$consumer_root/first-consumer.log"
second_log="$consumer_root/second-consumer.log"
(
  cd "$consumer_root"
  "$alr" exec -- env \
    FLYOLOGY_TEST_RTS_LOCK_PROBE_DIR="$probe_dir" \
    "$pin_root/scripts/prepare-alire-rts.sh"
) >"$first_log" 2>&1 &
first_pid=$!
(
  cd "$concurrent_root"
  "$alr" exec -- env \
    FLYOLOGY_TEST_RTS_LOCK_PROBE_DIR="$probe_dir" \
    "$pin_root/scripts/prepare-alire-rts.sh"
) >"$second_log" 2>&1 &
second_pid=$!

concurrent_status=0
if ! wait "$first_pid"; then
  concurrent_status=1
fi
if ! wait "$second_pid"; then
  concurrent_status=1
fi
if [ "$concurrent_status" -ne 0 ]; then
  printf '%s\n' "first concurrent consumer output:" >&2
  sed 's/^/  /' "$first_log" >&2
  printf '%s\n' "second concurrent consumer output:" >&2
  sed 's/^/  /' "$second_log" >&2
  exit 1
fi

#  Verify that sequential ordinary Alire builds select the shared freshly
#  generated native-default RTS through GPR_CONFIG without worktree state.
cd "$consumer_root"
"$alr" build
(cd "$concurrent_root" && "$alr" build)

runtime_archive="$pin_root/build/alire-rts/adalib/libgnarl.a"
runtime_object="$pin_root/build/alire-rts/obj/context_switch.o"
generated_config="$pin_root/build/flyology.cgpr"
persisted_policy="$pin_root/build/flyology-rts.conf"
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
"$concurrent_root/build/bin/external_consumer" native

#  Persist an explicit project policy, then prove that a normal build with no
#  configuration environment retains it instead of reverting to defaults.
FLYOLOGY_DEFAULT=lightweight \
  "$alr" exec -- "$pin_root/scripts/prepare-alire-rts.sh" --configure
if ! grep '^default=lightweight$' "$persisted_policy" >/dev/null; then
  printf '%s\n' "explicit Alire RTS policy was not persisted" >&2
  exit 1
fi
persistence_sentinel="$consumer_root/persistence-sentinel"
touch "$persistence_sentinel"
"$alr" build
if [ "$runtime_object" -nt "$persistence_sentinel" ]; then
  printf '%s\n' "plain Alire build replaced the persisted RTS policy" >&2
  exit 1
fi
"$consumer_root/build/bin/external_consumer" lightweight

#  Reset from outside `alr exec` with misleading PATH tools. The generated GPR
#  configuration must name the validated gnat_native prefix explicitly, and a
#  clean runtime replacement must not retain an arbitrary stale unit.
fake_bin="$consumer_root/mismatched compiler/bin"
mkdir -p "$fake_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\\n" "unexpected PATH gcc invocation" >&2' \
  'exit 88' >"$fake_bin/gcc"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\\n" "unexpected PATH gprconfig invocation" >&2' \
  'exit 89' >"$fake_bin/gprconfig"
chmod +x "$fake_bin/gcc" "$fake_bin/gprconfig"
stale_runtime_file="$pin_root/build/alire-rts/adainclude/stale-runtime-unit.ads"
touch "$stale_runtime_file"
PATH="$fake_bin:$PATH" ALR="$alr" \
  "$pin_root/scripts/prepare-alire-rts.sh" --reset
if [ -e "$persisted_policy" ]; then
  printf '%s\n' "Alire RTS policy reset retained its configuration file" >&2
  exit 1
fi
if [ -e "$stale_runtime_file" ]; then
  printf '%s\n' "clean RTS replacement retained a stale runtime unit" >&2
  exit 1
fi
compiler_prefix=$(ALR="$alr" "$pin_root/scripts/gnat-native-prefix.sh")
normalized_config=$(tr '[:upper:]' '[:lower:]' <"$generated_config")
normalized_prefix=$(printf '%s\n' "$compiler_prefix" |
  tr '[:upper:]' '[:lower:]')
case "$normalized_config" in
  *"$normalized_prefix/bin/gcc"*) ;;
  *)
    printf '%s\n' \
      "GPR configuration did not bind the validated gnat_native compiler" >&2
    exit 1
    ;;
esac
case "$normalized_config" in
  *"mismatched compiler"*)
    printf '%s\n' "GPR configuration selected the compiler from PATH" >&2
    exit 1
    ;;
esac
"$alr" build
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

printf '\n' >>"$pin_root/runtime/native/context_switch.S"
stamp_file="$pin_root/build/alire-rts/.flyology-input-stamp"
if FLYOLOGY_TEST_RTS_FAIL_BEFORE_PUBLICATION=1 \
  "$alr" exec -- "$pin_root/scripts/prepare-alire-rts.sh"
then
  printf '%s\n' "injected RTS preparation failure unexpectedly succeeded" >&2
  exit 1
fi
if [ -e "$stamp_file" ]; then
  printf '%s\n' \
    "interrupted RTS preparation retained its currentness stamp" >&2
  exit 1
fi

repair_sentinel="$consumer_root/interruption-repair-sentinel"
touch "$repair_sentinel"
"$alr" build
if [ ! "$runtime_object" -nt "$repair_sentinel" ]; then
  printf '%s\n' "interrupted RTS preparation was not rebuilt" >&2
  exit 1
fi
if [ ! -f "$stamp_file" ]; then
  printf '%s\n' "repaired RTS preparation did not publish its stamp" >&2
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
