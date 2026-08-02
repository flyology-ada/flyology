#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

cd "$project_root"
FLYOLOGY_DEFAULT=lightweight "$project_root/scripts/prepare-rts.sh" >/dev/null
"$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases/showcases.gpr

for showcase in \
  execution_groups \
  lightweight_file_io \
  lightweight_io \
  lightweight_pipeline \
  hybrid_blocking_bridge \
  many_lightweight_tasks \
  priority_scheduling \
  structured_http \
  lightweight_vs_native
do
  printf '\n== %s ==\n' "$showcase"
  "$project_root/showcases/bin/$showcase"
done

printf '\n== event_loop_pool ==\n'
"$project_root/showcases/run_event_loop_pool.sh"

printf '\n== connection_density ==\n'
"$project_root/showcases/run_connection_density.sh"
