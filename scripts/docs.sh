#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

if ! command -v gnatdoc >/dev/null 2>&1; then
   installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
   if [ ! -x "$installed_gnatdoc" ]; then
      printf '%s\n' \
        "gnatdoc not found; install it with: $alr install gnatdoc_bin" >&2
      exit 1
   fi
   PATH=$(dirname "$installed_gnatdoc"):$PATH
   export PATH
fi

cd "$project_root"
"$alr" build --stop-after=generation
export FLYOLOGY_DOCUMENTATION=true
"$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology.gpr \
  -O docs/api

mkdir -p docs/api/fonts
cp website/assets/fonts/geologica-latin-variable.woff2 docs/api/fonts/
cp assets/brand/flyology-mark-transparent.svg docs/api/flyology-mark.svg

test -f docs/api/index.html
