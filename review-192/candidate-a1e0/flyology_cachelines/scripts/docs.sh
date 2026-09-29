#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$crate_root/../scripts/find-alr.sh")
website_kit="$project_root/vendor/website-kit"
output_dir=${FLYOLOGY_CACHELINES_DOCS_OUTPUT:-"$crate_root/docs/api"}

case "$output_dir" in
   "$crate_root/docs/api" | "$project_root/docs/api/flyology_cachelines") ;;
   *)
      printf '%s\n' "refusing unsafe cachelines docs path: $output_dir" >&2
      exit 1
      ;;
esac

if [ ! -f "$website_kit/scripts/render-gnatdoc-theme.mjs" ]; then
   printf '%s\n' \
     "website kit is unavailable; run: git submodule update --init" >&2
   exit 1
fi

if ! command -v gnatdoc >/dev/null 2>&1; then
   installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
   if [ ! -x "$installed_gnatdoc" ]; then
      printf '%s\n' \
        "gnatdoc not found; install it with: $alr install gnatdoc_bin" >&2
      exit 1
   fi
   PATH=$(dirname "$installed_gnatdoc"):$PATH
   export PATH
fi

node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-cachelines-theme.json" \
  "$project_root/docs/gnatdoc-cachelines/html"
cachelines_index_template="$project_root/docs/gnatdoc-cachelines/html/template/index.xhtml"
sed "s|href='../guide/'|href='../../guide/cachelines/'|" \
  "$cachelines_index_template" >"$cachelines_index_template.tmp"
mv "$cachelines_index_template.tmp" "$cachelines_index_template"

cd "$crate_root"
"$alr" build
export FLYOLOGY_CACHELINES_DOCUMENTATION=true
rm -rf "$output_dir"
gnatdoc_log=$(mktemp "${TMPDIR:-/tmp}/flyology-cachelines-gnatdoc.XXXXXX")
cleanup () {
   rm -f "$gnatdoc_log"
}
trap cleanup EXIT HUP INT TERM
if ! "$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  --generate=public \
  -P flyology_cachelines.gpr \
  -O "$output_dir" >"$gnatdoc_log" 2>&1
then
   cat "$gnatdoc_log" >&2
   exit 1
fi
cat "$gnatdoc_log"

if grep -E -q 'warning:' "$gnatdoc_log"
then
   printf '%s\n' "unexpected warning in cachelines GNATdoc output" >&2
   grep -E 'warning:' "$gnatdoc_log" >&2
   exit 1
fi

#  GNATdoc 26.0 indexes tagged types declared in generics as standalone pages,
#  but emits their declarations only on the enclosing unit pages. Point those
#  two generated index entries at the declarations that actually exist.
cachelines_index="$output_dir/index.html"
sed \
  -e 's|href=df52f7dbdfbef0803917131e45ed2bb7c5f45a84493007ea9df3c5e62a188d20.html|href=753da6f5763de4c42b612bcef8c585174a004f9bbbfefc7c4e603da341cd7cf5.html#df52f7dbdfbef0803917131e45ed2bb7c5f45a84493007ea9df3c5e62a188d20|' \
  -e 's|href=810ae57d156fb82586820bdbab4e467a3e4f0b1bf5ca4a955c339d76fe9edb24.html|href=5539c86309fe1d062e35410cbf13db9c163b8bdf4f0837a636e1534023c85a06.html#810ae57d156fb82586820bdbab4e467a3e4f0b1bf5ca4a955c339d76fe9edb24|' \
  "$cachelines_index" >"$cachelines_index.tmp"
mv "$cachelines_index.tmp" "$cachelines_index"

mkdir -p "$output_dir/fonts"
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" \
  "$output_dir/fonts/"
cp "$project_root/assets/brand/flyology-mark-transparent.svg" \
  "$output_dir/flyology-mark.svg"
cp "$website_kit/assets/scripts/ada-highlight.js" \
  "$output_dir/ada-highlight.js"
node "$website_kit/scripts/build-api-search-index.mjs" "$output_dir"

test -f "$output_dir/index.html"
test -f "$output_dir/search-index.js"
