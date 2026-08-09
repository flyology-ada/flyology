#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

workers=${1:-8}
images=${2:-2000}
width=${3:-256}
height=${4:-256}
passes=${5:-128}
index_rounds=${6:-32}
batch_limit=${7:-}

for value in "$workers" "$images" "$width" "$height" "$passes" "$index_rounds"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "showcase arguments must be positive integers" >&2
      exit 2
      ;;
  esac
done

interactive=0
if [ -t 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ] \
  && [ "${TERM:-}" != "dumb" ]; then
  interactive=1
fi
if [ -n "$batch_limit" ]; then
  case "$batch_limit" in
    *[!0-9]*|0)
      printf '%s\n' "epoch count must be a positive integer" >&2
      exit 2
      ;;
  esac
elif [ "$interactive" -eq 1 ]; then
  batch_limit=0
else
  batch_limit=1
fi

corpus_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-image-index.XXXXXX")
summary_file="$corpus_root/final-summary.txt"
stop_file="$corpus_root/stop-requested"
terminal_state=
restore_terminal () {
  if [ -n "$terminal_state" ]; then
    printf '\033[?25h'
    stty "$terminal_state" </dev/tty
    terminal_state=
  fi
}
cleanup () {
  restore_terminal
  rm -rf "$corpus_root"
}
trap cleanup EXIT HUP INT TERM

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  phase () {
    printf '\033[1;36m%s\033[0m\n' "$1"
  }
else
  phase () {
    printf '%s\n' "$1"
  }
fi

phase "[1/4] Preparing the native Flyology runtime"
if command -v shasum >/dev/null 2>&1; then
  hash_command='shasum -a 256'
else
  hash_command='sha256sum'
fi

runtime_stamp=$(
  {
    printf '%s\n' \
      'default=native' \
      'loop-pool-size=1' \
      'placement=round_robin' \
      'loop-placement=none' \
      'sanitizer=none' \
      "compiler=$($project_root/scripts/gnat-native-release.sh "$alr")" \
      "host=$(uname -s):$(uname -m)"
    find \
      "$project_root/runtime/ada" \
      "$project_root/runtime/compat" \
      "$project_root/runtime/config" \
      "$project_root/runtime/native" \
      "$project_root/runtime/patches" \
      "$project_root/runtime/platform" \
      "$project_root/alire.toml" \
      "$project_root/scripts/gnat-native-prefix.sh" \
      "$project_root/scripts/gnat-native-release.sh" \
      "$project_root/scripts/prepare-rts.sh" \
      -type f -print | LC_ALL=C sort | while IFS= read -r source; do
        printf '%s\n' "$source"
        sed -n '1,$p' "$source"
      done
  } | $hash_command | awk '{ print $1 }'
)
runtime_stamp_file="$project_root/build/rts/.shared-image-index-input-stamp"
cached_runtime_stamp=
if [ -f "$runtime_stamp_file" ]; then
  cached_runtime_stamp=$(sed -n '1p' "$runtime_stamp_file")
fi

if [ "$cached_runtime_stamp" = "$runtime_stamp" ] \
  && [ -f "$project_root/build/rts/.flyology-rts-root" ] \
  && [ -f "$project_root/build/rts/adalib/libgnarl.a" ]; then
  phase "      native runtime cache hit"
else
  FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
    "$project_root/showcases/prepare-rts.sh" >/dev/null
  runtime_stamp_temp=$(mktemp \
    "$project_root/build/rts/.shared-image-index-input-stamp.XXXXXX")
  printf '%s\n' "$runtime_stamp" >"$runtime_stamp_temp"
  mv "$runtime_stamp_temp" "$runtime_stamp_file"
fi

phase "[2/4] Building the coordinator and exec'd worker"
build_log="$corpus_root/build.log"
if ! (
  cd "$showcase_root"
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" \
    -P showcases.gpr \
    shared_image_index.adb shared_image_index_worker.adb
) >"$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi
if ! grep -Eq '^(Compile|Bind|Link)' "$build_log"; then
  phase "      executable build cache hit"
fi

phase "[3/4] Checking the narrow native process boundary"
"$showcase_root/check-shared-image-index-native.sh" \
  "$showcase_root/obj/shared_image_index_process.o"

phase "[4/4] Generating and indexing the image corpus"
if [ "$interactive" -eq 1 ]; then
  terminal_state=$(stty -g </dev/tty)
  stty -icanon -echo min 0 time 1 </dev/tty
  printf '\033[2J\033[H\033[?25l'
fi
if [ "$batch_limit" -eq 0 ]; then
  continuous_flag=1
else
  continuous_flag=0
fi

escape=$(printf '\033')
if [ "$interactive" -eq 1 ]; then
  FLYOLOGY_SHOWCASE_CONTINUOUS="$continuous_flag" \
    FLYOLOGY_SHOWCASE_MANAGED_SCREEN=1 \
    FLYOLOGY_SHOWCASE_SUMMARY_FILE="$summary_file" \
    FLYOLOGY_SHOWCASE_STOP_FILE="$stop_file" \
    "$showcase_root/bin/shared_image_index" coordinator \
    "$corpus_root" "$workers" "$images" "$width" "$height" "$passes" \
    "$index_rounds" "$batch_limit" &
  session_pid=$!
  while kill -0 "$session_pid" 2>/dev/null; do
    key=$(dd if=/dev/tty bs=1 count=1 2>/dev/null || :)
    case "$key" in
      q|Q|"$escape")
        #  Generation stops at the current safety epoch; already admitted
        #  image jobs drain before workers detach from the shared segment.
        : >"$stop_file"
        ;;
    esac
  done
  if ! wait "$session_pid"; then
    exit 1
  fi
  restore_terminal
  printf '\n\n'
  cat "$summary_file"
else
  "$showcase_root/bin/shared_image_index" coordinator \
    "$corpus_root" "$workers" "$images" "$width" "$height" "$passes" \
    "$index_rounds" "$batch_limit"
fi
