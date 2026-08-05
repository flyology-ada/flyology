#!/bin/sh
set -eu

revision=${HTTP_BENCH_GIT_REVISION:?HTTP_BENCH_GIT_REVISION is required}
repository=${HTTP_BENCH_GIT_REPOSITORY:-https://github.com/flyology-ada/flyology.git}
workspace=${HTTP_BENCH_WORKSPACE:-/workspace/flyology}
output_root=${HTTP_BENCH_OUTPUT_ROOT:-/results}
alire_version=${HTTP_BENCH_ALIRE_VERSION:-2.1.1}
oha_version=${HTTP_BENCH_OHA_VERSION:-1.7.0}
rust_version=${HTTP_BENCH_RUST_VERSION:-1.97.1}

case "$(uname -m)" in
   arm64|aarch64)
      alire_arch=aarch64
      alire_sha=d76c93ad3dc631826144e10bdabc6b3bf98783805bebfd5e4a0e852dd524d812
      oha_arch=arm64
      oha_sha=d62dc196b9b7114c70c4b60cc255646de21aa6afa630fa37f72177c0c7832ae9
      ;;
   amd64|x86_64)
      alire_arch=x86_64
      alire_sha=09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7
      oha_arch=amd64
      oha_sha=36e081a31b80136cb35ac9385d1252dc30696378281c9c400abd3fee32929231
      ;;
   *)
      printf '%s\n' "unsupported Kubernetes architecture" >&2
      exit 2
      ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
   build-essential ca-certificates curl git libssl-dev pkg-config procps \
   python3 ripgrep unzip util-linux
rm -rf /var/lib/apt/lists/*

curl -fsSL \
   "https://github.com/alire-project/alire/releases/download/v${alire_version}/alr-${alire_version}-bin-${alire_arch}-linux.zip" \
   -o /tmp/alire.zip
printf '%s  %s\n' "$alire_sha" /tmp/alire.zip | sha256sum --check -
unzip -q /tmp/alire.zip -d /opt/alire
ln -s /opt/alire/bin/alr /usr/local/bin/alr
rm /tmp/alire.zip

curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
   -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "$rust_version"
rm /tmp/rustup-init.sh
export PATH="/root/.cargo/bin:$PATH"

curl -fsSL \
   "https://github.com/hatoo/oha/releases/download/v${oha_version}/oha-linux-${oha_arch}" \
   -o /usr/local/bin/oha
printf '%s  %s\n' "$oha_sha" /usr/local/bin/oha | sha256sum --check -
chmod +x /usr/local/bin/oha

git clone --filter=blob:none --no-checkout "$repository" "$workspace"
git -C "$workspace" checkout --detach "$revision"
if [ -f /bootstrap/overlay.tar.gz ]; then
   python3 /bootstrap/overlay-tool.py verify \
      --archive /bootstrap/overlay.tar.gz \
      --manifest /bootstrap/overlay-manifest.json \
      --extract "$workspace" \
      --source-root "$workspace"
   mkdir -p "$output_root"
   cp /bootstrap/overlay-manifest.json "$output_root/overlay-manifest.json"
fi

export ALR=/usr/local/bin/alr
export HTTP_BENCH_GNAT_VERSION=${HTTP_BENCH_GNAT_VERSION:-15.3.1}
export HTTP_BENCH_GPRBUILD_VERSION=${HTTP_BENCH_GPRBUILD_VERSION:-25.0.1}
export HTTP_BENCH_LOOPS=${HTTP_BENCH_LOOPS:-16}
export HTTP_BENCH_RUST_VERSION="$rust_version"
export HTTP_BENCH_CARGO_VERSION="$rust_version"
"$workspace/showcases/http-comparison/scripts/build.sh"

HTTP_BENCH_GIT_DIRTY=${HTTP_BENCH_GIT_DIRTY:-0} \
HTTP_BENCH_MODE=native-linux-loopback \
HTTP_BENCH_OUTPUT_ROOT="$output_root" \
HTTP_BENCH_REDACT_HOST=1 \
HTTP_BENCH_SKIP_BUILD=1 \
   "$workspace/showcases/http-comparison/scripts/run.sh"
