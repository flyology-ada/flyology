# Runtime patch families

Patch directories name the GNAT release range whose bundled runtime sources
have been tested. `prepare-rts.sh` reads the active compiler release and
refuses to continue when no matching family exists; it never guesses or falls
back to an unverified patch.

`gnat-13-16` is verified against these exact Alire `gnat_native` releases:

| Host | Releases |
| --- | --- |
| Darwin | 13.2.2, 14.1.3, 14.2.1, 16.1.0 |
| Linux | 13.2.2, 14.1.3, 14.2.1, 15.1.2, 15.3.1, 16.1.0 |

The Darwin GNARL source bundled with Alire's GNAT 15 releases has a different
task-primitives shape and needs its own patch family before it can be enabled.
Platform-specific changes live in `darwin/` and `linux/`; changes shared by
both GNARL implementations live in `common/`.

GNAT 13 through 15 implement `Ada.Synchronous_Task_Control` with a pthread
condition variable. Patches under `legacy/` backport the exact-task GNARL
sleep/wake protocol so a lightweight waiter suspends its task rather than its
event-loop pthread. The private lock type moved in GNAT 15, so its spec patch
is separate from the GNAT 13/14 patch; the behavioral body is shared. GNAT 16
already provides the hook-based implementation and is not patched here.

The Linux task-primitives patch also clamps native stack allocation to libc's
reported pthread minimum. GNAT 13 and 14 otherwise request 48 KiB for a 16 KiB
task on AArch64, where glibc requires 128 KiB. The clamp is a no-op when the
compiler already requests enough space.

The Darwin monotonic subunit patches replace GNAT's realtime tasking clock with
Mach absolute time. Native condition waits and kqueue timeouts use that same
sleep-pausing clock domain; adjustable calendar delays are translated again at
bounded one-second intervals after the machine resumes. The narrow C bridge
uses a widened intermediate for the tick-to-nanosecond conversion and rejects
samples outside GNAT's signed nanosecond `Duration` range.
The Darwin task-primitives patch applies the same bounded calendar translation
to lightweight timed sleeps and delay statements rather than passing a calendar
epoch directly to the scheduler's monotonic deadline heap. Runtime preparation
requires the exact Darwin monotonic patch selected for the compiler family;
Linux has no corresponding monotonic patch.

The common task-stages patch also invokes Flyology's one-shot finalizer after
GNARL has completed global tasks and controlled library objects. This placement
is part of the patch-family contract: moving it earlier would race live task
stacks, while omitting it leaves internal scheduler pthreads and pollers for the
operating system to reclaim at process exit.

The same common patch publishes a fixed task-owned exit result at GNARL's outer
task wrapper boundary, after the compiler-generated body has unwound and
completed its dependent-task master but before user termination handlers run.
It attaches the storage before activation and detaches it during ATCB reap; no
ATCB field, global result registry, or post-allocation registration is added.

When a future GNAT release changes the affected GNARL sources, add a new
versioned family rather than weakening patch validation. A family may span
multiple majors only while the same patch is built and behaviorally tested on
every advertised major.
