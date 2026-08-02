#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root=${GNATEVL_RTS_DIR:-"$project_root/build/rts"}
case "$build_root" in
  /*) ;;
  *) build_root="$(pwd)/$build_root" ;;
esac
mkdir -p "$build_root"
build_root=$(CDPATH= cd -- "$build_root" && pwd -P)
generated_include="$build_root/adainclude"
generated_lib="$build_root/adalib"
alr=$("$project_root/scripts/find-alr.sh")
execution_default=${GNATEVL_DEFAULT:-native}
loop_pool_size=${GNATEVL_LOOP_POOL_SIZE:-1}
placement_policy=${GNATEVL_PLACEMENT:-round_robin}
test_faults=${GNATEVL_TEST_FAULTS:-0}

case "$execution_default" in
  native|evented) ;;
  *)
    printf '%s\n' \
      "GNATEVL_DEFAULT must be 'native' or 'evented', got: $execution_default" \
      >&2
    exit 1
    ;;
esac

case "$loop_pool_size" in
  ''|*[!0-9]*)
    printf '%s\n' \
      "GNATEVL_LOOP_POOL_SIZE must be an integer from 1 through 128, got: $loop_pool_size" \
      >&2
    exit 1
    ;;
esac
if [ "$loop_pool_size" -lt 1 ] || [ "$loop_pool_size" -gt 128 ]; then
  printf '%s\n' \
    "GNATEVL_LOOP_POOL_SIZE must be an integer from 1 through 128, got: $loop_pool_size" \
    >&2
  exit 1
fi

case "$placement_policy" in
  round_robin) ;;
  *)
    printf '%s\n' \
      "GNATEVL_PLACEMENT must be 'round_robin', got: $placement_policy" \
      >&2
    exit 1
    ;;
esac

case "$test_faults" in
  0)
    fault_cflags=
    fault_config=disabled
    ;;
  1)
    fault_cflags=-DGNATEVL_TEST_FAULTS
    fault_config=enabled
    ;;
  *)
    printf '%s\n' \
      "GNATEVL_TEST_FAULTS must be '0' or '1', got: $test_faults" >&2
    exit 1
    ;;
esac

compiler_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")

case "$(uname -s)" in
  Darwin)
    platform=darwin
    ;;
  Linux)
    platform=linux
    ;;
  *) printf '%s\n' "unsupported GNATEVL host: $(uname -s)" >&2; exit 1 ;;
esac

case "$platform:$compiler_release" in
  darwin:13.2.2|darwin:14.1.3|darwin:14.2.1|\
  linux:13.2.2|linux:14.1.3|linux:14.2.1|linux:15.1.2|linux:15.3.1)
    patch_family=gnat-13-16
    compat_family=gnat-legacy
    ;;
  darwin:16.1.0|linux:16.1.0)
    patch_family=gnat-13-16
    compat_family=gnat-16
    ;;
  *)
    printf '%s\n' \
      "unsupported GNATEVL host/compiler pair: $platform / gnat_native $compiler_release" \
      "selected Alire release: $compiler_release" \
      "verified on Darwin: 13.2.2, 14.1.3, 14.2.1, 16.1.0" \
      "verified on Linux: 13.2.2, 14.1.3, 14.2.1, 15.1.2, 15.3.1, 16.1.0" >&2
    exit 1
    ;;
esac

compiler=$("$alr" exec -- sh -c 'command -v gcc' | tail -n 1)
patch_root="$project_root/runtime/patches/$patch_family"

tasking_patch="$patch_root/$platform/s-taprop.adb.patch"
task_state_patch="$patch_root/common/s-tassta.adb.patch"

source_include=$("$compiler" -print-file-name=adainclude)
source_lib=$("$compiler" -print-file-name=adalib)

mkdir -p "$generated_include" "$generated_lib" "$build_root/obj"
chmod -R u+w "$generated_include" "$generated_lib"
cp -R "$source_include/." "$generated_include/"
cp -R "$source_lib/." "$generated_lib/"
chmod -R u+w "$generated_include" "$generated_lib"
cp "$project_root"/runtime/ada/s-*.ad? "$generated_include/"
cp "$project_root"/runtime/platform/"$platform"/s-*.ad? "$generated_include/"
cp "$project_root/runtime/compat/$compat_family/s-gntiab.ads" \
  "$generated_include/"
cp "$project_root/runtime/config/$execution_default/s-gndeex.ads" \
  "$generated_include/"
sed \
  "s/@AUTOMATIC_POOL_SIZE@/$loop_pool_size/g" \
  "$project_root/runtime/config/pool/s-gnpoco.ads.in" \
  >"$generated_include/s-gnpoco.ads"
cp "$project_root/runtime/config/faults/$fault_config"/s-gnafau.ad? \
  "$generated_include/"

git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$tasking_patch"
git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$task_state_patch"

cc -O2 -c "$project_root/runtime/native/context_switch.S" \
  -o "$build_root/obj/context_switch.o"
cc -O2 $fault_cflags -c "$project_root/runtime/native/platform.c" \
  -o "$build_root/obj/platform.o"
cd "$build_root/obj"
if [ "$platform" = linux ]; then
  "$compiler" -c -gnatg -gnat2022 -O2 -fPIC -gnata \
    -I "$generated_include" \
    "$generated_include/s-gnlimo.ads"
fi
"$compiler" -c -gnatg -gnat2022 -O2 -fPIC -gnata \
  -I "$generated_include" \
  "$generated_include/s-gntiab.ads" \
  "$generated_include/s-gndeex.ads" \
  "$generated_include/s-gnpoco.ads" \
  "$generated_include/s-gnatev.ads" \
  "$generated_include/s-gnacon.adb" \
  "$generated_include/s-gnafau.adb" \
  "$generated_include/s-gnfien.adb" \
  "$generated_include/s-gnapol.adb" \
  "$generated_include/s-gnscpo.adb" \
  "$generated_include/s-gnasch.adb" \
  "$generated_include/s-taprop.adb" \
  "$generated_include/s-tassta.adb"

cp \
  s-gntiab.ali s-gndeex.ali s-gnpoco.ali s-gnatev.ali s-gnacon.ali \
  s-gnafau.ali s-gnfien.ali s-gnapol.ali \
  s-gnscpo.ali s-gnasch.ali s-taprop.ali s-tassta.ali \
  "$generated_lib/"
if [ "$platform" = linux ]; then
  cp s-gnlimo.ali "$generated_lib/"
fi
ar -r "$generated_lib/libgnarl.a" \
  s-gndeex.o \
  s-gnpoco.o \
  s-gnatev.o \
  s-gnacon.o \
  s-gnafau.o \
  s-gnfien.o \
  s-gnapol.o \
  s-gnscpo.o \
  s-gnasch.o \
  s-taprop.o \
  s-tassta.o \
  context_switch.o \
  platform.o
if [ "$platform" = linux ]; then
  ar -r "$generated_lib/libgnarl.a" s-gnlimo.o
fi
ranlib "$generated_lib/libgnarl.a"

printf '%s\n' "$build_root"
