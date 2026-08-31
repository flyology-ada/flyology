# Ada hosts Rust async spike

This spike tests an Ada-owned executable that submits bounded jobs to a
Rust-owned Tokio runtime. It is evidence gathering, not a proposed public
`Flyology.Rust` API.

## Hypotheses

- A narrow C ABI can keep the Tokio runtime, futures, panics, and allocation
  entirely Rust-owned while Ada retains task and scoped-operation ownership.
- A Flyology completion set's borrowed signal descriptor can be the only
  cross-thread notification. Rust never calls `Signal_Completion` and retains
  no Ada address.
- A signal published before Ada arms readiness remains observable.
- The same operation semantics work from native and lightweight tasks. A
  delayed Rust job must suspend a lightweight task without blocking a
  same-group lightweight ticker.
- Cancellation can remain pending until Tokio acknowledges it, after which
  typed `Finish` releases the generation-stamped Rust slot.

## Run

From this directory:

```sh
./run.sh
```

The runner uses Cargo's locked offline mode, prepares a one-group Flyology RTS,
builds the Ada executable, and runs it with a 20-second bound. Tokio is pinned
in `Cargo.lock`; the first run requires that pinned crate to already be present
in Cargo's local cache.

The executable runs, from both task lanes:

1. synchronous Rust completion before Ada readiness arming;
2. a Tokio timer completion with an integer result;
3. an intentional panic inside a Tokio task, captured as a terminal Ada error;
4. cancellation of a long Tokio timer, drained before result release;
5. 32 waves of eight near-simultaneous completions sharing one completion
source, followed by 32 waves of eight zero-delay cancellation/completion
races. Alternating waves give Tokio 5 ms before the cancel requests; every
process must observe both success and cancellation while retaining exactly one
terminal outcome per job.

The lightweight run additionally places a timer ticker and the waiting task in
execution group 1. All five ticks must occur while the Rust job is pending.
After both lanes, it fills all eight Rust slots, verifies that a ninth start is
rejected and its Flyology set reservation is rolled back, drains the admitted
jobs, and immediately reuses the released capacity. It also verifies that
engine shutdown is rejected while one job remains admitted, then succeeds
after cancellation, terminal observation, and typed `Finish`.

The stress pass also abandons one pending job and one early-completed job. A
controlled lease stored in each Ada operation must release the Rust slot after
Flyology's inherited finalizer cancels and drains the provider. A test-only
active-slot query verifies that both scope exits leave the engine empty.

The runner executes the complete process three times by default. Set
`FLYOLOGY_RUST_STRESS_RUNS` to another positive count for a longer campaign.
Tokio's default panic hook prints the two intentional task panics in each
process before the final `PASS` line; the outer Tokio task still joins and
translates both panics.

## Observed result

On 2026-08-31 the complete runner passed on Darwin/AArch64 with GNAT 16.1.0,
Rust 1.97.1, and Tokio 1.53.1. The two task lanes reused the same engine and
generation-stamped slot sequence. The lightweight ticker completed all five
10 ms waits while its same-group peer awaited a 150 ms Tokio timer.

The default three-process second-wave campaign also passed. Each process ran
1,024 multi-operation stress jobs across the two lanes. Every process observed
128 successful and 128 cancelled zero-delay jobs in each lane, with no missing
or duplicate terminal outcomes. All shared-source completion waves drained,
the ninth-slot admission rollback preserved completion-set capacity, the next
generation reused released capacity, busy shutdown was rejected, and both
abandoned-operation scopes left the Rust engine with zero active slots.

The second-wave stress campaign extends this evidence with shared-source wakes,
admission rollback, cancellation races, and generation reuse. The Rust unit
tests release a terminal slot, reuse the same slot with a new generation, and
verify that polling the old handle returns `INVALID_HANDLE`. A separate unit
test fills all eight slots and verifies that the ninth job is rejected until a
slot is released.

Review found and fixed a first-wave lifetime gap: the original plain
`JobHandle` record was released only by typed `Finish`. Flyology's operation
finalizer could cancel and drain an abandoned job, but it had no provider hook
with which to release the Rust slot. The handle is now held by a controlled Ada
lease. Normal `Finish` disarms that lease after releasing the slot; abandonment
drains through the inherited operation finalizer and then releases through the
lease finalizer. Engine shutdown would expose any missed release as `ENGINE_BUSY`.

This does not yet support a general claim that arbitrary Tokio I/O resources
can cross reactors.

## ABI and ownership evidence

`JobHandle` is a `repr(C)` value containing a one-based slot and nonzero
generation. Its Ada mirror uses `C_Pass_By_Copy`: plain `Convention => C`
passed this record indirectly on the tested Darwin/AArch64 GNAT toolchain and
produced invalid values at Rust's by-value ABI boundary. Ada never receives a
Rust pointer for a job. The engine itself is an opaque Rust allocation with
explicit create/destroy calls. Every exported
Rust function catches synchronous unwinding. An outer Tokio task also joins
the actual job task so an asynchronous panic becomes retained job state.

The signal descriptor is borrowed until the operation terminalizes. Rust
writes one byte to Flyology's nonblocking wake pipe; a full pipe already means
notification is retained. Ada polls job state only on its owner task's stack,
and releases the Rust slot only from typed `Finish`. Rust uses an internal
publishing state so terminal state is not visible until the descriptor write
has returned; this prevents Ada from closing or reusing a descriptor that a
producer can still touch.

## Kill criteria and limitations

Reject this bridge shape if any stress run finds a lost completion,
descriptor use after completion-set destruction, concurrent poll/release,
generation alias, or cancellation that publishes before the Tokio task has
stopped using job state.

This slice still omits descriptor transfer and borrowed data buffers. Buffer
canaries were deliberately not added: the current value-only job ABI has no
borrowed buffer, so a canary would test invented semantics rather than a precise
bridge contract. The eight-slot bound cannot saturate a normal wake pipe;
`WouldBlock` remains specified as a retained notification, but adversarial
saturation needs a dedicated signal-source test with enough concurrent
producers. Concurrent destroy/admission is also outside the ABI contract:
callers must exclude destroy from every engine call. The busy-shutdown test
covers outstanding admitted work, not a concurrent lifetime race.

The ABI has eight internal slots solely to expose bounded reuse; that number is
spike mechanism, not proposed policy. The dynamic-library link keeps this spike
focused on runtime semantics; a separate ABI/linkage spike should assess static
linking, native library dependencies, and symbol collisions.
