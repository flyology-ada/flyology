#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")

cd "$http_root/proof"
"$alr" build --stop-after=generation
"$alr" gnatprove \
  -P "$http_root/flyology_http.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u \
  flyology-rate_limit_policy.adb \
  flyology-http_chunk_encoding.adb \
  flyology-websocket_policy.adb \
  flyology-http-decoded_path_policy.adb \
  flyology-http-expect_policy.adb \
  flyology-http-client_policy.adb \
  flyology-http-route_parameter_policy.adb \
  flyology-websocket_deflate_policy.adb

printf '%s\n' "Flyology HTTP SPARK proof suite passed"
