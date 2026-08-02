#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/build/rts"
generated_include="$build_root/adainclude"
generated_lib="$build_root/adalib"
alr=${ALR:-"$HOME/alr"}

source_include=$("$alr" exec -- gcc -print-file-name=adainclude)
source_lib=$("$alr" exec -- gcc -print-file-name=adalib)

mkdir -p "$generated_include" "$generated_lib" "$build_root/obj"
chmod -R u+w "$generated_include" "$generated_lib"
cp -R "$source_include/." "$generated_include/"
cp -R "$source_lib/." "$generated_lib/"
cp "$project_root"/runtime/ada/s-*.ad? "$generated_include/"

git apply --recount --unidiff-zero --ignore-space-change --unsafe-paths \
  --directory="$generated_include" \
  "$project_root/runtime/patches/s-taprop.adb.patch"

cc -O2 -c "$project_root/runtime/native/context_switch.S" \
  -o "$build_root/obj/context_switch.o"

cd "$build_root/obj"
"$alr" exec -- gcc -c -gnatg -gnat2022 -O2 -fPIC -gnata \
  -I "$generated_include" \
  "$generated_include/s-gnatev.ads" \
  "$generated_include/s-gnacon.adb" \
  "$generated_include/s-gnapol.adb" \
  "$generated_include/s-gnscpo.adb" \
  "$generated_include/s-gnasch.adb" \
  "$generated_include/s-taprop.adb"

cp s-gnatev.ali s-gnacon.ali s-gnapol.ali s-gnscpo.ali s-gnasch.ali \
  s-taprop.ali "$generated_lib/"
ar -r "$generated_lib/libgnarl.a" \
  s-gnatev.o \
  s-gnacon.o \
  s-gnapol.o \
  s-gnscpo.o \
  s-gnasch.o \
  s-taprop.o \
  context_switch.o
ranlib "$generated_lib/libgnarl.a"

printf '%s\n' "$build_root"
