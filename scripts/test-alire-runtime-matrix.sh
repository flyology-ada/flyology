#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for toolchain in \
  13.2.2:25.0.1 \
  14.1.3:25.0.1 \
  14.2.1:25.0.1 \
  15.1.2:25.0.1 \
  15.3.1:25.0.1 \
  16.1.0:26.0.1
do
  gnat_version=${toolchain%%:*}
  gprbuild_version=${toolchain#*:}
  printf '\nTesting Linux GNAT %s with GPRbuild %s\n' \
    "$gnat_version" "$gprbuild_version"
  FLYOLOGY_LINUX_IMAGE="flyology-linux-test-$gnat_version" \
  FLYOLOGY_GNAT_VERSION="$gnat_version" \
  FLYOLOGY_GPRBUILD_VERSION="$gprbuild_version" \
    "$project_root/scripts/test-linux-docker.sh"
done
