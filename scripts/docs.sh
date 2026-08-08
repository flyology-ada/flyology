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
node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-bench-theme.json" \
  "$project_root/docs/gnatdoc-bench/html"
bench_index_template="$project_root/docs/gnatdoc-bench/html/template/index.xhtml"
sed "s|href='../guide/'|href='../../guide/benchmarking/'|" \
  "$bench_index_template" >"$bench_index_template.tmp"
mv "$bench_index_template.tmp" "$bench_index_template"

runtime_gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-gnatdoc.XXXXXX")
bench_gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-bench-gnatdoc.XXXXXX")
cleanup () {
   rm -f "$runtime_gnatdoc_log" "$bench_gnatdoc_log"
}
trap cleanup EXIT HUP INT TERM

export FLYOLOGY_DOCUMENTATION=true
if ! "$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology.gpr \
  -O docs/api >"$runtime_gnatdoc_log" 2>&1
then
   cat "$runtime_gnatdoc_log" >&2
   exit 1
fi
cat "$runtime_gnatdoc_log"

(
   cd "$project_root/flyology_bench"
   "$alr" build --stop-after=generation
   #  A generation-only Alire build does not create the project directories
   #  that GNATdoc expects when it loads the library project. Fresh Pages
   #  runners therefore need the ignored directories explicitly.
   mkdir -p obj lib
   if ! "$alr" exec -- gnatdoc \
     --backend=html \
     --warnings \
     --style=leading \
     -P flyology_bench.gpr \
     -O "$project_root/docs/api/flyology_bench" \
     >"$bench_gnatdoc_log" 2>&1
   then
      cat "$bench_gnatdoc_log" >&2
      exit 1
   fi
   #  GNATdoc 26.0 does not associate leading comments with formals of nested
   #  generic subprograms. Their adjacent source comments and names still
   #  render, but --warnings reports the formals as undocumented. Keep this
   #  exception narrow; every other public benchmark entity remains enforced.
   sed -E \
     '/^flyology_bench(-reporters)?\.ads:[0-9]+:[0-9]+: warning: generic formal `[^`]+` is not documented$/d' \
     "$bench_gnatdoc_log"
)

if grep -E -q 'warning: .*not documented' "$runtime_gnatdoc_log"
then
   printf '%s\n' "undocumented public API entity in GNATdoc output" >&2
   exit 1
fi

if grep -E 'warning:' "$bench_gnatdoc_log" \
  | grep -E -v -q \
    '^flyology_bench(-reporters)?\.ads:[0-9]+:[0-9]+: warning: generic formal `[^`]+` is not documented$'
then
   printf '%s\n' "unexpected warning in benchmark GNATdoc output" >&2
   grep -E 'warning:' "$bench_gnatdoc_log" \
     | grep -E -v \
       '^flyology_bench(-reporters)?\.ads:[0-9]+:[0-9]+: warning: generic formal `[^`]+` is not documented$' >&2
   exit 1
fi

#  GNATdoc accepts a qualified @exception name without a warning, but this
#  version renders only the first selector as the exception name and moves the
#  remaining selectors into a description beginning with a dot.
if grep -E -R -q --include='*.html' \
  '<dt data-search-kind=Exception>[^<]+<dd><p>\.' docs/api
then
   printf '%s\n' \
     "malformed qualified exception annotation in generated API docs" >&2
   exit 1
fi

mkdir -p docs/api/fonts
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" docs/api/fonts/
cp assets/brand/flyology-mark-transparent.svg docs/api/flyology-mark.svg
cp "$website_kit/assets/scripts/ada-highlight.js" docs/api/ada-highlight.js
mkdir -p docs/api/flyology_bench/fonts
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" \
  docs/api/flyology_bench/fonts/
cp assets/brand/flyology-mark-transparent.svg \
  docs/api/flyology_bench/flyology-mark.svg
cp "$website_kit/assets/scripts/ada-highlight.js" \
  docs/api/flyology_bench/ada-highlight.js
node "$website_kit/scripts/build-api-search-index.mjs" \
  docs/api/flyology_bench
node "$website_kit/scripts/build-api-search-index.mjs" docs/api

test -f docs/api/index.html
test -f docs/api/search-index.js
test -f docs/api/flyology_bench/index.html
test -f docs/api/flyology_bench/search-index.js
