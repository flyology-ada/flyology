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
- header-defined signal, errno, and wait-status macros;
- the opaque `siginfo_t` value used by `waitid(..., WNOWAIT)`.

The C file creates close-on-exec pipes, constructs spawn actions, resets signal
state, starts a new process group, and exposes wait-status observations. It has
no timeout arithmetic, retry loop, environment policy, protocol parser,
classification policy, or cleanup state machine. Ada validates and builds
`argv`/`envp`, owns monotonic deadlines, drains bounded diagnostics, signals
the anchored process group, reaps the child, validates the result envelope,
and classifies every outcome.

The protocol parser is not a useful SPARK boundary while it reconstructs the
existing controlled `Measurement` metric store. Its length, enum, number,
identity, completion, and trailing-data checks remain explicit in Ada. A later
proof effort can extract the byte cursor and scalar classifiers without moving
process policy into C.

`tests/workers_smoke.adb` exercises spawn, descriptor closure, timeout,
signal, reaping, and protocol behavior. `tests/native/workers_abi_probe.c`
links the fixed C symbols and verifies the platform constants. The crate test
script runs both on the current Darwin or Linux host; cross-platform claims
remain limited to whichever path CI actually executes.
