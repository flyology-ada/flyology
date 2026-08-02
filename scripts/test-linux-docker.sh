#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${GNATEVL_LINUX_IMAGE:-gnatevl-linux-test}

docker build \
  --platform linux/amd64 \
  -f "$project_root/docker/linux/Dockerfile" \
  -t "$image" \
  "$project_root"

docker run --rm --platform linux/amd64 "$image"
