# Flyology Rust bridge spikes

These programs test Ada/Rust interoperability boundaries before a public
bridge API is designed. They are executable evidence, not supported Flyology
APIs. Rust values stay behind a narrow C ABI, and every experiment makes
runtime, buffer, descriptor, cancellation, and shutdown ownership explicit.

## Evidence map

| Question | Spike | Result on the initial host |
| --- | --- | --- |
| Is the scalar/record/pointer/thread ABI usable? | [`abi`](abi) | Static and dynamic, debug and release pass. Small `repr(C)` values require Ada `C_Pass_By_Copy` on Darwin/AArch64. |
| Why does a statically linked Rust panic abort? | [`unwind`](unwind) | GNAT GCC 16.1 injects `-no_compact_unwind`. Clang static or a Rust dynamic library retains the required Mach-O unwind metadata. |
| Can Ada tasks await a Rust async runtime? | [`ada_hosts`](../flyology_rust/ada_hosts) | Native and lightweight tasks pass Tokio completion, panic translation, cancellation, shared wakes, slot reuse, and abandonment stress. |
| Does real Tokio I/O preserve ownership? | [`tokio_io`](../flyology_rust/tokio_io) | Local duplex socket I/O passes with synchronous copy-in, Rust-owned descriptors/results, and typed copy-out. |
| Can Rust own the Ada partition? | [`rust-hosts`](../rust-hosts) | Rust initializes/finalizes one partition and a registered Rust thread creates native and lightweight Ada tasks. |
| Can many Rust callers enter tasking Ada? | [`rust-ingress`](../rust-ingress) | Six standard threads and six Tokio blocking jobs enter concurrently behind a lifecycle admission gate. |
| Can Flyology poll a Rust future directly? | [`direct-futures`](../flyology-rust/direct-futures) | Serialized polling, wake-before-arm, cancellation, and late-waker deactivation pass. |
| Can the future use Flyology I/O directly? | [`direct-io`](../flyology-rust/direct-io) | Bridge-aware `Future + Send` values publish up to six descriptor interests and one deadline without another executor thread. |
| Does the matrix pass on Linux? | [`linux-aarch64`](../flyology-rust/linux-aarch64) | The complete x86-64 matrix passes. AArch64 fails closed before bridge execution because the custom GNAT configuration omits archive metadata. |

The main Darwin/AArch64 campaigns used GNAT 16.1.0, Rust 1.97.1, and Tokio
1.53.1. Each linked README records its exact repetitions, toolchain, negative
cases, and run command.

## Resulting bridge shapes

### Ada application using Rust async

The viable boundary is a Flyology scoped operation backed by a Rust-owned
runtime and generation-stamped slot. Rust borrows only the completion source's
signal descriptor. A publishing state keeps terminal completion hidden until
the signal write has returned, and cancellation remains pending until Rust has
dropped the future and every retained resource.

For data I/O, the default should retain no Ada pointer across `await`. `Start`
copies bounded input synchronously, Tokio owns its buffers and descriptors,
and typed `Finish` copies the retained result to Ada. The stress spike found
that the Rust slot also needs a controlled lease: typed `Finish` is the normal
release path, while abandonment must cancel, drain, and then release during
finalization.

### Rust application embedding Ada

The Rust main thread calls binder-produced `adainit` and `adafinal`. Every
foreign OS thread reserves lifecycle admission, explicitly registers with
GNAT, enters exported Ada code whose exceptions are translated to status
values, unregisters, and then releases the reservation. Shutdown closes
admission and drains both calls and registrations before finalization.

Tokio async worker migration is not covered by registration. The tested
Tokio boundary is `spawn_blocking`, where one blocking closure owns one honest
OS-thread registration for the complete Ada call. Binder initialization and
finalization exceptions are process-fatal on the tested toolchain; a public
bridge needs a supported non-unwinding lifecycle wrapper or must specify that
failure as fatal.

### Rust futures on Flyology execution groups

There are two distinct executor contracts:

- A general waker-driven future can use a coalesced descriptor wake, but its
  resource reactor remains external or must be adapted separately.
- A bridge-aware future can publish a bounded Flyology interest plan while it
  is polled: up to six read/write descriptors plus one deadline. Flyology arms
  those interests and repolls serially on the owner task's stack, with no Rust
  executor thread.

The tested direct-interest form requires `Future + Send`, process-wide
non-thread-affine descriptors, synchronous resource release from `Drop`, and a
panic-abort contract. Arbitrary Tokio futures, waker-only futures, `!Send`
futures, and thread-affine foreign state are not implied. A `!Send` variant
would need a separate type-erased ABI plus a `Thread_Pin` spanning creation,
poll, cancellation, and destruction.

## Cross-cutting contracts established by the spikes

- Use fixed-width C layouts, `C_Pass_By_Copy` for by-value Ada record mirrors,
  opaque Rust allocations, and generation-stamped bounded handles.
- No panic or Ada exception may unwind across the language ABI. On Darwin,
  recoverable Rust panic translation additionally requires checked compact
  unwind metadata in the final artifact.
- Terminal publication is a release boundary. The producer must finish every
  buffer, descriptor, callback, and wake-source access before the consumer can
  observe terminal state.
- Scope abandonment is part of the normal correctness model, not an optional
  cleanup test. It must cancel, drain, close, and release exactly once.
- Rust-hosted Ada is a one-shot partition lifecycle. Every entry point must
  participate in the same close/admission gate.
- Ada task activation does not mean a child body has published its result. An
  exported parent that needs child results must wait explicitly before it
  returns.

## Remaining gates before a public bridge

1. Repair the custom GNAT AArch64 target/configuration metadata, then rerun the
   complete native AArch64 matrix. The checked harness rejects a zero GPRbuild
   exit without archives or executables.
2. Package and continuously verify the Darwin link recipe, final unwind
   sections, and isolated native/lightweight panic self-tests.
3. Design the safe Rust-facing interest and result APIs without exposing the
   spike's poll-scoped TLS or permitting an empty interest plan to stall.
4. Decide whether generic waker-only futures are intentionally a separate
   Tokio/runtime bridge or receive a bounded coalesced-wake adapter.
5. Spike `!Send` plus `Thread_Pin`, large-payload backpressure, TCP/TLS, and an
   optional first-class pinned buffer owner before making zero-copy claims.
6. Benchmark bridge polling, wake coalescing, copies, cancellation, and
   foreign-thread admission against the equivalent native Flyology providers.

Those are bounded follow-ups. The current evidence is sufficient to keep the
three integration directions distinct while sharing the same ABI, terminal
publication, cancellation-drain, and lifecycle principles.
