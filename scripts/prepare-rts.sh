#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
caller_root=$(pwd -P)
requested_build_root=${FLYOLOGY_RTS_DIR:-"$project_root/build/rts"}
case "/$requested_build_root/" in
  */../*)
    printf '%s\n' "FLYOLOGY_RTS_DIR must not contain '..': $requested_build_root" >&2
    exit 1
    ;;
esac
case "$requested_build_root" in
  /*) ;;
  *) requested_build_root="$(pwd)/$requested_build_root" ;;
esac
case "$requested_build_root" in
  /)
    printf '%s\n' "FLYOLOGY_RTS_DIR must name a dedicated runtime directory" >&2
    exit 1
    ;;
esac
if [ -L "$requested_build_root" ]; then
  printf '%s\n' "FLYOLOGY_RTS_DIR must not be a symbolic link: $requested_build_root" >&2
  exit 1
fi
if [ -d "$requested_build_root" ]; then
  requested_build_root=$(CDPATH= cd -- "$requested_build_root" && pwd -P)
fi

build_parent=$(dirname -- "$requested_build_root")
build_name=$(basename -- "$requested_build_root")
case "$build_name" in
  ''|.|..)
    printf '%s\n' "FLYOLOGY_RTS_DIR must name a dedicated runtime directory" >&2
    exit 1
    ;;
esac
mkdir -p "$build_parent"
build_parent=$(CDPATH= cd -- "$build_parent" && pwd -P)
destination_root="$build_parent/$build_name"
if [ -L "$destination_root" ]; then
  printf '%s\n' "FLYOLOGY_RTS_DIR must not be a symbolic link: $destination_root" >&2
  exit 1
fi
if [ -e "$destination_root" ] && [ ! -d "$destination_root" ]; then
  printf '%s\n' "FLYOLOGY_RTS_DIR is not a directory: $destination_root" >&2
  exit 1
fi

reject_protected_target () {
  protected_root=$1
  protected_kind=$2
  [ -n "$protected_root" ] || return 0
  case "$protected_root" in
    "$destination_root"|"$destination_root"/*)
      printf '%s\n' \
        "FLYOLOGY_RTS_DIR must not be the $protected_kind or its ancestor: $destination_root" \
        >&2
      exit 1
      ;;
  esac
}

case "$destination_root" in
  /|/Applications|/Library|/System|/Users|/bin|/etc|/home|/opt|/private|\
  /private/tmp|/private/var|/sbin|/tmp|/usr|/var|/var/tmp)
    printf '%s\n' "FLYOLOGY_RTS_DIR is too broad: $destination_root" >&2
    exit 1
    ;;
esac
reject_protected_target "$project_root" "Flyology project root"
reject_protected_target "$caller_root" "caller workspace"
user_home_root=
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
  user_home_root=$(CDPATH= cd -- "$HOME" && pwd -P)
fi
reject_protected_target "$user_home_root" "user home directory"

marker_name=.flyology-rts-root
marker_value='Flyology prepared RTS version 1'
destination_is_owned () {
  marker_file="$destination_root/$marker_name"
  if [ -f "$marker_file" ] \
    && [ ! -L "$marker_file" ] \
    && [ "$(sed -n '1p' "$marker_file")" = "$marker_value" ]; then
    return 0
  fi

  #  Accept complete runtimes created before the ownership marker existed.
  [ -d "$destination_root/adainclude" ] \
    && [ -d "$destination_root/adalib" ] \
    && [ -d "$destination_root/obj" ] \
    && [ -f "$destination_root/adainclude/s-stalib.adb" ] \
    && [ -f "$destination_root/adalib/libgnat.a" ] \
    && [ -f "$destination_root/adalib/libgnarl.a" ]
}

if [ -d "$destination_root" ] \
  && [ -n "$(find "$destination_root" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  && ! destination_is_owned; then
  printf '%s\n' \
    "refusing to replace non-Flyology directory: $destination_root" \
    "choose a new or empty FLYOLOGY_RTS_DIR, or remove the target after inspecting it" \
    >&2
  exit 1
fi

#  Assemble a complete runtime beside its destination. Publishing only the
#  finished tree prevents files from an older compiler or configuration from
#  surviving a rebuild and leaves the previous tree usable if assembly fails.
build_root=$(mktemp -d "$build_parent/.${build_name}.flyology-build.XXXXXX")
printf '%s\n' "$marker_value" >"$build_root/$marker_name"
backup_root=
replacement_state=building
cleanup_build () {
  status=$?
  trap - EXIT

  case "$replacement_state" in
    backup_placeholder)
      if [ -n "$backup_root" ]; then
        rmdir "$backup_root" 2>/dev/null || true
      fi
      ;;
    displacing|displaced|installing)
      if [ "$replacement_state" = installing ] && [ -e "$destination_root" ]; then
        installed_marker="$destination_root/$marker_name"
        if [ -f "$installed_marker" ] \
          && [ "$(sed -n '1p' "$installed_marker")" = "$marker_value" ]; then
          rm -rf -- "$destination_root"
        else
          printf '%s\n' \
            "refusing to remove an unmarked destination during rollback: $destination_root" \
            >&2
        fi
      fi
      if [ -n "$backup_root" ] && [ -e "$backup_root" ]; then
        if [ -e "$destination_root" ]; then
          printf '%s\n' \
            "could not restore the previous RTS; preserved it at: $backup_root" \
            >&2
        else
          mv "$backup_root" "$destination_root"
          backup_root=
        fi
      fi
      ;;
  esac

  if [ -n "$build_root" ] && [ -e "$build_root" ]; then
    rm -rf -- "$build_root"
  fi
  exit "$status"
}
trap cleanup_build EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

generated_include="$build_root/adainclude"
generated_lib="$build_root/adalib"
alr=$("$project_root/scripts/find-alr.sh")
execution_default=${FLYOLOGY_DEFAULT:-native}
loop_pool_size=${FLYOLOGY_LOOP_POOL_SIZE:-1}
placement_policy=${FLYOLOGY_PLACEMENT:-round_robin}
loop_placement=${FLYOLOGY_LOOP_PLACEMENT:-none}
loop_placement_map=${FLYOLOGY_LOOP_PLACEMENT_MAP:-}
test_faults=${FLYOLOGY_TEST_FAULTS:-0}
deny_io_uring=${FLYOLOGY_TEST_DENY_IO_URING:-0}
# The test runner uses this seam only to verify fail-closed patch selection.
test_missing_monotonic_patch=${FLYOLOGY_TEST_MISSING_MONOTONIC_PATCH:-0}
sanitizer=${FLYOLOGY_SANITIZER:-none}

for test_switch in \
  "${FLYOLOGY_TEST_RTS_FAIL_DURING_ASSEMBLY:-0}" \
  "${FLYOLOGY_TEST_RTS_SIGNAL_BEFORE_DISPLACEMENT:-0}" \
  "${FLYOLOGY_TEST_RTS_SIGNAL_DURING_DISPLACEMENT:-0}"
do
  case "$test_switch" in
    0|1) ;;
    *)
      printf '%s\n' "Flyology RTS transaction test switches accept only 0 or 1" >&2
      exit 1
      ;;
  esac
done

case "$execution_default" in
  native|lightweight) ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_DEFAULT must be 'native' or 'lightweight', got: $execution_default" \
      >&2
    exit 1
    ;;
esac

case "$loop_pool_size" in
  ''|*[!0-9]*)
    printf '%s\n' \
      "FLYOLOGY_LOOP_POOL_SIZE must be an integer from 1 through 128, got: $loop_pool_size" \
      >&2
    exit 1
    ;;
esac
if [ "$loop_pool_size" -lt 1 ] || [ "$loop_pool_size" -gt 128 ]; then
  printf '%s\n' \
    "FLYOLOGY_LOOP_POOL_SIZE must be an integer from 1 through 128, got: $loop_pool_size" \
    >&2
  exit 1
fi

case "$placement_policy" in
  round_robin) ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_PLACEMENT must be 'round_robin', got: $placement_policy" \
      >&2
    exit 1
    ;;
esac

case "$loop_placement" in
  none)
    placement_mode=0
    if [ -n "$loop_placement_map" ]; then
      printf '%s\n' \
        "FLYOLOGY_LOOP_PLACEMENT_MAP requires strict or advisory placement" \
        >&2
      exit 1
    fi
    ;;
  strict)
    placement_mode=1
    ;;
  advisory)
    placement_mode=2
    ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_LOOP_PLACEMENT must be 'none', 'strict', or 'advisory', got: $loop_placement" \
      >&2
    exit 1
    ;;
esac

if [ "$loop_placement" != none ]; then
  if [ -z "$loop_placement_map" ]; then
    printf '%s\n' \
      "FLYOLOGY_LOOP_PLACEMENT_MAP must list group:value pairs for $loop_placement placement" \
      >&2
    exit 1
  fi
  if ! printf '%s\n' "$loop_placement_map" | awk '
    BEGIN { FS = ","; valid = 1 }
    {
      for (i = 1; i <= NF; i++) {
        if ($i !~ /^[0-9]+:[0-9]+$/) { valid = 0; continue }
        split($i, pair, ":")
        group = pair[1] + 0
        value = pair[2] + 0
        if (group < 0 || group > 255 || value > 2147483647) valid = 0
        if (mode == "advisory" && value == 0) valid = 0
        if (seen[group]++) valid = 0
      }
    }
    END { exit valid ? 0 : 1 }
  ' mode="$loop_placement"; then
    printf '%s\n' \
      "FLYOLOGY_LOOP_PLACEMENT_MAP must contain unique GROUP:VALUE pairs (group 0..255, value 0..2147483647), got: $loop_placement_map" \
      >&2
    exit 1
  fi
fi

if [ "$loop_placement" = none ]; then
  placement_requests='(others => (Mode => 0, Value => 0))'
  placement_any=False
else
  placement_requests=$(printf '%s\n' "$loop_placement_map" | awk \
    -v mode="$placement_mode" '
      BEGIN { FS = ","; printf "(" }
      {
        for (i = 1; i <= NF; i++) {
          split($i, pair, ":")
          printf "%s%s => (Mode => %s, Value => %s)",
            (i == 1 ? "" : ", "), pair[1], mode, pair[2]
        }
      }
      END { print ", others => (Mode => 0, Value => 0))" }
    ')
  placement_any=True
fi

case "$test_faults" in
  0)
    fault_cflags=
    fault_config=disabled
    ;;
  1)
    fault_cflags=-DFLYOLOGY_TEST_FAULTS
    fault_config=enabled
    ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_TEST_FAULTS must be '0' or '1', got: $test_faults" >&2
    exit 1
    ;;
esac

case "$deny_io_uring" in
  0)
    io_uring_test_cflags=
    ;;
  1)
    io_uring_test_cflags=-DFLYOLOGY_TEST_DENY_IO_URING
    ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_TEST_DENY_IO_URING must be '0' or '1', got: $deny_io_uring" >&2
    exit 1
    ;;
esac

case "$test_missing_monotonic_patch" in
  0|1) ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_TEST_MISSING_MONOTONIC_PATCH must be '0' or '1', got: $test_missing_monotonic_patch" \
      >&2
    exit 1
    ;;
esac

case "$sanitizer" in
  none)
    sanitizer_config=disabled
    ;;
  address)
    sanitizer_config=enabled
    ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_SANITIZER must be 'none' or 'address', got: $sanitizer" >&2
    exit 1
    ;;
esac

compiler_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")
runtime_warnings_source=
runtime_warnings_name=runtime-warnings.adc
case "$compiler_release" in
  13.2.2)
    runtime_warnings_source="$project_root/runtime/config/gnat-13/$runtime_warnings_name"
    ;;
esac

case "$(uname -s)" in
  Darwin)
    platform=darwin
    ;;
  Linux)
    platform=linux
    ;;
  *) printf '%s\n' "unsupported Flyology host: $(uname -s)" >&2; exit 1 ;;
esac

if [ "$loop_placement" = strict ] && [ "$platform" != linux ]; then
  printf '%s\n' \
    "strict event-loop CPU placement is unsupported on $platform" \
    "Darwin offers no hard-core binding; some hosts support advisory tags" >&2
  exit 1
fi
if [ "$loop_placement" = advisory ] && [ "$platform" != darwin ]; then
  printf '%s\n' \
    "advisory event-loop affinity tags are unsupported on $platform" >&2
  exit 1
fi
if [ "$loop_placement" = advisory ] \
  && [ "$platform" = darwin ] \
  && [ "$(uname -m)" = arm64 ]; then
  printf '%s\n' \
    "Darwin THREAD_AFFINITY_POLICY is unavailable on this arm64 host" \
    "event-loop affinity tags are advisory and cannot be configured here" >&2
  exit 1
fi

if [ "$loop_placement" = strict ]; then
  allowed_cpus=$(awk '/Cpus_allowed_list:/ { print $2; exit }' /proc/self/status)
  if ! printf '%s\n' "$loop_placement_map" | awk \
    -v allowed="$allowed_cpus" '
      function permitted(cpu, count, ranges, i, ends, low, high) {
        count = split(allowed, ranges, ",")
        for (i = 1; i <= count; i++) {
          split(ranges[i], ends, "-")
          low = ends[1] + 0
          high = (ends[2] == "" ? low : ends[2] + 0)
          if (cpu >= low && cpu <= high) return 1
        }
        return 0
      }
      BEGIN { FS = ","; valid = 1 }
      {
        for (i = 1; i <= NF; i++) {
          split($i, pair, ":")
          if (!permitted(pair[2] + 0)) valid = 0
        }
      }
      END { exit valid ? 0 : 1 }
    '; then
    printf '%s\n' \
      "FLYOLOGY_LOOP_PLACEMENT_MAP requests a CPU outside this process's allowed Linux set: $allowed_cpus" \
      >&2
    exit 1
  fi
fi

case "$platform:$compiler_release" in
  darwin:13.2.2|darwin:14.1.3|darwin:14.2.1|\
  linux:13.2.2|linux:14.1.3|linux:14.2.1|linux:15.1.2|linux:15.3.1)
    patch_family=gnat-13-16
    compat_family=gnat-legacy
    ;;
  darwin:16.1.0|darwin:16.2.0|linux:16.1.0|linux:16.2.0)
    patch_family=gnat-13-16
    compat_family=gnat-16
    ;;
  *)
    printf '%s\n' \
      "unsupported Flyology host/compiler pair: $platform / GNAT $compiler_release" \
      "selected Alire release: $compiler_release" \
      "verified on Darwin: 13.2.2, 14.1.3, 14.2.1, 16.1.0, 16.2.0" \
      "verified on Linux: 13.2.2, 14.1.3, 14.2.1, 15.1.2, 15.3.1, 16.1.0, 16.2.0" >&2
    exit 1
    ;;
esac

compiler_prefix=$("$project_root/scripts/gnat-native-prefix.sh" "$alr")
compiler="$compiler_prefix/bin/gcc"
patch_root="$project_root/runtime/patches/$patch_family"

tasking_patch="$patch_root/$platform/s-taprop.adb.patch"
case "$platform:$compat_family" in
  darwin:gnat-16)
    monotonic_patch="$patch_root/darwin/s-tpopmo-gnat-16.adb.patch"
    ;;
  darwin:*)
    monotonic_patch="$patch_root/darwin/s-tpopmo.adb.patch"
    ;;
  linux:*)
    monotonic_patch=
    ;;
esac
if [ "$platform" = darwin ]; then
  if [ "$test_missing_monotonic_patch" = 1 ]; then
    monotonic_patch="$monotonic_patch.missing-test"
  fi
  if [ ! -f "$monotonic_patch" ]; then
    printf '%s\n' \
      "required Darwin monotonic patch is missing: $monotonic_patch" >&2
    exit 1
  fi
fi
task_state_patch="$patch_root/common/s-tassta.adb.patch"
blocking_detection_patch="$patch_root/common/s-taskin.adb.patch"
legacy_suspension_body_patch="$patch_root/legacy/a-sytaco.adb.patch"
case "$compiler_release" in
  13.2.2|14.1.3|14.2.1)
    legacy_suspension_spec_patch="$patch_root/legacy/pre-15/a-sytaco.ads.patch"
    ;;
  15.1.2|15.3.1)
    legacy_suspension_spec_patch="$patch_root/legacy/gnat-15/a-sytaco.ads.patch"
    ;;
  *)
    legacy_suspension_spec_patch=
    ;;
esac

source_include=$("$compiler" -print-file-name=adainclude)
source_lib=$("$compiler" -print-file-name=adalib)

mkdir -p "$generated_include" "$generated_lib" "$build_root/obj"
chmod -R u+w "$generated_include" "$generated_lib"
cp -R "$source_include/." "$generated_include/"
cp -R "$source_lib/." "$generated_lib/"
chmod -R u+w "$generated_include" "$generated_lib"
cp "$project_root"/runtime/ada/s-*.ad? "$generated_include/"
cp "$project_root"/runtime/platform/"$platform"/s-*.ad? "$generated_include/"
cp "$project_root/runtime/compat/$compat_family/s-fltiab.ads" \
  "$generated_include/"
cp "$project_root/runtime/config/$execution_default/s-fldeex.ads" \
  "$generated_include/"
sed \
  "s/@AUTOMATIC_POOL_SIZE@/$loop_pool_size/g" \
  "$project_root/runtime/config/pool/s-flpoco.ads.in" \
  >"$generated_include/s-flpoco.ads"
sed \
  -e "s/@PLACEMENT_REQUESTS@/$placement_requests/g" \
  -e "s/@PLACEMENT_ANY@/$placement_any/g" \
  "$project_root/runtime/config/placement/s-flplco.ads.in" \
  >"$generated_include/s-flplco.ads"
cp "$project_root/runtime/config/faults/$fault_config"/s-flyfau.ad? \
  "$generated_include/"
cp "$project_root/runtime/config/sanitizers/$sanitizer_config"/s-flyasa.ad? \
  "$generated_include/"
runtime_warnings=
if [ -n "$runtime_warnings_source" ]; then
  cp "$runtime_warnings_source" "$generated_include/$runtime_warnings_name"
  runtime_warnings="$generated_include/$runtime_warnings_name"
fi

compile_runtime_ada () {
  if [ -n "$runtime_warnings" ]; then
    "$compiler" -c -gnatg -gnatyM110 -gnat2022 -O2 -fPIC -gnata \
      "-gnatec=$runtime_warnings" -gnateb "$@"
  else
    "$compiler" -c -gnatg -gnatyM110 -gnat2022 -O2 -fPIC -gnata "$@"
  fi
}

#  git apply resolves --directory relative to the repository worktree even
#  when an absolute path is supplied. Anchor it here so callers may invoke
#  prepare-rts.sh from a nested Alire crate or any other working directory.
cd "$project_root"
git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$tasking_patch"
if [ -n "$monotonic_patch" ]; then
  git apply --ignore-space-change --unsafe-paths \
    --directory="$generated_include" \
    "$monotonic_patch"
fi
git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$task_state_patch"
git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$blocking_detection_patch"
if [ "$compat_family" = gnat-legacy ]; then
  git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
    --directory="$generated_include" \
    "$legacy_suspension_spec_patch"
  git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
    --directory="$generated_include" \
    "$legacy_suspension_body_patch"
fi

if [ "${FLYOLOGY_TEST_RTS_FAIL_DURING_ASSEMBLY:-0}" = 1 ]; then
  printf '%s\n' "injected failure during Flyology RTS assembly" >&2
  exit 96
fi

cc -O2 -c "$project_root/runtime/native/context_switch.S" \
  -o "$build_root/obj/context_switch.o"
cc -O2 $fault_cflags $io_uring_test_cflags \
  -c "$project_root/runtime/native/platform.c" \
  -o "$build_root/obj/platform.o"
#  The scheduler imports this object's release entry point unconditionally, so
#  the archive member is always extracted and its strong nested-subprogram
#  trampoline helpers take precedence over libgcc's weak definitions.
cc -O2 -c "$project_root/runtime/native/heap_trampoline.c" \
  -o "$build_root/obj/heap_trampoline.o"
cd "$build_root/obj"
if [ "$platform" = linux ]; then
  compile_runtime_ada \
    -I "$generated_include" \
    "$generated_include/s-fllimo.ads"
fi
compile_runtime_ada \
  -I "$generated_include" \
  "$generated_include/s-fltiab.ads" \
  "$generated_include/s-fldeex.ads" \
  "$generated_include/s-flpoco.ads" \
  "$generated_include/s-flplco.ads" \
  "$generated_include/s-flyolo.adb" \
  "$generated_include/s-ftrepo.adb" \
  "$generated_include/s-fltare.adb" \
  "$generated_include/s-flstpo.adb" \
  "$generated_include/s-flycon.adb" \
  "$generated_include/s-flyasa.adb" \
  "$generated_include/s-flyfau.adb" \
  "$generated_include/s-flfien.adb" \
  "$generated_include/s-flpopo.adb" \
  "$generated_include/s-flypol.adb" \
  "$generated_include/s-flscpo.adb" \
  "$generated_include/s-fszcpo.adb" \
  "$generated_include/s-flysch.adb" \
  "$generated_include/s-taprop.adb" \
  "$generated_include/s-taskin.adb" \
  "$generated_include/s-tassta.adb"
if [ "$compat_family" = gnat-legacy ]; then
  compile_runtime_ada \
    -I "$generated_include" \
    "$generated_include/a-sytaco.adb"
fi

cp \
  s-fltiab.ali s-fldeex.ali s-flpoco.ali s-flplco.ali s-flyolo.ali s-ftrepo.ali s-fltare.ali s-flstpo.ali s-flycon.ali \
  s-flyasa.ali \
  s-flyfau.ali s-flfien.ali s-flpopo.ali s-flypol.ali \
  s-flscpo.ali s-fszcpo.ali s-flysch.ali s-taprop.ali s-taskin.ali s-tassta.ali \
  "$generated_lib/"
if [ "$compat_family" = gnat-legacy ]; then
  cp a-sytaco.ali "$generated_lib/"
fi
if [ "$platform" = linux ]; then
  cp s-fllimo.ali "$generated_lib/"
fi
ar -r "$generated_lib/libgnarl.a" \
  s-fldeex.o \
  s-flpoco.o \
  s-flplco.o \
  s-flyolo.o \
  s-ftrepo.o \
  s-fltare.o \
  s-flstpo.o \
  s-flycon.o \
  s-flyasa.o \
  s-flyfau.o \
  s-flfien.o \
  s-flpopo.o \
  s-flypol.o \
  s-flscpo.o \
  s-fszcpo.o \
  s-flysch.o \
  s-taprop.o \
  s-taskin.o \
  s-tassta.o \
  context_switch.o \
  platform.o \
  heap_trampoline.o
if [ "$compat_family" = gnat-legacy ]; then
  ar -r "$generated_lib/libgnarl.a" a-sytaco.o
fi
if [ "$platform" = linux ]; then
  ar -r "$generated_lib/libgnarl.a" s-fllimo.o
fi
ranlib "$generated_lib/libgnarl.a"

if [ "${FLYOLOGY_TEST_RTS_SIGNAL_BEFORE_DISPLACEMENT:-0}" = 1 ]; then
  printf '%s\n' "injected signal before Flyology RTS displacement" >&2
  kill -TERM "$$"
fi
if [ -e "$destination_root" ]; then
  backup_root=$(mktemp -d "$build_parent/.${build_name}.flyology-old.XXXXXX")
  replacement_state=backup_placeholder
  rmdir "$backup_root"
  replacement_state=displacing
  mv "$destination_root" "$backup_root"
  if [ "${FLYOLOGY_TEST_RTS_SIGNAL_DURING_DISPLACEMENT:-0}" = 1 ]; then
    printf '%s\n' "injected signal during Flyology RTS displacement" >&2
    kill -TERM "$$"
  fi
  replacement_state=displaced
fi
replacement_state=installing
mv "$build_root" "$destination_root"
replacement_state=published
build_root=
if [ -n "$backup_root" ]; then
  rm -rf -- "$backup_root"
  backup_root=
fi

printf '%s\n' "$destination_root"
