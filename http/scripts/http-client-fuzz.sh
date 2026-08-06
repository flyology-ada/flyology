#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
output_root="$project_root/build/gnatfuzz/http-client"
analysis_dir="$output_root/analysis"
analysis_file="$analysis_dir/analyze.json"
harness_dir="$output_root/harness"
harness_project="$harness_dir/fuzz_test.gpr"
corpus_dir="$output_root/starting_corpus"
command=${1:-prepare}

if ! "$alr" exec -- gnatfuzz --version >/dev/null 2>&1; then
  printf '%s\n' \
    "gnatfuzz is unavailable in the Alire environment; install AdaCore GNATfuzz first" >&2
  exit 127
fi

analyze () {
  "$alr" build
  mkdir -p "$analysis_dir"
  "$alr" exec -- gnatfuzz analyze \
    -P "$project_root/flyology.gpr" \
    -S "$project_root/src/flyology-http-client-testing.ads" \
    -o "$analysis_dir" --disable-styled-output
}

target_id () {
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const match = data.fuzzable_subprograms.find((item) =>
  /Fuzz_Response/i.test(item.label) &&
  /flyology-http-client-testing\.ads$/.test(item.source_filename));
if (!match) {
  console.error("Fuzz_Response was not reported as fuzzable");
  process.exit(1);
}
process.stdout.write(String(match.id));
' "$analysis_file"
}

prepare () {
  analyze
  id=$(target_id)
  "$alr" exec -- gnatfuzz generate \
    -P "$project_root/flyology.gpr" \
    --analysis "$analysis_file" --subprogram-id "$id" \
    -o "$harness_dir" --disable-styled-output
  "$alr" exec -- gnatfuzz build \
    -P "$harness_project" --afl-mode afl_plain
  mkdir -p "$corpus_dir"
  "$alr" exec -- gnatfuzz generate-corpus \
    -P "$harness_project" -o "$corpus_dir"
}

case "$command" in
  analyze)
    analyze
    ;;
  prepare)
    prepare
    ;;
  fuzz)
    if [ ! -f "$harness_project" ] || [ ! -d "$corpus_dir" ]; then
      prepare
    fi
    shift
    "$alr" exec -- gnatfuzz fuzz \
      -P "$harness_project" --corpus-path "$corpus_dir" \
      --disable-styled-output "$@"
    ;;
  *)
    printf '%s\n' "usage: $0 {analyze|prepare|fuzz [gnatfuzz options]}" >&2
    exit 2
    ;;
esac
