# Rust panic/unwind linkage spike

This spike isolates a Darwin/AArch64 failure observed when a GNAT-built Ada
executable statically links Rust code that uses `catch_unwind`. It tests the
same intentional Rust panic from an Ada native task and a Flyology lightweight
task. Each failing case runs as an isolated child process; process abort is
never counted as panic containment.

## Matrix

The runner builds debug and release Rust artifacts and holds the Ada objects,
archive order, Flyology RTS, and Rust panic strategy constant while varying the
final-link configuration:

| Rust packaging | Final driver | Extra linker behavior | Expected on Darwin |
| --- | --- | --- | --- |
| static archive | GNAT GCC 16.1 | driver injects `-no_compact_unwind` | isolated failure |
| static archive | Apple Clang | compact unwind enabled | success |
| static archive last | Apple Clang | archive moved after the Ada runtime libraries | success |
| static archive | Apple Clang | explicitly adds `-no_compact_unwind` | isolated failure |
| dynamic library | GNAT GCC 16.1 | Rust dylib retains its own unwind metadata | success |

The ordinary and negative Clang wrappers preserve GPRbuild's argument and
archive order. They only remove GCC's Clang-incompatible `-static-libgcc`
switch; the negative wrapper additionally adds `-Wl,-no_compact_unwind`. A
third wrapper deliberately moves the Rust archive after the runtime libraries.

Run from any directory:

```sh
./spikes/rust_bridge/unwind/run.sh
```

The runner prepares an isolated Flyology RTS and stores the Mach-O load
commands, linked libraries, symbols, negative-child logs, and GNAT GCC specs
under the ignored `build/` directory.

## Observed evidence

On 2026-08-31, macOS/AArch64 with Rust 1.97.1, GNAT GCC 16.1.0, GPRbuild
26.0.1, and Apple Clang 21.0.0 produced the same outcome in debug and release:

- GNAT GCC's driver specs include `-no_compact_unwind`. Its static executables
  contain `__eh_frame` but no `__unwind_info`; both the native and lightweight
  probes abort with `failed to initiate panic, error 5`.
- Apple Clang's static executables contain `__unwind_info` and `__eh_frame`;
  both probes catch the Rust panic and return the translated status to Ada.
- Moving the Rust archive from GPRbuild's ordinary position to the end of the
  Clang link still passes on both lanes and retains both unwind sections.
- Adding only `-no_compact_unwind` to the otherwise successful Clang link
  removes `__unwind_info` and reproduces the same error 5 on both task lanes.
- The GNAT GCC-linked executable for the dynamic case has no `__unwind_info`,
  but the Rust dynamic library has its own `__unwind_info`; both probes pass.

This controlled reversal identifies final-link compact-unwind generation, not
Ada task stack type or the two tested static archive orders, as the cause on
this host.

## Boundary contract and kill criteria

A viable Darwin contract is either:

- link a Rust static archive through the checked Clang wrapper and require
  `__unwind_info` in the resulting executable; or
- retain the Rust dynamic library for the process lifetime and verify its
  unwind metadata.

The bridge must isolate a startup self-test that intentionally panics on every
supported Ada task lane. If that child aborts, if the final artifact lacks the
expected unwind metadata, or if Rust is built with `panic=abort`, the bridge
must not claim recoverable panic translation. No Rust panic may unwind across
the C ABI into Ada even in a passing configuration.

This is a host-specific result. Linux uses DWARF unwind tables rather than
Mach-O compact unwind, and has not been exercised by this Darwin run. Other
macOS architectures, GNAT releases, Apple linker releases, other static
library orders, LTO, sanitizers, and dynamically unloading Rust remain explicit
unknowns. The Linux branch of the runner expects the ordinary GCC static and
dynamic cases to pass, but that expectation still needs execution on Linux.
