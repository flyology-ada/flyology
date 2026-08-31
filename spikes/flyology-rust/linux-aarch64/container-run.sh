#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

cd "$project_root"

printf '%s\n' "Linux Rust bridge spike environment"
uname -a
sed -n '1,8p' /etc/os-release
rustc --version --verbose
cargo --version
alr version
alr exec -- gcc --version | sed -n '1p'
alr exec -- gprbuild --version | sed -n '1p'
alr exec -- gnatls -v | sed -n '1,4p'

printf '%s\n' "CASE abi"
./spikes/rust_bridge/abi/run.sh

printf '%s\n' "CASE supported-gprbuild-link-probe"
./spikes/flyology-rust/linux-aarch64/toolchain-probe.sh

printf '%s\n' "CASE ada-hosts-rust-async"
FLYOLOGY_RUST_STRESS_RUNS=1 ./spikes/flyology_rust/ada_hosts/run.sh

printf '%s\n' "CASE rust-hosts-ada"
./spikes/rust-hosts/build-and-run.sh

printf '%s\n' "CASE direct-futures"
./spikes/flyology-rust/direct-futures/run.sh

printf '%s\n' "CASE unwind"
./spikes/rust_bridge/unwind/run.sh

printf '%s\n' "PASS Linux Rust bridge spike matrix"
