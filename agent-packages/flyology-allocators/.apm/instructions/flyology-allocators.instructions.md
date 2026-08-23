---
description: Apply the standalone Flyology Allocators crate rules.
applyTo: "flyology_allocators/**"
---

# Flyology Allocators agent guide

- This crate is standalone. Never add a dependency on Flyology, shared-memory
  packages, a hosted operating system, libc, a mapping provider, or a scheduler
  implementation.
- Keep persisted application identity outside this crate. Allocator layouts
  contain geometry and algorithm bookkeeping, but no magic or schema values.
- Backing memory is caller-owned and represented by `Regions.View`; the crate
  neither allocates nor maps it.
- Timed contention retry uses only `Ada.Real_Time` and `delay 0.0`. A selected
  runtime must provide those standard facilities, exception propagation, and
  lock-free 32-bit GNAT atomic primitives. Do not require 64-bit atomics.
- Keep the project file independent of Alire-generated configuration so a
  cross `gprbuild` can compile it directly.
- Run `./scripts/test.sh` for native changes. Use
  `./scripts/cross-build.sh` with an explicit target/runtime for each supported
  bare-board toolchain. The maintained cross-check is GNAT 15 `arm-eabi` with
  `embedded-stm32f4`; `No_Exception_Propagation` runtimes are incompatible with
  the public exception contracts.
- `benchmarks/` is a separate optional hosted Alire subcrate. Its
  `flyology_bench` and C allocator dependencies must not enter the parent
  manifest or direct GPR build.
