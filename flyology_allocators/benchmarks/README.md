# Flyology Allocators benchmarks

This optional hosted subcrate compares the standalone Buddy, Best-Fit, and
TLSF algorithms with the platform C `malloc`/`free` implementation. It depends
on `flyology_bench`; none of its hosted dependencies enter the parent
`flyology_allocators` crate.

Two workload families are included:

- fixed-size cycles perform one allocation followed by one release, for 8,
  64, 256, 1,024, and 4,096 requested bytes;
- fragmented churn keeps 256 allocations live, then replaces one slot per
  operation with a deterministic mix of 8 through 4,096 requested bytes.

All four implementations are sampled in balanced rounds with shared logical
iteration counts. Arena construction, backing allocation, churn prefill, and
final cleanup occur outside timed batches. `malloc` is always the reference.

Build and run the release profile:

```sh
./scripts/run.sh
```

The executable accepts:

```text
allocator_benchmark [maximum_iterations] [samples] [milliseconds] [mode] [size]
```

`mode` is `all`, `fixed`, or `churn`. `size` is used only by `fixed` and
defaults to 64. For a short behavioral smoke run:

```sh
./scripts/run.sh 2000 10 50 fixed 64
./scripts/run.sh 2000 10 50 churn
```

Short runs validate the benchmark; they are not evidence for performance
claims. Use the defaults on a quiet host for comparisons.

