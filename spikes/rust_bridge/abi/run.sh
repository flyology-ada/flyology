#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cargo_target="$spike_root/build/cargo"

build_variant () {
   profile=$1
   linkage=$2
   driver_kind=$3
   variant="$linkage-$profile-$driver_kind"
   profile_dir=$profile
   cargo_flags=
   link_driver=gcc

   if [ "$profile" = release ]; then
      cargo_flags=--release
   fi

   cargo build \
      --manifest-path "$spike_root/Cargo.toml" \
      --target-dir "$cargo_target" \
      $cargo_flags

   case "$(uname -s):$linkage" in
      Darwin:static) rust_library="$cargo_target/$profile_dir/libflyology_rust_abi_spike.a" ;;
      Darwin:dynamic) rust_library="$cargo_target/$profile_dir/libflyology_rust_abi_spike.dylib" ;;
      Linux:static) rust_library="$cargo_target/$profile_dir/libflyology_rust_abi_spike.a" ;;
      Linux:dynamic) rust_library="$cargo_target/$profile_dir/libflyology_rust_abi_spike.so" ;;
      *) echo "unsupported host/linkage: $(uname -s)/$linkage" >&2; exit 1 ;;
   esac

   if [ "$driver_kind" = clang ]; then
      link_driver="$spike_root/clang-link.sh"
   fi

   if [ "$(uname -s)" = Linux ]; then
      mkdir -p "$spike_root/build/$variant/obj" "$spike_root/build/$variant/bin"
      set -- "$rust_library"
      if [ "$linkage" = dynamic ]; then
         set -- "$@" "-Wl,-rpath,$cargo_target/$profile_dir"
      fi
      alr exec -- env -u GPR_CONFIG gnatmake \
         -f \
         -D "$spike_root/build/$variant/obj" \
         -o "$spike_root/build/$variant/bin/rust_abi_spike" \
         -gnat2022 -gnata -gnatVa -gnatwa -gnatyM110 \
         "$spike_root/ada/rust_abi_spike.adb" \
         -largs "$@"
   else
      alr exec -- env -u GPR_CONFIG gprbuild \
         -p -q -P "$spike_root/rust_abi_spike.gpr" \
         -X"RUST_ABI_VARIANT=$variant" \
         -X"RUST_ABI_LINK_DRIVER=$link_driver" \
         -largs "$rust_library"
   fi

   executable="$spike_root/build/$variant/bin/rust_abi_spike"
   if command -v otool >/dev/null 2>&1; then
      otool -L "$executable" >"$spike_root/build/$variant/linked-libraries.txt"
   elif command -v ldd >/dev/null 2>&1; then
      ldd "$executable" >"$spike_root/build/$variant/linked-libraries.txt"
   fi
   nm "$executable" >"$spike_root/build/$variant/symbols.txt"
}

run_success () {
   profile=$1
   linkage=$2
   driver_kind=$3
   variant="$linkage-$profile-$driver_kind"
   build_variant "$profile" "$linkage" "$driver_kind"
   "$spike_root/build/$variant/bin/rust_abi_spike"
}

run_darwin_gcc_static_negative () {
   profile=$1
   variant="static-$profile-gcc"
   executable="$spike_root/build/$variant/bin/rust_abi_spike"
   log="$spike_root/build/$variant/panic-negative.log"
   build_variant "$profile" static gcc
   "$executable" --skip-panic
   set +e
   "$executable" >"$log" 2>&1
   status=$?
   set -e
   if [ "$status" -eq 0 ]; then
      echo "GNAT GCC static link unexpectedly supported Rust panic unwind" >&2
      exit 1
   fi
   if ! grep -q "failed to initiate panic" "$log"; then
      echo "GNAT GCC static panic failed for an unexpected reason" >&2
      cat "$log" >&2
      exit 1
   fi
}

case "$(uname -s)" in
   Darwin)
      run_darwin_gcc_static_negative debug
      run_darwin_gcc_static_negative release
      run_success debug static clang
      run_success release static clang
      run_success debug dynamic gcc
      run_success release dynamic gcc
      ;;
   Linux)
      run_success debug static gcc
      run_success release static gcc
      run_success debug dynamic gcc
      run_success release dynamic gcc
      ;;
esac

echo "Rust ABI spike passed: static/dynamic, debug/release"
