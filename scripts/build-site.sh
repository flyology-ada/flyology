#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
site_output="$project_root/build/site"

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
cp -R "$project_root/assets/brand" "$site_output/assets/brand"

"$project_root/scripts/docs.sh"
cp -R "$project_root/docs/api/." "$site_output/api/"
touch "$site_output/.nojekyll"

test -f "$site_output/index.html"
test "$(cat "$site_output/CNAME")" = "flyology.org"
test -f "$site_output/guide/index.html"
test -f "$site_output/guide/timers/index.html"
test -f "$site_output/guide/http/index.html"
test -f "$site_output/architecture/index.html"
test -f "$site_output/journal/index.html"
test -f "$site_output/journal/2026-08-teaching-programs-postgres/index.html"
test -f "$site_output/journal/2026-08-http-comparison/index.html"
test -f "$site_output/journal/2026-08-http-comparison-follow-up/index.html"
test -f "$site_output/reports/websocket/index.html"
test -f "$site_output/reports/websocket/core-lightweight/index.html"
test -f "$site_output/reports/websocket/core-native/index.html"
test -f "$site_output/reports/websocket/core-lightweight-wss/index.html"
test -f "$site_output/reports/websocket/limits-lightweight/index.html"
test -f "$site_output/reports/websocket/performance-lightweight/index.html"
test -f "$site_output/reports/websocket/performance-native/index.html"
test -f "$site_output/api/index.html"

printf 'Flyology site built at %s\n' "$site_output"
