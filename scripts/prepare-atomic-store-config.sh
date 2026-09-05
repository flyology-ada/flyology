#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "$#" in
  0) alr=$("$project_root/scripts/find-alr.sh") ;;
  1) alr=$1 ;;
  *)
    printf '%s\n' "usage: prepare-atomic-store-config.sh [ALR]" >&2
    exit 2
    ;;
esac

compiler_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")
config_file="$project_root/config/flyology_atomic_store_config.gpr"
mkdir -p "$project_root/config"
config_temp=$(mktemp "$project_root/config/.flyology_atomic_store_config.gpr.XXXXXX")
cleanup () {
  rm -f -- "$config_temp"
}
trap cleanup EXIT HUP INT TERM
"$project_root/scripts/configure-atomic-store-family.sh" \
  "$compiler_release" >"$config_temp"
mv "$config_temp" "$config_file"
trap - EXIT HUP INT TERM

printf '%s\n' "$compiler_release"
