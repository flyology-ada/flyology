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
keep_image=${FLYOLOGY_KEEP_LINUX_IMAGE:-0}
case "$keep_image" in
  0|1)
    ;;
  *)
    printf '%s\n' "FLYOLOGY_KEEP_LINUX_IMAGE must be 0 or 1" >&2
    exit 1
    ;;
esac

image_built=0
cleanup_image() {
  exit_status=$?
  trap - EXIT

  if [ "$image_built" -eq 1 ]; then
    if [ "$keep_image" -eq 1 ]; then
      printf 'Retaining Docker test image %s\n' "$image"
    else
      printf 'Removing Docker test image %s\n' "$image"
      if ! docker image rm "$image" >/dev/null; then
        printf 'warning: could not remove Docker test image %s\n' \
          "$image" >&2
      fi
    fi
  fi

  exit "$exit_status"
}
trap cleanup_image EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

docker build \
  --platform "linux/$linux_arch" \
  --build-arg "GNAT_VERSION=$gnat_version" \
  --build-arg "GPRBUILD_VERSION=$gprbuild_version" \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$image" \
  "$project_root"
image_built=1

docker run --rm \
  --platform "linux/$linux_arch" \
  --env FLYOLOGY_TEST_DENY_IO_URING=1 \
  --env FLYOLOGY_EXPECT_FILE_BACKEND=native-aio \
  "$image"
