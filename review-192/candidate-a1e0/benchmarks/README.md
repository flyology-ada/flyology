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

`runtime_callback_bench` reports seven timings:

- `trampoline_cycle_lightweight` — creating and releasing one nested-subprogram
  trampoline inside a lightweight task. This is the path
  `runtime/native/heap_trampoline.c` implements.
- `trampoline_cycle_native` — the same cycle on a native task, which keeps the
  ordinary per-thread cursor and must stay unaffected.
- `fiber_dispatch` — a lightweight task yielding to its event loop and back,
  covering the scheduler's dispatch loop.
- `poller_idle_cycle` — a lightweight task suspending until its event loop has
  nothing ready, so the loop runs its whole idle path once per iteration. This
  is the path the loop's utilization accounting is on.
- `monotonic_clock_read` — one reading of the runtime's platform monotonic
  clock. The idle accounting takes two per blocking poller wait, so this is the
  unit that measurement adds.
- `debug_selector_lightweight` — automatic trace-producer selection using the
  calling lightweight task's current execution group.
- `debug_selector_native` — automatic trace-producer selection using the
  calling native task's pthread identity.

`idle_wait_rate` runs a socket ping-pong between lightweight tasks on two
groups and reports each loop's blocking-wait count, rate, and idle fraction
from `Flyology.Observability`. Each round trip leaves both loops with nothing
ready, so this is close to the highest sustained idle-path rate a loop doing
real work reaches. Multiplying that rate by twice `monotonic_clock_read` gives
the accounting's share of a loop's time directly, which matters because the
effect is far below what a differential timing run can resolve: on the checked
macOS/AArch64 host the untouched cases in `runtime_callback_bench` vary by about
2% between runs and `poller_idle_cycle` by tens of percent, against an expected
effect near 0.6%. Pass a measurement window in seconds; the default is 2.

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
