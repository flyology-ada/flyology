#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
development_alr="$project_root/scripts/alr-development.sh"

if [ "${FLYOLOGY_HOOK_ELISION_IN_ALIRE:-0}" != 1 ]; then
  "$project_root/scripts/prepare-atomic-store-config.sh" >/dev/null
  "$development_alr" build >/dev/null
  FLYOLOGY_HOOK_ELISION_IN_ALIRE=1
  export FLYOLOGY_HOOK_ELISION_IN_ALIRE
  exec "$development_alr" exec -- "$0"
fi

probe="$project_root/tests/probes/flyology-test_hook_elision_probe.adb"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-hook-elision.XXXXXX")

cleanup () {
  rm -rf -- "$temp_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

hook_names='dns tls connection worker_pool task_lifecycle subprocess structured_server file_watch wall_clock buffer channel'

case $(uname -s) in
  Darwin) platform_source_dir="$project_root/src/platform/darwin" ;;
  Linux) platform_source_dir="$project_root/src/platform/linux" ;;
  *)
    printf '%s\n' "unsupported hook-elision test host: $(uname -s)" >&2
    exit 1
    ;;
esac

hook_external () {
  case $1 in
    dns) printf '%s\n' FLYOLOGY_DNS_TEST_HOOKS ;;
    tls) printf '%s\n' FLYOLOGY_TLS_TEST_HOOKS ;;
    connection) printf '%s\n' FLYOLOGY_CONNECTION_TEST_HOOKS ;;
    worker_pool) printf '%s\n' FLYOLOGY_WORKER_POOL_TEST_HOOKS ;;
    task_lifecycle) printf '%s\n' FLYOLOGY_TASK_LIFECYCLE_TEST_HOOKS ;;
    subprocess) printf '%s\n' FLYOLOGY_SUBPROCESS_TEST_HOOKS ;;
    structured_server) printf '%s\n' FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS ;;
    file_watch) printf '%s\n' FLYOLOGY_FILE_WATCH_TEST_HOOKS ;;
    wall_clock) printf '%s\n' FLYOLOGY_WALL_CLOCK_TEST_HOOKS ;;
    buffer) printf '%s\n' FLYOLOGY_BUFFER_TEST_HOOKS ;;
    channel) printf '%s\n' FLYOLOGY_CHANNEL_TEST_HOOKS ;;
  esac
}

hook_symbol () {
  case $1 in
    dns) printf '%s\n' flyology__dns_test_observations__reset ;;
    tls) printf '%s\n' flyology__tls_test_hooks__reset ;;
    connection) printf '%s\n' flyology__connection_test_hooks__barrier ;;
    worker_pool) printf '%s\n' flyology__worker_pool_test_hooks__run_claim_barrier ;;
    task_lifecycle) printf '%s\n' flyology__task_lifecycle_test_hooks__barrier ;;
    subprocess) printf '%s\n' flyology__subprocess_test_hooks__fail_reaper_allocation ;;
    structured_server) printf '%s\n' flyology__structured_server_test_hooks__barrier ;;
    file_watch) printf '%s\n' flyology__file_watch_test_hooks__consume_events_lost ;;
    wall_clock) printf '%s\n' flyology__wall_clock_testing__note_sample ;;
    buffer) printf '%s\n' flyology__buffer_test_hooks__arm_next_acquisition_near_exhaustion ;;
    channel) printf '%s\n' flyology__channel_test_hooks__before_send_barrier ;;
  esac
}

hook_state () {
  combination=$1
  hook_index=$2
  if [ $(((combination / hook_index) % 2)) -eq 1 ]; then
    printf '%s\n' enabled
  else
    printf '%s\n' disabled
  fi
}

undefined_symbols () {
  nm -u "$1" | awk '
    {
      found = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "U") {
          print $(i + 1)
          found = 1
        }
      }
      if (!found && NF == 1 && $1 !~ /:$/) print $1
    }
  '
}

check_project_selection () {
  combination=$1
  set -- -P "$project_root/flyology.gpr" --attributes --display=textual --views=flyology
  hook_index=1
  for hook in $hook_names; do
    state=$(hook_state "$combination" "$hook_index")
    external=$(hook_external "$hook")
    if [ "$state" = enabled ]; then
      value=true
    else
      value=false
    fi
    set -- "$@" -X"$external=$value"
    hook_index=$((hook_index * 2))
  done
  inspection=$(gprinspect "$@")

  hook_index=1
  for hook in $hook_names; do
    state=$(hook_state "$combination" "$hook_index")
    if [ "$state" = enabled ]; then
      opposite=disabled
    else
      opposite=enabled
    fi
    expected="/src/test_hooks/$hook/$state"
    unexpected="/src/test_hooks/$hook/$opposite"
    if ! printf '%s\n' "$inspection" | grep -F "$expected" >/dev/null; then
      printf '%s\n' "hook combination $combination omits $expected" >&2
      exit 1
    fi
    if printf '%s\n' "$inspection" | grep -F "$unexpected" >/dev/null; then
      printf '%s\n' "hook combination $combination includes $unexpected" >&2
      exit 1
    fi
    hook_index=$((hook_index * 2))
  done
}

compile_probe () {
  combination=$1
  mode=$2
  shift 2
  work_dir="$temp_root/$mode-$combination"
  mkdir -p "$work_dir"

  set -- "$@" -gnatW8 -I"$project_root/src" -I"$platform_source_dir"
  hook_index=1
  for hook in $hook_names; do
    state=$(hook_state "$combination" "$hook_index")
    set -- "$@" -I"$project_root/src/test_hooks/$hook/$state"
    hook_index=$((hook_index * 2))
  done
  object="$work_dir/flyology-test_hook_elision_probe.o"
  set -- "$@" -c "$probe" -o "$object"
  (
    cd "$work_dir"
    gcc "$@"
  )

  symbols=$(undefined_symbols "$object")
  if printf '%s\n' "$symbols" | grep -F flyology_disabled_hook_must_be_elided >/dev/null; then
    printf '%s\n' "disabled hook reference survived in $mode combination $combination" >&2
    exit 1
  fi

  hook_index=1
  for hook in $hook_names; do
    state=$(hook_state "$combination" "$hook_index")
    symbol=$(hook_symbol "$hook")
    if [ "$state" = enabled ]; then
      if ! printf '%s\n' "$symbols" | grep -F "$symbol" >/dev/null; then
        printf '%s\n' "enabled $hook probe call disappeared in $mode combination $combination" >&2
        exit 1
      fi
    elif printf '%s\n' "$symbols" | grep -F "$symbol" >/dev/null; then
      printf '%s\n' "disabled $hook probe call survived in $mode combination $combination" >&2
      exit 1
    fi
    hook_index=$((hook_index * 2))
  done

  if [ $(((combination / 256) % 2)) -eq 1 ]; then
    if ! printf '%s\n' "$symbols" | grep -F flyology__wall_clock_io_testing__reset >/dev/null; then
      printf '%s\n' "enabled wall-clock I/O probe call disappeared in $mode combination $combination" >&2
      exit 1
    fi
  elif printf '%s\n' "$symbols" | grep -F flyology__wall_clock_io_testing__reset >/dev/null; then
    printf '%s\n' "disabled wall-clock I/O probe call survived in $mode combination $combination" >&2
    exit 1
  fi
}

check_edge_combinations () {
  mode=$1
  shift
  compile_probe 0 "$mode" "$@"
  hook_index=1
  for hook in $hook_names; do
    compile_probe "$hook_index" "$mode" "$@"
    hook_index=$((hook_index * 2))
  done
}

check_production_archive () {
  mode=$1
  shift
  subdir="hook-elision-$mode"
  set -- -P "$project_root/flyology.gpr" --subdirs="$subdir" -f -p -q -j0 \
    -XFLYOLOGY_DNS_TEST_HOOKS=false \
    -XFLYOLOGY_TLS_TEST_HOOKS=false \
    -XFLYOLOGY_CONNECTION_TEST_HOOKS=false \
    -XFLYOLOGY_WORKER_POOL_TEST_HOOKS=false \
    -XFLYOLOGY_TASK_LIFECYCLE_TEST_HOOKS=false \
    -XFLYOLOGY_SUBPROCESS_TEST_HOOKS=false \
    -XFLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS=false \
    -XFLYOLOGY_FILE_WATCH_TEST_HOOKS=false \
    -XFLYOLOGY_WALL_CLOCK_TEST_HOOKS=false \
    -XFLYOLOGY_BUFFER_TEST_HOOKS=false \
    -XFLYOLOGY_CHANNEL_TEST_HOOKS=false \
    -cargs:Ada "$@"
  build_log="$temp_root/production-$mode.log"
  if ! gprbuild "$@" >"$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
  fi

  archive="$project_root/lib/$subdir/libFlyology.a"
  if [ ! -f "$archive" ]; then
    printf '%s\n' "hook-elision build did not produce $archive" >&2
    exit 1
  fi
  symbols=$(undefined_symbols "$archive")
  if printf '%s\n' "$symbols" | grep -E \
    'flyology_disabled_hook_must_be_elided|flyology__(buffer_test_hooks|channel_test_hooks|dns_test_observations|tls_test_hooks|connection_test_hooks|worker_pool_test_hooks|task_lifecycle_test_hooks|subprocess_test_hooks|structured_server_test_hooks|file_watch_test_hooks|wall_clock(_io)?_testing)__|flyology_test_(connection|worker|structured_server|subprocess|file_watch|tls)' \
    >/dev/null
  then
    printf '%s\n' "production hook reference survived in $mode" >&2
    printf '%s\n' "$symbols" | grep -E \
      'flyology_disabled_hook_must_be_elided|flyology__(buffer_test_hooks|channel_test_hooks|dns_test_observations|tls_test_hooks|connection_test_hooks|worker_pool_test_hooks|task_lifecycle_test_hooks|subprocess_test_hooks|structured_server_test_hooks|file_watch_test_hooks|wall_clock(_io)?_testing)__|flyology_test_(connection|worker|structured_server|subprocess|file_watch|tls)' \
      >&2 || true
    exit 1
  fi
}

if git -C "$project_root" grep -n -E '^#(if|else|end if)' -- '*.adb' '*.ads' >/dev/null; then
  printf '%s\n' "Ada preprocessing directives reappeared" >&2
  exit 1
fi

printf '%s\n' 'test-hook-elision: all 2048 project selections and strict -O0 probe combinations'
combination=0
while [ "$combination" -lt 2048 ]; do
  check_project_selection "$combination"
  compile_probe "$combination" O0-strict \
    -O0 -fno-inline -fno-inline-functions -fno-tree-dce -fno-dce
  combination=$((combination + 1))
done

printf '%s\n' 'test-hook-elision: optimization edge combinations'
check_edge_combinations O0 -O0
check_edge_combinations Og -Og
check_edge_combinations O1 -O1
check_edge_combinations O2 -O2
check_edge_combinations O3 -O3
check_edge_combinations Os -Os
check_edge_combinations Oz -Oz
check_edge_combinations Ofast -Ofast

printf '%s\n' 'test-hook-elision: production archives'
check_production_archive O0-strict \
  -O0 -fno-inline -fno-inline-functions -fno-tree-dce -fno-dce
check_production_archive O0 -O0
check_production_archive Og -Og
check_production_archive O1 -O1
check_production_archive O2 -O2
check_production_archive O3 -O3
check_production_archive Os -Os
check_production_archive Oz -Oz
check_production_archive Ofast -Ofast

printf '%s\n' 'test-hook-elision: PASS'
