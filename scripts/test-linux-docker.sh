#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
gnat_version=${FLYOLOGY_GNAT_VERSION:-16.1.0}
gprbuild_version=${FLYOLOGY_GPRBUILD_VERSION:-26.0.1}
case "${FLYOLOGY_LINUX_ARCH:-$(uname -m)}" in
  arm64|aarch64)
    linux_arch=arm64
    ;;
  amd64|x86_64)
    linux_arch=amd64
    ;;
  *)
    printf '%s\n' \
      "FLYOLOGY_LINUX_ARCH must be arm64/aarch64 or amd64/x86_64" >&2
    exit 1
    ;;
esac
image=${FLYOLOGY_LINUX_IMAGE:-flyology-linux-test-$linux_arch}

docker build \
  --platform "linux/$linux_arch" \
  --build-arg "GNAT_VERSION=$gnat_version" \
  --build-arg "GPRBUILD_VERSION=$gprbuild_version" \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$image" \
  "$project_root"

docker run --rm \
  --platform "linux/$linux_arch" \
  --env FLYOLOGY_TEST_DENY_IO_URING=1 \
  --env FLYOLOGY_EXPECT_FILE_BACKEND=native-aio \
  "$image"
