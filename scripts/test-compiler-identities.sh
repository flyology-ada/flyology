#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-compiler-identities.XXXXXX")

cleanup () {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

make_compiler_prefix () {
  compiler_package=$1
  compiler_prefix="$test_root/$compiler_package"
  mkdir -p "$compiler_prefix/bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$compiler_prefix/bin/gcc"
  chmod +x "$compiler_prefix/bin/gcc"
  printf '%s\n' "$compiler_prefix"
}

expect_rejection () {
  label=$1
  shift
  if "$@" >"$test_root/$label.log" 2>&1; then
    printf '%s\n' "unsupported compiler selection was accepted: $label" >&2
    exit 1
  fi
}

for identity in gnat_native gnat_flyology_native; do
  for release in 13.2.2 14.1.3 14.2.1 15.1.2 15.3.1 16.1.0; do
    compiler_prefix=$(make_compiler_prefix "${identity}_${release}_test")
    case "$identity" in
      gnat_native)
        selected_prefix=$(env -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
          GNAT_NATIVE_ALIRE_PREFIX="$compiler_prefix" \
          "$project_root/scripts/gnat-native-prefix.sh")
        selected_release=$(env -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
          GNAT_NATIVE_ALIRE_PREFIX="$compiler_prefix" \
          "$project_root/scripts/gnat-native-release.sh")
        ;;
      gnat_flyology_native)
        selected_prefix=$(env -u GNAT_NATIVE_ALIRE_PREFIX \
          GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="$compiler_prefix" \
          "$project_root/scripts/gnat-native-prefix.sh")
        selected_release=$(env -u GNAT_NATIVE_ALIRE_PREFIX \
          GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="$compiler_prefix" \
          "$project_root/scripts/gnat-native-release.sh")
        ;;
    esac
    if [ "$selected_prefix" != "$compiler_prefix" ] \
      || [ "$selected_release" != "$release" ]; then
      printf '%s\n' \
        "compiler identity did not resolve exactly: $identity $release" >&2
      exit 1
    fi
  done
done

native_prefix=$(make_compiler_prefix gnat_native_16.1.0_native)
flyology_prefix=$(make_compiler_prefix \
  gnat_flyology_native_16.1.0_flyology)
selected_prefix=$(GNAT_NATIVE_ALIRE_PREFIX="$flyology_prefix" \
  GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="$flyology_prefix" \
  "$project_root/scripts/gnat-native-prefix.sh")
if [ "$selected_prefix" != "$flyology_prefix" ]; then
  printf '%s\n' "matching compiler aliases did not resolve exactly" >&2
  exit 1
fi
expect_rejection ambiguous env \
  GNAT_NATIVE_ALIRE_PREFIX="$native_prefix" \
  GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="$flyology_prefix" \
  "$project_root/scripts/gnat-native-prefix.sh"

unsupported_release=$(make_compiler_prefix \
  gnat_flyology_native_15.2.0_unknown)
expect_rejection unsupported-release env -u GNAT_NATIVE_ALIRE_PREFIX \
  GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="$unsupported_release" \
  "$project_root/scripts/gnat-native-release.sh"

unsupported_identity=$(make_compiler_prefix gnat_cross_16.1.0_unknown)
expect_rejection unsupported-identity env -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
  GNAT_NATIVE_ALIRE_PREFIX="$unsupported_identity" \
  "$project_root/scripts/gnat-native-prefix.sh"

empty_package_suffix=$(make_compiler_prefix gnat_flyology_native_16.1.0_)
expect_rejection empty-package-suffix env -u GNAT_NATIVE_ALIRE_PREFIX \
  GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="$empty_package_suffix" \
  "$project_root/scripts/gnat-native-release.sh"

fake_alr="$test_root/alr-flyology"
printf '%s\n' \
  '#!/bin/sh' \
  'printf '\''export GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="%s"\n'\'' "$FAKE_COMPILER_PREFIX"' \
  >"$fake_alr"
chmod +x "$fake_alr"
selected_prefix=$(env -u GNAT_NATIVE_ALIRE_PREFIX \
  -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
  FAKE_COMPILER_PREFIX="$flyology_prefix" \
  "$project_root/scripts/gnat-native-prefix.sh" "$fake_alr")
if [ "$selected_prefix" != "$flyology_prefix" ]; then
  printf '%s\n' \
    "Alire printenv did not resolve gnat_flyology_native exactly" >&2
  exit 1
fi

fake_alr="$test_root/alr-native"
printf '%s\n' \
  '#!/bin/sh' \
  'printf '\''export GNAT_NATIVE_ALIRE_PREFIX="%s"\n'\'' "$FAKE_COMPILER_PREFIX"' \
  >"$fake_alr"
chmod +x "$fake_alr"
selected_prefix=$(env -u GNAT_NATIVE_ALIRE_PREFIX \
  -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
  FAKE_COMPILER_PREFIX="$native_prefix" \
  "$project_root/scripts/gnat-native-prefix.sh" "$fake_alr")
if [ "$selected_prefix" != "$native_prefix" ]; then
  printf '%s\n' "Alire printenv did not resolve gnat_native exactly" >&2
  exit 1
fi

gprbuild_prefix="$test_root/gprbuild_26.0.0_test"
mkdir -p "$gprbuild_prefix/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$gprbuild_prefix/bin/gprconfig"
chmod +x "$gprbuild_prefix/bin/gprconfig"

fake_alr="$test_root/alr-clean-environment"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ -n "${FLYOLOGY_ROOT+x}" ] || [ -n "${GPR_CONFIG+x}" ] || [ -n "${FLYOLOGY_ALIRE_PREFIX+x}" ]; then' \
  '  printf "%s\n" "recursive Alire inherited Flyology dependency environment" >&2' \
  '  exit 91' \
  'fi' \
  'printf '\''export GNAT_NATIVE_ALIRE_PREFIX="%s"\n'\'' "$FAKE_COMPILER_PREFIX"' \
  'printf '\''export GPRBUILD_ALIRE_PREFIX="%s"\n'\'' "$FAKE_GPRBUILD_PREFIX"' \
  >"$fake_alr"
chmod +x "$fake_alr"

selected_prefix=$(env -u GNAT_NATIVE_ALIRE_PREFIX \
  -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
  FLYOLOGY_ROOT=/stale/flyology \
  GPR_CONFIG=/stale/flyology/build/flyology.cgpr \
  FLYOLOGY_ALIRE_PREFIX=/stale/flyology \
  FAKE_COMPILER_PREFIX="$native_prefix" \
  FAKE_GPRBUILD_PREFIX="$gprbuild_prefix" \
  "$project_root/scripts/gnat-native-prefix.sh" "$fake_alr")
if [ "$selected_prefix" != "$native_prefix" ]; then
  printf '%s\n' \
    "compiler discovery did not isolate recursive Alire environment" >&2
  exit 1
fi

selected_prefix=$(env \
  FLYOLOGY_ROOT=/stale/flyology \
  GPR_CONFIG=/stale/flyology/build/flyology.cgpr \
  FLYOLOGY_ALIRE_PREFIX=/stale/flyology \
  FAKE_COMPILER_PREFIX="$native_prefix" \
  FAKE_GPRBUILD_PREFIX="$gprbuild_prefix" \
  "$project_root/scripts/gprbuild-prefix.sh" "$fake_alr")
if [ "$selected_prefix" != "$gprbuild_prefix" ]; then
  printf '%s\n' \
    "GPRbuild discovery did not isolate recursive Alire environment" >&2
  exit 1
fi
