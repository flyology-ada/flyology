#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: check-shared-image-index-native.sh OBJECT" >&2
  exit 2
fi

symbols=$(nm -g "$1" | awk '
  /_?flyology_showcase_/ && $(NF - 1) != "U" {
    name=$NF
    sub(/^_/, "", name)
    print name
  }
' | sort -u)

expected='flyology_showcase_image_socketpair
flyology_showcase_poll_image_worker
flyology_showcase_spawn_image_worker'

if [ "$symbols" != "$expected" ]; then
  printf '%s\n' "unexpected shared-image-index C boundary:" >&2
  printf '%s\n' "$symbols" >&2
  exit 1
fi
