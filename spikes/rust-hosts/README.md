# Rust-hosted Ada tasking spike

This spike asks whether a Rust-owned executable can initialize one Flyology
Ada partition, enter it from Rust threads, create both native and lightweight
Ada tasks, and finalize the partition without a second GNAT runtime.

Run it from the repository root:

```sh
./spikes/rust-hosts/build-and-run.sh
```

The script uses only local Rust standard-library facilities and the Alire
dependencies already required by Flyology. It prepares Flyology's patched
runtime, asks `gnatbind -n` for a foreign-main binder, links the binder and the
prepared static GNAT runtime into the Rust executable, rejects a resulting
shared `libgnat` or `libgnarl` dependency, and runs the executable under a
30-second timeout.

## Hypotheses

1. Calling binder-produced `adainit` on Rust's main thread establishes that
   thread as GNAT's environment task.
2. A joined `std::thread` can enter tasking Ada after explicit registration
   through the C exports documented by `GNAT.Threads`.
3. An Ada call from either thread can observe its current task identity, use a
   protected object, and create and join one explicitly native task and one
   explicitly lightweight task.
4. Once the Rust thread has unregistered and joined, calling `adafinal` on the
   initialization thread completes Flyology's one-shot process finalization.
5. Ada exceptions can be contained on the Ada side and represented as a C
   integer status, so no exception crosses the language ABI.
6. Rust panic unwinding remains functional after the Ada partition is
   initialized and the prepared static GNAT runtime is present in the process.

## Lifecycle exercised

```text
Rust main
  -> adainit
  -> Ada probe; local native and lightweight task masters finish
  -> catch one intentional Rust panic entirely within Rust
  -> spawn Rust std thread
       -> __gnat_register_thread
       -> Ada probe; local native and lightweight task masters finish
       -> __gnat_unregister_thread
  -> join Rust std thread
  -> adafinal
  -> process exit
```

The ordering is part of the contract under test. In particular, `adafinal`
does not race an admitted Rust caller, and no Rust thread remains registered
when finalization starts.

## Result on the initial host

The spike passed on macOS arm64 with GNAT 16.1.0 and Rust 1.97.1:

```text
PASS rust-main-thread
PASS rust-panic-catch
PASS registered-rust-std-thread
PASS adafinal
```

The following integration requirements were observable rather than assumed:

- Rust must link the binder object and Flyology's prepared static
  `libgnarl.a`/`libgnat.a`. Allowing the host linker to select GNAT's shared
  libraries instead omits Flyology's patched runtime units.
- On Darwin, Rust normally invokes Clang for the final link. Clang does not
  automatically add GNAT GCC's `libemutls_w`, `libheapt_w`, and `libgcc`
  support archives, so the build script supplies the locally resolved
  toolchain archives explicitly.
- On Linux/x86-64, the prepared static GNAT runtime and the spike's Ada
  objects contain `R_X86_64_32` and `R_X86_64_32S` relocations. Rust 1.97.1
  defaults the executable link to PIE, and rust-lld rejects those static
  relocations. The runner passes `-no-pie` only to the final link on this
  architecture and asserts that the result is ELF type `EXEC`. Rust retains
  its normal code-generation model. Rebuilding Flyology and the complete GNAT
  runtime as PIC would be a separate runtime policy, not a harness fix.
- `GNAT.Threads` is the supported public registration surface. Current GNARL
  can register an unknown pthread lazily from its `Self` path, but depending
  on that target-specific behavior obscures ownership and cleanup. This spike
  registers explicitly and always unregisters before the Rust thread exits.
- The binder's `adainit` and `adafinal` procedures have no status return and
  may propagate an elaboration or finalization exception. The current probe
  contains exceptions raised by its exported application entry, but it does
  not solve exception containment around the binder lifecycle procedures.

## Linux/x86-64 evidence

On 2026-08-31 the unmodified runner failed in a clean, no-bind-mount
Linux/amd64 Docker image when rust-lld combined Rust's default `-pie` with
static relocations from the binder, probe object, and prepared `libgnat.a`.
Two controls separated code generation from final-link policy:

- `-C relocation-model=static` produced a passing executable; and
- the narrower `-C link-arg=-no-pie` also passed without changing Rust code
  generation.

The committed runner uses the second control. In a fresh image it produced an
x86-64 ELF `EXEC` with no dynamic `TEXTREL`, created and joined native and
lightweight Ada tasks from both Rust callers, caught the intentional Rust
panic, and finalized normally. The output was:

```text
PASS rust-main-thread
PASS rust-panic-catch
PASS registered-rust-std-thread
PASS adafinal
```

This proves one correct static-link policy for the current prepared runtime;
it does not establish that non-PIE is an acceptable deployment policy for
every consumer. A consumer requiring PIE must instead provide a consistently
PIC-built Ada probe, Flyology archive, allocator archive, and GNAT runtime.

## Kill criteria and remaining boundaries

This direction should be narrowed or rejected if a supported host exhibits
any of the following:

- foreign-thread registration returns null or task creation fails after
  registration;
- a native or lightweight child outlives the exported Ada call's local task
  master;
- joining a registered caller or running `adafinal` deadlocks;
- correct linkage requires both Flyology's prepared GNARL and a stock shared
  GNARL in one process;
- an Ada exception must unwind through a Rust frame;
- shutdown requires finalizing Ada while Rust callers are still admitted.

This is not yet evidence that arbitrary Tokio worker threads should enter Ada,
that concurrent Rust callers are safe under shutdown admission, or that a
Rust-owned process can initialize and finalize Ada more than once. Those are
separate follow-up spikes. A lifecycle wrapper that contains binder-time
exceptions also remains open before this shape can become a public API.
