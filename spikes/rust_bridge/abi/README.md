# Rust ABI and linkage spike

This spike tests the smallest boundary shared by all proposed Flyology/Rust
integration directions. An Ada-owned executable links the same Rust crate as a
static archive and as a process-lifetime dynamic library.

## Hypotheses

- Fixed-width C-layout records have identical size, alignment, and field
  offsets in Ada and Rust.
- Empty borrowed spans may use a null pointer; nonempty spans may not.
- Rust allocations remain opaque and are released only by Rust.
- A Rust panic can be caught and translated before it reaches Ada when the
  crate uses the unwind panic strategy.
- Rust thread-local state is persistent on the calling pthread and independent
  on a spawned Rust pthread.
- Debug/release and static/dynamic packaging do not change those semantics.

On Darwin, the runner also records a known negative configuration discovered by
the spike: GNAT GCC 16.1's final link does not emit `__unwind_info` for the Rust
static archive, and Rust's caught panic aborts with unwind result 5. Relinking
the same GNAT binder objects and archive through Apple Clang emits compact
unwind metadata and permits `catch_unwind` to work. The runner keeps the GNAT
GCC failure as an expected negative and uses a narrow driver wrapper, which
removes GCC's Clang-incompatible `-static-libgcc` option, for the positive
static configuration.

## Run

```sh
./spikes/rust_bridge/abi/run.sh
```

The runner stores linked-library and symbol listings under `build/` for manual
inspection. Build products are intentionally untracked.

## Failure criteria

- Any Rust ABI type or allocator ownership must cross the boundary to make the
  test work.
- A panic unwinds into Ada or requires `panic = "abort"` while recoverable
  panic translation is claimed.
- Static linkage requires a target-specific, hand-maintained system-library
  list.
- Dynamic linkage changes value, lifetime, TLS, or panic behavior.

Dynamic unloading is not tested and is not implied to be safe. A later spike
must cover Rust TLS destructors and `dlclose` before unloading can be supported.

## Observed evidence

On 2026-08-31, macOS/AArch64 with Rust 1.97.1, GNAT 16.1.0, and GPRbuild
26.0.1 produced these results in both debug and release profiles:

- Record layout, borrowed spans, Rust-owned allocation, and Rust TLS/thread
  isolation passed with static and dynamic linkage.
- The process-lifetime Rust dynamic library caught and translated the
  intentional panic when linked by the GNAT GCC driver.
- The Rust static archive caught and translated the panic when Apple Clang
  performed the final link.
- The default GNAT GCC static link passed every non-panic check, but the panic
  aborted with `failed to initiate panic, error 5`. Its executable contained
  `__eh_frame` but no `__unwind_info`; the Clang-linked executable contained
  both sections.

This is evidence for a Darwin final-link constraint, not yet a portable
conclusion. The Linux matrix remains a required next-wave run.
