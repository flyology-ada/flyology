#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root="$project_root/build/tests/atomic-store-entrypoints"

case "$test_root" in
  "$project_root"/build/tests/atomic-store-entrypoints) ;;
  *)
    printf '%s\n' "refusing unsafe atomic-store entrypoint test root: $test_root" >&2
    exit 1
    ;;
esac

rm -rf -- "$test_root"
mkdir -p \
  "$test_root/scripts" \
  "$test_root/proof" \
  "$test_root/build/tmp" \
  "$test_root/fake-bin" \
  "$test_root/gnat_native_16.1.0_fixture/bin" \
  "$test_root/flyology_allocators/benchmarks/bin" \
  "$test_root/flyology_allocators/benchmarks/scripts" \
  "$test_root/flyology_allocators/scripts" \
  "$test_root/flyology_allocators/tests" \
  "$test_root/vendor/website-kit/scripts" \
  "$test_root/website/journal/_entry-template" \
  "$test_root/assets/brand"

for script in \
  build-site.sh \
  build-tla-allocator-refinement.sh \
  check-tla.sh \
  configure-atomic-store-family.sh \
  docs.sh \
  find-alr.sh \
  gnat-native-prefix.sh \
  gnat-native-release.sh \
  prepare-atomic-store-config.sh \
  prove.sh
do
  cp "$project_root/scripts/$script" "$test_root/scripts/"
done
cp "$project_root/flyology_allocators/scripts/configure-atomic-store-family.sh" \
  "$test_root/flyology_allocators/scripts/"
cp "$project_root/flyology_allocators/benchmarks/scripts/run.sh" \
  "$test_root/flyology_allocators/benchmarks/scripts/"

printf '%s\n' \
  '#!/bin/sh' \
  'case "${1:-}" in' \
  '  -dumpfullversion) printf "%s\n" 16.1.0 ;;' \
  'esac' \
  >"$test_root/gnat_native_16.1.0_fixture/bin/gcc"
chmod +x "$test_root/gnat_native_16.1.0_fixture/bin/gcc"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'selector="$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/config/flyology_atomic_store_config.gpr"' \
  'case " $* " in' \
  '  *" printenv "*)' \
  '    printf '\''export GNAT_NATIVE_ALIRE_PREFIX="%s"\n'\'' "$FLYOLOGY_ENTRYPOINT_TOOLCHAIN"' \
  '    ;;' \
  '  *" gnatprove "*)' \
  '    test -f "$selector"' \
  '    touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/proof-project-loaded"' \
  '    ;;' \
  '  *" exec -- gnatdoc "*)' \
  '    test -f "$selector"' \
  '    touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/docs-project-loaded"' \
  '    printf "%s\n" "fixture GNATdoc stop" >&2' \
  '    exit 73' \
  '    ;;' \
  '  *"flyology_allocators/scripts/configure-atomic-store-family.sh"*)' \
  '    case "$PWD" in' \
  '      "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT")' \
  '        touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/tla-configured-in-build-environment"' \
  '        ;;' \
  '      "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/flyology_allocators/benchmarks")' \
  '        touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/benchmark-configured-in-build-environment"' \
  '        ;;' \
  '      *) printf "%s\n" "unexpected selector working directory: $PWD" >&2; exit 76 ;;' \
  '    esac' \
  '    PATH="$FLYOLOGY_ENTRYPOINT_TOOLCHAIN/bin:$PATH" "$3"' \
  '    ;;' \
  '  *" exec -- gprbuild "*)' \
  '    allocator_root="$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/flyology_allocators"' \
  '    allocator_selector="$allocator_root/config/flyology_allocators_atomic_store_config.gpr"' \
  '    test -f "$allocator_selector"' \
  '    grep -F '\''Compiler_Version := "16.1.0";'\'' "$allocator_selector" >/dev/null' \
  '    grep -F '\''Source_Dir := "src/atomic_stores/gnat-15-plus/";'\'' "$allocator_selector" >/dev/null' \
  '    case " $* " in' \
  '      *"allocator_tests.gpr"*)' \
  '        test "$PWD" = "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT"' \
  '        test -f "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/tla-configured-in-build-environment"' \
  '        touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/tla-replay-project-loaded"' \
  '        ;;' \
  '      *"flyology_allocator_benchmarks.gpr"*)' \
  '        test "$PWD" = "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/flyology_allocators/benchmarks"' \
  '        test -f "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/benchmark-configured-in-build-environment"' \
  '        touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/benchmark-project-loaded"' \
  '        ;;' \
  '      *) printf "%s\n" "unexpected fixture GPRbuild project: $*" >&2; exit 77 ;;' \
  '    esac' \
  '    ;;' \
  '  *" build "*) test -f "$selector" ;;' \
  '  *) printf "%s\n" "unexpected fixture Alire invocation: $*" >&2; exit 74 ;;' \
  'esac' >"$test_root/fake-bin/alr"
chmod +x "$test_root/fake-bin/alr"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'test -f "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/benchmark-project-loaded"' \
  'touch "$FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT/benchmark-executed"' \
  >"$test_root/flyology_allocators/benchmarks/bin/allocator_benchmark"
chmod +x "$test_root/flyology_allocators/benchmarks/bin/allocator_benchmark"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'case "$1" in' \
  '  *render-gnatdoc-theme.mjs)' \
  '    mkdir -p "$3/template"' \
  '    printf "%s\n" "<a href='\''../guide/'\''>fixture</a>" >"$3/template/index.xhtml"' \
  '    ;;' \
  '  *install-assets.mjs) ;;' \
  '  *) printf "%s\n" "unexpected fixture Node invocation: $*" >&2; exit 75 ;;' \
  'esac' >"$test_root/fake-bin/node"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$test_root/fake-bin/gnatdoc"
chmod +x "$test_root/fake-bin/node" "$test_root/fake-bin/gnatdoc"

printf '%s\n' '// fixture' \
  >"$test_root/vendor/website-kit/scripts/render-gnatdoc-theme.mjs"
printf '%s\n' '// fixture' \
  >"$test_root/vendor/website-kit/scripts/install-assets.mjs"
printf '%s\n' '<html></html>' \
  >"$test_root/website/journal/_entry-template/index.html"
printf '%s\n' '<svg></svg>' >"$test_root/assets/brand/fixture.svg"

export FLYOLOGY_ENTRYPOINT_FIXTURE_ROOT="$test_root"
export FLYOLOGY_ENTRYPOINT_TOOLCHAIN="$test_root/gnat_native_16.1.0_fixture"
ALR="$test_root/fake-bin/alr" \
PATH="$test_root/fake-bin:$PATH" \
TMPDIR="$test_root/build/tmp" \
  "$test_root/scripts/prove.sh" >"$test_root/prove.log" 2>&1
if [ ! -f "$test_root/proof-project-loaded" ]; then
  printf '%s\n' "proof entrypoint did not load the project after generating its selector" >&2
  exit 1
fi

if ! grep -F 'build-tla-allocator-refinement.sh' \
  "$test_root/scripts/check-tla.sh" >/dev/null
then
  printf '%s\n' "TLA entrypoint does not use its selector-aware replay builder" >&2
  exit 1
fi
"$test_root/scripts/build-tla-allocator-refinement.sh" \
  "$test_root/fake-bin/alr" >"$test_root/tla-replay.log" 2>&1
if [ ! -f "$test_root/tla-replay-project-loaded" ]; then
  printf '%s\n' "TLA replay loaded the allocator project before generating its selector" >&2
  exit 1
fi

rm -f -- \
  "$test_root/flyology_allocators/config/flyology_allocators_atomic_store_config.gpr"
ALR="$test_root/fake-bin/alr" \
PATH="$test_root/fake-bin:$PATH" \
  "$test_root/flyology_allocators/benchmarks/scripts/run.sh" \
  >"$test_root/benchmark.log" 2>&1
if [ ! -f "$test_root/benchmark-executed" ]; then
  printf '%s\n' "benchmark entrypoint loaded its project before generating its selector" >&2
  exit 1
fi

rm -f -- "$test_root/config/flyology_atomic_store_config.gpr"
site_status=0
ALR="$test_root/fake-bin/alr" \
PATH="$test_root/fake-bin:$PATH" \
TMPDIR="$test_root/build/tmp" \
  "$test_root/scripts/build-site.sh" >"$test_root/site.log" 2>&1 \
  || site_status=$?
if [ "$site_status" -eq 0 ] \
  || [ ! -f "$test_root/docs-project-loaded" ] \
  || ! grep -F "fixture GNATdoc stop" "$test_root/site.log" >/dev/null
then
  printf '%s\n' "site entrypoint did not generate its selector before GNATdoc" >&2
  exit 1
fi

printf '%s\n' "atomic-store clean-entrypoint selection: PASS"
