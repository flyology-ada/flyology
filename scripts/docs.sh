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
node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-debug-theme.json" \
  "$project_root/docs/gnatdoc-debug/html"
debug_index_template="$project_root/docs/gnatdoc-debug/html/template/index.xhtml"
sed "s|href='../guide/'|href='../../guide/'|" \
  "$debug_index_template" >"$debug_index_template.tmp"
mv "$debug_index_template.tmp" "$debug_index_template"
bench_index_template="$project_root/docs/gnatdoc-bench/html/template/index.xhtml"
sed "s|href='../guide/'|href='../../guide/benchmarking/'|" \
  "$bench_index_template" >"$bench_index_template.tmp"
mv "$bench_index_template.tmp" "$bench_index_template"

runtime_gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-gnatdoc.XXXXXX")
bench_gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-bench-gnatdoc.XXXXXX")
debug_gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-debug-gnatdoc.XXXXXX")
cleanup () {
   rm -f "$runtime_gnatdoc_log" "$bench_gnatdoc_log" "$debug_gnatdoc_log"
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

#  GNATdoc updates its destination in place and does not remove pages for
#  units that leave the documented source set. Recreate this generated-only
#  subtree so an internal or renamed unit cannot survive into Pages or search.
rm -rf "$project_root/docs/api/flyology_bench"

(
   cd "$project_root/flyology_debug"
   "$alr" build --stop-after=generation
   mkdir -p obj/docs
   if ! "$alr" exec -- gnatdoc \
     --backend=html \
     --generate=public \
     --warnings \
     --style=leading \
     -P flyology_debug_docs.gpr \
     -O "$project_root/docs/api/flyology_debug" \
     >"$debug_gnatdoc_log" 2>&1
   then
      cat "$debug_gnatdoc_log" >&2
      exit 1
   fi
   #  GNATdoc 26.0 reports documented formals on these child generics as
   #  undocumented. Their exact @formal comments and names still render.
   sed -E \
     '/^flyology_debug-(gauges|tracers)\.ads:[0-9]+:[0-9]+: warning: generic formal `(Message_Type|Gauge_Kind|Gauge_Value_Type|Capacity|Overflow|Now|Producer_Count|Select_Producer)` is not documented$/d' \
     "$debug_gnatdoc_log"
)

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
     -P flyology_bench_docs.gpr \
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
     -e '/^flyology_bench(-reporters|-sweeps)?\.ads:[0-9]+:[0-9]+: warning: generic formal `[^`]+` is not documented$/d' \
     "$bench_gnatdoc_log"
)

#  GNATdoc 26.0 does not associate leading comments with the formal callback
#  of a nested generic subprogram or with the formals of Elements and the
#  allocation-algorithm Contract, whose formal types contribute to later
#  formal subprogram profiles. It likewise misses the documented formals of
#  the Process_Generations.Agents child generic. The source comments and
#  entities still render.
#  Keep these exceptions to exact units and names and continue enforcing every
#  other runtime warning.
runtime_documentation_warnings=$(mktemp \
  "${TMPDIR:-/tmp}/flyology-runtime-gnatdoc-warnings.XXXXXX")
sed -E \
  -e '/^flyology-data_structures-vectors\.ads:[0-9]+:[0-9]+: warning: generic formal `Process` is not documented$/d' \
  -e '/^flyology-data_structures-storage_types-elements\.ads:[0-9]+:[0-9]+: warning: generic formal `(Representation|Source_Type|Observed_Type|Create_Value|Observe_Value|Direct_Constructor)` is not documented$/d' \
  -e '/^flyology-data_structures-allocation_algorithms-contract\.ads:[0-9]+:[0-9]+: warning: generic formal `(Algorithm_Identity|Algorithm_Minimum_Block_Limit|Algorithm_Capabilities|Algorithm_Configuration|Algorithm_View|Implementation_Required_Storage|Implementation_Initialize|Implementation_Create_Or_Attach|Implementation_Attach|Implementation_Detach|Implementation_Is_Attached|Implementation_Current_Metadata|Implementation_Is_Poisoned|Implementation_Poison|Implementation_Try_Allocate_Immediate|Implementation_Try_Allocate_Timed|Implementation_Release_Immediate|Implementation_Release_Timed|Implementation_Block_Capacity|Implementation_Attach_Allocation|Implementation_Bind_Allocation|Implementation_Read|Implementation_Write|Implementation_Copy|Implementation_Destroy)` is not documented$/d' \
  -e '/^flyology-process_generations-agents\.ads:[0-9]+:[0-9]+: warning: generic formal `(Application_Context|Prepare|Run_Server|Ready|Request_Stop|Promoted|Compensate)` is not documented$/d' \
  "$runtime_gnatdoc_log" >"$runtime_documentation_warnings"
if grep -E -q 'warning: .*not documented' "$runtime_documentation_warnings"
then
   printf '%s\n' "undocumented public API entity in GNATdoc output" >&2
   rm -f "$runtime_documentation_warnings"
   exit 1
fi
rm -f "$runtime_documentation_warnings"

if grep -E 'warning:' "$bench_gnatdoc_log" \
  | grep -E -v -q \
    '^flyology_bench(-reporters|-sweeps)?\.ads:[0-9]+:[0-9]+: warning: generic formal `[^`]+` is not documented$'
then
   printf '%s\n' "unexpected warning in benchmark GNATdoc output" >&2
   grep -E 'warning:' "$bench_gnatdoc_log" \
     | grep -E -v \
       '^flyology_bench(-reporters|-sweeps)?\.ads:[0-9]+:[0-9]+: warning: generic formal `[^`]+` is not documented$' >&2
   exit 1
fi

if grep -E 'warning:' "$debug_gnatdoc_log" \
  | grep -E -v -q \
    '^flyology_debug-(gauges|tracers)\.ads:[0-9]+:[0-9]+: warning: generic formal `(Message_Type|Gauge_Kind|Gauge_Value_Type|Capacity|Overflow|Now|Producer_Count|Select_Producer)` is not documented$'
then
   printf '%s\n' "unexpected warning in debug GNATdoc output" >&2
   grep -E 'warning:' "$debug_gnatdoc_log" \
     | grep -E -v \
       '^flyology_debug-(gauges|tracers)\.ads:[0-9]+:[0-9]+: warning: generic formal `(Message_Type|Gauge_Kind|Gauge_Value_Type|Capacity|Overflow|Now|Producer_Count|Select_Producer)` is not documented$' >&2
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

FLYOLOGY_CACHELINES_DOCS_OUTPUT="$project_root/docs/api/flyology_cachelines" \
  "$project_root/flyology_cachelines/scripts/docs.sh"

FLYOLOGY_NUMA_DOCS_OUTPUT="$project_root/docs/api/flyology_numa" \
  "$project_root/flyology_numa/scripts/docs.sh"

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
mkdir -p docs/api/flyology_debug/fonts
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" \
  docs/api/flyology_debug/fonts/
cp assets/brand/flyology-mark-transparent.svg \
  docs/api/flyology_debug/flyology-mark.svg
cp "$website_kit/assets/scripts/ada-highlight.js" \
  docs/api/flyology_debug/ada-highlight.js
node "$website_kit/scripts/build-api-search-index.mjs" \
  docs/api/flyology_debug
node "$website_kit/scripts/build-api-search-index.mjs" docs/api

test -f docs/api/index.html
test -f docs/api/search-index.js
test -f docs/api/flyology_debug/index.html
test -f docs/api/flyology_debug/search-index.js
test -f docs/api/flyology_bench/index.html
test -f docs/api/flyology_bench/search-index.js
test -f docs/api/flyology_cachelines/index.html
test -f docs/api/flyology_cachelines/search-index.js
test -f docs/api/flyology_numa/index.html
test -f docs/api/flyology_numa/search-index.js
