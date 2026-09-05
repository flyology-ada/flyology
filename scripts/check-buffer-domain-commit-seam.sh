#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
development_alr="$project_root/scripts/alr-development.sh"

if [ "${FLYOLOGY_COMMIT_SEAM_IN_DEVELOPMENT_WORKSPACE:-0}" != 1 ]; then
  "$project_root/scripts/prepare-atomic-store-config.sh" >/dev/null
  FLYOLOGY_COMMIT_SEAM_IN_DEVELOPMENT_WORKSPACE=1
  export FLYOLOGY_COMMIT_SEAM_IN_DEVELOPMENT_WORKSPACE
  exec "$development_alr" exec -- "$0"
fi

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-commit-seam.XXXXXX")

cleanup () {
  rm -rf -- "$temp_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

subdir=buffer-domain-commit-seam
build_log="$temp_root/build.log"

if ! gprbuild \
  -P "$project_root/flyology.gpr" \
  --subdirs="$subdir" \
  -XFLYOLOGY_BUFFER_TEST_HOOKS=false \
  -f -p -q -j0 \
  -cargs:Ada \
  -O0 -fno-inline -fno-inline-functions -fno-tree-dce -fno-dce \
  >"$build_log" 2>&1
then
  cat "$build_log" >&2
  exit 1
fi

inspection=$(gprinspect \
  -P "$project_root/flyology.gpr" \
  --attributes --display=textual --views=flyology)
object_dir=$(printf '%s\n' "$inspection" | awk -F ': ' '
  /- Object directory/ {
    print $2
    exit
  }
')
object="$object_dir/$subdir/flyology-buffers-domains-drivers.o"

if [ -z "$object_dir" ] || [ ! -f "$object" ]; then
  printf '%s\n' "commit-seam build omitted $object" >&2
  exit 1
fi

if nm -u "$object" | grep -Ei \
  'flyology_disabled_hook|flyology__buffer_test_hooks|flyology_test_' \
  >/dev/null
then
  printf '%s\n' 'commit-seam object retains a disabled test-hook reference' >&2
  exit 1
fi

if strings "$object" | grep -Ei \
  'flyology_disabled_hook|flyology__buffer_test_hooks|flyology_test_' \
  >/dev/null
then
  printf '%s\n' 'commit-seam object retains disabled test-hook metadata' >&2
  exit 1
fi

disassembly="$temp_root/disassembly.txt"
objdump -d "$object" >"$disassembly"

extract_instructions () {
  awk '
    /^[[:space:]]*[[:xdigit:]]+:/ {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      count = split(line, fields, /[[:space:]]+/)
      field = 1
      while (field <= count) {
        if (fields[field] !~ /^[[:xdigit:]]+$/) break
        width = length(fields[field])
        if (width != 2 && width != 8) break
        field++
      }
      if (field > count) {
        print "__unparsed_instruction__"
      } else {
        instruction = fields[field]
        for (operand = field + 1; operand <= count; operand++) {
          instruction = instruction " " fields[operand]
        }
        print instruction
      }
    }
  ' "$@"
}

extract_mnemonics () {
  extract_instructions "$@" | awk '{ print $1 }'
}

#  Prove that instruction bytes cannot hide all-hex mnemonics such as AArch64
#  b/add or x86 loop, and that a byte-only line fails closed. This is
#  independent of the host selected below.
parser_probe=$(printf '%s\n' \
  '0: 14000000 b 0x8' \
  '4: 91000400 add x0, x0, #1' \
  '0: 48 89 e5 mov %rsp, %rbp' \
  '3: e2 fc loop 0x1' \
  '7: deadbeef' | extract_mnemonics)
parser_expected=$(printf 'b\nadd\nmov\nloop\n__unparsed_instruction__')
if [ "$parser_probe" != "$parser_expected" ]; then
  printf '%s\n' 'commit-seam instruction parser self-test failed' >&2
  exit 1
fi

#  Fail closed: these are the complete data-movement, address calculation,
#  stack-frame, padding, and ordinary-return instruction families currently
#  reviewed for the supported native code generators. New code generation
#  must fail this check until its instruction is reviewed and added.
case $(uname -m) in
  arm64|aarch64)
    safe_instruction='^(add|adr|adrp|and|bic|bti|dup|eor|fmov|ins|'
    safe_instruction="${safe_instruction}ld1|ldp|ldr|ldur|mov|movi|movk|movn|movz|"
    safe_instruction="${safe_instruction}nop|orr|ret|st1|stp|str|stur|sub)$"
    safe_samples='add adrp ldr mov ret str sub'
    return_mnemonic='^ret([[:space:]]|$)'
    terminal_instruction='^ret$'
    ;;
  x86_64|amd64)
    safe_instruction='^(add[bwlq]?|and[bwlq]?|endbr64|lea[bwlq]?|leaveq?|'
    safe_instruction="${safe_instruction}mov[[:alnum:]]*|nop[[:alnum:]]*|or[bwlq]?|pop[qwl]?|"
    safe_instruction="${safe_instruction}push[qwl]?|pxor|retq?|sub[bwlq]?|v?mov[[:alnum:]]*|"
    safe_instruction="${safe_instruction}v?pxor[dq]?|xchg[bwlq]?|xor[[:alnum:]]*)$"
    safe_samples='leaq movq pushq retq subq'
    return_mnemonic='^retq?([[:space:]]|$)'
    terminal_instruction='^retq?$'
    ;;
  *)
    printf '%s\n' "unsupported commit-seam audit architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

for instruction in $safe_samples; do
  if ! printf '%s\n' "$instruction" | grep -E "$safe_instruction" >/dev/null; then
    printf '%s\n' "commit-seam safe classifier rejected $instruction" >&2
    exit 1
  fi
done
for instruction in b blraa boundl divq hvc int3 loopne svc syscall vmrun; do
  if printf '%s\n' "$instruction" | grep -E "$safe_instruction" >/dev/null; then
    printf '%s\n' "commit-seam safe classifier accepted $instruction" >&2
    exit 1
  fi
done

has_one_terminal_return () {
  return_count=$(grep -Ec "$return_mnemonic" "$1" || true)
  if [ "$return_count" -ne 1 ]; then
    return 1
  fi
  tail -n 1 "$1" | grep -E "$terminal_instruction" >/dev/null
}

valid_sequence="$temp_root/valid-sequence.txt"
early_return="$temp_root/early-return.txt"
duplicate_return="$temp_root/duplicate-return.txt"
register_return="$temp_root/register-return.txt"
stack_return="$temp_root/stack-return.txt"
printf 'mov\nret\n' >"$valid_sequence"
printf 'ret\nmov\n' >"$early_return"
printf 'ret\nret\n' >"$duplicate_return"
printf 'ret x0\n' >"$register_return"
printf 'retq $8\n' >"$stack_return"
if ! has_one_terminal_return "$valid_sequence" \
  || has_one_terminal_return "$early_return" \
  || has_one_terminal_return "$duplicate_return" \
  || has_one_terminal_return "$register_return" \
  || has_one_terminal_return "$stack_return"
then
  printf '%s\n' 'commit-seam terminal-return classifier self-test failed' >&2
  exit 1
fi

for helper in commit_prevalidated_from_owned commit_prevalidated_move; do
  body="$temp_root/$helper.txt"
  if ! awk -v suffix="$helper" '
    $0 ~ "<_*flyology__buffers__domains__drivers__" suffix ">:" {
      found = 1
      inside = 1
      next
    }
    inside && $0 ~ /^[[:space:]]*[[:xdigit:]]+[[:space:]]+<[^>]+>:/ {
      exit
    }
    inside {
      print
    }
    END {
      if (!found) exit 2
    }
  ' "$disassembly" >"$body"
  then
    printf '%s\n' "commit-seam object omits $helper" >&2
    exit 1
  fi

  instructions="$temp_root/$helper.instructions"
  mnemonics="$temp_root/$helper.mnemonics"
  extract_instructions "$body" >"$instructions"
  awk '{ print $1 }' "$instructions" >"$mnemonics"

  if ! has_one_terminal_return "$instructions"; then
    printf '%s\n' "commit-seam helper $helper lacks one terminal return instruction" >&2
    exit 1
  fi
  if grep -Ev "$safe_instruction" "$mnemonics" >"$temp_root/$helper.rejected"
  then
    printf '%s\n' "commit-seam helper $helper contains an unreviewed instruction" >&2
    cat "$temp_root/$helper.rejected" >&2
    cat "$body" >&2
    exit 1
  fi
done

printf '%s\n' 'buffer-domain-commit-seam: PASS'
