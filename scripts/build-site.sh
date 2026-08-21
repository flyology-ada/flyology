#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
site_output="$project_root/build/site"
website_kit="$project_root/vendor/website-kit"

if [ ! -f "$website_kit/scripts/install-assets.mjs" ]; then
   printf '%s\n' \
     "website kit is unavailable; run: git submodule update --init" >&2
   exit 1
fi

case "$site_output" in
   "$project_root"/build/site) ;;
   *)
      printf '%s\n' "refusing unsafe site output path: $site_output" >&2
      exit 1
      ;;
esac

rm -rf "$site_output"
mkdir -p "$site_output/assets" "$site_output/api"

cp -R "$project_root/website/." "$site_output/"
rm "$site_output/journal/_entry-template/index.html"
rmdir "$site_output/journal/_entry-template"
node "$website_kit/scripts/install-assets.mjs" "$site_output"
cp -R "$project_root/assets/brand" "$site_output/assets/brand"

"$project_root/scripts/docs.sh"
cp -R "$project_root/docs/api/." "$site_output/api/"
touch "$site_output/.nojekyll"

test -f "$site_output/index.html"
test "$(cat "$site_output/CNAME")" = "flyology.org"
test -f "$site_output/llms.txt"
test -f "$site_output/runtime/index.html"
test -f "$site_output/libraries/index.html"
test -f "$site_output/guide/index.html"
test -f "$site_output/guide/shared-memory/index.html"
test -f "$site_output/guide/data-structures/index.html"
test -f "$site_output/guide/file-watching/index.html"
test -f "$site_output/guide/file-transfers/index.html"
test -f "$site_output/guide/subprocesses/index.html"
test -f "$site_output/guide/supervision/index.html"
test -f "$site_output/guide/process-upgrades/index.html"
test -f "$site_output/guide/timers/index.html"
test -f "$site_output/guide/cachelines/index.html"
test -f "$site_output/guide/numa/index.html"
test -f "$site_output/guide/http/index.html"
test -f "$site_output/guide/benchmarking/index.html"
test -f "$site_output/architecture/index.html"
test -f "$site_output/journal/index.html"
test -f "$project_root/website/journal/_entry-template/index.html"
test ! -e "$site_output/journal/_entry-template"
test -f "$site_output/journal/2026-08-teaching-programs-postgres/index.html"
test -f "$site_output/journal/2026-08-http-comparison/index.html"
test -f "$site_output/journal/2026-08-http-comparison-follow-up/index.html"
test -f "$site_output/journal/2026-08-http-comparison-correction/index.html"
test -f "$site_output/journal/2026-08-benchmark-harness-comparison/index.html"
test -f "$site_output/assets/scripts/termcast.js"
test -f "$site_output/assets/styles/termcast.css"
test -f "$site_output/assets/casts/flyology-bench-basic.cast"
test -f "$site_output/assets/casts/flyology-bench-recording.cast"
node "$project_root/scripts/test-termcast.mjs"
test -f "$site_output/reports/websocket/index.html"
test -f "$site_output/reports/websocket/core-lightweight/index.html"
test -f "$site_output/reports/websocket/core-native/index.html"
test -f "$site_output/reports/websocket/core-lightweight-wss/index.html"
test -f "$site_output/reports/websocket/core-native-wss/index.html"
test -f "$site_output/reports/websocket/limits-lightweight/index.html"
test -f "$site_output/reports/websocket/limits-native/index.html"
test -f "$site_output/reports/websocket/compression-lightweight/index.html"
test -f "$site_output/reports/websocket/compression-native/index.html"
test -f "$site_output/reports/websocket/compression-lightweight-wss/index.html"
test -f "$site_output/reports/websocket/compression-native-wss/index.html"
test -f "$site_output/reports/websocket/performance-lightweight/index.html"
test -f "$site_output/reports/websocket/performance-native/index.html"
test -f "$site_output/reports/websocket/performance-lightweight-wss/index.html"
test -f "$site_output/reports/websocket/performance-native-wss/index.html"
test -f "$site_output/api/index.html"
test -f "$site_output/api/flyology_debug/index.html"
test -f "$site_output/api/flyology_debug/search-index.js"
test -f "$site_output/api/flyology_bench/index.html"
test -f "$site_output/api/flyology_bench/search-index.js"
test -f "$site_output/api/flyology_cachelines/index.html"
test -f "$site_output/api/flyology_cachelines/search-index.js"

printf 'Flyology site built at %s\n' "$site_output"
