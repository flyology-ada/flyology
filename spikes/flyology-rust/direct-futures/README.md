# Direct Rust futures on Flyology spike

This spike asks whether a Flyology scoped operation can directly and serially
poll an opaque Rust `Pin<Box<dyn Future<Output = Result<i64, ()>> + Send +
'static>>` without Tokio or another Rust executor.

The Rust library owns the future, a safe `Wake` implementation, a mutex, and a
nonblocking close-on-exec pipe. Ada receives only an opaque job handle and the
borrowed readable descriptor. The waker retains no Ada pointer. Flyology polls
the future on the scoped operation owner's stack and arms the descriptor after
`Pending`.

Run it from the repository root or this directory:

```sh
./spikes/flyology-rust/direct-futures/run.sh
```

The script builds Cargo offline, prepares an isolated Flyology RTS under the
repository build directory, links the Rust static library into the Ada test,
and runs these cases on one lightweight execution group:

- self-wake during the initial poll, before Ada arms readiness;
- delayed wake from a Rust thread;
- same-group Ada ticker progress while the future is pending;
- isolated native and lightweight children that probe Rust panic containment;
- cancellation, synchronized waker deactivation, and a late escaped waker;
- instrumentation rejecting concurrent polling and descriptor signal failure.

## Hypotheses and kill criteria

The direct polling design survives this spike if all wake schedules make
progress, each job has at most one active poll, a pending lightweight task does
not block its event loop, and cancellation can return only after wake
deactivation excludes a write racing descriptor close. Panic containment is
evaluated separately for native and lightweight task stacks because a failed
unwind aborts the process before Ada can observe it.

Kill or redesign the direct executor boundary if a wake can be lost between
Rust returning `Pending` and Flyology arming readiness, if cancellation cannot
synchronize with cloned wakers without retaining Ada state, if a future needs
concurrent polling to progress, or if Rust panic containment is unreliable on
the task lane where polling occurs.

## Scope limits

This is a test-only C ABI and supports macOS and Linux pipe flag values. It has
no general result/error schema, no `!Send` policy, no Flyology-native Rust I/O
interest plan, and no Tokio compatibility claim. The delayed test deliberately
detaches one short-lived Rust thread; production cancellation and shutdown
would need an owned thread/runtime lifecycle rather than detached work.

## Observed result

On macOS/AArch64 with GNAT 16.1.0 and Rust 1.97.1, self-wake, delayed
cross-thread wake, same-group ticker progress, cancellation, and late-waker
deactivation pass. Both isolated panic children abort inside Rust before
`catch_unwind` returns, reporting `failed to initiate panic, error 5`. The
current boundary must therefore require panic-free Rust code (or build with
`panic=abort` and accept process termination) until a later linkage/unwinding
spike explains and removes that restriction.
