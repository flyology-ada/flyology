#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${1:-$("$project_root/scripts/find-alr.sh")}
compiler_prefix=$("$project_root/scripts/gnat-native-prefix.sh" "$alr")

compiler_package=${compiler_prefix##*/}
case "$compiler_package" in
  gnat_native_13.2.2_?*|gnat_flyology_native_13.2.2_?*)
    printf '%s\n' 13.2.2 ;;
  gnat_native_14.1.3_?*|gnat_flyology_native_14.1.3_?*)
    printf '%s\n' 14.1.3 ;;
  gnat_native_14.2.1_?*|gnat_flyology_native_14.2.1_?*)
    printf '%s\n' 14.2.1 ;;
  gnat_native_15.1.2_?*|gnat_flyology_native_15.1.2_?*)
    printf '%s\n' 15.1.2 ;;
  gnat_native_15.3.1_?*|gnat_flyology_native_15.3.1_?*)
    printf '%s\n' 15.3.1 ;;
  gnat_native_16.1.0_?*|gnat_flyology_native_16.1.0_?*)
    printf '%s\n' 16.1.0 ;;
  gnat_flyology_native_16.2.0_?*)
    printf '%s\n' 16.2.0 ;;
  *)
    printf '%s\n' \
      "unsupported or unidentified Alire GNAT compiler prefix: $compiler_prefix" \
      >&2
    exit 1
    ;;
esac
