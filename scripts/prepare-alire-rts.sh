#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rts_root="$project_root/build/alire-rts"
config_file="$project_root/build/flyology.cgpr"
stamp_file="$rts_root/.flyology-input-stamp"
alr=${ALR:-$("$project_root/scripts/find-alr.sh")}
compiler_prefix=$("$project_root/scripts/gnat-native-prefix.sh" "$alr")
compiler="$compiler_prefix/bin/gcc"
compiler_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")

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
      "host=$(uname -s):$(uname -m)" \
      "default=${FLYOLOGY_DEFAULT:-native}" \
      "loop_pool_size=${FLYOLOGY_LOOP_POOL_SIZE:-1}" \
      "placement=${FLYOLOGY_PLACEMENT:-round_robin}" \
      "loop_placement=${FLYOLOGY_LOOP_PLACEMENT:-none}" \
      "loop_placement_map=${FLYOLOGY_LOOP_PLACEMENT_MAP:-}" \
      "sanitizer=${FLYOLOGY_SANITIZER:-none}" \
      "test_faults=${FLYOLOGY_TEST_FAULTS:-0}" \
      "deny_io_uring=${FLYOLOGY_TEST_DENY_IO_URING:-0}"
    find "$project_root/runtime" -type f -print | LC_ALL=C sort
    printf '%s\n' \
      "$project_root/scripts/prepare-rts.sh" \
      "$project_root/scripts/prepare-alire-rts.sh" \
      "$project_root/scripts/gnat-native-prefix.sh" \
      "$project_root/scripts/gnat-native-release.sh"
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
  FLYOLOGY_RTS_DIR="$rts_root" \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
  rebuilt=1
fi

if ! runtime_artifacts_valid; then
  printf '%s\n' \
    "prepared Flyology RTS lacks a current context-switch archive member" \
    >&2
  exit 1
fi

if [ "$rebuilt" -eq 1 ] || [ ! -f "$config_file" ]; then
  gprconfig \
    --batch \
    --config="ada,,$rts_root" \
    --config=c \
    -o "$config_file"
fi

if [ "$rebuilt" -eq 1 ]; then
  mkdir -p "$rts_root"
  stamp_temp="$stamp_file.tmp"
  printf '%s\n' "$input_stamp" >"$stamp_temp"
  mv "$stamp_temp" "$stamp_file"
fi
