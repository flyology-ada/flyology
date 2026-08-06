#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
website_kit="$project_root/vendor/website-kit"

if [ ! -f "$website_kit/scripts/render-gnatdoc-theme.mjs" ]; then
   printf '%s\n' \
     "website kit is unavailable; run: git submodule update --init" >&2
   exit 1
fi

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
node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-theme.json" \
  "$project_root/docs/gnatdoc/html"
export FLYOLOGY_DOCUMENTATION=true
"$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology.gpr \
  -O docs/api

#  GNATdoc accepts a qualified @exception name without a warning, but this
#  version renders only the first selector as the exception name and moves the
#  remaining selectors into a description beginning with a dot.
if grep -E -q \
  '<dt data-search-kind=Exception>[^<]+<dd><p>\.' docs/api/*.html
then
   printf '%s\n' \
     "malformed qualified exception annotation in generated API docs" >&2
   exit 1
fi

mkdir -p docs/api/fonts
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" docs/api/fonts/
cp assets/brand/flyology-mark-transparent.svg docs/api/flyology-mark.svg
cp "$website_kit/assets/scripts/ada-highlight.js" docs/api/ada-highlight.js
node "$website_kit/scripts/build-api-search-index.mjs" docs/api

test -f docs/api/index.html
test -f docs/api/search-index.js
