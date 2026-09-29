#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

have_boost=false
boost_include=.
if [ -n "${FLYOLOGY_BENCH_BOOST_ROOT:-}" ]; then
  if [ -f "$FLYOLOGY_BENCH_BOOST_ROOT/boost/container/vector.hpp" ]; then
    have_boost=true
    boost_include=$FLYOLOGY_BENCH_BOOST_ROOT
  elif [ -f "$FLYOLOGY_BENCH_BOOST_ROOT/include/boost/container/vector.hpp" ]; then
    have_boost=true
    boost_include=$FLYOLOGY_BENCH_BOOST_ROOT/include
  fi
elif command -v brew >/dev/null 2>&1; then
  boost_prefix=$(brew --prefix boost 2>/dev/null || true)
  if [ -f "$boost_prefix/include/boost/container/vector.hpp" ]; then
    have_boost=true
    boost_include=$boost_prefix/include
  fi
elif [ -f /usr/include/boost/container/vector.hpp ]; then
  have_boost=true
  boost_include=/usr/include
fi

have_abseil=false
abseil_include=.
abseil_lib=.
cpp_driver=g++
cpp_runtime=libstdc++
if [ "$have_boost" = true ] && command -v pkg-config >/dev/null 2>&1 \
  && pkg-config --exists absl_flat_hash_map
then
  abseil_include=$(pkg-config --variable=includedir absl_flat_hash_map)
  abseil_lib=$(pkg-config --variable=libdir absl_flat_hash_map)
  case $(uname -s) in
    Darwin)
      # Homebrew Abseil uses Apple libc++; compile every C++ peer with the same
      # frontend so the process never crosses an incompatible template ABI.
      if command -v clang++ >/dev/null 2>&1; then
        have_abseil=true
        cpp_driver=$(command -v clang++)
        cpp_runtime=libc++
      fi
      ;;
    *)
      have_abseil=true
      ;;
  esac
fi

"$project_root/showcases/prepare-alire.sh" >/dev/null
FLYOLOGY_DEFAULT=native \
  "$project_root/showcases/prepare-rts.sh" >/dev/null
(
  cd "$project_root/showcases"
  FLYOLOGY_SHOWCASE_PROFILE=release \
  FLYOLOGY_BENCH_CPP_DRIVER=$cpp_driver \
  FLYOLOGY_BENCH_CPP_RUNTIME=$cpp_runtime \
  FLYOLOGY_BENCH_HAVE_BOOST=$have_boost \
  FLYOLOGY_BENCH_BOOST_INCLUDE=$boost_include \
  FLYOLOGY_BENCH_HAVE_ABSEIL=$have_abseil \
  FLYOLOGY_BENCH_ABSEIL_INCLUDE=$abseil_include \
  FLYOLOGY_BENCH_ABSEIL_LIB=$abseil_lib \
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -f \
      -P data_structures_benchmark.gpr
)

benchmark=$project_root/showcases/bin/data_structures_benchmark
printf 'Built runnable benchmark: %s\n' "$benchmark"
if [ "${FLYOLOGY_BENCH_BUILD_ONLY:-0}" != 1 ]; then
  "$benchmark" "$@"
fi
