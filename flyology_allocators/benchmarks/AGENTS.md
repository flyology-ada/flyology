# Flyology Allocators benchmark agent guide

- This is an optional hosted benchmark subcrate. Its dependencies do not belong
  in the parent `flyology_allocators` manifest or project closure.
- Use `flyology_bench` paired multi-way comparisons. Keep `malloc`/`free` as
  case one so every reported speedup is relative to the native allocator.
- Run the release-profile benchmark on an otherwise quiet host before making a
  performance claim. Smoke settings establish behavior, not performance.
- Every logical operation must have the same lifecycle shape in every case.
  Setup, arena creation, and final cleanup remain outside timed batches.

