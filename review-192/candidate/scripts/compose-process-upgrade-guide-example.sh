#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' \
    "usage: compose-process-upgrade-guide-example.sh PROJECT_ROOT OUTPUT_ROOT" >&2
  exit 2
fi

project_root=$1
output_root=$2
guide=$project_root/website/guide/process-upgrades/index.html
source_root=$output_root/src

mkdir -p "$source_root"

extract_file () {
  source_name=$1
  fragment_count=$2
  destination=$3
  temporary=$destination.tmp

  awk -v wanted="$source_name" -v required="$fragment_count" '
    function decode_html(text) {
      gsub(/&gt;/, ">", text)
      gsub(/&lt;/, "<", text)
      gsub(/&quot;/, "\"", text)
      gsub(/&apos;/, "\047", text)
      gsub(/&amp;/, "\\&", text)
      return text
    }

    function emit_source(text, closes) {
      closes = index(text, "</code>") != 0
      if (closes) {
        sub(/<\/code>.*/, "", text)
      }
      print decode_html(text)
      if (closes) {
        inside = 0
      }
    }

    BEGIN {
      expected_order = 1
      inside = 0
      found = 0
      failed = 0
    }

    {
      if (inside) {
        emit_source($0)
      } else if (index($0, "<code") != 0 &&
                 index($0, "data-extract-file=\"" wanted "\"") != 0) {
        expected_attribute = "data-extract-order=\"" expected_order "\""
        if (index($0, expected_attribute) == 0) {
          printf "unexpected or duplicate fragment order for %s; expected %d\n",
            wanted, expected_order > "/dev/stderr"
          failed = 1
          exit 1
        }
        found++
        expected_order++
        inside = 1
        line = $0
        sub(/^.*<code[^>]*>/, "", line)
        emit_source(line)
      }
    }

    END {
      if (!failed && inside) {
        printf "unterminated source fragment for %s\n", wanted > "/dev/stderr"
        exit 1
      }
      if (!failed && found != required) {
        printf "expected %d ordered fragments for %s, found %d\n",
          required, wanted, found > "/dev/stderr"
        exit 1
      }
    }
  ' "$guide" >"$temporary"

  mv "$temporary" "$destination"
}

extract_file guide_process_upgrade.adb 6 \
  "$source_root/guide_process_upgrade.adb"
extract_file process_generation_agent_v1.adb 1 \
  "$source_root/process_generation_agent_v1.adb"
extract_file process_generation_agent_v2.adb 1 \
  "$source_root/process_generation_agent_v2.adb"
extract_file process_generation_demo.ads 1 \
  "$source_root/process_generation_demo.ads"
extract_file process_generation_demo.adb 1 \
  "$source_root/process_generation_demo.adb"
extract_file process_upgrade_guide.gpr 1 \
  "$output_root/process_upgrade_guide.gpr"

printf '%s\n' "process-upgrade guide source: extracted ordered text fragments"
