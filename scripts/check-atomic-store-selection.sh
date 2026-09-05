#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' "usage: check-atomic-store-selection.sh COMPILER_RELEASE COMPILER_FAMILY" >&2
  exit 2
fi

compiler_release=$1
compiler_family=$2
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root="$project_root/build/tests/atomic-store-selection"

case "$compiler_family" in
  gnat-13)
    source_dir=src/atomic_stores/gnat-13/
    ;;
  gnat-14-plus)
    source_dir=src/atomic_stores/gnat-14-plus/
    ;;
  *)
    printf '%s\n' "unknown compiler family: $compiler_family" >&2
    exit 2
    ;;
esac

check_root_config () {
  config_file=$1
  if ! grep -F "Compiler_Release := \"$compiler_release\";" "$config_file" >/dev/null \
    || ! grep -F "Source_Dir := \"$source_dir\";" "$config_file" >/dev/null
  then
    printf '%s\n' "Flyology selected the wrong atomic-store implementation" >&2
    exit 1
  fi
}

check_root_config "$project_root/config/flyology_atomic_store_config.gpr"
if ! grep -F "Source_Dir := \"$source_dir\";" \
  "$project_root/flyology_allocators/config/flyology_allocators_atomic_store_config.gpr" >/dev/null
then
  printf '%s\n' "flyology_allocators selected the wrong atomic-store implementation" >&2
  exit 1
fi

mkdir -p "$test_root/fake-bin"
mkdir -p "$test_root/allocator-known/scripts"
cp "$project_root/flyology_allocators/scripts/configure-atomic-store-family.sh" \
  "$test_root/allocator-known/scripts/"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$FLYOLOGY_TEST_GCC_VERSION"' \
  >"$test_root/fake-bin/gcc"
chmod +x "$test_root/fake-bin/gcc"
for known_version in 15.0.1 15.1.0; do
  env -u FLYOLOGY_ALLOCATORS_TARGET \
    FLYOLOGY_TEST_GCC_VERSION="$known_version" \
    PATH="$test_root/fake-bin:$PATH" \
    "$test_root/allocator-known/scripts/configure-atomic-store-family.sh"
  known_config="$test_root/allocator-known/config/flyology_allocators_atomic_store_config.gpr"
  if ! grep -F "Compiler_Version := \"$known_version\";" "$known_config" >/dev/null \
    || ! grep -F 'Languages := ("Ada");' "$known_config" >/dev/null \
    || ! grep -F 'Source_Dir := "src/atomic_stores/gnat-14-plus/";' "$known_config" >/dev/null
  then
    printf '%s\n' "flyology_allocators rejected a supported GNAT 15 compiler identity" >&2
    exit 1
  fi
done

if "$project_root/scripts/configure-atomic-store-family.sh" 99.0.0 \
  >"$test_root/root-unknown.log" 2>&1
then
  printf '%s\n' "Flyology accepted an unknown atomic-store compiler family" >&2
  exit 1
fi

if env -u FLYOLOGY_ALLOCATORS_TARGET \
  FLYOLOGY_TEST_GCC_VERSION=99.0.0 \
  PATH="$test_root/fake-bin:$PATH" \
  "$project_root/flyology_allocators/scripts/configure-atomic-store-family.sh" \
  >"$test_root/allocator-unknown.log" 2>&1
then
  printf '%s\n' "flyology_allocators accepted an unknown atomic-store compiler family" >&2
  exit 1
fi
