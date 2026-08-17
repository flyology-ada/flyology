# Flyology Cachelines

Cache-line-aligned storage and cache information for Ada, with no runtime
crate dependencies.

The Alire crate is `flyology_cachelines`; its Ada root package is
`Flyology_Cachelines`. It is a standalone related package in the Flyology
repository and does not depend on the Flyology runtime.

The crate is currently available on Linux and macOS. Windows support is not
included in this adoption.

## Why cache-line-aware storage?

Modern processors maintain cache coherence in cache-line-sized units. Two Ada
tasks can update completely different objects and still contend if those
objects occupy the same line: each write invalidates the other core's cached
copy and the line repeatedly moves between cores. This is *false sharing*—the
program has no logical shared value, but its physical layout creates
interference.

Avoiding false sharing requires more than aligning the first object. Every
independently written object must start on an appropriate boundary, and its
size or array stride must keep the next object out of the same interference
region. This crate packages those representation rules into reusable Ada types
for stack objects, heap objects, records, and arrays.

The compile-time `Destructive_Interference_Size` is a conservative spacing
policy, not merely the detected physical cache-line size. For example, x86-64
normally reports a 64-byte line while this crate selects 128-byte spacing to
also separate adjacent-line prefetch pairs. Runtime cache queries are provided
for inspection and capacity planning; they do not change a type's compiled
representation.

This crate controls placement only. It does not make values atomic or make
unsynchronized concurrent access safe. Use atomic types, protected objects, or
clear task ownership independently of the chosen layout.

## Choosing a representation

| Need | Package or type | Trade-off |
| --- | --- | --- |
| Isolate every independently written value | `Flyology_Cachelines.Padded` | Strongest separation; every value consumes one or more whole interference regions. |
| Keep a known number of same-owner values together | `Flyology_Cachelines.Padded_Groups` | Explicit density; instantiation fails if the group would spill beyond one region. |
| Pack as many same-owner values as safely fit | `Flyology_Cachelines.Fitted_Groups` | Maximum per-region density; capacity depends on the selected architecture spacing and element representation. |
| Treat multiple isolated groups as one logical sequence | `Grouped_Array` from either group package | Flat indexing and iteration with physical group gaps; choose standard iteration or `Fast_View` for measured hot loops. |

Grouping is an ownership decision: elements within a group may share cache
lines and should normally be written by the same task or shard. Values with
independent writers should receive separate groups or individual `Padded`
wrappers.

## Individually padded values

The generic `Flyology_Cachelines.Padded` package wraps any definite Ada type. Its
`Padded` type is aligned to a destructive-interference boundary and rounded up
to a whole number of boundaries, so adjacent objects do not falsely share the
same boundary.

```ada
with Flyology_Cachelines.Padded;

procedure Example is
   package Padded_Counters is new Flyology_Cachelines.Padded (Natural);

   Counters : array (1 .. 2) of Padded_Counters.Padded :=
     [others => Padded_Counters.Create (0)];
begin
   Counters (1).Value := Counters (1).Value + 1;
end Example;
```

## Ownership-aware groups

`Flyology_Cachelines.Padded_Groups` packs an explicit number of elements into one
destructive-interference region. Elements inside a group may share cache lines;
separate groups cannot share the selected region. This is useful when every
group belongs to one task or shard:

```ada
with Flyology_Cachelines.Padded_Groups;

package Worker_Counters is new Flyology_Cachelines.Padded_Groups
  (Element_Type => Atomic_Counter,
   Group_Length => 8);

Counters : array (Worker_Id) of Worker_Counters.Group;
```

`Group` is itself an array, so one group is directly indexable and iterable:

```ada
for Counter of Counters (Worker) loop
   Counter := Counter + 1;
end loop;
```

The instantiation is rejected at compile time if either its element array or
the final aligned representation exceeds one region. It can therefore never
silently turn a one-region group into a multi-region object.

`Flyology_Cachelines.Fitted_Groups` chooses the largest safe element count for the
architecture selected by the build:

```ada
with Flyology_Cachelines.Fitted_Groups;

package Worker_Counters is new Flyology_Cachelines.Fitted_Groups (Atomic_Counter);

--  Compile-time constant; for an eight-byte counter this is 16 when the
--  selected destructive-interference size is 128 bytes.
Capacity : constant Positive := Worker_Counters.Elements_Per_Group;
```

Both generics also provide `Grouped_Array`, which preserves the physical group
boundaries while presenting every logical element as one flat sequence:

```ada
Counters : aliased Worker_Counters.Grouped_Array :=
  Worker_Counters.Create
    (Element_Count => 2 * Worker_Counters.Elements_Per_Group,
     Initial_Value => 0);

Counters (Worker_Counters.Elements_Per_Group + 1) :=
  Counters (Worker_Counters.Elements_Per_Group + 1) + 1;

for Counter of Counters loop
   Counter := Counter + 1;
end loop;
```

Flat indexing and mutable iteration cross group boundaries without copying.
`Length` returns the logical element count, and iteration skips unused elements
in a partial final group. `Counters.Groups` remains available when code needs
to assign or process whole physical groups directly.

There are two whole-sequence traversal choices:

- Direct `for Counter of Counters` uses the standard Ada iterator protocol. It
  is the simplest choice and supports constant and mutable containers. GNAT
  currently implements the class-wide iterator with cursor dispatch, reference
  objects, and secondary-stack work, which can be expensive in a tiny hot loop.
- `Fast_View` uses GNAT's lightweight `Iterable` aspect and a cached address
  cursor. It retains one-level mutable `for ... of` syntax for measured hot
  loops.

### Using `Fast_View`

Declare the `Grouped_Array` as `aliased`, then construct a short-lived view
with the container's `'Access`. A reusable traversal procedure looks like this:

```ada
with Flyology_Cachelines.Fitted_Groups;

procedure Increment_Counters is
   type Counter is mod 2 ** 64 with Atomic;

   package Worker_Counters is new Flyology_Cachelines.Fitted_Groups (Counter);

   procedure Increment_All
     (Container : aliased in out Worker_Counters.Grouped_Array)
   is
      View : Worker_Counters.Fast_View (Container'Access);
   begin
      for Item of View loop
         Item := Item + 1;
      end loop;
   end Increment_All;

   Counters : aliased Worker_Counters.Grouped_Array :=
     Worker_Counters.Create
       (Element_Count => 10_003,
        Initial_Value => 0);
begin
   Increment_All (Counters);
end Increment_Counters;
```

The same `Fast_View (Container'Access)` pattern is available from
`Flyology_Cachelines.Padded_Groups` when the group length is chosen explicitly.

The usage rules are:

- `Fast_View` operates on `Grouped_Array`; a single `Group` is already an array
  and can be iterated directly.
- The container must be `aliased`. The view's access discriminant ties its
  lifetime to that container, and the limited view is intended to remain local
  to the traversal.
- Creating a view allocates no storage and copies no elements.
- Iteration is mutable and flat. It visits exactly `Length (Container)` logical
  elements, crosses aligned group gaps, and never exposes the unused tail of a
  partial final group.
- The view adds no synchronization. Elements shared between tasks still need
  atomic operations, protected access, or an ownership scheme.
- A constant or read-only traversal should use the standard
  `for Item of Container` form instead.

Internally, the cursor stores the current element address, remaining logical
element count, and slot within the physical group. Advancing uses the component
stride inside a group and the aligned group stride at a boundary. This avoids
logical-index division and the class-wide standard iterator machinery.

`Fast_View` is intentionally opt-in: `Iterable` is a GNAT-defined aspect and
the view is mutable-only. These group packages already target GNAT for their
compile-time spill checks; `Fast_View` adds another explicitly
implementation-defined dependency. Use it only after measuring the relevant
hot loop. The benchmark reports standard and fast-view traversal separately
against explicit group/slot traversal over identical storage.

If even one element cannot fit, instantiation fails. Both generics describe a
compile-time destructive-interference region, not necessarily one physical
cache line: x86-64 deliberately selects 128-byte regions even though its
physical lines are normally 64 bytes. Grouping must be based on common
ownership; automatically packing independently written values would recreate
false sharing.

The root package also exposes:

- `Destructive_Interference_Size`
- `Hardware_Cache_Line_Size`
- `L1_Data_Cache_Size`
- `L1_Data_Cache_Slots`
- `Cache_Query_Result` and `Value_Or`

Runtime cache detection uses `sysctlbyname` on macOS. Linux x86-64 queries
CPUID first; other Linux targets query `sysconf`. Both Linux paths fall back
to `/sys/devices/system/cpu/cpu0/cache` when their primary mechanism cannot
report the L1 data cache. Results are detected once during package elaboration
and reused because cache geometry is stable for the life of a process.
Malformed or failed host queries return `(Available => False)` rather than an
ambiguous default value or a conversion exception.

```ada
declare
   Line : constant Flyology_Cachelines.Cache_Query_Result :=
     Flyology_Cachelines.Hardware_Cache_Line_Size;
begin
   if Line.Available then
      Put_Line ("hardware line:" & Line.Value'Image);
   end if;

   --  A fallback is only used when the caller explicitly requests one.
   Put_Line (Flyology_Cachelines.Value_Or (Line, 64)'Image);
end;
```

The compile-time spacing follows the documented architecture table: 128 bytes
for x86-64, AArch64, and PowerPC64; 32 bytes for ARM, MIPS, SPARC, and Hexagon;
16 bytes for m68k; 256 bytes for s390x; and 64 bytes otherwise.

### Hosts with more than one core type

A host whose cores are not identical has no single L1 data-cache capacity, so
`L1_Data_Cache_Size` reports the capacity of one core type rather than a value
that holds for every core. `L1_Data_Cache_Slots` divides that capacity by the
compiled `Destructive_Interference_Size` and describes the same core type.

macOS 12 and later publish per-core-type geometry as ordered *performance
levels*, where `hw.perflevel0` is the highest-performing level. The crate
queries `hw.perflevel0.l1dcachesize` and reports the performance-core capacity
on Apple silicon. The flat `hw.l1dcachesize` reports the efficiency-core
capacity instead: one 12P/4E Apple silicon host reports 65536 bytes for the
flat name and 131072 bytes for `hw.perflevel0.l1dcachesize`. The crate falls
back to the flat name only on a host that publishes no performance level, such
as macOS 11 and earlier or an Intel Mac. `Hardware_Cache_Line_Size` is
unaffected, because Darwin publishes no per-level line size and both Apple
silicon core types use the same 128-byte line.

Linux reports whichever L1 data cache its own query mechanism describes.
`sysconf` answers for the calling CPU, and the sysfs fallback reads CPU 0.
Neither is normalized to the largest core.

## Why these alignment sizes?

The policy is adapted from the `CachePadded` implementation in
[`crossbeam-utils`](https://github.com/crossbeam-rs/crossbeam/blob/master/crossbeam-utils/src/cache_padded.rs),
which is available under MIT or Apache-2.0. It is the same policy used by the
Rust crate this project ports.

### 128 bytes: x86-64, AArch64, Arm64EC, and PowerPC64

Starting with Intel Sandy Bridge, the spatial prefetcher can fetch pairs of
adjacent 64-byte cache lines. Aligning independent values to only 64 bytes can
therefore still create destructive interference through prefetching. The
128-byte spacing keeps independently written values out of the prefetched
pair. See Intel's
[Optimization Reference Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
and Folly's
[`hardware_destructive_interference_size`](https://github.com/facebook/folly/blob/main/folly/lang/Align.h).

AArch64 systems may combine asymmetric cores in a big.LITTLE design, and the
larger cores can use 128-byte cache lines. See Mono's
[ARM64 cache-line discussion](https://www.mono-project.com/news/2016/09/12/arm64-icache/).
PowerPC64 also conventionally uses 128-byte cache lines, as reflected in
[Go's PPC64 CPU definitions](https://github.com/golang/go/blob/master/src/internal/cpu/cpu_ppc64x.go)
and the
[Linux PowerPC cache definitions](https://github.com/torvalds/linux/blob/master/arch/powerpc/include/asm/cache.h).

### 32 bytes: ARM, MIPS, SPARC, and Hexagon

These targets conventionally use 32-byte cache lines. The policy follows the
corresponding Go CPU definitions and the Linux architecture cache headers,
including
[Linux SPARC](https://github.com/torvalds/linux/blob/master/arch/sparc/include/asm/cache.h)
and
[Linux Hexagon](https://github.com/torvalds/linux/blob/master/arch/hexagon/include/asm/cache.h).

### 16 bytes: m68k

The m68k alignment follows the
[Linux m68k cache definition](https://github.com/torvalds/linux/blob/master/arch/m68k/include/asm/cache.h).

### 256 bytes: s390x

s390x uses 256-byte spacing, following
[Go's s390x CPU definition](https://github.com/golang/go/blob/master/src/internal/cpu/cpu_s390x.go)
and the
[Linux s390 cache definition](https://github.com/torvalds/linux/blob/master/arch/s390/include/asm/cache.h).

### 64 bytes: x86, WebAssembly, RISC-V, SPARC64, and fallback

These targets use the common 64-byte alignment. Unknown architectures also
default to 64 bytes. Relevant references include
[Go's x86 CPU definition](https://github.com/golang/go/blob/master/src/internal/cpu/cpu_x86.go)
and the
[Linux RISC-V cache definition](https://github.com/torvalds/linux/blob/master/arch/riscv/include/asm/cache.h).

Build and test:

```sh
alr build
cd tests
alr test
```

The native test compares the architecture-selected interference spacing with
the queried physical cache-line size. The values need not be equal: x86-64
normally selects 128-byte spacing around a 64-byte hardware line. Instead, the
compiled spacing must be the architecture's expected value and an exact
multiple of the physical line. When the OS reports L1 capacity, the test also
checks that it consists of whole hardware lines and that
`L1_Data_Cache_Slots` derives the correct number of interference-sized slots.
Tests also distinguish an unavailable query with an explicit 64-byte fallback
from a successfully detected 64-byte line.

`alr test` also compares the five architecture-selected public specifications
after normalizing their alignment literal. This prevents the duplicated specs
from drifting as the public API or its documentation changes. On Linux, it
also invokes the private `sysconf` and sysfs detectors independently; the
ordinary native test exercises the public CPUID-first x86-64 path. On macOS, it
invokes the private sysctl reader directly and checks that the reported L1
capacity is the highest performance level the host publishes, and that the flat
name is used only when the host publishes no performance level. Compile-fail
tests verify that explicit and automatically fitted groups which would spill
beyond one region are rejected.

## Benchmarks

The nested `benchmarks` crate compares compact and padded storage under nine
workloads. Same-task measurements cover sequential, coprime-stride, hot-set,
and standard and GNAT `Iterable` grouped traversal versus explicit group/slot
loops. Multi-task measurements cover
isolated hot counters, task-owned compact groups, fitted versus individually
aligned groups, interleaved ownership, and contiguous shards.
Defaults use one million elements, up to 16 tasks, and three alternating-order
samples.

```sh
cd benchmarks
alr -n build --release
./bin/benchmarks
```

See `benchmarks/README.md` for workload definitions, positional scale controls,
memory requirements, and interpretation guidance.

## License

Licensed under either the MIT License or Apache License 2.0, at your option.
The architecture spacing policy is adapted from Crossbeam's `CachePadded`; see
`NOTICE` and the repository's `LICENSE-MIT` and `LICENSE-APACHE` files.
