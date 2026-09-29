#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_root/build"
test_root=$(mktemp -d "$project_root/build/runtime-matrix-enumeration.XXXXXX")

cleanup () {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_root/bin"
cat >"$test_root/bin/docker" <<'EOF'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"$FLYOLOGY_MATRIX_TEST_DOCKER_LOG"
if [ "$1" = build ] \
  && [ -n "${FLYOLOGY_MATRIX_TEST_FAIL_VERSION:-}" ]
then
  case " $* " in
    *" GNAT_VERSION=$FLYOLOGY_MATRIX_TEST_FAIL_VERSION "*)
      exit 71
      ;;
  esac
fi
case "$1:$2" in
  container:create)
    printf '%s\n' fake-container
    ;;
  container:inspect)
    exit 1
    ;;
esac
EOF
chmod +x "$test_root/bin/docker"

cat >"$test_root/bin/alr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FLYOLOGY_MATRIX_TEST_ALR_LOG"
printf '%s\n' "matrix enumeration invoked Alire" >&2
exit 99
EOF
chmod +x "$test_root/bin/alr"

cat >"$test_root/amd64.expected" <<'EOF'
Testing Linux gnat_native 13.2.2 with GPRbuild 25.0.1
Testing Linux gnat_native 14.1.3 with GPRbuild 25.0.1
Testing Linux gnat_native 14.2.1 with GPRbuild 25.0.1
Testing Linux gnat_native 15.1.2 with GPRbuild 25.0.1
Testing Linux gnat_native 15.3.1 with GPRbuild 25.0.1
Testing Linux gnat_native 16.1.0 with GPRbuild 26.0.1
Testing Linux gnat_flyology_native 16.2.0-patchset.1.1.0 with GPRbuild 26.0.1
EOF

cat >"$test_root/arm64.expected" <<'EOF'
Skipping Linux gnat_native 13.2.2 with GPRbuild 25.0.1: not published for arm64/aarch64
Skipping Linux gnat_native 14.1.3 with GPRbuild 25.0.1: not published for arm64/aarch64
Testing Linux gnat_native 14.2.1 with GPRbuild 25.0.1
Testing Linux gnat_native 15.1.2 with GPRbuild 25.0.1
Testing Linux gnat_native 15.3.1 with GPRbuild 25.0.1
Testing Linux gnat_native 16.1.0 with GPRbuild 26.0.1
Testing Linux gnat_flyology_native 16.2.0-patchset.1.1.0 with GPRbuild 26.0.1
EOF

cat >"$test_root/amd64-builds.expected" <<'EOF'
linux/amd64 GNAT_PROVIDER=gnat_native GNAT_VERSION=13.2.2 GPRBUILD_VERSION=25.0.1
linux/amd64 GNAT_PROVIDER=gnat_native GNAT_VERSION=14.1.3 GPRBUILD_VERSION=25.0.1
linux/amd64 GNAT_PROVIDER=gnat_native GNAT_VERSION=14.2.1 GPRBUILD_VERSION=25.0.1
linux/amd64 GNAT_PROVIDER=gnat_native GNAT_VERSION=15.1.2 GPRBUILD_VERSION=25.0.1
linux/amd64 GNAT_PROVIDER=gnat_native GNAT_VERSION=15.3.1 GPRBUILD_VERSION=25.0.1
linux/amd64 GNAT_PROVIDER=gnat_native GNAT_VERSION=16.1.0 GPRBUILD_VERSION=26.0.1
linux/amd64 GNAT_PROVIDER=gnat_flyology_native GNAT_VERSION=16.2.0-patchset.1.1.0 GPRBUILD_VERSION=26.0.1
EOF

cat >"$test_root/arm64-builds.expected" <<'EOF'
linux/arm64 GNAT_PROVIDER=gnat_native GNAT_VERSION=14.2.1 GPRBUILD_VERSION=25.0.1
linux/arm64 GNAT_PROVIDER=gnat_native GNAT_VERSION=15.1.2 GPRBUILD_VERSION=25.0.1
linux/arm64 GNAT_PROVIDER=gnat_native GNAT_VERSION=15.3.1 GPRBUILD_VERSION=25.0.1
linux/arm64 GNAT_PROVIDER=gnat_native GNAT_VERSION=16.1.0 GPRBUILD_VERSION=26.0.1
linux/arm64 GNAT_PROVIDER=gnat_flyology_native GNAT_VERSION=16.2.0-patchset.1.1.0 GPRBUILD_VERSION=26.0.1
EOF

run_architecture () {
  architecture=$1
  canonical=$2
  docker_log="$test_root/$architecture.docker.log"
  output="$test_root/$architecture.output"

  : >"$docker_log"
  FLYOLOGY_LINUX_ARCH="$architecture" \
  FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$docker_log" \
  PATH="$test_root/bin:$PATH" \
    "$project_root/scripts/test-alire-runtime-matrix.sh" >"$output"

  grep -E '^(Testing|Skipping) Linux ' "$output" \
    >"$test_root/$architecture.selection"
  diff -u "$test_root/$canonical.expected" \
    "$test_root/$architecture.selection"

  awk '$1 == "build" { print $3, $5, $7, $9 }' "$docker_log" \
    >"$test_root/$architecture.builds"
  diff -u "$test_root/$canonical-builds.expected" \
    "$test_root/$architecture.builds"

  awk '
    $1 == "build" {
      for (field = 1; field <= NF; field++) {
        if ($field == "-t") {
          print $(field + 1)
        }
      }
    }
  ' "$docker_log" >"$test_root/$architecture.tags"
  if [ "$(wc -l <"$test_root/$architecture.tags")" -ne \
       "$(wc -l <"$test_root/$architecture.builds")" ]
  then
    printf '%s\n' "matrix build omitted a Docker image tag" >&2
    exit 1
  fi
  if ! awk -v architecture="$canonical" '
    $1 == "build" {
      provider = $5
      version = $7
      sub(/^GNAT_PROVIDER=/, "", provider)
      sub(/^GNAT_VERSION=/, "", version)
      expected = "flyology-linux-test:" architecture "-" provider "-" version "-"
      for (field = 1; field <= NF; field++) {
        if ($field == "-t" && index($(field + 1), expected) != 1) {
          exit 1
        }
      }
    }
  ' "$docker_log"
  then
    printf '%s\n' \
      "matrix image tag omitted canonical architecture or compiler identity" >&2
    exit 1
  fi
  while IFS= read -r image_tag
  do
    case "$image_tag" in
      flyology-linux-test:*)
        docker_tag=${image_tag#*:}
        ;;
      *)
        printf '%s\n' "matrix produced an invalid Docker image: $image_tag" >&2
        exit 1
        ;;
    esac
    case "$docker_tag" in
      ''|*[!A-Za-z0-9_.-]*)
        printf '%s\n' "matrix produced an invalid Docker tag: $docker_tag" >&2
        exit 1
        ;;
    esac
    if [ "${#docker_tag}" -gt 128 ]; then
      printf '%s\n' "matrix produced an overlong Docker tag: $docker_tag" >&2
      exit 1
    fi
  done <"$test_root/$architecture.tags"
}

run_architecture amd64 amd64
run_architecture x86_64 amd64
run_architecture arm64 arm64
run_architecture aarch64 arm64

amd64_common_tag=$(sed -n '3p' "$test_root/amd64.tags")
arm64_common_tag=$(sed -n '1p' "$test_root/arm64.tags")
if [ "$amd64_common_tag" = "$arm64_common_tag" ]; then
  printf '%s\n' "matrix reused an image tag across Linux architectures" >&2
  exit 1
fi

single_cell_matrix="$test_root/single-cell-matrix.txt"
printf '%s' 'gnat_native:14.2.1:25.0.1:amd64,arm64' \
  >"$single_cell_matrix"
: >"$test_root/first-concurrent.docker.log"
: >"$test_root/second-concurrent.docker.log"
env -u FLYOLOGY_LINUX_ARCH \
  FLYOLOGY_TEST_ALIRE_RUNTIME_MATRIX_FILE="$single_cell_matrix" \
  FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$test_root/first-concurrent.docker.log" \
  PATH="$test_root/bin:$PATH" \
    "$project_root/scripts/test-alire-runtime-matrix.sh" \
      >"$test_root/first-concurrent.output" &
first_pid=$!
env -u FLYOLOGY_LINUX_ARCH \
  FLYOLOGY_TEST_ALIRE_RUNTIME_MATRIX_FILE="$single_cell_matrix" \
  FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$test_root/second-concurrent.docker.log" \
  PATH="$test_root/bin:$PATH" \
    "$project_root/scripts/test-alire-runtime-matrix.sh" \
      >"$test_root/second-concurrent.output" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
for invocation in first second
do
  awk '
    $1 == "build" {
      for (field = 1; field <= NF; field++) {
        if ($field == "-t") {
          print $(field + 1)
        }
      }
    }
  ' "$test_root/$invocation-concurrent.docker.log" \
    >"$test_root/$invocation-concurrent.tag"
done
if cmp -s "$test_root/first-concurrent.tag" \
   "$test_root/second-concurrent.tag"
then
  printf '%s\n' "concurrent matrix invocations reused an image tag" >&2
  exit 1
fi

failed_cell_log="$test_root/failed-cell.docker.log"
: >"$failed_cell_log"
if FLYOLOGY_LINUX_ARCH=amd64 \
   FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$failed_cell_log" \
   FLYOLOGY_MATRIX_TEST_FAIL_VERSION=15.1.2 \
   PATH="$test_root/bin:$PATH" \
     "$project_root/scripts/test-alire-runtime-matrix.sh" \
       >"$test_root/failed-cell.output" 2>&1
then
  printf '%s\n' "failed declared-present matrix cell was ignored" >&2
  exit 1
fi
if ! grep -q 'GNAT_VERSION=15.1.2' "$failed_cell_log"; then
  printf '%s\n' "declared-present failure did not reach its exact cell" >&2
  exit 1
fi
if grep -q 'GNAT_VERSION=15.3.1' "$failed_cell_log"; then
  printf '%s\n' "matrix continued after a declared-present cell failed" >&2
  exit 1
fi

expect_manifest_rejection () {
  label=$1
  expected_error=$2
  manifest="$test_root/$label.matrix"
  docker_log="$test_root/$label.docker.log"
  : >"$docker_log"
  if FLYOLOGY_LINUX_ARCH=amd64 \
     FLYOLOGY_TEST_ALIRE_RUNTIME_MATRIX_FILE="$manifest" \
     FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$docker_log" \
     PATH="$test_root/bin:$PATH" \
       "$project_root/scripts/test-alire-runtime-matrix.sh" \
         >"$test_root/$label.output" 2>&1
  then
    printf '%s\n' "invalid runtime matrix was accepted: $label" >&2
    exit 1
  fi
  if ! grep -F "$expected_error" "$test_root/$label.output" >/dev/null; then
    printf '%s\n' "runtime matrix reported the wrong error: $label" >&2
    cat "$test_root/$label.output" >&2
    exit 1
  fi
  if [ -s "$docker_log" ]; then
    printf '%s\n' "invalid runtime matrix invoked Docker: $label" >&2
    exit 1
  fi
}

printf '%s\n' ':13.2.2:25.0.1:amd64' >"$test_root/missing-provider.matrix"
printf '%s\n' 'gnat_native::25.0.1:amd64' >"$test_root/missing-gnat.matrix"
printf '%s\n' 'gnat_native:13.2.2::amd64' >"$test_root/missing-gprbuild.matrix"
printf '%s\n' 'gnat_native:13.2.2:25.0.1:' >"$test_root/missing-architectures.matrix"
printf '%s\n' 'gnat_native:13.2.2:25.0.1:amd64:extra' \
  >"$test_root/extra-field.matrix"
: >"$test_root/empty.matrix"
printf '%s\n' '' '   # indented comment' ' # another comment' \
  >"$test_root/comments-only.matrix"

for malformed in \
  missing-provider \
  missing-gnat \
  missing-gprbuild \
  missing-architectures \
  extra-field
do
  expect_manifest_rejection "$malformed" "invalid runtime matrix record at"
done
expect_manifest_rejection empty "runtime matrix contains no cells:"
expect_manifest_rejection comments-only "runtime matrix contains no cells:"

unterminated_log="$test_root/unterminated.docker.log"
: >"$unterminated_log"
FLYOLOGY_LINUX_ARCH=amd64 \
FLYOLOGY_TEST_ALIRE_RUNTIME_MATRIX_FILE="$single_cell_matrix" \
FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$unterminated_log" \
PATH="$test_root/bin:$PATH" \
  "$project_root/scripts/test-alire-runtime-matrix.sh" \
    >"$test_root/unterminated.output"
if [ "$(grep -c '^build ' "$unterminated_log")" -ne 1 ]; then
  printf '%s\n' "unterminated final matrix record was not processed once" >&2
  exit 1
fi

unsupported_log="$test_root/unsupported.docker.log"
unsupported_alr_log="$test_root/unsupported.alr.log"
: >"$unsupported_log"
: >"$unsupported_alr_log"
if FLYOLOGY_LINUX_ARCH=riscv64 \
   FLYOLOGY_MATRIX_TEST_DOCKER_LOG="$unsupported_log" \
   FLYOLOGY_MATRIX_TEST_ALR_LOG="$unsupported_alr_log" \
   PATH="$test_root/bin:$PATH" \
     "$project_root/scripts/test-alire-runtime-matrix.sh" \
       >"$test_root/unsupported.output" 2>&1
then
  printf '%s\n' "unsupported matrix architecture was accepted" >&2
  exit 1
fi
if ! grep -Fx \
     "FLYOLOGY_LINUX_ARCH must be arm64/aarch64 or amd64/x86_64" \
     "$test_root/unsupported.output" >/dev/null
then
  printf '%s\n' "unsupported matrix architecture reported the wrong error" >&2
  cat "$test_root/unsupported.output" >&2
  exit 1
fi
if grep -q '^Testing Linux ' "$test_root/unsupported.output"; then
  printf '%s\n' "unsupported matrix architecture began a matrix cell" >&2
  exit 1
fi
if [ -s "$unsupported_log" ]; then
  printf '%s\n' "unsupported matrix architecture invoked Docker" >&2
  exit 1
fi
if [ -s "$unsupported_alr_log" ]; then
  printf '%s\n' "unsupported matrix architecture invoked Alire" >&2
  exit 1
fi

matrix_file="$project_root/scripts/alire-runtime-matrix.txt"
awk -F: '
  BEGIN {
    print "<!-- BEGIN ALIRE LINUX RUNTIME MATRIX -->"
    print "| Provider | GNAT release | GPRbuild release | Linux/x86-64 | Linux/AArch64 |"
    print "| --- | --- | --- | --- | --- |"
  }
  $1 !~ /^#/ && NF {
    arm64 = $4 == "amd64,arm64" ? "required" : "not published"
    printf "| `%s` | `%s` | `%s` | required | %s |\n", $1, $2, $3, arm64
  }
  END {
    print "<!-- END ALIRE LINUX RUNTIME MATRIX -->"
  }
' "$matrix_file" >"$test_root/documentation.expected"

for documentation in README.md runtime/patches/README.md
do
  sed -n \
    '/<!-- BEGIN ALIRE LINUX RUNTIME MATRIX -->/,/<!-- END ALIRE LINUX RUNTIME MATRIX -->/p' \
    "$project_root/$documentation" >"$test_root/documentation.actual"
  diff -u "$test_root/documentation.expected" \
    "$test_root/documentation.actual"
done

printf '%s\n' "Alire runtime matrix enumeration tests passed"
