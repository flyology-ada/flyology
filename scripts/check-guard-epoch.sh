#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${FLYOLOGY_TLA_HARNESS_ROOT:?select the pinned harness checkout}"
: "${FLYOLOGY_TLA_TOOLCHAIN:?evaluate the pinned harness toolchain env}"
: "${FLYOLOGY_TLA_JAVA:?evaluate the pinned harness toolchain env}"
: "${FLYOLOGY_TLA_TLC_JAR:?evaluate the pinned harness toolchain env}"
harness="$FLYOLOGY_TLA_HARNESS_ROOT"
if [ "$(git -C "$harness" rev-parse HEAD)" != dea289018a3eef2ac2aeab7a5ee8bc4e287fe231 ]; then
  printf '%s\n' 'guard epoch replay requires the pinned harness revision' >&2
  exit 2
fi
cli="$harness/bin/flyology-tla"
"$cli" toolchain verify "$FLYOLOGY_TLA_TOOLCHAIN"
mkdir -p "$project_root/build"
run_root=$(mktemp -d "$project_root/build/guard-epoch.XXXXXX")
trap 'rm -rf -- "$run_root"' EXIT HUP INT TERM
source_root="$project_root/tests/guard_epoch_conformance"
model="$project_root/formal/tla/GuardedMapAttach.tla"
config="$source_root/GuardedMapAttach_witness.cfg"
raw="$run_root/raw.json"
log="$run_root/witness.log"
if "$FLYOLOGY_TLA_JAVA" -Xmx1g -XX:+UseParallelGC -cp "$FLYOLOGY_TLA_TLC_JAR" tlc2.TLC \
  -deadlock -noGenerateSpecTE -workers 1 -metadir "$run_root/states" \
  -config "$config" -dumpTrace json "$raw" "$model" >"$log" 2>&1
then
  printf '%s\n' 'guard epoch witness unexpectedly remained incomplete' >&2
  exit 1
fi
if ! grep -Fq 'Invariant EpochWitnessIncomplete is violated' "$log"; then
  cat "$log" >&2
  exit 1
fi
trace="$run_root/guard-epoch.trace.json"
"$cli" trace normalize "$raw" "$trace" "$model" --config "$config" \
  --toolchain tla2tools-1.8.0+b123b22 10 20
"$cli" trace validate "$trace" 10 20
cmp "$source_root/traces/guard_epoch.trace.json" "$trace"
consumer="$run_root/consumer"
mkdir -p "$consumer/src"
cp "$source_root/alire.toml" "$source_root/guard_epoch_conformance.gpr" \
  "$source_root/guard_epoch_conformance_flyology.gpr" "$consumer/"
cp "$source_root/src/"* "$consumer/src/"
alire=$("$project_root/scripts/find-alr.sh")
"$alire" -n --chdir="$consumer" settings --set dependencies.shared false
"$alire" -n --chdir="$consumer" with flyology --use "$project_root"
"$alire" -n --chdir="$consumer" with flyology_allocators --use "$project_root/flyology_allocators"
"$alire" -n --chdir="$consumer" with flyology_tla --use "$harness"
build_log="$run_root/build.log"
if ! FLYOLOGY_ADAPTIVE_POOL_TEST_HOOKS=true "$alire" -n --chdir="$consumer" build >"$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi
"$project_root/scripts/run-with-timeout.sh" 20 "$consumer/bin/guard-epoch-conformance" \
  --format json --result-json "$run_root/result.json" "$trace" >"$run_root/stdout.json"
cmp "$run_root/result.json" "$run_root/stdout.json"
grep -Fq '"verdict":"conformant"' "$run_root/result.json"
grep -Fq '"compared_steps":6' "$run_root/result.json"
cat "$run_root/result.json"
printf '%s\n' 'Ada/TLA+ match    GuardedMapAttach epoch         6 transitions'
