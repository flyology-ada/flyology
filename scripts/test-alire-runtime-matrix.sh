#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
matrix_file=${FLYOLOGY_TEST_ALIRE_RUNTIME_MATRIX_FILE:-"$project_root/scripts/alire-runtime-matrix.txt"}

case "${FLYOLOGY_LINUX_ARCH:-$(uname -m)}" in
  arm64|aarch64)
    linux_arch=arm64
    architecture_names=arm64/aarch64
    ;;
  amd64|x86_64)
    linux_arch=amd64
    architecture_names=amd64/x86_64
    ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_LINUX_ARCH must be arm64/aarch64 or amd64/x86_64" >&2
    exit 1
    ;;
esac

matrix_run_id=$(date -u +%Y%m%d%H%M%S)-$$
matrix_line_number=0
matrix_cell_count=0

invalid_matrix_record () {
  printf 'invalid runtime matrix record at %s:%s; %s\n' \
    "$matrix_file" "$matrix_line_number" \
    "expected provider:GNAT-release:GPRbuild-release:architectures" >&2
  exit 1
}

while IFS= read -r matrix_record || [ -n "$matrix_record" ]
do
  matrix_line_number=$((matrix_line_number + 1))
  trimmed_record=$matrix_record
  while :
  do
    case "$trimmed_record" in
      [[:space:]]*)
        trimmed_record=${trimmed_record#?}
        ;;
      *)
        break
        ;;
    esac
  done
  case "$trimmed_record" in
    ''|'#'*)
      continue
      ;;
  esac

  case "$matrix_record" in
    *:*)
      gnat_provider=${matrix_record%%:*}
      matrix_fields=${matrix_record#*:}
      ;;
    *)
      invalid_matrix_record
      ;;
  esac
  case "$matrix_fields" in
    *:*)
      gnat_version=${matrix_fields%%:*}
      matrix_fields=${matrix_fields#*:}
      ;;
    *)
      invalid_matrix_record
      ;;
  esac
  case "$matrix_fields" in
    *:*)
      gprbuild_version=${matrix_fields%%:*}
      architectures=${matrix_fields#*:}
      ;;
    *)
      invalid_matrix_record
      ;;
  esac
  case "$architectures" in
    *:*)
      invalid_matrix_record
      ;;
  esac
  case "$gnat_provider" in
    gnat_native|gnat_flyology_native)
      ;;
    *)
      invalid_matrix_record
      ;;
  esac
  case "$gnat_version:$gprbuild_version" in
    *[!0-9A-Za-z._:-]*|:*|*:)
      invalid_matrix_record
      ;;
  esac
  if [ -z "$architectures" ]; then
    invalid_matrix_record
  fi
  case "$architectures" in
    amd64)
      available_architecture=amd64
      ;;
    amd64,arm64)
      available_architecture=$linux_arch
      ;;
    *)
      printf 'invalid architecture availability for %s %s: %s\n' \
        "$gnat_provider" "$gnat_version" "$architectures" >&2
      exit 1
      ;;
  esac
  matrix_cell_count=$((matrix_cell_count + 1))

  if [ "$available_architecture" != "$linux_arch" ]; then
    printf 'Skipping Linux %s %s with GPRbuild %s: not published for %s\n' \
      "$gnat_provider" "$gnat_version" "$gprbuild_version" \
      "$architecture_names"
    continue
  fi

  printf '\nTesting Linux %s %s with GPRbuild %s\n' \
    "$gnat_provider" "$gnat_version" "$gprbuild_version"
  image_tag="$linux_arch-$gnat_provider-$gnat_version-$matrix_run_id"
  FLYOLOGY_LINUX_IMAGE="flyology-linux-test:$image_tag" \
  FLYOLOGY_LINUX_ARCH="$linux_arch" \
  FLYOLOGY_GNAT_PROVIDER="$gnat_provider" \
  FLYOLOGY_GNAT_VERSION="$gnat_version" \
  FLYOLOGY_GPRBUILD_VERSION="$gprbuild_version" \
    "$project_root/scripts/test-linux-docker.sh"
done <"$matrix_file"

if [ "$matrix_cell_count" -eq 0 ]; then
  printf 'runtime matrix contains no cells: %s\n' "$matrix_file" >&2
  exit 1
fi
