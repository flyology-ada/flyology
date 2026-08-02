#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/build/rts"
generated_include="$build_root/adainclude"
generated_lib="$build_root/adalib"
alr=${ALR:-"$HOME/alr"}
execution_default=${GNATEVL_DEFAULT:-native}

case "$execution_default" in
  native|evented) ;;
  *)
    printf '%s\n' \
      "GNATEVL_DEFAULT must be 'native' or 'evented', got: $execution_default" \
      >&2
    exit 1
    ;;
esac

case "$(uname -s)" in
  Darwin)
    platform=darwin
    tasking_patch="$project_root/runtime/patches/s-taprop.adb.patch"
    ;;
  Linux)
    platform=linux
    tasking_patch="$project_root/runtime/patches/s-taprop-linux.adb.patch"
    ;;
  *) printf '%s\n' "unsupported GNATEVL host: $(uname -s)" >&2; exit 1 ;;
esac

source_include=$("$alr" exec -- gcc -print-file-name=adainclude)
source_lib=$("$alr" exec -- gcc -print-file-name=adalib)

mkdir -p "$generated_include" "$generated_lib" "$build_root/obj"
chmod -R u+w "$generated_include" "$generated_lib"
cp -R "$source_include/." "$generated_include/"
cp -R "$source_lib/." "$generated_lib/"
cp "$project_root"/runtime/ada/s-*.ad? "$generated_include/"
cp "$project_root"/runtime/platform/"$platform"/s-*.ad? "$generated_include/"
cp "$project_root/runtime/config/$execution_default/s-gndeex.ads" \
  "$generated_include/"

git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$tasking_patch"
git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$project_root/runtime/patches/s-tassta.adb.patch"

cc -O2 -c "$project_root/runtime/native/context_switch.S" \
  -o "$build_root/obj/context_switch.o"
cc -O2 -c "$project_root/runtime/native/platform.c" \
  -o "$build_root/obj/platform.o"
cd "$build_root/obj"
if [ "$platform" = linux ]; then
  "$alr" exec -- gcc -c -gnatg -gnat2022 -O2 -fPIC -gnata \
    -I "$generated_include" \
    "$generated_include/s-gnlimo.ads"
fi
"$alr" exec -- gcc -c -gnatg -gnat2022 -O2 -fPIC -gnata \
  -I "$generated_include" \
  "$generated_include/s-gndeex.ads" \
  "$generated_include/s-gnatev.ads" \
  "$generated_include/s-gnacon.adb" \
  "$generated_include/s-gnfien.adb" \
  "$generated_include/s-gnapol.adb" \
  "$generated_include/s-gnscpo.adb" \
  "$generated_include/s-gnasch.adb" \
  "$generated_include/s-taprop.adb" \
  "$generated_include/s-tassta.adb"

cp \
  s-gndeex.ali s-gnatev.ali s-gnacon.ali s-gnfien.ali s-gnapol.ali \
  s-gnscpo.ali s-gnasch.ali s-taprop.ali s-tassta.ali \
  "$generated_lib/"
if [ "$platform" = linux ]; then
  cp s-gnlimo.ali "$generated_lib/"
fi
ar -r "$generated_lib/libgnarl.a" \
  s-gndeex.o \
  s-gnatev.o \
  s-gnacon.o \
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
