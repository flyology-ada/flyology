#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:---compiler-only}
alr=$("$project_root/scripts/find-alr.sh")
compiler_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")
compiler_prefix=$("$project_root/scripts/gnat-native-prefix.sh" "$alr")
compiler="$compiler_prefix/bin/gcc"
gnatmake="$compiler_prefix/bin/gnatmake"
fixture_root="$project_root/tests/fixtures/gnat13_runtime_warnings"
test_build_root="$project_root/build/tests/gnat13-runtime-warnings"
warning_config=

mkdir -p "$test_build_root"

compile_with_warning_policy () {
  if [ -n "$warning_config" ]; then
    "$compiler" -c -gnatg -gnatyM110 -gnat2022 -O2 -fPIC -gnata \
      "-gnatec=$warning_config" -gnateb "$@"
  else
    "$compiler" -c -gnatg -gnatyM110 -gnat2022 -O2 -fPIC -gnata "$@"
  fi
}

check_config_dependency () {
  poller_ali=$1
  expected=$2
  if [ "$expected" = present ]; then
    if ! grep -F 'runtime-warnings.adc' "$poller_ali" >/dev/null; then
      printf '%s\n' "GNAT 13 poller policy did not record the warning configuration" >&2
      exit 1
    fi
    if grep -F '.flyology-build.' "$poller_ali" >/dev/null \
      || grep -F "$project_root/runtime/config" "$poller_ali" >/dev/null
    then
      printf '%s\n' "GNAT 13 poller policy recorded a machine-specific configuration path" >&2
      exit 1
    fi
  elif grep -F 'runtime-warnings.adc' "$poller_ali" >/dev/null; then
    printf '%s\n' "GNAT $compiler_release poller policy used the GNAT 13 warning configuration" >&2
    exit 1
  fi
}

case "$mode" in
  --compiler-only)
    if [ "$compiler_release" = 13.2.2 ]; then
      warning_config="$project_root/runtime/config/gnat-13/runtime-warnings.adc"
    fi
    poller_build_root="$test_build_root/poller-$compiler_release"
    mkdir -p "$poller_build_root"
    (
      cd "$poller_build_root"
      compile_with_warning_policy \
        -I"$project_root/runtime/ada" \
        "$project_root/runtime/ada/s-flpopo.adb"
    )
    poller_ali="$poller_build_root/s-flpopo.ali"
    poller_object="$poller_build_root/s-flpopo.o"
    if [ ! -f "$poller_ali" ] || [ ! -f "$poller_object" ]; then
      printf '%s\n' "focused compiler check omitted s-flpopo.ali or s-flpopo.o" >&2
      exit 1
    fi
    if [ "$compiler_release" = 13.2.2 ]; then
      check_config_dependency "$poller_ali" present
    else
      check_config_dependency "$poller_ali" absent
    fi

    warning_log="$test_build_root/unrelated-warning-$compiler_release.log"
    if (
      cd "$test_build_root"
      compile_with_warning_policy "$fixture_root/unrelated_runtime_warning_probe.adb"
    ) >"$warning_log" 2>&1
    then
      printf '%s\n' "the runtime warning policy suppressed an unrelated warning" >&2
      exit 1
    fi
    if ! grep -F 'useless assignment of "Value" to itself' "$warning_log" >/dev/null; then
      printf '%s\n' "the unrelated warning probe failed without its expected diagnostic" >&2
      exit 1
    fi

    if [ "$compiler_release" = 13.2.2 ] && [ "$(uname -s)" = Linux ]; then
      probe_object_dir="$test_build_root/contract-assertions-obj"
      probe_exec_dir="$test_build_root/contract-assertions-bin"
      mkdir -p "$probe_object_dir" "$probe_exec_dir"
      (
        cd "$test_build_root"
        "$gnatmake" \
          -q -f \
          -D "$probe_object_dir" \
          -I"$fixture_root" \
          -o "$probe_exec_dir/contract_assertion_probe" \
          "$fixture_root/contract_assertion_probe.adb" \
          -cargs -gnatg -gnatyM110 -gnat2022 -O2 -gnata \
          "-gnatec=$warning_config" -gnateb
      )
      "$probe_exec_dir/contract_assertion_probe"
    fi
    ;;
  --prepared-runtime)
    prepared_runtime=${FLYOLOGY_RTS_DIR:-"$project_root/build/rts"}
    prepared_config="$prepared_runtime/adainclude/runtime-warnings.adc"
    poller_ali="$prepared_runtime/adalib/s-flpopo.ali"
    poller_object="$prepared_runtime/obj/s-flpopo.o"
    if [ ! -f "$poller_ali" ] || [ ! -f "$poller_object" ]; then
      printf '%s\n' "prepared runtime omitted s-flpopo.ali or s-flpopo.o" >&2
      exit 1
    fi
    if [ "$compiler_release" = 13.2.2 ]; then
      if [ ! -f "$prepared_config" ]; then
        printf '%s\n' "GNAT 13 prepared runtime omitted runtime-warnings.adc" >&2
        exit 1
      fi
      check_config_dependency "$poller_ali" present
    elif [ -e "$prepared_config" ]; then
      printf '%s\n' "GNAT $compiler_release prepared runtime received the GNAT 13 warning configuration" >&2
      exit 1
    else
      check_config_dependency "$poller_ali" absent
    fi
    ;;
  *)
    printf '%s\n' "usage: $0 [--compiler-only|--prepared-runtime]" >&2
    exit 1
    ;;
esac
