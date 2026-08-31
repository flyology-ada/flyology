#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../../.." && pwd)
linux_arch=${FLYOLOGY_RUST_LINUX_ARCH:-arm64}
base_image=${FLYOLOGY_RUST_LINUX_BASE_IMAGE:-flyology-rust-linux-base-$linux_arch}
image=${FLYOLOGY_RUST_LINUX_IMAGE:-flyology-rust-linux-$linux_arch}
keep_images=${FLYOLOGY_KEEP_RUST_LINUX_IMAGES:-0}

case "$linux_arch" in
  arm64|amd64)
    ;;
  *)
    printf '%s\n' "FLYOLOGY_RUST_LINUX_ARCH must be arm64 or amd64" >&2
    exit 1
    ;;
esac

case "$keep_images" in
  0|1)
    ;;
  *)
    printf '%s\n' "FLYOLOGY_KEEP_RUST_LINUX_IMAGES must be 0 or 1" >&2
    exit 1
    ;;
esac

base_built=0
image_built=0
cleanup () {
  exit_status=$?
  trap - EXIT
  if [ "$keep_images" -eq 0 ]; then
    if [ "$image_built" -eq 1 ]; then
      docker image rm "$image" >/dev/null 2>&1 || true
    fi
    if [ "$base_built" -eq 1 ]; then
      docker image rm "$base_image" >/dev/null 2>&1 || true
    fi
  else
    printf 'Retaining Docker images %s and %s\n' "$base_image" "$image"
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

docker build \
  --platform "linux/$linux_arch" \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$base_image" \
  "$project_root"
base_built=1

docker build \
  --platform "linux/$linux_arch" \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg RUST_VERSION=1.97.1 \
  -f "$spike_root/Dockerfile" \
  -t "$image" \
  "$project_root"
image_built=1

docker run --rm --platform "linux/$linux_arch" "$image"
