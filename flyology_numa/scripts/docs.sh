#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$crate_root/../scripts/find-alr.sh")
website_kit="$project_root/vendor/website-kit"
output_dir=${FLYOLOGY_NUMA_DOCS_OUTPUT:-"$crate_root/docs/api"}

case "$output_dir" in
   "$crate_root/docs/api" | "$project_root/docs/api/flyology_numa") ;;
   *)
      printf '%s\n' "refusing unsafe numa docs path: $output_dir" >&2
      exit 1
      ;;
esac

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

node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-numa-theme.json" \
  "$project_root/docs/gnatdoc-numa/html"
numa_index_template="$project_root/docs/gnatdoc-numa/html/template/index.xhtml"
sed "s|href='../guide/'|href='../../guide/numa/'|" \
  "$numa_index_template" >"$numa_index_template.tmp"
mv "$numa_index_template.tmp" "$numa_index_template"

cd "$crate_root"
"$alr" build
export FLYOLOGY_NUMA_DOCUMENTATION=true
rm -rf "$output_dir"
gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-numa-gnatdoc.XXXXXX")
cleanup () {
   rm -f "$gnatdoc_log"
}
trap cleanup EXIT HUP INT TERM
if ! "$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  --generate=public \
  -P flyology_numa.gpr \
  -O "$output_dir" >"$gnatdoc_log" 2>&1
then
   cat "$gnatdoc_log" >&2
   exit 1
fi
cat "$gnatdoc_log"

if grep -E -q 'warning:' "$gnatdoc_log"
then
   printf '%s\n' "unexpected warning in numa GNATdoc output" >&2
   grep -E 'warning:' "$gnatdoc_log" >&2
   exit 1
fi

mkdir -p "$output_dir/fonts"
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" \
  "$output_dir/fonts/"
cp "$project_root/assets/brand/flyology-mark-transparent.svg" \
  "$output_dir/flyology-mark.svg"
cp "$website_kit/assets/scripts/ada-highlight.js" \
  "$output_dir/ada-highlight.js"
node "$website_kit/scripts/build-api-search-index.mjs" "$output_dir"

test -f "$output_dir/index.html"
test -f "$output_dir/search-index.js"
