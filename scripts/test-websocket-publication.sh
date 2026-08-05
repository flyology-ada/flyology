#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

sh -n "$project_root/scripts/websocket-conformance.sh"
node --check "$project_root/scripts/websocket-run-provenance.mjs"
node --check "$project_root/scripts/publish-websocket-conformance.mjs"
node --test "$project_root/tests/websocket_run_provenance_test.mjs"
