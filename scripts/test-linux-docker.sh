#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
gnat_version=${GNATEVL_GNAT_VERSION:-16.1.0}
gprbuild_version=${GNATEVL_GPRBUILD_VERSION:-26.0.1}
case "${GNATEVL_LINUX_ARCH:-$(uname -m)}" in
  arm64|aarch64)
    linux_arch=arm64
    ;;
  amd64|x86_64)
    linux_arch=amd64
    ;;
  *)
    printf '%s\n' \
      "GNATEVL_LINUX_ARCH must be arm64/aarch64 or amd64/x86_64" >&2
    exit 1
    ;;
esac
image=${GNATEVL_LINUX_IMAGE:-gnatevl-linux-test-$linux_arch}

docker build \
  --platform "linux/$linux_arch" \
  --build-arg "GNAT_VERSION=$gnat_version" \
  --build-arg "GPRBUILD_VERSION=$gprbuild_version" \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$image" \
  "$project_root"

docker run --rm \
  --platform "linux/$linux_arch" \
  --env GNATEVL_TEST_DENY_IO_URING=1 \
  --env GNATEVL_EXPECT_FILE_BACKEND=native-aio \
  "$image"
