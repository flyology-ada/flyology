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
  "$test_root/vendor/website-kit/scripts" \
  "$test_root/website/journal/_entry-template" \
  "$test_root/assets/brand"

for script in \
  build-site.sh \
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

printf '%s\n' '#!/bin/sh' 'exit 0' \
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
  '  *" build "*) test -f "$selector" ;;' \
  '  *) printf "%s\n" "unexpected fixture Alire invocation: $*" >&2; exit 74 ;;' \
  'esac' >"$test_root/fake-bin/alr"
chmod +x "$test_root/fake-bin/alr"

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
