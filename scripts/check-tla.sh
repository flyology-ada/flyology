#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
model_root="$project_root/formal/tla"
mkdir -p "$project_root/build"
run_root=$(mktemp -d "$project_root/build/flyology-tlc.XXXXXX")

cleanup()
{
  rm -rf "$run_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -n "${FLYOLOGY_TLA_JAVA:-}" ]; then
  java_bin=$FLYOLOGY_TLA_JAVA
elif [ -n "${JAVA:-}" ]; then
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

if [ -n "${FLYOLOGY_TLA_TLC_JAR:-}" ]; then
  tla_jar=$FLYOLOGY_TLA_TLC_JAR
elif [ -n "${TLA2TOOLS_JAR:-}" ]; then
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

harness_revision=dea289018a3eef2ac2aeab7a5ee8bc4e287fe231
harness_root=${FLYOLOGY_TLA_HARNESS_ROOT:-"$project_root/build/flyology-tla"}
tla_cli="$harness_root/bin/flyology-tla"
if [ ! -e "$harness_root/.git" ] \
  || ! git -C "$harness_root" rev-parse --is-inside-work-tree >/dev/null 2>&1
then
  printf '%s\n' \
    "set FLYOLOGY_TLA_HARNESS_ROOT to the exact flyology-ada/tla checkout" >&2
  exit 2
elif [ "$(git -C "$harness_root" rev-parse HEAD)" != "$harness_revision" ]; then
  printf '%s\n' \
    "flyology-ada/tla checkout is not the required revision $harness_revision" >&2
  exit 2
elif [ ! -x "$tla_cli" ]; then
  printf '%s\n' "build the required flyology-ada/tla checkout first" >&2
  exit 2
fi
: "${FLYOLOGY_TLA_TOOLCHAIN:?evaluate 'flyology-tla toolchain env' first}"
: "${FLYOLOGY_TLAPM:?evaluate 'flyology-tla toolchain env' first}"
"$tla_cli" toolchain verify "$FLYOLOGY_TLA_TOOLCHAIN"

run_tlc()
{
  module=$1
  config=$2
  tag=$3
  log="$run_root/$tag.log"
  meta="$run_root/$tag-states"
  "$java_bin" -XX:+UseParallelGC -cp "$tla_jar" tlc2.TLC \
    -deadlock -noGenerateSpecTE -workers 1 -metadir "$meta" \
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
  if ! grep -Fq "Temporal property $property was violated" \
    "$run_root/$tag.log" &&
    ! grep -Fq "Temporal properties were violated" "$run_root/$tag.log"
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
  CompletionSetFinalize CompletionSetFinalize.cfg completion-finalize-safe
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
  SlabSpanAllocator SlabSpanAllocator.cfg allocator-slab-span
expect_safe \
  SlabSpanPublication SlabSpanPublication.cfg allocator-slab-publication
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
expect_temporal_counterexample \
  CompletionSetFinalize CompletionSetFinalize_broken.cfg \
  FinalizeCompletes completion-finalize-broken
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
expect_counterexample \
  SlabSpanAllocator SlabSpanAllocator_no_retry.cfg \
  NoFalseExhaustion allocator-slab-span-no-retry
expect_temporal_counterexample \
  SlabSpanAllocator SlabSpanAllocator_nontermination.cfg \
  OperationTermination allocator-slab-span-nontermination
expect_counterexample \
  SlabSpanPublication SlabSpanPublication_broken.cfg \
  NoStaleHandleAccepted allocator-slab-publication-broken
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

proof_log="$run_root/completion-finalize-proof.log"
if ! "$FLYOLOGY_TLAPM" \
  --cache-dir "$run_root/tlapm-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/CompletionSetFinalizeProof.tla" \
  >"$proof_log" 2>&1
then
  cat "$proof_log" >&2
  exit 1
fi
if ! grep -Fq 'All 2 obligations proved' "$proof_log"; then
  cat "$proof_log" >&2
  printf '%s\n' 'completion-finalization proof did not discharge both obligations' >&2
  exit 1
fi
printf '%s\n' 'TLAPS proved       CompletionSetFinalizeProof    2 obligations'

finalize_raw="$run_root/completion-set-finalize-raw.json"
finalize_log="$run_root/completion-set-finalize-witness.log"
finalize_meta="$run_root/completion-set-finalize-witness-states"
finalize_config="$project_root/tests/operations_finalize_conformance/CompletionSetFinalize_trace.cfg"
set +e
"$java_bin" -Xmx1g -XX:+UseParallelGC -cp "$tla_jar" tlc2.TLC \
  -workers 1 -coverage 1 -noGenerateSpecTE -metadir "$finalize_meta" \
  -config "$finalize_config" \
  -dumpTrace json "$finalize_raw" CompletionSetFinalize.tla \
  >"$finalize_log" 2>&1
finalize_status=$?
set -e
if [ "$finalize_status" -ne 12 ] \
  || ! grep -Fq 'Invariant WitnessIncomplete is violated.' "$finalize_log" \
  || ! grep -Fq '2 states generated, 2 distinct states found' "$finalize_log"
then
  cat "$finalize_log" >&2
  printf '%s\n' \
    'completion-finalization witness did not reach its exact terminal state' >&2
  exit 1
fi
if ! grep -Eq '^<FinalizeAtomically .*: [1-9]' "$finalize_log"; then
  cat "$finalize_log" >&2
  printf '%s\n' 'completion-finalization witness did not cover FinalizeAtomically' >&2
  exit 1
fi
if grep -q '^Warning:' "$finalize_log"; then
  cat "$finalize_log" >&2
  printf '%s\n' 'completion-finalization witness emitted a TLC warning' >&2
  exit 1
fi

generated_one="$run_root/generated-one"
generated_two="$run_root/generated-two"
"$tla_cli" ada generate \
  "$model_root/CompletionSetFinalize.tla" \
  --config "$finalize_config" \
  --package Completion_Set_Finalize_Model --output "$generated_one" \
  --type-invariant TypeOK \
  --input-type HarnessInputType --outcome-type HarnessOutcomeType
"$tla_cli" ada generate \
  "$model_root/CompletionSetFinalize.tla" \
  --config "$finalize_config" \
  --package Completion_Set_Finalize_Model --output "$generated_two" \
  --type-invariant TypeOK \
  --input-type HarnessInputType --outcome-type HarnessOutcomeType
for generated_file in \
  completion_set_finalize_model.ads completion_set_finalize_model.adb \
  completion_set_finalize_model.inference.json
do
  cmp "$generated_one/$generated_file" "$generated_two/$generated_file"
  cmp \
    "$project_root/tests/operations_finalize_conformance/generated/$generated_file" \
    "$generated_one/$generated_file"
done

finalize_trace="$run_root/completion-set-finalize.trace.json"
"$tla_cli" trace normalize \
  "$finalize_raw" "$finalize_trace" \
  "$model_root/CompletionSetFinalize.tla" \
  --config "$finalize_config" \
  --toolchain tla2tools-1.8.0+b123b22 16 32
"$tla_cli" trace validate "$finalize_trace" 16 32
cmp \
  "$project_root/tests/operations_finalize_conformance/traces/completion-set-finalize.trace.json" \
  "$finalize_trace"

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

conformance_source="$project_root/tests/operations_finalize_conformance"
conformance_root="$run_root/operations-finalize-conformance"
mkdir -p \
  "$conformance_root/src" "$conformance_root/generated" \
  "$conformance_root/traces"
cp \
  "$conformance_source/alire.toml" \
  "$conformance_source/operations_finalize_conformance.gpr" \
  "$conformance_source/CompletionSetFinalize_trace.cfg" \
  "$conformance_root/"
cp "$conformance_source/src/operations_finalize_conformance.adb" \
  "$conformance_root/src/"
cp "$conformance_source/generated/"* "$conformance_root/generated/"
cp "$conformance_source/traces/"* "$conformance_root/traces/"
cd "$conformance_root"
pin_flyology_log="$run_root/operations-finalize-pin-flyology.log"
if ! "$alire" -n with flyology --use "$project_root" \
  >"$pin_flyology_log" 2>&1
then
  cat "$pin_flyology_log" >&2
  exit 1
fi
pin_harness_log="$run_root/operations-finalize-pin-harness.log"
if ! "$alire" -n with flyology_tla --use "$harness_root" \
  >"$pin_harness_log" 2>&1
then
  cat "$pin_harness_log" >&2
  exit 1
fi
conformance_build_log="$run_root/operations-finalize-build.log"
if ! "$alire" -n build >"$conformance_build_log" 2>&1; then
  cat "$conformance_build_log" >&2
  exit 1
fi
"$project_root/scripts/run-with-timeout.sh" 20 \
  ./bin/operations-finalize-conformance --format json \
  --result-json "$run_root/operations-finalize-result.json" \
  "$finalize_trace" >"$run_root/operations-finalize-stdout.json"
cmp \
  "$run_root/operations-finalize-result.json" \
  "$run_root/operations-finalize-stdout.json"
grep -Fq '"verdict":"conformant"' \
  "$run_root/operations-finalize-result.json"
grep -Fq '"compared_steps":1' \
  "$run_root/operations-finalize-result.json"
printf '%s\n' 'Ada/TLA+ match    CompletionSetFinalize          1 transition'

printf '%s\n' "Flyology TLA+ model checks passed"
