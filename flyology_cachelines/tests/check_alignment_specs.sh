#!/bin/sh

set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_directory="$test_directory/../src/alignment"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/flyology_cachelines-specs.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

normalize()
{
   sed \
     's/Destructive_Interference_Size : constant Positive := [0-9][0-9]*/Destructive_Interference_Size : constant Positive := ALIGNMENT/' \
     "$1"
}

reference="$temporary_directory/flyology_cachelines.ads"
normalize "$source_directory/64/flyology_cachelines.ads" > "$reference"

for alignment in 16 32 128 256
do
   candidate="$temporary_directory/flyology_cachelines-$alignment.ads"
   normalize "$source_directory/$alignment/flyology_cachelines.ads" > "$candidate"
   if ! cmp -s "$reference" "$candidate"
   then
      echo "flyology_cachelines.ads for $alignment-byte alignment differs from the 64-byte reference" >&2
      diff -u "$reference" "$candidate" >&2 || true
      exit 1
   fi
done

echo "all architecture-selected flyology_cachelines.ads specifications are consistent"
