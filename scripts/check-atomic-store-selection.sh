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
  gnat-13-14)
    source_dir=src/atomic_stores/gnat-13-14/
    allocator_languages='("Ada", "C")'
    ;;
  gnat-15-plus)
    source_dir=src/atomic_stores/gnat-15-plus/
    allocator_languages='("Ada")'
    ;;
  *)
    printf '%s\n' "unknown compiler family: $compiler_family" >&2
    exit 2
    ;;
esac

check_root_config () {
  config_file=$1
  expected_release=$2
  expected_source_dir=$3
  if ! grep -F "Compiler_Release := \"$expected_release\";" "$config_file" >/dev/null \
    || ! grep -F "Source_Dir := \"$expected_source_dir\";" "$config_file" >/dev/null
  then
    printf '%s\n' "Flyology selected the wrong atomic-store implementation" >&2
    exit 1
  fi
}

check_allocator_config () {
  config_file=$1
  expected_version=$2
  expected_source_dir=$3
  expected_languages=$4
  if ! grep -F "Compiler_Version := \"$expected_version\";" "$config_file" >/dev/null \
    || ! grep -F "Languages := $expected_languages;" "$config_file" >/dev/null \
    || ! grep -F "Source_Dir := \"$expected_source_dir\";" "$config_file" >/dev/null
  then
    printf '%s\n' "flyology_allocators selected the wrong atomic-store implementation" >&2
    exit 1
  fi
}

check_root_config \
  "$project_root/config/flyology_atomic_store_config.gpr" \
  "$compiler_release" "$source_dir"
allocator_config="$project_root/flyology_allocators/config/flyology_allocators_atomic_store_config.gpr"
if ! grep -F "Languages := $allocator_languages;" "$allocator_config" >/dev/null \
  || ! grep -F "Source_Dir := \"$source_dir\";" "$allocator_config" >/dev/null
then
  printf '%s\n' "flyology_allocators selected the wrong atomic-store implementation" >&2
  exit 1
fi

case "$test_root" in
  "$project_root"/build/tests/atomic-store-selection) ;;
  *)
    printf '%s\n' "refusing unsafe atomic-store selection test root: $test_root" >&2
    exit 1
    ;;
esac
rm -rf -- "$test_root"
mkdir -p "$test_root/fake-bin"
mkdir -p "$test_root/allocator-known/scripts"
cp "$project_root/flyology_allocators/scripts/configure-atomic-store-family.sh" \
  "$test_root/allocator-known/scripts/"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$FLYOLOGY_TEST_GCC_VERSION"' \
  >"$test_root/fake-bin/gcc"
chmod +x "$test_root/fake-bin/gcc"

for selection in \
  13.2.2:src/atomic_stores/gnat-13-14/ \
  14.1.3:src/atomic_stores/gnat-13-14/ \
  14.2.1:src/atomic_stores/gnat-13-14/ \
  15.1.2:src/atomic_stores/gnat-15-plus/ \
  15.3.1:src/atomic_stores/gnat-15-plus/ \
  16.1.0:src/atomic_stores/gnat-15-plus/ \
  16.2.0:src/atomic_stores/gnat-15-plus/
do
  known_release=${selection%%:*}
  known_source_dir=${selection#*:}
  known_config="$test_root/root-$known_release.gpr"
  "$project_root/scripts/configure-atomic-store-family.sh" \
    "$known_release" >"$known_config"
  check_root_config "$known_config" "$known_release" "$known_source_dir"
done

check_allocator_selection () {
  known_version=$1
  known_source_dir=$2
  known_languages=$3
  env -u FLYOLOGY_ALLOCATORS_TARGET \
    FLYOLOGY_TEST_GCC_VERSION="$known_version" \
    PATH="$test_root/fake-bin:$PATH" \
    "$test_root/allocator-known/scripts/configure-atomic-store-family.sh"
  known_config="$test_root/allocator-known/config/flyology_allocators_atomic_store_config.gpr"
  check_allocator_config \
    "$known_config" "$known_version" "$known_source_dir" "$known_languages"
}

for known_version in 13.2.0 14.1.0 14.2.0; do
  check_allocator_selection \
    "$known_version" src/atomic_stores/gnat-13-14/ '("Ada", "C")'
done
for known_version in 15.0.1 15.1.0 15.3.0 16.1.0 16.2.0; do
  check_allocator_selection \
    "$known_version" src/atomic_stores/gnat-15-plus/ '("Ada")'
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

printf '%s\n' "atomic-store compiler-family selection: PASS"
