#!/bin/sh
# Record the maintained flyology_bench examples as asciicast v2 files.
#
# The casts are published with the website and replayed by
# website/assets/scripts/termcast.js. Re-run this script to refresh them; the
# recorded output is whatever the examples produce on this host, so the
# committed casts describe the machine that recorded them and nothing else.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
crate="$project_root/flyology_bench"
casts="$project_root/website/assets/casts"
recorder="$project_root/scripts/lib/record_cast.py"

#  Each example emits a fixed-width report; the terminal must be at least
#  that wide or the reporter's own lines wrap and the replay is unreadable.
#  scripts/test-termcast.mjs fails the build when a recorded line exceeds the
#  recorded width, so these numbers cannot silently drift below the output.
basic_columns=${FLYOLOGY_CAST_COLUMNS_BASIC:-200}
recording_columns=${FLYOLOGY_CAST_COLUMNS_RECORDING:-120}
rows=${FLYOLOGY_CAST_ROWS:-30}

mkdir -p "$casts"

if [ ! -x "$crate/examples/bin/basic" ] \
   || [ ! -x "$crate/examples/bin/recording_service" ]
then
   printf '%s\n' "building examples" >&2
   (cd "$crate" && alr exec -- gprbuild -p -P examples/flyology_bench_examples.gpr)
fi

record() {
   name=$1
   columns=$2
   shift 2
   printf '%s\n' "recording $name at ${columns}x${rows}" >&2
   (cd "$crate" && python3 "$recorder" "$casts/$name.cast" \
      "$columns" "$rows" "$@")
}

record flyology-bench-basic "$basic_columns" ./examples/bin/basic
record flyology-bench-recording "$recording_columns" \
   ./examples/bin/recording_service

printf '%s\n' "casts written to $casts" >&2
ls -l "$casts"
