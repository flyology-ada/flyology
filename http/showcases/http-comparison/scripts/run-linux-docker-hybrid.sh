#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$comparison_root/../.." && pwd)
case "${FLYOLOGY_HTTP_BENCH_ARCH:-$(uname -m)}" in
   arm64|aarch64) linux_arch=arm64 ;;
   amd64|x86_64) linux_arch=amd64 ;;
   *) printf '%s\n' "unsupported Docker architecture" >&2; exit 2 ;;
esac
image=${FLYOLOGY_HTTP_BENCH_IMAGE:-flyology-http-hybrid-$linux_arch}
keep_image=${FLYOLOGY_HTTP_BENCH_KEEP_IMAGE:-0}
loops=${HTTP_BENCH_LOOPS:-8}
output_root="$project_root/build/http-comparison/docker-hybrid-results"
git_revision=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || printf '%s' unavailable)
if [ -n "$(git -C "$project_root" status --porcelain 2>/dev/null)" ]; then
   git_dirty=1
else
   git_dirty=0
fi

case "$keep_image" in 0|1) ;; *) printf '%s\n' "FLYOLOGY_HTTP_BENCH_KEEP_IMAGE must be 0 or 1" >&2; exit 2 ;; esac
mkdir -p "$output_root"

image_built=0
cleanup () {
   status=$?
   trap - EXIT
   if [ "$image_built" -eq 1 ] && [ "$keep_image" -eq 0 ]; then
      docker image rm "$image" >/dev/null 2>&1 || true
   fi
   exit "$status"
}
trap cleanup EXIT HUP INT TERM

docker build \
   --platform "linux/$linux_arch" \
   --build-arg "FLYOLOGY_GIT_REVISION=$git_revision" \
   --build-arg "FLYOLOGY_GIT_DIRTY=$git_dirty" \
   --build-arg "HTTP_BENCH_LOOPS=$loops" \
   -f "$comparison_root/docker/Dockerfile" \
   -t "$image" \
   "$project_root"
image_built=1

docker run --rm \
   --platform "linux/$linux_arch" \
   --volume "$output_root:/results" \
   --env HTTP_BENCH_CLIENT_CPUSET \
   --env HTTP_BENCH_SERVER_CPUSET \
   --env HTTP_HYBRID_CONCURRENCIES \
   --env HTTP_HYBRID_COOLDOWN \
   --env HTTP_HYBRID_DURATION \
   --env HTTP_HYBRID_HANDLER_CAPACITY \
   --env HTTP_HYBRID_MIXED \
   --env HTTP_HYBRID_MIXED_CONTROL_CONCURRENCY \
   --env HTTP_HYBRID_MIXED_CPU_CONCURRENCY \
   --env HTTP_HYBRID_QUEUE_CAPACITY \
   --env HTTP_HYBRID_TARGETS_US \
   --env HTTP_HYBRID_TRIALS \
   --env HTTP_HYBRID_VERIFY_ONLY \
   --env HTTP_HYBRID_WARMUP \
   --env HTTP_HYBRID_WORKERS \
   --env "HTTP_BENCH_LOOPS=$loops" \
   --env HTTP_BENCH_MODE=hybrid-docker-loopback \
   --env HTTP_HYBRID_OUTPUT_ROOT=/results \
   "$image" ./showcases/http-comparison/scripts/run_hybrid.sh

printf '%s\n' "Docker hybrid results are under $output_root"
