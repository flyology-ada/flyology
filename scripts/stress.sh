#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
seeds=${FLYOLOGY_STRESS_SEEDS:-"1 7 42 8675309"}
batches=${FLYOLOGY_STRESS_BATCHES:-8}
width=${FLYOLOGY_STRESS_WIDTH:-24}
case_timeout=${FLYOLOGY_STRESS_TIMEOUT:-120}
run_faults=${FLYOLOGY_STRESS_FAULTS:-1}

case "$run_faults" in
  0|1) ;;
  *) printf '%s\n' "FLYOLOGY_STRESS_FAULTS must be 0 or 1" >&2; exit 2 ;;
esac

cd "$project_root"

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- env -u GPR_CONFIG gprbuild "$@"
}

run_timed () {
  seconds=$1
  shift
  perl -e '$seconds = shift; $SIG{ALRM} = sub { die "timeout\n" }; alarm $seconds; exec @ARGV or die "$ARGV[0]: $!\n"' \
    "$seconds" "$@"
}

restore_runtime () {
  FLYOLOGY_TEST_FAULTS=0 "$project_root/scripts/prepare-rts.sh" >/dev/null
}
trap restore_runtime EXIT HUP INT TERM

printf '%s\n' \
  "Flyology short stress: seeds=[$seeds] batches=$batches width=$width timeout=${case_timeout}s"

FLYOLOGY_TEST_FAULTS=0 "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f -P tests/runtime_smoke.gpr stress_randomized.adb

for seed in $seeds; do
  printf '%s\n' "stress seed=$seed"
  run_timed "$case_timeout" \
    "$project_root/tests/bin/stress_randomized" "$seed" "$batches" "$width"
done

if [ "$run_faults" = 1 ]; then
  FLYOLOGY_TEST_FAULTS=1 "$project_root/scripts/prepare-rts.sh" >/dev/null
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f -P tests/runtime_smoke.gpr \
    fault_injection_smoke.adb reap_finalize_race_smoke.adb \
    create_finalize_race_smoke.adb

  if [ "$(uname -s)" = Linux ]; then
    run_gprbuild \
      --RTS="$project_root/build/rts" \
      -f -P tests/runtime_smoke.gpr linux_poller_fairness_smoke.adb
    printf '%s\n' "fault case=linux-poller-fairness"
    run_timed "$case_timeout" \
      "$project_root/tests/bin/linux_poller_fairness_smoke"
  fi

  printf '%s\n' "fault case=final-reap-window"
  run_timed "$case_timeout" \
    "$project_root/tests/bin/reap_finalize_race_smoke"

  printf '%s\n' "fault case=create-lifecycle-window"
  run_timed "$case_timeout" \
    "$project_root/tests/bin/create_finalize_race_smoke"

  fault_cases='
    fiber-allocation stack-map stack-protect stack-discard group-startup
    watch-error eintr file-saturation file-dormancy-exclusion
    file-uring-cq-backpressure file-uring-probe-fallback
    file-uring-post-setup-fallback
    file-cancellation file-abort file-pre-park-abort file-backend-cancel
    file-cancel-fallback file-uring-identity file-uring-last-fiber'
  if [ "$(uname -s)" = Darwin ]; then
    fault_cases="$fault_cases file-darwin-cancel-cleanup"
  fi
  for fault_case in $fault_cases
  do
    printf '%s\n' "fault case=$fault_case"
    run_timed "$case_timeout" \
      "$project_root/tests/bin/fault_injection_smoke" "$fault_case"
  done

  for fault_case in fatal-wake fatal-wait fatal-stack-release; do
    printf '%s\n' "fatal fault case=$fault_case (expecting SIGABRT)"
    set +e
    run_timed "$case_timeout" \
      "$project_root/tests/bin/fault_injection_smoke" "$fault_case"
    status=$?
    set -e
    if [ "$status" -ne 134 ]; then
      printf '%s\n' \
        "fatal fault case $fault_case exited $status, expected 134" >&2
      exit 1
    fi
  done
fi

printf '%s\n' "Flyology short stress passed"
