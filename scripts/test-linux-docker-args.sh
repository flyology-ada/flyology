#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_root/build"
fixture_dir=$(mktemp -d "$project_root/build/test-linux-docker-args.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$fixture_dir/bin"
cat > "$fixture_dir/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FLYOLOGY_DOCKER_CALL"
exit 42
EOF
chmod +x "$fixture_dir/bin/docker"

for case_name in amd64 x86_64 arm64 aarch64; do
  case "$case_name" in
    amd64|x86_64) expected_arch=amd64 ;;
    arm64|aarch64) expected_arch=arm64 ;;
  esac

  call_file="$fixture_dir/$case_name.call"
  if FLYOLOGY_LINUX_ARCH="$case_name" \
    FLYOLOGY_LINUX_IMAGE="test-image-$expected_arch" \
    FLYOLOGY_GNAT_PROVIDER=test_provider \
    FLYOLOGY_GNAT_VERSION=test_gnat_version \
    FLYOLOGY_GPRBUILD_VERSION=test_gprbuild_version \
    FLYOLOGY_DOCKER_CALL="$call_file" \
    PATH="$fixture_dir/bin:$PATH" \
    "$project_root/scripts/test-linux-docker.sh" > "$fixture_dir/$case_name.log" 2>&1
  then
    printf 'Docker stub did not fail for %s\n' "$case_name" >&2
    exit 1
  else
    status=$?
  fi
  if [ "$status" -ne 42 ]; then
    printf 'Unexpected runner status %s for %s\n' "$status" "$case_name" >&2
    cat "$fixture_dir/$case_name.log" >&2
    exit 1
  fi

  cat > "$fixture_dir/$case_name.expected" <<EOF
build
--platform
linux/$expected_arch
--build-arg
TARGETARCH=$expected_arch
--build-arg
GNAT_PROVIDER=test_provider
--build-arg
GNAT_VERSION=test_gnat_version
--build-arg
GPRBUILD_VERSION=test_gprbuild_version
-f
$project_root/docker/linux/Dockerfile
-t
test-image-$expected_arch
$project_root
EOF
  if ! cmp -s "$fixture_dir/$case_name.expected" "$call_file"; then
    printf 'Unexpected Docker build arguments for %s\n' "$case_name" >&2
    diff -u "$fixture_dir/$case_name.expected" "$call_file" >&2 || true
    exit 1
  fi
done

call_file="$fixture_dir/unsupported.call"
if FLYOLOGY_LINUX_ARCH=unsupported \
  FLYOLOGY_DOCKER_CALL="$call_file" \
  PATH="$fixture_dir/bin:$PATH" \
  "$project_root/scripts/test-linux-docker.sh" > "$fixture_dir/unsupported.log" 2>&1
then
  printf '%s\n' 'Unsupported architecture was accepted' >&2
  exit 1
fi
if [ -e "$call_file" ]; then
  printf '%s\n' 'Docker was called for an unsupported architecture' >&2
  exit 1
fi
if ! grep -Fq 'FLYOLOGY_LINUX_ARCH must be' "$fixture_dir/unsupported.log"; then
  cat "$fixture_dir/unsupported.log" >&2
  exit 1
fi

printf '%s\n' 'Linux Docker build arguments passed'
