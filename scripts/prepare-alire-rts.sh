#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rts_root="$project_root/build/alire-rts"
config_file="$project_root/build/flyology.cgpr"

FLYOLOGY_RTS_DIR="$rts_root" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null

gprconfig \
  --batch \
  --config="ada,,$rts_root" \
  --config=c \
  -o "$config_file"
