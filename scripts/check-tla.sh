#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
model_root="$project_root/formal/tla"
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-tlc.XXXXXX")

cleanup()
{
  rm -rf "$run_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -n "${JAVA:-}" ]; then
  java_bin=$JAVA
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  java_bin="$JAVA_HOME/bin/java"
else
  java_bin=
  for candidate in \
    "/Applications/TLA+ Toolbox.app"/Contents/Eclipse/plugins/org.lamport.openjdk.*/Contents/Home/bin/java
  do
    if [ -x "$candidate" ]; then
      java_bin=$candidate
      break
    fi
  done
  if [ -z "$java_bin" ]; then
    java_bin=$(command -v java || true)
  fi
fi

if [ -n "${TLA2TOOLS_JAR:-}" ]; then
  tla_jar=$TLA2TOOLS_JAR
elif [ -f "/Applications/TLA+ Toolbox.app/Contents/Eclipse/tla2tools.jar" ]; then
  tla_jar="/Applications/TLA+ Toolbox.app/Contents/Eclipse/tla2tools.jar"
else
  printf '%s\n' \
    "set TLA2TOOLS_JAR to an official tla2tools.jar installation" >&2
  exit 2
fi

if [ -z "$java_bin" ] || [ ! -x "$java_bin" ]; then
  printf '%s\n' "set JAVA or JAVA_HOME to a working Java runtime" >&2
  exit 2
elif [ ! -f "$tla_jar" ]; then
  printf '%s\n' "TLA2TOOLS_JAR does not name a regular file: $tla_jar" >&2
  exit 2
fi

run_tlc()
{
  module=$1
  config=$2
  tag=$3
  log="$run_root/$tag.log"
  meta="$run_root/$tag-states"
  "$java_bin" -XX:+UseParallelGC -cp "$tla_jar" tlc2.TLC \
    -deadlock -workers 1 -metadir "$meta" \
    -config "$config" "$module.tla" >"$log" 2>&1
}

expect_safe()
{
  module=$1
  config=$2
  tag=$3
  if ! run_tlc "$module" "$config" "$tag"; then
    cat "$run_root/$tag.log" >&2
    return 1
  fi
  states=$(sed -n \
    's/.*states generated, \([0-9][0-9]*\) distinct states found.*/\1/p' \
    "$run_root/$tag.log")
  printf 'TLC safe          %-30s %s distinct states\n' \
    "$config" "${states:-checked}"
}

expect_counterexample()
{
  module=$1
  config=$2
  invariant=$3
  tag=$4
  if run_tlc "$module" "$config" "$tag"; then
    printf '%s\n' \
      "$config unexpectedly satisfied broken invariant $invariant" >&2
    return 1
  fi
  if ! grep -Fq "Invariant $invariant is violated" "$run_root/$tag.log"; then
    cat "$run_root/$tag.log" >&2
    printf '%s\n' \
      "$config failed without the expected $invariant counterexample" >&2
    return 1
  fi
  printf 'TLC counterexample %-27s %s\n' "$config" "$invariant"
}

cd "$model_root"

expect_safe MPMCActiveAttach MPMCActiveAttach.cfg mpmc-safe
expect_safe GuardedMapAttach GuardedMapAttach.cfg map-safe
expect_safe SegmentRegistry SegmentRegistry.cfg registry-safe

expect_counterexample \
  MPMCActiveAttach MPMCActiveAttach_legacy.cfg \
  NoFalseAttachRejection mpmc-legacy
expect_counterexample \
  GuardedMapAttach GuardedMapAttach_legacy.cfg \
  NoFalseCorruption map-legacy
expect_counterexample \
  SegmentRegistry SegmentRegistry_unlocked.cfg \
  ClaimsMatchInitializingSlot registry-unlocked

printf '%s\n' "Flyology TLA+ model checks passed"
