# Ada-hosted Tokio socket I/O spike

This spike extends the Ada-hosted Tokio experiment from timers and integer
results to real, local, bidirectional socket I/O. It is evidence gathering,
not a proposed public `Flyology.Rust` API.

## Run

From this directory:

```sh
./run.sh
```

The runner builds a locked, offline Tokio dynamic library, prepares a
one-group Flyology RTS, builds the Ada executable, and runs the process three
times. Set `FLYOLOGY_RUST_STRESS_RUNS` to another positive count to change the
repeat count.

Each operation creates a local Unix-domain stream pair inside Rust. A Tokio
future sends the request from the first endpoint to the second, reads it,
constructs a reversed and byte-masked response, sends the response in the
other direction, and reads it back at the first endpoint. Every read and write
is limited to the requested chunk size, so the retained counters demonstrate
multiple progress steps in both directions rather than one convenient
socket-buffer transfer.

The Ada executable checks:

- the same successful duplex operation from native and lightweight tasks;
- more than one request write, request read, response write, and response read;
- a lightweight wait does not prevent a same-group timer ticker from running;
- terminal completion and typed `Finish` after Rust signals before Ada arms
  descriptor readiness;
- cancellation after observable partial request progress;
- cancellation drains and closes both descriptors before terminal state is
  visible;
- scope abandonment cancels, drains, closes, and releases the Rust slot;
- input and output canaries remain intact across start, wait, cancellation,
  and abandonment; and
- every typed `Finish` or finalizer leaves zero active jobs and descriptors.

## Ownership contract tested

Ada input storage is borrowed only for the synchronous `Start` ABI call. Rust
copies at most 256 bytes before returning and retains no Ada buffer address.
The test overwrites the entire Ada input immediately after `Start`; the result
must still derive from the original bytes.

The response remains in a Rust-owned `Vec` after terminal completion. Rust
does not receive the Ada output address until typed `Finish`, which performs a
bounded synchronous copy. The output remains filled with a sentinel through
`Wait_All`, and guards immediately outside the output slice must survive
`Finish`.

The two data descriptors never cross the language boundary. Rust creates,
registers, owns, and closes both. Dropping the selected I/O future closes the
descriptors on success, error, or cancellation; only then does the task drop
its descriptor lease and publish terminal state. This avoids an ambiguous
half-transfer rule for raw descriptors.

The completion-set signal descriptor is different: it is borrowed from Ada
until terminal publication finishes. A publishing state prevents Ada from
observing a terminal job while Rust can still write that descriptor. A full
nonblocking signal pipe already represents retained notification.

The Ada operation owns a generation-stamped Rust slot handle. Poll, cancel,
copy, and release validate both slot and generation. Normal `Finish` releases
the slot explicitly. On abandonment, Flyology's operation finalizer first
cancels and drains the provider; the controlled Rust lease then releases the
terminal slot.

## Observed result

On 2026-08-31 the default three-process campaign passed on Darwin/AArch64 with
GNAT 16.1.0, Rust 1.97.1, and Tokio 1.53.1. Both task lanes completed real
Tokio socket reads and writes with multiple progress steps in each direction.
Cancellation and abandonment left no active Rust job or descriptor, and all
buffer guards survived. A follow-up campaign ran the final executable 20 times,
with a 10-second process bound and 5-second bounds on each task-lane report;
all 20 processes passed.

The completion-before-arm case deliberately waits for Rust's published state
with a bounded test-only poll before arming the Flyology descriptor. The
already-written signal then wakes the ordinary completion-set path. This is a
retention test, not a proposed initiation algorithm.

## Decision and remaining risks

This spike rejects retaining raw Ada buffer addresses across a Rust `await` as
the default bridge shape. Rust cannot encode the lifetime of an arbitrary Ada
actual in the future's type, and Ada cancellation or scope exit would need a
provable drain before storage reuse. The copy-in/Rust-owned/copy-out shape is
small, auditable, and compatible with Flyology's typed `Finish` rule. A future
zero-copy design would need a first-class pinned buffer owner whose lifetime
and cancellation drain are represented on both sides.

This does not test transfer of application-owned descriptors, TCP, TLS, large
payload backpressure, vectored I/O, concurrent engine destruction, or Linux.
It also does not make an arbitrary Tokio I/O resource safe to cross reactors.
Reject this bridge if any repeat observes a buffer guard change outside
`Start`/`Finish`, a descriptor count after terminalization, a lost wake, a
stale generation alias, or a cancellation that publishes while its I/O future
can still access job state.
