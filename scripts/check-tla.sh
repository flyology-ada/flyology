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
    "$run_root/$tag.log" | tail -n 1)
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

expect_temporal_counterexample()
{
  module=$1
  config=$2
  property=$3
  tag=$4
  if run_tlc "$module" "$config" "$tag"; then
    printf '%s\n' \
      "$config unexpectedly satisfied broken property $property" >&2
    return 1
  fi
  if ! grep -Fq "Temporal properties were violated" \
    "$run_root/$tag.log"
  then
    cat "$run_root/$tag.log" >&2
    printf '%s\n' \
      "$config failed without the expected $property counterexample" >&2
    return 1
  fi
  printf 'TLC temporal cex  %-27s %s\n' "$config" "$property"
}

cd "$model_root"

expect_safe MPMCActiveAttach MPMCActiveAttach.cfg mpmc-safe
expect_safe GuardedMapAttach GuardedMapAttach.cfg map-safe
expect_safe SegmentRegistry SegmentRegistry.cfg registry-safe
expect_safe \
  SupervisionLifecycle SupervisionLifecycle.cfg supervision-safe
expect_safe \
  SupervisionLifecycle SupervisionLifecycle_liveness.cfg supervision-live
expect_safe \
  AllocatorAlgorithms AllocatorAlgorithms_buddy.cfg allocator-buddy
expect_safe \
  AllocatorAlgorithms AllocatorAlgorithms_best_fit.cfg allocator-best-fit
expect_safe \
  AllocatorAlgorithms AllocatorAlgorithms_tlsf.cfg allocator-tlsf
expect_safe \
  AllocatorAlgorithms AllocatorAlgorithms_stale_release_safe.cfg \
  allocator-stale-release-safe
expect_safe \
  AllocatorAlgorithmsRefinement \
  AllocatorAlgorithms_refinement_buddy.cfg allocator-refinement-buddy
expect_safe \
  AllocatorAlgorithmsRefinement \
  AllocatorAlgorithms_refinement_best_fit.cfg allocator-refinement-best-fit
expect_safe \
  AllocatorAlgorithmsRefinement \
  AllocatorAlgorithms_refinement_tlsf.cfg allocator-refinement-tlsf

expect_counterexample \
  MPMCActiveAttach MPMCActiveAttach_legacy.cfg \
  NoFalseAttachRejection mpmc-legacy
expect_counterexample \
  GuardedMapAttach GuardedMapAttach_legacy.cfg \
  NoFalseCorruption map-legacy
expect_counterexample \
  SegmentRegistry SegmentRegistry_unlocked.cfg \
  ClaimsMatchInitializingSlot registry-unlocked
expect_counterexample \
  SupervisionLifecycle SupervisionLifecycle_stale.cfg \
  NoStaleCommandAccepted supervision-stale
expect_counterexample \
  SupervisionLifecycle SupervisionLifecycle_overlap.cfg \
  ReplacementFollowsJoin supervision-overlap
expect_counterexample \
  SupervisionLifecycle SupervisionLifecycle_incident.cfg \
  NestedEscalationPreservesIncident supervision-incident
expect_counterexample \
  SupervisionLifecycle SupervisionLifecycle_readmission.cfg \
  OwnerReadinessFollowsReadmission supervision-readmission
expect_temporal_counterexample \
  SupervisionLifecycle SupervisionLifecycle_no_forward.cfg \
  CooperativeShutdownCompletes supervision-no-forward
expect_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_buddy_no_retry.cfg \
  NoFalseExhaustion allocator-buddy-no-retry
expect_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_best_fit_no_retry.cfg \
  NoFalseExhaustion allocator-best-fit-no-retry
expect_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_tlsf_no_retry.cfg \
  NoFalseExhaustion allocator-tlsf-no-retry
expect_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_buddy_stale_hint.cfg \
  StoredBlocksWellFormed allocator-buddy-stale-hint
expect_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_tlsf_stale_bitmap.cfg \
  TLSFBitmapMatchesBins allocator-tlsf-stale-bitmap
expect_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_stale_release.cfg \
  HandlesMatchAllocatedBlocks allocator-stale-release
expect_temporal_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_buddy_nontermination.cfg \
  OperationTermination allocator-buddy-nontermination
expect_temporal_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_best_fit_nontermination.cfg \
  OperationTermination allocator-best-fit-nontermination
expect_temporal_counterexample \
  AllocatorAlgorithms AllocatorAlgorithms_tlsf_nontermination.cfg \
  OperationTermination allocator-tlsf-nontermination
expect_temporal_counterexample \
  AllocatorAlgorithmsRefinement \
  AllocatorAlgorithms_refinement_buddy_no_retry.cfg \
  TraceCompletion allocator-refinement-buddy-no-retry
expect_temporal_counterexample \
  AllocatorAlgorithmsRefinement \
  AllocatorAlgorithms_refinement_best_fit_no_retry.cfg \
  TraceCompletion allocator-refinement-best-fit-no-retry
expect_temporal_counterexample \
  AllocatorAlgorithmsRefinement \
  AllocatorAlgorithms_refinement_tlsf_no_retry.cfg \
  TraceCompletion allocator-refinement-tlsf-no-retry

if [ -n "${ALR:-}" ]; then
  alire=$ALR
else
  alire=$("$project_root/scripts/find-alr.sh")
fi

cd "$project_root"
"$alire" exec -- gprbuild \
  -P flyology_allocators/tests/allocator_tests.gpr \
  -p allocator_refinement.adb >/dev/null

compare_refinement()
{
  algorithm=$1
  tag=$2
  ada_trace="$run_root/$tag-ada.trace"
  tla_trace="$run_root/$tag-tla.trace"

  "$project_root/flyology_allocators/tests/bin/allocator_refinement" \
    "$algorithm" >"$ada_trace"
  sed -n 's/^"\(@@REFINEMENT@@.*\)"$/\1/p' \
    "$run_root/$tag.log" |
    awk '!seen[$0]++' >"$tla_trace"
  if [ ! -s "$tla_trace" ]; then
    printf '%s\n' "$algorithm TLC refinement trace is empty" >&2
    return 1
  fi
  if ! diff -u "$tla_trace" "$ada_trace"; then
    printf '%s\n' \
      "$algorithm Ada state diverges from its TLA+ refinement trace" >&2
    return 1
  fi
  lines=$(wc -l <"$ada_trace" | tr -d ' ')
  printf 'Ada/TLA+ match    %-30s %s snapshots\n' "$algorithm" "$lines"
}

compare_refinement Buddy allocator-refinement-buddy
compare_refinement BestFit allocator-refinement-best-fit
compare_refinement TLSF allocator-refinement-tlsf

printf '%s\n' "Flyology TLA+ model checks passed"
