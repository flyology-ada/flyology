# Runtime benchmarks

Benchmarks that need the Flyology runtime itself. They are built against a
prepared RTS, which is why they live here rather than in the `flyology_bench`
crate: that crate deliberately does not depend on Flyology.

```sh
scripts/bench-runtime.sh              # build and print results
scripts/bench-runtime.sh save DIR     # persist timing baselines
scripts/bench-runtime.sh check DIR    # compare against saved baselines
```

Baselines record host and toolchain fingerprints, so they are meaningful only
on the machine that produced them and are not committed. `check` reports an
incompatible baseline rather than failing on it, and flags a case as regressed
when its median time grows by more than 10%.

## What is measured

`runtime_callback_bench` reports three timings:

- `trampoline_cycle_lightweight` — creating and releasing one nested-subprogram
  trampoline inside a lightweight task. This is the path
  `runtime/native/heap_trampoline.c` implements.
- `trampoline_cycle_native` — the same cycle on a native task, which keeps the
  ordinary per-thread cursor and must stay unaffected.
- `fiber_dispatch` — a lightweight task yielding to its event loop and back,
  covering the scheduler's dispatch loop.

`fiber_trampoline_memory` holds `count` lightweight tasks suspended with, and
without, a live callback and reports the resident-set difference. Subtracting
the two runs isolates trampoline storage from the fiber stack. Set
`FLYOLOGY_BENCH_FIBERS` to change the fiber count from its default of 512.

## Why the memory case exists

GNAT allocates nested-subprogram trampolines off the stack on Darwin/AArch64,
and its own allocator reclaims them by count, which requires each thread to
release them in stack order. Fibers sharing an event loop violate that, so
Flyology tracks live trampolines per fiber instead. Keeping the storage pooled
rather than reserving a page per fiber is what keeps that correctness fix from
costing a mapped page for every fiber holding a callback; this benchmark is the
guard on that property.
