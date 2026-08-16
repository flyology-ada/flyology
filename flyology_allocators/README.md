# Flyology Allocators

`flyology_allocators` provides caller-owned memory allocation algorithms for
Ada. Its Ada root package is `Flyology_Allocators`.

The crate is standalone: it does not depend on Flyology, shared memory, an
event loop, a mapping provider, or a hosted operating system. The caller
supplies an address and extent through `Flyology_Allocators.Regions`; the crate
stores only fixed-width offsets, counters, generations, geometry, and allocator
bookkeeping in those bytes. Application magic and schema values deliberately
remain outside the allocator image.

Four compile-time-selected algorithms are included:

- `Allocation_Algorithms.Buddy` uses an out-of-band buddy tree with view-local
  reuse hints.
- `Allocation_Algorithms.Best_Fit` uses boundary tags and an offset-based AVL
  tree.
- `Allocation_Algorithms.TLSF` uses boundary tags, bitmaps, and offset-linked
  segregated free lists.
- `Allocation_Algorithms.Slab_Span` uses bitmap slots in power-of-two small
  classes and contiguous fixed-run spans for larger requests.

All four return released blocks to the current tree or free index without
coalescing physical neighbors. A successful fast path uses the algorithm's
normal hint, tree, or bitmap lookup. Before reporting exhaustion, Buddy and
TLSF scan and coalesce the stored structure, then retry. Best-Fit scans for
adjacent free runs and retries if the index changed. The advertised worst-case
search bound is therefore linear. Slab/span release immediately frees large
runs, retains empty small slabs for reuse, and reclaims those slabs when a new
slab or contiguous span otherwise cannot be found.

The stored field geometry and required extent are unchanged, but the set of
valid stored states changed. Applications that retain allocator bytes across
binary versions must supply an outer compatibility contract. Flyology's
adapters use version-3 identities for these lazy-coalescing states. The
standalone allocator image still contains no application magic or schema.

Instantiate `Flyology_Allocators.Arenas` with one algorithm:

```ada
with Flyology_Allocators.Allocation_Algorithms.Buddy;
with Flyology_Allocators.Arenas;
with Flyology_Allocators.Regions;

package Arenas is new Flyology_Allocators.Arenas
  (Flyology_Allocators.Allocation_Algorithms.Buddy);

Arenas.Initialize
  (Item          => Arena,
   Region        => Region,
   Location      => 64,
   Configuration =>
     (Usable_Capacity => 65_536, Minimum_Block_Size => 64),
   Instance_ID   => 1);
```

Immediate operations return contention without waiting. Timed allocation and
release retry metadata contention against a monotonic deadline and execute
`delay 0.0` between attempts. This uses only `Ada.Real_Time` and the selected
Ada runtime's delay implementation; Flyology's runtime can therefore supply
fiber-aware behavior without becoming a crate dependency.

## Bare-board and cross builds

The project file has no generated configuration and selects no operating-system
source directory. It can be built directly by a cross `gprbuild`:

```sh
FLYOLOGY_ALLOCATORS_TARGET=arm-eabi \
FLYOLOGY_ALLOCATORS_RTS=/absolute/path/to/runtime \
./scripts/cross-build.sh
```

Set `FLYOLOGY_ALLOCATORS_GPRBUILD` when the cross toolchain uses a distinct
driver. Cross outputs default to `obj/cross` and `lib/cross`; override them with
`FLYOLOGY_ALLOCATORS_OBJECT_DIR` and `FLYOLOGY_ALLOCATORS_LIBRARY_DIR`.

The selected runtime must provide exception propagation, `Ada.Real_Time`,
`delay 0.0`, lock-free 32-bit operations through
`System.Atomic_Primitives`, and optimized `memmove` and `memcmp` primitives.
GNAT's verified `embedded-stm32f4` runtime and toolchain provide this profile.
Allocator generation counters are 64-bit but are accessed only while the
32-bit metadata guard is held, so a 32-bit target needs no lock-free 64-bit
atomic instruction. No POSIX clock or Darwin/Linux ABI constant is imported by
this crate.

The crate is cross-compiled in this repository with GNAT 15's `arm-eabi`
toolchain and the `embedded-stm32f4` bare-board runtime. GNAT runtimes that
impose `No_Exception_Propagation`, including `light-tasking-stm32f4`, cannot
implement this exception-reporting API and are outside the supported runtime
profile.

Native verification is `./scripts/test.sh`. It builds the standalone project,
runs all four allocators including a timed-contention case, and rejects any
reference to a `Flyology` runtime symbol in the resulting archive.

## Hosted benchmarks

The optional [`benchmarks`](benchmarks) Alire subcrate uses `flyology_bench` to
compare Buddy, Best-Fit, TLSF, and Slab/Span directly with C `malloc`/`free`.
Fixed-size cycles and a bounded fragmented-churn workload use shared iteration
counts and balanced paired rounds. Benchmark-only hosted dependencies do not
enter this crate's manifest or bare-board project closure.
