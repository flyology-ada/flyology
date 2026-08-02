#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${ALR:-"$HOME/alr"}

cd "$project_root"
"$project_root/scripts/prepare-rts.sh" >/dev/null
"$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases/showcases.gpr

for showcase in \
  execution_groups \
  evented_io \
  evented_pipeline \
  hybrid_blocking_bridge \
  many_evented_tasks \
  evented_vs_threads
do
  printf '\n== %s ==\n' "$showcase"
  "$project_root/showcases/bin/$showcase"
done

printf '\n== connection_density ==\n'
"$project_root/showcases/run_connection_density.sh"
