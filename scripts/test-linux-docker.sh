#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
gnat_provider=${FLYOLOGY_GNAT_PROVIDER:-gnat_flyology_native}
gnat_version=${FLYOLOGY_GNAT_VERSION:-16.2.0-patchset.1.1.0}
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
require_perf=${FLYOLOGY_LINUX_PERF:-0}
case "$keep_image" in
  0|1)
    ;;
  *)
    printf '%s\n' "FLYOLOGY_KEEP_LINUX_IMAGE must be 0 or 1" >&2
    exit 1
    ;;
esac
case "$require_perf" in
  0|1)
    ;;
  *)
    printf '%s\n' "FLYOLOGY_LINUX_PERF must be 0 or 1" >&2
    exit 1
    ;;
esac

image_built=0
container_created=0
container_id=
cleanup_image() {
  exit_status=$?
  trap - EXIT

  if [ "$container_created" -eq 1 ]; then
    cleanup_attempt=0
    while docker container inspect "$container_id" >/dev/null 2>&1; do
      cleanup_attempt=$((cleanup_attempt + 1))
      if [ "$cleanup_attempt" -gt 10 ]; then
        printf 'warning: could not remove Docker test container %s\n' \
          "$container_id" >&2
        break
      fi
      docker container rm --force "$container_id" >/dev/null 2>&1 || true
      sleep 1
    done
  fi

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
  --build-arg "GNAT_PROVIDER=$gnat_provider" \
  --build-arg "GNAT_VERSION=$gnat_version" \
  --build-arg "GPRBUILD_VERSION=$gprbuild_version" \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$image" \
  "$project_root"
image_built=1

if [ "$require_perf" -eq 1 ]; then
  # CAP_PERFMON lets the container open hardware counters, and
  # FLYOLOGY_BENCH_REQUIRE_PERF makes the crate's smoke test insist that the
  # counters are collected and that inherited worker-task work is counted.
  # A host whose hypervisor exposes no PMU fails here rather than reporting
  # unavailable counters as a pass.
  container_id=$(docker container create \
    --platform "linux/$linux_arch" \
    --cap-add PERFMON \
    --env FLYOLOGY_TEST_DENY_IO_URING=1 \
    --env FLYOLOGY_EXPECT_FILE_BACKEND=native-aio \
    --env FLYOLOGY_BENCH_REQUIRE_PERF=1 \
    "$image" \
    sh -c 'cd flyology_debug && alr --non-interactive test && cd ../flyology_bench && alr --non-interactive test && ./examples/bin/basic --metrics=perf --require-perf && cd .. && ./scripts/test.sh')
else
  container_id=$(docker container create \
    --platform "linux/$linux_arch" \
    --env FLYOLOGY_TEST_DENY_IO_URING=1 \
    --env FLYOLOGY_EXPECT_FILE_BACKEND=native-aio \
    "$image")
fi
container_created=1
docker container start --attach "$container_id"
