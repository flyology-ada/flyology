# Flyology Cachelines benchmarks

These benchmarks compare compact and cache-padded counters under identical
workloads. They intentionally include cases where padding helps and cases where
its larger memory footprint hurts.

Build with optimizations and run the executable directly so a later `alr run`
does not rebuild it in development mode:

```sh
cd benchmarks
alr -n build --release
./bin/benchmarks
```

The positional arguments are:

```text
benchmarks [elements] [passes] [iterations-per-worker] [workers] [samples]
```

Defaults are 1,000,003 elements, 3 passes, 5,000,000 iterations per worker,
up to 16 workers, and 3 samples. The padded dataset is approximately 128 MiB
when the destructive-interference size is 128 bytes.

The executable reports the best sample for each layout while alternating
measurement order between samples. Every workload validates its final counter
sum outside the timed region.

Single-task algorithms:

- Sequential full-array sweep measures streaming locality.
- Coprime-stride sweep visits every element in a cache-unfriendly order.
- Fitted grouped-array full sweep compares explicit group/slot loops with
  two flat traversal APIs over identically sized `Grouped_Array` objects: the
  standard mutable `for ... of` iterator and mutable `for ... of` over a GNAT
  `Iterable` `Fast_View`. This isolates traversal abstraction cost while
  exercising a partial final group at the default element count. Each API is
  measured pairwise with the nested control and alternates run order
  independently.

  The standard iterator is the most direct language-defined interface, and it
  also supports constant traversal. GNAT's class-wide iterator currently
  entails cursor dispatch, reference objects, and secondary-stack work. The
  group packages already require GNAT for compile-time spill checks; `Fast_View`
  adds a further implementation-defined dependency. It is mutable-only; its
  cached address cursor advances by the component stride within a group and by
  the aligned group stride at a boundary. It is the specialized hot-loop
  option, not the default semantic choice. Compare the results on the actual
  compiler and hardware rather than assuming one interface is always fastest.
- Eight-counter hot set shows the cost of spreading data that one task could
  otherwise keep together.

Multi-task algorithms:

- One hot counter per task is the canonical false-sharing workload.
- One compact hot group per task packs several task-owned counters together,
  then compares adjacent compact groups with groups isolated on destructive-
  interference boundaries. The group length is half of the automatically
  fitted capacity, so neighboring compact groups can share a region while the
  padded layout retains useful within-task locality.
- One aligned region per counter versus one automatically fitted group gives
  each task the same number of counters and the same access order. Both layouts
  isolate task ownership, but the first consumes one full destructive-
  interference region for every counter while the fitted layout packs the
  maximum safe number of counters into one region. The report prints bytes for
  both layouts and their storage ratio as well as timing.

The group types are arrays, and the library's `Grouped_Array` wrapper supports
flat indexing and mutable standard or fast-view iteration across any number of
physical groups. The dedicated full-sweep control measures those abstractions
directly; the ownership/layout workloads use physical groups so their results
remain focused on cache placement.
- Interleaved ownership makes neighboring counters belong to different tasks
  throughout a large dataset.
- Contiguous sharding gives each task its own region, leaving little false
  sharing except at shard boundaries.

Do not treat one run as a universal performance claim. Run on otherwise idle
hardware, use release mode, repeat the benchmark, and evaluate the access
pattern that resembles the intended application.
