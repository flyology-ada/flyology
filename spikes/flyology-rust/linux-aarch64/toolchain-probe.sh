#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
probe_subdir=rust-linux-gpr-probe
probe_executable="$project_root/tests/bin/$probe_subdir/default_policy_smoke"
flyology_archive="$project_root/lib/libFlyology.a"

cd "$project_root"

printf '%s\n' "GPRbuild binary:"
alr exec -- gprbuild --version | sed -n '1,2p'
printf '%s\n' "GPRbuild helper inventory:"
gprbuild_path=$(alr exec -- sh -c 'command -v gprbuild')
gprbuild_prefix=$(CDPATH= cd -- "$(dirname -- "$gprbuild_path")/.." && pwd)
find "$gprbuild_prefix/libexec/gprbuild" -maxdepth 1 -type f -print | sort

# This is the smallest exact reproduction of scripts/test.sh's established
# compile-then-bind/link sequence on one existing runtime-smoke main.
alr exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$project_root/build/alire-rts" \
  --subdirs="$probe_subdir" \
  -f -c -r -p \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb
alr exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$project_root/build/alire-rts" \
  --subdirs="$probe_subdir" \
  -f -b -l -p \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb

missing=0
if [ ! -f "$probe_executable" ]; then
  printf 'FAIL missing executable: %s\n' "$probe_executable" >&2
  missing=1
fi
if [ ! -f "$flyology_archive" ]; then
  printf 'FAIL missing archive: %s\n' "$flyology_archive" >&2
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  printf '%s\n' "Exchange files left by GPRbuild:" >&2
  find "$project_root" -name '*.lexch' -print | sort | sed -n '1,20p' >&2
  printf '%s\n' \
    "FAIL supported GPRbuild cannot link Flyology cases; repair its link helpers before rerunning" >&2
  exit 1
fi

printf '%s\n' "PASS supported GPRbuild link probe"
