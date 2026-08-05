#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
generated_config_temp=
policy_temp=
stamp_temp=

#  The external-consumer race regression holds each critical section long
#  enough to make an omitted or ineffective preparation lock deterministic.
lock_probe=${FLYOLOGY_TEST_RTS_LOCK_PROBE_DIR:-}
cleanup_transaction () {
  if [ -n "$generated_config_temp" ]; then
    rm -f -- "$generated_config_temp"
  fi
  if [ -n "$policy_temp" ]; then
    rm -f -- "$policy_temp"
  fi
  if [ -n "$stamp_temp" ]; then
    rm -f -- "$stamp_temp"
  fi
  if [ -n "$lock_probe" ]; then
    rmdir "$lock_probe" 2>/dev/null || true
  fi
}
trap cleanup_transaction EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$lock_probe" ]; then
  if ! mkdir "$lock_probe"; then
    printf '%s\n' \
      "concurrent Flyology RTS preparation entered its critical section" \
      >&2
    exit 1
  fi
  sleep 2
fi

rts_root="$project_root/build/alire-rts"
generated_config_file="$project_root/build/flyology.cgpr"
policy_file="$project_root/build/flyology-rts.conf"
stamp_file="$rts_root/.flyology-input-stamp"

mode=prepare
case "$#:$*" in
  0:) ;;
  1:--configure) mode=configure ;;
  1:--reset) mode=reset ;;
  *)
    printf '%s\n' \
      "usage: prepare-alire-rts.sh [--configure|--reset]" >&2
    exit 2
    ;;
esac

set_default_policy () {
  execution_default=native
  loop_pool_size=1
  placement_policy=round_robin
  loop_placement=none
  loop_placement_map=
  sanitizer=none
  test_faults=0
  deny_io_uring=0
}

load_policy () {
  if ! awk '
    function known(key) {
      return key == "version" || key == "default" ||
        key == "loop_pool_size" || key == "placement" ||
        key == "loop_placement" || key == "loop_placement_map" ||
        key == "sanitizer" || key == "test_faults" ||
        key == "deny_io_uring"
    }
    {
      separator = index($0, "=")
      if (separator == 0) { invalid = 1; next }
      key = substr($0, 1, separator - 1)
      if (!known(key) || seen[key]++) invalid = 1
    }
    END {
      required[1] = "version"
      required[2] = "default"
      required[3] = "loop_pool_size"
      required[4] = "placement"
      required[5] = "loop_placement"
      required[6] = "loop_placement_map"
      required[7] = "sanitizer"
      required[8] = "test_faults"
      required[9] = "deny_io_uring"
      for (i = 1; i <= 9; i++) {
        if (seen[required[i]] != 1) invalid = 1
      }
      exit invalid ? 1 : 0
    }
  ' "$policy_file"; then
    printf '%s\n' \
      "invalid persisted Flyology RTS configuration: $policy_file" \
      "run prepare-alire-rts.sh --reset to restore defaults" >&2
    exit 1
  fi

  policy_version=$(sed -n 's/^version=//p' "$policy_file")
  if [ "$policy_version" != 1 ]; then
    printf '%s\n' \
      "unsupported Flyology RTS configuration version: $policy_version" \
      "run prepare-alire-rts.sh --reset to restore defaults" >&2
    exit 1
  fi
  execution_default=$(sed -n 's/^default=//p' "$policy_file")
  loop_pool_size=$(sed -n 's/^loop_pool_size=//p' "$policy_file")
  placement_policy=$(sed -n 's/^placement=//p' "$policy_file")
  loop_placement=$(sed -n 's/^loop_placement=//p' "$policy_file")
  loop_placement_map=$(sed -n 's/^loop_placement_map=//p' "$policy_file")
  sanitizer=$(sed -n 's/^sanitizer=//p' "$policy_file")
  test_faults=$(sed -n 's/^test_faults=//p' "$policy_file")
  deny_io_uring=$(sed -n 's/^deny_io_uring=//p' "$policy_file")
}

set_default_policy
policy_publication=none
case "$mode" in
  prepare)
    if [ -f "$policy_file" ]; then
      load_policy
    fi
    ;;
  configure)
    execution_default=${FLYOLOGY_DEFAULT:-native}
    loop_pool_size=${FLYOLOGY_LOOP_POOL_SIZE:-1}
    placement_policy=${FLYOLOGY_PLACEMENT:-round_robin}
    loop_placement=${FLYOLOGY_LOOP_PLACEMENT:-none}
    loop_placement_map=${FLYOLOGY_LOOP_PLACEMENT_MAP:-}
    sanitizer=${FLYOLOGY_SANITIZER:-none}
    test_faults=${FLYOLOGY_TEST_FAULTS:-0}
    deny_io_uring=${FLYOLOGY_TEST_DENY_IO_URING:-0}
    policy_publication=write
    ;;
  reset)
    policy_publication=remove
    ;;
esac

alr=${ALR:-$("$project_root/scripts/find-alr.sh")}
compiler_prefix=$("$project_root/scripts/gnat-native-prefix.sh" "$alr")
compiler="$compiler_prefix/bin/gcc"
compiler_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")
gprbuild_prefix=$("$project_root/scripts/gprbuild-prefix.sh" "$alr")
gprconfig="$gprbuild_prefix/bin/gprconfig"

hash_stream () {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    printf '%s\n' "SHA-256 tool not found" >&2
    return 1
  fi
}

hash_file () {
  hash_stream <"$1" | awk '{ print $1 }'
}

input_stamp=$(
  {
    printf '%s\n' \
      "compiler_prefix=$compiler_prefix" \
      "compiler_release=$compiler_release" \
      "compiler_target=$("$compiler" -dumpmachine)" \
      "gprbuild_prefix=$gprbuild_prefix" \
      "gprconfig_version=$("$gprconfig" --version | sed -n '1p')" \
      "host=$(uname -s):$(uname -m)" \
      "default=$execution_default" \
      "loop_pool_size=$loop_pool_size" \
      "placement=$placement_policy" \
      "loop_placement=$loop_placement" \
      "loop_placement_map=$loop_placement_map" \
      "sanitizer=$sanitizer" \
      "test_faults=$test_faults" \
      "deny_io_uring=$deny_io_uring"
    find "$project_root/runtime" -type f -print | LC_ALL=C sort
    printf '%s\n' \
      "$project_root/scripts/prepare-rts.sh" \
      "$project_root/scripts/prepare-alire-rts.sh" \
      "$project_root/scripts/prepare-alire-rts-internal.sh" \
      "$project_root/scripts/gnat-native-prefix.sh" \
      "$project_root/scripts/gnat-native-release.sh" \
      "$project_root/scripts/gprbuild-prefix.sh"
  } |
    while IFS= read -r item; do
      if [ -f "$item" ]; then
        relative=${item#"$project_root/"}
        printf 'file=%s:%s\n' "$relative" "$(hash_file "$item")"
      else
        printf '%s\n' "$item"
      fi
    done |
    hash_stream | awk '{ print $1 }'
)

runtime_artifacts_valid () {
  object="$rts_root/obj/context_switch.o"
  archive="$rts_root/adalib/libgnarl.a"
  [ -f "$object" ] && [ -f "$archive" ] || return 1
  ar -t "$archive" | grep '^context_switch[.]o$' >/dev/null || return 1
  object_hash=$(hash_file "$object")
  archived_hash=$(ar -p "$archive" context_switch.o | hash_stream |
    awk '{ print $1 }')
  [ "$object_hash" = "$archived_hash" ] || return 1

  case "$(uname -m)" in
    arm64|aarch64)
      case "$(uname -s)" in
        Darwin)
          frame_dump=$(xcrun dwarfdump --eh-frame "$object")
          ;;
        Linux)
          frame_dump=$(readelf --debug-dump=frames "$object")
          ;;
        *)
          return 1
          ;;
      esac
      case "$frame_dump" in
        *"DW_CFA_undefined: W30"*|*"DW_CFA_undefined: r30"*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

runtime_is_current () {
  [ -f "$stamp_file" ] || return 1
  [ "$(sed -n '1p' "$stamp_file")" = "$input_stamp" ] || return 1
  runtime_artifacts_valid
}

rebuilt=0
if ! runtime_is_current; then
  #  The stamp is the transaction commit marker. Invalidate it before the
  #  clean replacement is assembled; prepare-rts publishes only a completed
  #  directory, and interruption always forces the next lock owner to retry.
  rm -f -- "$stamp_file"
  FLYOLOGY_RTS_DIR="$rts_root" \
  FLYOLOGY_DEFAULT="$execution_default" \
  FLYOLOGY_LOOP_POOL_SIZE="$loop_pool_size" \
  FLYOLOGY_PLACEMENT="$placement_policy" \
  FLYOLOGY_LOOP_PLACEMENT="$loop_placement" \
  FLYOLOGY_LOOP_PLACEMENT_MAP="$loop_placement_map" \
  FLYOLOGY_SANITIZER="$sanitizer" \
  FLYOLOGY_TEST_FAULTS="$test_faults" \
  FLYOLOGY_TEST_DENY_IO_URING="$deny_io_uring" \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
  rebuilt=1
fi

if ! runtime_artifacts_valid; then
  printf '%s\n' \
    "prepared Flyology RTS lacks a current context-switch archive member" \
    >&2
  exit 1
fi

if [ "$rebuilt" -eq 1 ] || [ ! -f "$generated_config_file" ]; then
  generated_config_temp=$(mktemp "$project_root/build/.flyology.cgpr.XXXXXX")
  "$gprconfig" \
    --batch \
    --config="ada,,$rts_root,$compiler_prefix/bin" \
    --config="c,,,$compiler_prefix/bin" \
    -o "$generated_config_temp"
  mv "$generated_config_temp" "$generated_config_file"
  generated_config_temp=
fi

if [ "$rebuilt" -eq 1 ] \
  && [ "${FLYOLOGY_TEST_RTS_FAIL_BEFORE_PUBLICATION:-0}" = 1 ]; then
  printf '%s\n' \
    "injected failure before Flyology RTS stamp publication" >&2
  exit 97
fi

case "$policy_publication" in
  write)
    policy_temp=$(mktemp "$project_root/build/.flyology-rts.conf.XXXXXX")
    printf '%s\n' \
      "version=1" \
      "default=$execution_default" \
      "loop_pool_size=$loop_pool_size" \
      "placement=$placement_policy" \
      "loop_placement=$loop_placement" \
      "loop_placement_map=$loop_placement_map" \
      "sanitizer=$sanitizer" \
      "test_faults=$test_faults" \
      "deny_io_uring=$deny_io_uring" >"$policy_temp"
    mv "$policy_temp" "$policy_file"
    policy_temp=
    ;;
  remove)
    rm -f -- "$policy_file"
    ;;
esac

if [ "$rebuilt" -eq 1 ]; then
  stamp_temp=$(mktemp "$rts_root/.flyology-input-stamp.XXXXXX")
  printf '%s\n' "$input_stamp" >"$stamp_temp"
  mv "$stamp_temp" "$stamp_file"
  stamp_temp=
fi
