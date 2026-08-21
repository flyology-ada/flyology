# Fresh-worker native boundary audit

`Flyology_Bench.Workers` must remain independent of the Flyology runtime and
must be safe after Ada tasking starts. The repository's existing
`Flyology.Subprocesses` package satisfies the process-lifecycle rule, but using
it here would add the runtime dependency that the standalone benchmark crate
deliberately avoids.

Direct Ada imports are used for `read`, `write`, `close`, `kill`, and
`waitpid`. Their fixed signatures and scalar arguments have stable platform
representations. The worker boundary retains C only for mechanisms that do not
have a stable fixed Ada representation:

- opaque `posix_spawn_file_actions_t` and `posix_spawnattr_t` values;
- platform-selected chdir and close-from spawn extensions;
- the variadic `fcntl` operation used to make parent endpoints nonblocking;
- header-defined signal, errno, and wait-status macros;
- the opaque `siginfo_t` value used by `waitid(..., WNOWAIT)`.

The C file creates close-on-exec pipes, constructs spawn actions, resets signal
state, starts a new process group, exposes one-shot nonblocking setup and
header-defined errno values, and reports wait-status observations. It has no
child cleanup decision, timeout arithmetic, retry loop, environment policy,
protocol parser, classification policy, or lifecycle state machine. Ada
validates and builds `argv`/`envp` and
adopts the returned PID and descriptors inside an abort-deferred protected
action. Ada then owns monotonic deadlines, bounded drain turns, process-group
signals, retrying reap, result validation, and outcome classification.
Detected loss of waitable-child ownership through an external reaper is an Ada
policy failure: the guard is disarmed and no longer signals the reusable PID
value. The caller must exclude concurrent reapers; they can race the
observation-to-reap interval on hosts without a stable process handle.

The protocol parser is not a useful SPARK boundary while it reconstructs the
existing controlled `Measurement` metric store. Its length, enum, number,
identity, completion, and trailing-data checks remain explicit in Ada. A later
proof effort can extract the byte cursor and scalar classifiers without moving
process policy into C.

`tests/workers_smoke.adb` exercises spawn, descriptor closure, continuous-output
timeouts, parent-abort cleanup, external reaping, signal, field bounds,
semantic result validation, and protocol behavior. Fixture-only C mechanisms
live in `tests/worker_fixture_native.c` and are absent from the production
archive. Its descendant fixture must call `fork` after Ada tasking has started;
keeping the branch and its `signal`/`pause`/`_exit` loop in C ensures the child
runs only async-signal-safe operations. Directly importing `fork` into Ada would
return through the Ada caller in the child and violate that invariant. The
helper contains no timeout, retry, or cleanup policy. The parent-side test still
owns the expected process-group outcome and bounded observation loop.
`tests/native/workers_abi_probe.c` links the fixed production symbols and
verifies the platform constants. The crate test script runs both on the current
Darwin or Linux host; cross-platform claims remain limited to whichever path CI
actually executes.
