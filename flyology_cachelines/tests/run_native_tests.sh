#!/bin/sh

set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${ALR:-}" ]
then
   alr_command=$ALR
elif command -v alr >/dev/null 2>&1
then
   alr_command=$(command -v alr)
elif [ -x "${HOME}/alr" ]
then
   alr_command="${HOME}/alr"
elif [ -x "${HOME}/.local/bin/alr" ]
then
   alr_command="${HOME}/.local/bin/alr"
else
   echo "alr was not found; set ALR to its executable path" >&2
   exit 1
fi

cd "$test_directory"
"$alr_command" -n build
"$test_directory/bin/tests"

overflow_log="$test_directory/obj/group_overflow.log"
expect_group_overflow()
{
   main=$1
   expected_message=$2

   if "$alr_command" exec -- \
     gprbuild -p -P group_overflow_tests.gpr "$main" \
       >"$overflow_log" 2>&1
   then
      echo "$main unexpectedly accepted a spilling group" >&2
      exit 1
   fi

   if ! grep -Fq "$expected_message" "$overflow_log"
   then
      echo "$main failed for an unexpected reason" >&2
      sed -n '1,160p' "$overflow_log" >&2
      exit 1
   fi
}

expect_group_overflow \
  explicit_group_overflow.adb \
  "padded group payload exceeds one destructive-interference region"
expect_group_overflow \
  fitted_group_overflow.adb \
  "automatically fitted group payload exceeds its interference region"
echo "spilling explicit and automatically fitted groups were rejected"

case "$(uname -s)" in
   Linux)
      "$alr_command" exec -- \
        gprbuild -p -P linux_detection_tests.gpr
      "$test_directory/bin/flyology_cachelines-linux_testing-main" \
        "$test_directory/fixtures/"
      ;;
   Darwin)
      "$alr_command" exec -- \
        gprbuild -p -P macos_detection_tests.gpr
      "$test_directory/bin/flyology_cachelines-macos_testing-main"
      ;;
esac
