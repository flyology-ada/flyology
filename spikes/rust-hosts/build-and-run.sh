#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
rts_root=$project_root/build/alire-rts
ada_object_dir=$spike_root/build/ada-obj
rust_target_dir=$spike_root/build/rust-target

cd "$project_root"
"$alr" build

allocator_root=$(
  "$alr" exec -- sh -c 'printf "%s\n" "$FLYOLOGY_ALLOCATORS_ALIRE_PREFIX"'
)
if [ -z "$allocator_root" ] || [ ! -d "$allocator_root/lib" ]; then
  printf '%s\n' "cannot locate the resolved flyology_allocators dependency" >&2
  exit 1
fi

"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$rts_root" \
  -c -p \
  -P "$spike_root/ada/rust_host_probe.gpr" \
  "$spike_root/ada/rust_host_probe.adb"

(
  cd "$ada_object_dir"
  "$alr" exec -- gnatbind \
    --RTS="$rts_root" \
    -n -Es \
    -aO"$project_root/lib" \
    -aO"$allocator_root/lib" \
    -o b__rust_host_probe.adb \
    rust_host_probe.ali
  "$alr" exec -- gcc \
    --RTS="$rts_root" \
    -c -gnat2022 -I. \
    b__rust_host_probe.adb
)

set -- \
  -C "link-arg=$ada_object_dir/b__rust_host_probe.o" \
  -C "link-arg=$ada_object_dir/rust_host_probe.o" \
  -C "link-arg=$project_root/lib/libFlyology.a" \
  -C "link-arg=$allocator_root/lib/libflyology_allocators.a" \
  -C "link-arg=$rts_root/adalib/libgnarl.a" \
  -C "link-arg=$rts_root/adalib/libgnat.a"

libgcc=$("$alr" exec -- gcc -print-libgcc-file-name)
toolchain_library_dir=$(dirname -- "$libgcc")
expect_exec_elf=0

case $(uname -s) in
  Darwin)
    deployment_target=$(sw_vers -productVersion | awk -F. '{ print $1 "." $2 }')
    MACOSX_DEPLOYMENT_TARGET=$deployment_target
    export MACOSX_DEPLOYMENT_TARGET
    for support_library in libemutls_w.a libheapt_w.a; do
      support_path=$toolchain_library_dir/$support_library
      if [ ! -f "$support_path" ]; then
        printf '%s\n' "missing GNAT support archive: $support_path" >&2
        exit 1
      fi
      set -- "$@" -C "link-arg=$support_path"
    done
    ;;
  Linux)
    set -- "$@" -C link-arg=-ldl -C link-arg=-pthread
    case $(uname -m) in
      x86_64|amd64)
        #  The prepared GNAT runtime and this probe's Ada objects use static
        #  R_X86_64_32/32S relocations. Rust defaults Linux executables to PIE,
        #  which rust-lld correctly rejects for those objects. Keep Rust's
        #  normal code generation and make only the final executable non-PIE.
        set -- "$@" -C link-arg=-no-pie
        expect_exec_elf=1
        ;;
    esac
    ;;
  *)
    printf '%s\n' "unsupported spike host: $(uname -s)" >&2
    exit 1
    ;;
esac

set -- "$@" -C "link-arg=$libgcc"

cargo rustc \
  --manifest-path "$spike_root/rust/Cargo.toml" \
  --target-dir "$rust_target_dir" \
  -- "$@"

executable=$rust_target_dir/debug/flyology-rust-host-spike
case $(uname -s) in
  Darwin)
    if otool -L "$executable" | grep -E 'libgnat|libgnarl' >/dev/null; then
      printf '%s\n' "Rust executable unexpectedly depends on a shared GNAT runtime" >&2
      exit 1
    fi
    ;;
  Linux)
    if ldd "$executable" | grep -E 'libgnat|libgnarl' >/dev/null; then
      printf '%s\n' "Rust executable unexpectedly depends on a shared GNAT runtime" >&2
      exit 1
    fi
    if [ "$expect_exec_elf" -eq 1 ]; then
      elf_type=$(readelf -h "$executable" | awk '$1 == "Type:" { print $2 }')
      if [ "$elf_type" != EXEC ]; then
        printf '%s\n' \
          "Linux/x86-64 Rust-host executable must be non-PIE ELF type EXEC, got: $elf_type" >&2
        exit 1
      fi
    fi
    ;;
esac

"$project_root/scripts/run-with-timeout.sh" 30 "$executable"
