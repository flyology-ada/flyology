# Flyology-native interests for Rust futures spike

This spike asks whether a standard Rust `Future` can make I/O and timer
progress directly on a Flyology execution group, without Tokio, another Rust
executor, or a Rust executor thread.

The result is a deliberately small executor-shape seam. Rust serially polls an
opaque `Pin<Box<dyn Future<Output = Result<i64, ()>> + Send + 'static>>`. While
that poll is active, bridge-aware future code records a bounded next-interest
plan in poll-scoped thread-local storage. A pending poll returns one record
containing up to six borrowed read/write descriptors and one relative
monotonic deadline. The Ada scoped-operation driver arms those interests with
`Flyology.Operations.Drivers`, suspends, and polls the same future again on the
owner task's stack after readiness or deadline delivery.

Run from the repository root or this directory:

```sh
./spikes/flyology-rust/direct-io/run.sh
```

The runner builds Cargo offline, checks formatting, runs Rust unit tests and
strict Clippy, prepares an isolated Flyology RTS, builds the Ada executable,
and runs it ten times by default. Set `FLYOLOGY_RUST_INTEREST_REPEATS` to
change the repeat count.

## Cases exercised

- a timer-only future whose only progress source is a Flyology deadline;
- a borrowed readable descriptor made ready by an Ada lightweight task in the
  same execution group;
- read and write readiness directions;
- two simultaneous readable descriptors plus a deadline in one plan;
- data made ready before the initial poll returns `Pending`, so readiness
  exists before Ada arms the descriptor;
- a same-group Ada ticker progressing while the future owner is suspended;
- cancellation followed by Rust future destruction before the Ada owner
  closes either borrowed descriptor; and
- instrumentation requiring serial polling and exactly one destruction per
  future.

The ready-before-arm case works because the future retries the nonblocking
operation on every poll and Flyology uses level-observed descriptor readiness.
An adapter for an edge-triggered or consumable notification still needs its
own probe/arm/recheck or generation protocol; this spike does not generalize
the result to such sources.

## Exact support boundary

The object being polled implements `std::future::Future`, but it is not an
arbitrary ecosystem future. A future may return `Pending` only after publishing
at least one interest understood by this bridge. The no-op `Waker` means a
future whose sole progress protocol is `Waker::wake` will stall and is rejected
if it returns an empty plan. Tokio futures are therefore not supported by this
seam.

The spike requires `Send`. That lets one lightweight task migrate between
execution groups between serialized polls: the interest recorder retains no
thread-local state after a poll, and the tested descriptors are process-wide.
This does not make a thread-affine foreign library migratable. A `!Send` or
thread-affine future would require a scoped `Flyology.Execution_Groups.Thread_Pin`
covering creation, every poll, cancellation, and destruction, plus a separate
type-erased boundary that never promises `Send`. That variant is not tested.

One operation can publish at most the existing Flyology bound of six
descriptor interests, with read/write direction retained per entry, and can
coexist with one earliest deadline. Rust borrows every descriptor. Ada retains
sole closing ownership and must keep each descriptor live until the operation
has terminalized and the Rust job has been destroyed. Cancellation is an
owner-stack drop, not cooperative Rust cancellation; it is suitable only when
dropping the particular future synchronously releases all of its references.

The Rust crate uses `panic = "abort"`. No panic can cross the C ABI, but an
unexpected panic terminates the process. This is the explicit panic-free route
identified by the separate unwind spike, not a claim of recoverable panic
translation.

## What this removes and what remains

This spike demonstrates that Flyology already has the scheduler primitives
needed for a bridge-aware Rust future executor: bounded multi-readiness,
coexisting monotonic deadlines, owner-stack driving, cancellation, and serial
polling. It does not require a second scheduler or a wake thread.

The remaining design work is mainly at the Rust API and ownership boundary:

- define safe Rust awaitables/adapters that emit these interests without
  exposing poll-scoped TLS as public API;
- decide whether ordinary waker-driven futures get a separate coalesced wake
  descriptor or remain outside the direct executor;
- specify cancellation for futures that retain kernel submissions, buffers,
  or foreign callbacks beyond `Drop`;
- select a result/error ABI wider than this spike's `i64` value;
- test Linux and other supported toolchain/architecture combinations; and
- measure polling and interest-plan overhead against Flyology's native Ada
  scoped providers.

Kill this shape if a safe adapter cannot enforce descriptor and buffer
lifetimes, if required futures cannot express bounded interests, if
cancellation needs to block an event-loop pthread, or if adding generic waker
support recreates a second executor with independent scheduling policy.
