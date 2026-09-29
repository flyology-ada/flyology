#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli="$project_root/bin/flyology"
alr=$(command -v alr)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/flyology-cli-tests.XXXXXX")
fake_bin="$scratch/fake-bin"
tool_log="$scratch/tools.log"

cleanup () {
   rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

fail () {
   printf '%s\n' "test failure: $*" >&2
   exit 1
}

assert_contains () {
   file=$1
   expected=$2
   grep -F -q -- "$expected" "$file" || fail "$file does not contain: $expected"
}

mkdir -p "$fake_bin"

"$alr" exec -- gprbuild -q -p -P "$project_root/flyology_cli.gpr"

"$cli" --help >"$scratch/help.out"
assert_contains "$scratch/help.out" "flyology <command>"
"$cli" init --help >"$scratch/init-help.out"
assert_contains "$scratch/init-help.out" "--flyology-project"
if grep -F -q -- "--consumer" "$scratch/init-help.out"
then
   fail "init help exposed the redundant --consumer option"
fi
if grep -F -q -- "--agents" "$scratch/init-help.out"
then
   fail "init help exposed the redundant --agents option"
fi
if grep -F -q -- "--no-website" "$scratch/init-help.out"
then
   fail "init help exposed the redundant --no-website option"
fi
"$cli" init --bin --help >"$scratch/late-init-help.out"
assert_contains "$scratch/late-init-help.out" "--website"

if "$cli" init --consumer >"$scratch/consumer-option.out" 2>"$scratch/consumer-option.err"
then
   fail "removed --consumer option unexpectedly succeeded"
fi
assert_contains "$scratch/consumer-option.err" "unknown init option: --consumer"

for removed_option in --agents --no-website
do
   if "$cli" init "$removed_option" >"$scratch/removed-option.out" 2>"$scratch/removed-option.err"
   then
      fail "removed $removed_option option unexpectedly succeeded"
   fi
   assert_contains "$scratch/removed-option.err" "unknown init option: $removed_option"
done

for forbidden_name in ada interfaces standard system flyology gnat
do
   forbidden_project="$scratch/forbidden-$forbidden_name"
   if "$cli" init "$forbidden_project" --name "$forbidden_name" --lib --no-agents --yes \
     >"$scratch/forbidden-name.out" 2>"$scratch/forbidden-name.err"
   then
      fail "forbidden crate name $forbidden_name unexpectedly succeeded"
   fi
   assert_contains "$scratch/forbidden-name.err" "conflicts with a predefined unit or dependency"
   test ! -e "$forbidden_project" || fail "forbidden crate name created a destination"
done

cat >"$fake_bin/flyology-probe" <<'EOF'
#!/bin/sh
{
   printf '%s\n' "$#"
   printf '<%s>\n' "$@"
} >"$FLYOLOGY_PLUGIN_OUTPUT"
exit 37
EOF
chmod +x "$fake_bin/flyology-probe"

if FLYOLOGY_PLUGIN_OUTPUT="$scratch/plugin.out" PATH="$fake_bin:$PATH" \
  "$cli" probe "two words" --flag
then
   fail "extension command unexpectedly succeeded"
else
   extension_status=$?
fi
test "$extension_status" -eq 37 || fail "extension exit status was $extension_status, expected 37"
assert_contains "$scratch/plugin.out" "2"
assert_contains "$scratch/plugin.out" "<two words>"
assert_contains "$scratch/plugin.out" "<--flag>"

if "$cli" command-that-does-not-exist >"$scratch/unknown.out" 2>"$scratch/unknown.err"
then
   fail "unknown command unexpectedly succeeded"
fi
assert_contains "$scratch/unknown.err" "unknown command 'command-that-does-not-exist'"

cat >"$fake_bin/alr" <<'EOF'
#!/bin/sh
if test "$#" -eq 2 && test "$1" = index && test "$2" = --list
then
   if test "${FLYOLOGY_TEST_INDEX_MODE:-present}" = present
   then
      printf '%s\n' \
        '# NAME              URL' \
        '1 flyology          file:/test/flyology' \
        '2 community         git+https://github.com/alire-project/alire-index'
   else
      printf '%s\n' \
        '# NAME              URL' \
        '1 flyology_review   file:/test/review' \
        '2 community         git+https://github.com/alire-project/alire-index'
   fi
   exit 0
fi
printf 'alr' >>"$FLYOLOGY_TOOL_LOG"
printf ' <%s>' "$@" >>"$FLYOLOGY_TOOL_LOG"
printf '\n' >>"$FLYOLOGY_TOOL_LOG"
EOF

cat >"$fake_bin/apm" <<'EOF'
#!/bin/sh
printf 'apm' >>"$FLYOLOGY_TOOL_LOG"
printf ' <%s>' "$@" >>"$FLYOLOGY_TOOL_LOG"
printf '\n' >>"$FLYOLOGY_TOOL_LOG"
case "$1" in
   install) touch apm.lock.yaml ;;
   compile) printf '%s\n' '# Generated test guidance' >AGENTS.md ;;
esac
EOF

cat >"$fake_bin/git" <<'EOF'
#!/bin/sh
printf 'git' >>"$FLYOLOGY_TOOL_LOG"
printf ' <%s>' "$@" >>"$FLYOLOGY_TOOL_LOG"
printf '\n' >>"$FLYOLOGY_TOOL_LOG"
if test "$1" = init
then
   mkdir -p .git
elif test "$1" = submodule && test "$2" = add
then
   mkdir -p "$4"
   printf '%s\n' '[submodule "vendor/website-kit"]' >.gitmodules
fi
EOF
chmod +x "$fake_bin/alr" "$fake_bin/apm" "$fake_bin/git"

consumer="$scratch/consumer_app"
FLYOLOGY_TOOL_LOG="$tool_log" PATH="$fake_bin:$PATH" \
  "$cli" init "$consumer" --name consumer_app --bin \
  --no-agents --yes

test -f "$consumer/src/consumer_app.adb" || fail "binary source was not generated"
test ! -e "$consumer/apm.yml" || fail "APM manifest generated despite --no-agents"
test ! -e "$consumer/website" || fail "website generated despite its disabled default"
assert_contains "$consumer/alire.toml" 'executables = ["consumer_app"]'
assert_contains "$consumer/alire.toml" 'flyology = "^0.1.0"'
assert_contains "$consumer/consumer_app.gpr" 'with "flyology.gpr";'
assert_contains "$consumer/consumer_app.gpr" 'external ("FLYOLOGY_ROOT", "")'
assert_contains "$consumer/.gitignore" '/config/'
assert_contains "$consumer/.gitignore" '/apm_modules/'
assert_contains "$consumer/.gitignore" '/.agents/'
assert_contains "$consumer/.gitignore" '/docs/api/'
test ! -s "$tool_log" || fail "configured index caused an unexpected external setup command"

symlink_project="$scratch/symlink-project"
symlink_outside="$scratch/symlink-outside"
mkdir -p "$symlink_project" "$symlink_outside"
ln -s "$symlink_outside" "$symlink_project/src"
if FLYOLOGY_TOOL_LOG="$tool_log" PATH="$fake_bin:$PATH" \
  "$cli" init "$symlink_project" --name symlink_app --bin --no-agents --yes \
  >"$scratch/symlink.out" 2>"$scratch/symlink.err"
then
   fail "init followed a symbolic-link source directory"
fi
test ! -e "$symlink_outside/symlink_app.adb" || fail "source escaped through symbolic-link directory"
test ! -e "$symlink_project/alire.toml" || fail "symlink preflight wrote project files"
assert_contains "$scratch/symlink.err" "refusing symbolic-link output directory src"

current_project="$scratch/current_project"
mkdir -p "$current_project"
(
   cd "$current_project"
   FLYOLOGY_TOOL_LOG="$tool_log" PATH="$fake_bin:$PATH" \
     "$cli" init --bin --no-agents --yes
)
test -f "$current_project/current_project.gpr" || fail "current-directory init did not derive the crate name"

project_default="$scratch/project_default"
FLYOLOGY_TOOL_LOG="$tool_log" PATH="$fake_bin:$PATH" \
  "$cli" init "$project_default" --name project_default --bin --flyology-project --no-agents --yes
test ! -e "$project_default/website" || fail "Flyology project enabled its website by default"

stub="$scratch/stub"
mkdir -p "$stub"
cat >"$stub/flyology.gpr" <<'EOF'
project Flyology is
end Flyology;
EOF
GPR_PROJECT_PATH="$stub" "$alr" exec -- gprbuild -q -p -P "$consumer/consumer_app.gpr"
"$consumer/bin/consumer_app" >"$scratch/consumer.out"
assert_contains "$scratch/consumer.out" "Hello from consumer_app"

flyology_library="$scratch/flyology_library"
FLYOLOGY_TEST_INDEX_MODE=similar \
FLYOLOGY_TOOL_LOG="$tool_log" \
PATH="$fake_bin:$PATH" \
  "$cli" init "$flyology_library" --name flyology_library --lib \
  --flyology-project --website --yes

test -f "$flyology_library/src/flyology_library.ads" || fail "library source was not generated"
test -x "$flyology_library/scripts/docs.sh" || fail "documentation script is not executable"
test -x "$flyology_library/scripts/build-site.sh" || fail "site script is not executable"
test -f "$flyology_library/website/gnatdoc-theme.json" || fail "GNATdoc theme was not generated"
test -f "$flyology_library/.gitmodules" || fail "website-kit submodule was not configured"
sh -n "$flyology_library/scripts/docs.sh"
sh -n "$flyology_library/scripts/build-site.sh"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
  "$flyology_library/website/gnatdoc-theme.json"
assert_contains "$flyology_library/alire.toml" 'website = "https://flyology.org/"'
assert_contains "$flyology_library/flyology_library.gpr" \
  'for Resources_Dir ("html") use "docs/gnatdoc/html";'
assert_contains "$flyology_library/apm.yml" 'path: packages/profiles/ada-library'
assert_contains "$flyology_library/apm.yml" 'path: packages/profiles/flyology-website'
test -f "$flyology_library/website/flyology-mark.svg" || fail "website icon was not generated"
assert_contains "$flyology_library/scripts/docs.sh" \
  'cp vendor/website-kit/assets/fonts/geologica-latin-variable.woff2 docs/api/fonts/'
assert_contains "$flyology_library/scripts/docs.sh" \
  'cp vendor/website-kit/assets/scripts/ada-highlight.js docs/api/'
assert_contains "$flyology_library/scripts/docs.sh" 'cp website/flyology-mark.svg docs/api/'
assert_contains "$tool_log" 'alr <index> <--reset-community>'
assert_contains "$tool_log" 'alr <index> <--add=git+https://github.com/flyology-ada/alire-index.git>'
assert_contains "$tool_log" '<--name=flyology>'
assert_contains "$tool_log" '<--before=community>'
assert_contains "$tool_log" 'apm <install>'
assert_contains "$tool_log" 'apm <compile> <--target> <codex>'
assert_contains "$tool_log" 'git <submodule> <add>'

GPR_PROJECT_PATH="$stub" "$alr" exec -- \
  gprbuild -q -p -P "$flyology_library/flyology_library.gpr"

protected_project="$scratch/protected-project"
preflight_log="$scratch/preflight-tools.log"
mkdir -p "$protected_project"
printf '%s\n' sentinel >"$protected_project/README.md"
if FLYOLOGY_TEST_INDEX_MODE=similar FLYOLOGY_TOOL_LOG="$preflight_log" PATH="$fake_bin:$PATH" \
  "$cli" init "$protected_project" --name guarded_project --bin \
  --no-agents --yes >"$scratch/protected.out" 2>"$scratch/protected.err"
then
   fail "init overwrote an existing destination file"
fi
test "$(cat "$protected_project/README.md")" = sentinel || fail "existing README was changed"
test ! -e "$protected_project/alire.toml" || fail "init wrote files before completing collision checks"
test ! -s "$preflight_log" || fail "collision preflight changed Alire indexes"
assert_contains "$scratch/protected.err" "refusing to overwrite README.md"

declined="$scratch/declined"
if printf '%s\n' n | \
  FLYOLOGY_TEST_INDEX_MODE=similar FLYOLOGY_TOOL_LOG="$tool_log" PATH="$fake_bin:$PATH" \
  "$cli" init "$declined" --name declined --bin \
  --no-agents >"$scratch/declined.out" 2>"$scratch/declined.err"
then
   fail "init continued after index installation was declined"
fi
test ! -e "$declined" || fail "destination was created after index installation was declined"
assert_contains "$scratch/declined.err" "Flyology Alire index is required"

printf '%s\n' "flyology_cli tests passed"
