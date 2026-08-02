#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${GNATEVL_LINUX_IMAGE:-gnatevl-linux-test}
gnat_version=${GNATEVL_GNAT_VERSION:-16.1.0}
gprbuild_version=${GNATEVL_GPRBUILD_VERSION:-26.0.1}

docker build \
  --platform linux/amd64 \
  --build-arg "GNAT_VERSION=$gnat_version" \
  --build-arg "GPRBUILD_VERSION=$gprbuild_version" \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$image" \
  "$project_root"

docker run --rm --platform linux/amd64 "$image"
