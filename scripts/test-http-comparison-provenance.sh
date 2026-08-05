#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

node --check "$project_root/tests/http_comparison_provenance_test.mjs"
node --test "$project_root/tests/http_comparison_provenance_test.mjs"
