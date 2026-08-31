# Concurrent Rust ingress and lifecycle spike

This spike extends `spikes/rust-hosts` from one joined caller to concurrent
Rust-owned callers racing a one-shot Ada shutdown. It exercises ordinary Rust
threads and Tokio blocking jobs. Tokio's async workers do not enter Ada:
`spawn_blocking` supplies an honest OS-thread boundary, and each blocking
closure explicitly registers and unregisters that thread with GNAT.

Run it from the repository root:

```sh
./spikes/rust-ingress/build-and-run.sh
```

The default runner starts ten fresh processes because an Ada partition is
one-shot. Set `FLYOLOGY_RUST_INGRESS_REPETITIONS` to change that count.

## Admission contract under test

The Rust lifecycle gate tracks two resources independently:

- a reservation acquired before `__gnat_register_thread` and released only
  after `__gnat_unregister_thread` returns;
- an admission held around every exported Ada application call.

Closing atomically rejects new reservations and calls, then waits for both
counts to reach zero. Only the Rust thread that called `adainit` invokes
`adafinal`. Twelve registered callers hold an Ada call open when closing
starts: six `std::thread` callers and six Tokio `spawn_blocking` callers. Each
Ada call overlaps other callers and creates one native and one lightweight
child task. A per-call protected wait makes both child outcomes explicit
before the exported call returns; it does not serialize separate callers.

Pure Rust tests repeat the close/admission interleaving 250 times. The runner
then repeats the complete one-shot process lifecycle ten times. This probes a
race boundary; it is not a proof that every GNARL service is safe for arbitrary
concurrent foreign callers.

## Task-activation result

The first concurrent version treated child activation as if both task bodies
had already published their observations. That assumption failed consistently:
10, 11, and 12 of the 12 calls in three diagnostic runs returned status 21,
meaning the native child had not yet recorded its result. Registration had
succeeded, its returned task id matched `Current_Task`, the foreign caller was
native, and the task declarations raised no exception.

The retained negative samples child state immediately after activation and
requires at least one incomplete observation. It then waits on a per-call
protected entry until both child bodies publish either an observation or an
exception. This distinguishes task activation from child-body completion and
keeps the application boundary explicit.

On the initial macOS arm64 host with GNAT 16.1.0 and Rust 1.97.1, ten fresh
processes passed. Every process completed all 12 initially admitted calls,
observed a maximum of 12 concurrent Ada entries, and correctly observed the
identity and lane of every native and lightweight child after the explicit
wait. Between 5 and 12 activation-only observations per process were
incomplete. Closing drained every call and registration reservation before
`adafinal`.

## Binder exception probe

GNAT's generated `adainit` and `adafinal` have no status result. A companion
partition deliberately raises during elaboration and during library-level
controlled finalization. The runner executes each mode in a subprocess and
requires that the lifecycle call does not return to Rust as if it succeeded.

Both failures were process-fatal. Rust reported that it could not catch the
foreign exception and aborted; the marker after the relevant binder call was
absent. Rust code therefore cannot turn binder failures into a normal `Result`
merely by declaring and calling the generated symbols. A reusable bridge needs
a non-unwinding lifecycle boundary with an explicit status contract, supplied
by supported Ada/GNAT integration rather than by letting an Ada exception cross
a Rust frame. Until that exists, binder failure is a process-fatal
initialization/finalization condition.

## Kill criteria and limits

Reject or narrow Rust-owned ingress if any supported host shows:

- failed explicit registration, lost task identity, or wrong child lane;
- an Ada exception crossing the C ABI instead of becoming an integer status;
- `adafinal` beginning while a registration reservation or call admission is
  live;
- deadlock while closing drains callers, unregisters threads, or joins child
  task masters;
- dependence on both Flyology's prepared GNARL and a stock shared GNARL;
- a need to run Ada directly on a migrating Tokio async worker.

The gate is process-local and cooperative: every bridge entry must use it.
Cancellation of a Rust future does not cancel a `spawn_blocking` closure, so
the closure remains registered and admitted until its synchronous Ada call
returns. The spike does not support reinitializing Ada after `adafinal`, does
not finalize with live callers, and does not establish a recoverable binder
exception mechanism.
