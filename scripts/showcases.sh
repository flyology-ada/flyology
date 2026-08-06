#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

"$project_root/showcases/prepare-alire.sh" >/dev/null
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE=1 \
  "$project_root/showcases/prepare-rts.sh" >/dev/null
#  Showcase-only dependencies live in the nested manifest, so the core
#  Flyology crate remains usable without them. The first pass retains one
#  group because several scheduler demonstrations intentionally assert that
#  exact topology.
(
  cd "$project_root/showcases"
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P showcases.gpr
)

for showcase in \
  execution_groups \
  lightweight_file_io \
  lightweight_io \
  lightweight_pipeline \
  hybrid_blocking_bridge \
  many_lightweight_tasks \
  priority_scheduling \
  lightweight_vs_native
do
  printf '\n== %s ==\n' "$showcase"
  "$project_root/showcases/bin/$showcase"
done

printf '\n== event_loop_pool ==\n'
"$project_root/showcases/run_event_loop_pool.sh"

printf '\n== thread_per_core ==\n'
"$project_root/showcases/run_thread_per_core.sh"

printf '\n== buffer_handoff ==\n'
"$project_root/showcases/run_buffer_handoff.sh"

printf '\n== buffer_pool_contention ==\n'
"$project_root/showcases/run_buffer_pool_contention.sh"

printf '\n== connection_density ==\n'
"$project_root/showcases/run_connection_density.sh"

printf '\n== task_lifecycle ==\n'
FLYOLOGY_LIFECYCLE_SMALL=100 \
FLYOLOGY_LIFECYCLE_LARGE=1000 \
FLYOLOGY_LIFECYCLE_NATIVE=100 \
  "$project_root/showcases/run_task_lifecycle.sh" 1

printf '\n== task_snapshot_contention ==\n'
FLYOLOGY_SNAPSHOT_SMALL=100 \
FLYOLOGY_SNAPSHOT_LARGE=1000 \
FLYOLOGY_SNAPSHOT_WINDOW=0.050 \
FLYOLOGY_SNAPSHOT_PERIODIC_WINDOW=0.100 \
  "$project_root/showcases/run_task_snapshot_contention.sh" 1

printf '\n== dormant_stack_pressure ==\n'
"$project_root/showcases/run_dormant_stack_pressure.sh"
