#!/bin/sh
set -eu

spike_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$spike_root/../../.." && pwd)
cargo_target="$spike_root/build/cargo"
rts_root="$spike_root/build/rts"

build_rust () {
   cargo test --manifest-path "$spike_root/Cargo.toml" --target-dir "$cargo_target" --offline
   cargo build --manifest-path "$spike_root/Cargo.toml" --target-dir "$cargo_target" --offline
   cargo build --manifest-path "$spike_root/Cargo.toml" --target-dir "$cargo_target" --offline --release
}

prepare_runtime () {
   GPR_PROJECT_PATH="$project_root/flyology_allocators"
   export GPR_PROJECT_PATH
   cd "$project_root"
   alr build --stop-after=generation
   alr exec -- gprbuild -p -q -P "$project_root/flyology.gpr"
   FLYOLOGY_RTS_DIR="$rts_root" "$project_root/scripts/prepare-rts.sh"
   if [ "$(uname -s)" = Darwin ]; then
      alr exec -- gcc -dumpspecs >"$spike_root/build/gnat-gcc-specs.txt"
      grep -q -- "-no_compact_unwind" "$spike_root/build/gnat-gcc-specs.txt"
   fi
}

library_path () {
   profile=$1
   linkage=$2
   case "$(uname -s):$linkage" in
      Darwin:static) printf '%s/%s/libflyology_rust_unwind_spike.a\n' "$cargo_target" "$profile" ;;
      Darwin:dynamic) printf '%s/%s/libflyology_rust_unwind_spike.dylib\n' "$cargo_target" "$profile" ;;
      Linux:static) printf '%s/%s/libflyology_rust_unwind_spike.a\n' "$cargo_target" "$profile" ;;
      Linux:dynamic) printf '%s/%s/libflyology_rust_unwind_spike.so\n' "$cargo_target" "$profile" ;;
      *) echo "unsupported host/linkage: $(uname -s)/$linkage" >&2; exit 1 ;;
   esac
}

build_variant () {
   profile=$1
   linkage=$2
   driver_name=$3
   link_driver=$4
   variant="$linkage-$profile-$driver_name"
   rust_library=$(library_path "$profile" "$linkage")

   FLYOLOGY_RUST_UNWIND_VARIANT=$variant
   FLYOLOGY_RUST_UNWIND_LINK_DRIVER=$link_driver
   FLYOLOGY_RUST_UNWIND_LIBRARY=$rust_library
   export FLYOLOGY_RUST_UNWIND_VARIANT
   export FLYOLOGY_RUST_UNWIND_LINK_DRIVER
   export FLYOLOGY_RUST_UNWIND_LIBRARY

   cd "$project_root"
   alr exec -- gprbuild --RTS="$rts_root" -p -q -P "$spike_root/unwind_spike.gpr"

   if command -v otool >/dev/null 2>&1; then
      otool -l "$rust_library" >"$spike_root/build/$variant/rust-library-load-commands.txt"
   fi

   for program in unwind_native unwind_lightweight; do
      executable="$spike_root/build/$variant/bin/$program"
      if command -v otool >/dev/null 2>&1; then
         otool -l "$executable" >"$spike_root/build/$variant/$program-load-commands.txt"
         otool -L "$executable" >"$spike_root/build/$variant/$program-linked-libraries.txt"
      fi
      nm "$executable" >"$spike_root/build/$variant/$program-symbols.txt"
   done
}

run_success () {
   variant=$1
   for program in unwind_native unwind_lightweight; do
      "$spike_root/build/$variant/bin/$program"
   done
}

run_expected_failure () {
   variant=$1
   for program in unwind_native unwind_lightweight; do
      executable="$spike_root/build/$variant/bin/$program"
      log="$spike_root/build/$variant/$program-negative.log"
      set +e
      "$executable" >"$log" 2>&1
      status=$?
      set -e
      if [ "$status" -eq 0 ]; then
         echo "$variant/$program unexpectedly caught the Rust panic" >&2
         exit 1
      fi
      if ! grep -q "failed to initiate panic, error 5" "$log"; then
         echo "$variant/$program failed for an unexpected reason" >&2
         sed -n '1,120p' "$log" >&2
         exit 1
      fi
   done
}

assert_section () {
   variant=$1
   expected=$2
   load_commands="$spike_root/build/$variant/unwind_native-load-commands.txt"
   if [ "$expected" = present ]; then
      grep -q "sectname __unwind_info" "$load_commands"
   elif grep -q "sectname __unwind_info" "$load_commands"; then
      echo "$variant unexpectedly contains __unwind_info" >&2
      exit 1
   fi
}

build_rust
prepare_runtime

case "$(uname -s)" in
   Darwin)
      for profile in debug release; do
         build_variant "$profile" static gcc gcc
         run_expected_failure "static-$profile-gcc"
         assert_section "static-$profile-gcc" absent

         build_variant "$profile" static clang "$spike_root/clang-link.sh"
         run_success "static-$profile-clang"
         assert_section "static-$profile-clang" present

         build_variant "$profile" static clang-rust-last "$spike_root/clang-rust-last-link.sh"
         run_success "static-$profile-clang-rust-last"
         assert_section "static-$profile-clang-rust-last" present

         build_variant "$profile" static clang-no-compact "$spike_root/clang-no-compact-unwind-link.sh"
         run_expected_failure "static-$profile-clang-no-compact"
         assert_section "static-$profile-clang-no-compact" absent

         build_variant "$profile" dynamic gcc gcc
         run_success "dynamic-$profile-gcc"
         assert_section "dynamic-$profile-gcc" absent
         grep -q "sectname __unwind_info" \
            "$spike_root/build/dynamic-$profile-gcc/rust-library-load-commands.txt"
      done
      ;;
   Linux)
      for profile in debug release; do
         build_variant "$profile" static gcc gcc
         run_success "static-$profile-gcc"
         build_variant "$profile" dynamic gcc gcc
         run_success "dynamic-$profile-gcc"
      done
      ;;
esac

echo "Rust unwind spike passed"
