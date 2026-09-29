#!/bin/sh

case ${1-} in
  helper-leaf)
    trap '' HUP INT TERM
    printf '%s\n' "$$" >"$2"
    perl -MPOSIX -e 'print POSIX::getpgrp(), "\n"' >"$3"
    while :; do
      sleep 60
    done
    ;;
  helper-tree)
    # A timeout must remain a failure even when the group leader handles TERM
    # and reports success. The leaf resists TERM to exercise KILL escalation.
    trap '' HUP INT
    trap 'exit 0' TERM
    printf '%s\n' "$$" >"$2"
    perl -MPOSIX -e 'print POSIX::getpgrp(), "\n"' >"$3"
    "$0" helper-leaf "$4" "$5" &
    while :; do
      sleep 60
    done
    ;;
esac

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runner="$project_root/scripts/run-with-timeout.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-timeout.XXXXXX")
active_runner_pid=

cleanup () {
  if [ -n "$active_runner_pid" ]; then
    kill -TERM "$active_runner_pid" 2>/dev/null || true
    wait "$active_runner_pid" 2>/dev/null || true
  fi
  rm -rf -- "$temporary_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail () {
  printf '%s\n' "run-with-timeout test: $*" >&2
  exit 1
}

wait_for_file () {
  wait_path=$1
  wait_count=0
  while [ ! -s "$wait_path" ]; do
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 200 ] || fail "timed out waiting for $wait_path"
    sleep 0.01
  done
}

assert_process_gone () {
  gone_pid=$1
  gone_count=0
  while kill -0 "$gone_pid" 2>/dev/null; do
    gone_count=$((gone_count + 1))
    [ "$gone_count" -le 200 ] || fail "process $gone_pid survived cleanup"
    sleep 0.01
  done
}

set +e
dependency_error=$(PATH=/nonexistent "$runner" 5 true 2>&1)
dependency_status=$?
set -e
[ "$dependency_status" -eq 2 ] || \
  fail "missing Perl returned $dependency_status instead of 2"
[ "$dependency_error" = \
  "run-with-timeout.sh: Perl 5 with core POSIX support is required" ] || \
  fail "missing Perl did not report its dependency"

set +e
"$runner" 5 sh -c 'exit 23'
failed_status=$?
set -e
[ "$failed_status" -eq 23 ] || \
  fail "failed command returned $failed_status instead of 23"
"$runner" 5 sh -c 'exit 0'

timeout_dir="$temporary_root/timeout"
mkdir "$timeout_dir"
set +e
"$runner" 1 "$0" helper-tree \
  "$timeout_dir/leader.pid" "$timeout_dir/leader.pgid" \
  "$timeout_dir/leaf.pid" "$timeout_dir/leaf.pgid" \
  2>"$timeout_dir/stderr"
timeout_status=$?
set -e
[ "$timeout_status" -eq 124 ] || \
  fail "timeout returned $timeout_status instead of 124"
wait_for_file "$timeout_dir/leaf.pid"
leader_pid=$(cat "$timeout_dir/leader.pid")
leader_pgid=$(cat "$timeout_dir/leader.pgid")
leaf_pid=$(cat "$timeout_dir/leaf.pid")
leaf_pgid=$(cat "$timeout_dir/leaf.pgid")
[ "$leader_pgid" -eq "$leader_pid" ] || \
  fail "command did not lead its dedicated process group"
[ "$leaf_pgid" -eq "$leader_pgid" ] || \
  fail "descendant escaped the command process group"
assert_process_gone "$leaf_pid"
grep -F "timeout: 1 seconds elapsed for pid $leader_pid " \
  "$timeout_dir/stderr" >/dev/null || fail "timeout diagnostic omitted the pid"
grep -F "(process group $leader_pgid)" "$timeout_dir/stderr" >/dev/null || \
  fail "timeout diagnostic omitted the process group"

for signal_case in HUP INT TERM; do
  case $signal_case in
    HUP) expected_status=129 ;;
    INT) expected_status=130 ;;
    TERM) expected_status=143 ;;
  esac
  signal_dir="$temporary_root/signal-$signal_case"
  mkdir "$signal_dir"
  "$runner" 30 "$0" helper-tree \
    "$signal_dir/leader.pid" "$signal_dir/leader.pgid" \
    "$signal_dir/leaf.pid" "$signal_dir/leaf.pgid" \
    2>"$signal_dir/stderr" &
  runner_pid=$!
  active_runner_pid=$runner_pid
  wait_for_file "$signal_dir/leaf.pid"
  kill -s "$signal_case" "$runner_pid"
  set +e
  wait "$runner_pid"
  signal_status=$?
  set -e
  active_runner_pid=
  [ "$signal_status" -eq "$expected_status" ] || \
    fail "$signal_case returned $signal_status instead of $expected_status"
  assert_process_gone "$(cat "$signal_dir/leaf.pid")"
done

printf '%s\n' "run-with-timeout test: PASS"
