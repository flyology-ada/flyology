# Protected-object runtime investigation

This notebook records a local investigation on 2026-08-10. It makes no
portable or production-level performance claim. The surviving changes are
benchmarking and fail-closed runtime validation only; no Flyology or GNAT
runtime behavior was changed.

## Provenance

- Flyology baseline: `24f3067437e1b0b0c54ef77a2f00d64639954b01`
- Host: Apple M3 Max, 16 physical/logical CPUs, 48 GiB RAM
- OS: macOS 26.5.2 (25F84), Darwin 25.5.0, arm64
- Compiler/tooling: GNAT 16.1.0, Alire 2.1.1
- Build: `release`, `-O3`
- RTS: `build/rts`, prepared separately for 1 and 16 loops
- Required exact marker: `Flyology prepared RTS version 1`
- Required shape: `adalib/libgnat.a`, `adalib/libgnarl.a`, and
  `adainclude/s-stalib.adb`

Both benchmark runners now reject a missing, wrong, or incomplete runtime
after preparation. Every compilation below also passed the explicit
`--RTS="$PWD/build/rts"` path. GNAT's default RTS was never used.

## Commands

```sh
git fetch origin main
git rev-parse HEAD origin/main

FLYOLOGY_LOOP_POOL_SIZE=1 \
  ./showcases/run_synchronization_benchmark.sh 20000 7
FLYOLOGY_LOOP_POOL_SIZE=16 \
  ./showcases/run_synchronization_benchmark.sh 20000 7

test "$(sed -n '1p' build/rts/.flyology-rts-root)" = \
  'Flyology prepared RTS version 1'
/usr/bin/time -lp \
  ./showcases/bin/synchronization_benchmark 20000 7

./scripts/run-tcp-readiness-benchmark.sh \
  1 16 300000 build/tcp-readiness-1.json
./scripts/run-tcp-readiness-benchmark.sh \
  16 16 300000 build/tcp-readiness-16.json
```

The complete TCP path was also run for 2,000,000 requests and sampled for five
seconds with `/usr/bin/sample <pid> 5 -file <output>`. The adjacent descriptor
experiment used a detached worktree at the exact baseline commit and a
separately prepared marker-verified RTS; baseline and candidate runs were
alternated to reduce thermal and background-load bias.

## Focused synchronization results

Values are median nanoseconds per public operation over seven samples. The
program also emits p95, p99, operations/second, exact operation counts, and
lightweight scheduler wakeups. Checksums or state assertions cover every case.

| Operation | 1 loop | 16 loops |
| --- | ---: | ---: |
| Raw acquire load | 0.3 | 0.3 |
| Raw lock-free read + CAS | 5.2 | 4.8 |
| Entry-free protected function | 1.0 | 0.9 |
| Entry-free protected procedure, uncontended lightweight | 5.2 | 4.9 |
| Entry-free protected procedure, uncontended native | 5.2 | 4.9 |
| Entry-free protected procedure, same loop | 5.2 | 4.8 |
| Entry-free protected procedure, cross loop | 16.0 | 11.0 |
| Entry-free protected procedure, native/native | 17.7 | 12.5 |
| Entry-free protected procedure, mixed | 16.9 | 11.5 |
| `Cancellation.Token.Requested` | 20.2 | 19.3 |
| Stable `Cancellation.Token.Wait_Source` | 28.1 | 27.1 |
| `Capacity.Gate.Shutdown_Requested` | 19.3 | 19.3 |
| Stable `Capacity.Gate.Wait_Source` | 30.1 | 28.7 |
| Long action, same loop | 45.2 | 36.5 |
| Long action, cross loop | 68.9 | 62.3 |
| Long action, native/native | 60.1 | 50.3 |
| Long action, mixed | 62.8 | 61.7 |
| Closed conditional protected entry | 33.6 | 32.8 |
| Zero-timeout protected entry | 94.0 | 87.7 |
| Immediate protected-entry requeue | 46.0 | 45.2 |
| Alternating protected entries, same loop | 128.9 | 126.5 |
| Alternating protected entries, cross loop | 1,141.6 | 1,039.8 |
| Alternating protected entries, native/native | 1,395.1 | 877.4 |
| Alternating protected entries, mixed | 1,526.8 | 1,151.9 |
| Rendezvous, same loop | 367.6 | 300.7 |
| Rendezvous, cross loop | 4,645.9 | 3,416.4 |
| Rendezvous, native/native | 4,139.4 | 2,225.1 |
| Rendezvous, mixed | 4,886.3 | 3,265.4 |

The direct 16-loop run took 4.67 s real, 3.82 s user, and 1.86 s system. macOS
reported 717,767 involuntary and zero voluntary context switches, 44.68 billion
instructions, 19.15 billion cycles, 2.70 MiB maximum RSS, 820 page reclaims,
one page fault, and no swaps. No allocator appeared in the sampled hot paths;
allocation counts were not directly instrumented. Darwin does not expose the
Linux `perf` cache and scheduler counters used by the repository's Linux
workflow, so cache-line and scheduler-stall attribution remains qualitative on
this host.

The scheduler wake counters distinguish local protected actions from actual
handoffs. Loads, CAS, protected functions/procedures, conditional calls,
zero-timeout calls, requeue, and long actions rounded to zero wakes per
operation. Same-loop alternating entries used about 0.333 wakes/operation;
cross-loop entries also used about 0.333; mixed entries used about 0.167.
Rendezvous used 1.0 wake/operation for lightweight/lightweight and 0.5 for
mixed callers.

## Complete TCP path

The persistent cleartext H1 fixture verified all responses.

| Loops | Connections | Requests | Requests/s | p50 | p99 | Server real/user/system | Involuntary context switches |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 1 | 16 | 300,000 | 140,442.7 | 107.333 us | 179.750 us | 2.53/0.73/1.38 s | 1,041 |
| 16 | 16 | 300,000 | 68,378.9 | 219.208 us | 570.500 us | 4.85/1.23/51.83 s | 454,048 |
| 16 | 16 | 2,000,000 | 68,409.3 | 214.542 us | 703.750 us | sampled run | — |

All 16 event-loop groups owned one connection in the long run. Per-group
dispatch counts ranged from 108,837 to 112,289, so no owner/loop imbalance was
visible. The 16-loop regression on this host instead correlates with system
time, context switches, repeated `kevent64` registration/cancellation, and
contended protected-object mutex waits.

## Profile attribution

GNAT 16 expands the small entry-free `Counter` protected object into
`System.Atomic_Primitives.Lock_Free_Read_32` and
`Lock_Free_Try_Write_32`. This explains the 4–18 ns short-action results and
shows that a new general uncontended lock fast path would duplicate compiler
behavior for this important class.

Objects that contain entries take the general GNARL path even for functions
and procedures whose bodies do not touch a queue. The sampled TCP stacks were:

```text
Receive/Send_All
  Acquire_Operation or Interrupt_Sources
    Cancellation.Token.Wait_Source / Capacity.Gate.Wait_Source
      Lock_Entries
        Lock_Entries_With_Status
          Task_Primitives.Write_Lock
            pthread_mutex_firstfit_lock_slow
              __psynch_mutexwait
```

The wrappers also sampled `Abort_Defer`, `Self`, lightweight
`Scheduler.Current_Task`, `Unlock_Entries`, `PO_Service_Entries`,
`Select_Protected_Entry_Call`, and `Abort_Undefer`. These are the required
abort/ATC and entry-queue semantics, not benchmark scaffolding. Generic runtime
initialization retains priority-ceiling/inheritance mutex attributes and the
ceiling checks; bypassing that path would therefore require a GNAT runtime
change and a mixed native/lightweight proof of equivalence.

Blocked entry callers follow
`Protected_Entry_Call -> Entry_Calls.Wait_For_Completion ->
Task_Primitives.Operations.Sleep`. Flyology's existing runtime patch parks a
lightweight task for task sleeps and wakes, while native callers retain GNARL
condition-variable behavior. Entry results and wake counters show that the
handoff and queue path, not the protected action alone, accounts for the
microsecond-scale cross-loop cost.

The full I/O path separately sampled:

```text
Wait_Interruptibly
  Wait_Any_Internal
    flyology_runtime_wait_io_many
      Poller.Watch_Many -> kevent64
      Contexts.Switch

Scheduler_Main
  Poller.Wait_Batch -> kevent64
  Handle_Poll_Event
    Remove_IO_Waits_Locked
      Poller.Cancel_Many -> kevent64
```

This separates protected-object mutex time from readiness syscalls and fiber
park/wake work. No evidence isolated false sharing from ordinary shared-token
cache-line contention, and no excess application wake source signal was seen.

## Ranked hypotheses and experiments

1. **Repeated stable descriptor reads in a single connection operation.**
   Strong profile support: `Interrupt_Sources` calls entry-capable token and
   capacity protected operations both during acquisition and again before the
   immediate I/O wait. An experiment retained those borrowed descriptors only
   for the already-active operation, preserving their documented owner/token
   lifetime. Five alternating pairs produced these requests/s values:

   | Pair | Exact-main baseline | Candidate |
   | ---: | ---: | ---: |
   | 1 | 72,049 | 73,847 |
   | 2 | 73,383 | 71,976 |
   | 3 | 76,611 | 72,508 |
   | 4 | 70,403 | 73,516 |
   | 5 | 69,653 | 69,047 |

   Median throughput changed from 72,049 to 72,508 requests/s (+0.64%). Median
   instructions fell from 28.554 to 27.028 billion (-5.34%), but median cycles
   rose from 161.498 to 165.097 billion (+2.23%), system time rose from 46.97
   to 47.84 s, and latency/context-switch results were mixed. The change was
   rejected and fully reverted because the throughput gain was not material
   or reproducible.

2. **Atomic state for one-shot/read-mostly queries.** The acquire-load control
   is much cheaper than `Requested`, but `Cancellation.Token` deliberately
   contains the public `Await_Request` protected entry and lazily owned wake
   source. Replacing the protected representation would break selective and
   asynchronous entry calls, abort deferral, queue behavior, and descriptor
   lifetime. Keeping the entry while merely marking its boolean atomic does
   not remove the entry-capable wrapper. No compatible production candidate
   survived.

3. **Combine operation registration and acquisition.** This would remove one
   controller lock, but the maintained `Stale_Operation_Registration` race
   oracle requires the interval: a TLS upgrade may advance the transport
   generation after registration and before acquisition. Coalescing the calls
   changes scheduling and stale-generation semantics. Rejected before code or
   measurement.

4. **General protected-object uncontended fast path.** Entry-free objects
   already use compiler-generated lock-free load/CAS. Entry-capable objects
   require ceiling, abort, entry-service, and mixed-caller behavior. The
   benchmark does not justify a GNAT 13–16 patch in this area.

5. **Scheduler-aware protected mutex contention.** The profile confirms that
   a lightweight caller can reach a blocking pthread mutex in the general
   entry-object lock path. Replacing this with fiber parking must preserve
   priority ceilings/inheritance, FIFO entry service, abort/ATC, native callers,
   finalization, and owner death. The current evidence does not distinguish
   enough mutex wait from readiness syscall pressure to justify that runtime
   redesign.

6. **Adaptive spin/yield, affinity, false sharing, and excess wakes.** No
   bounded spin interval had evidence of a net win; spinning on an event-loop
   worker risks delaying all fibers. Group utilization was balanced, local
   actions had zero scheduler wakes, and Darwin supplied no cache-miss counter.
   No change was attempted.

## Correctness and disposition

The benchmark covers uncontended and contended functions/procedures, short and
long actions, native/lightweight/mixed callers, protected-entry queues and
wakeups, conditional and timed calls, requeue, stable one-shot/read-mostly
sources, and raw atomic controls. Existing repository semantic suites remain
the authority for FIFO/fairness, timed/conditional calls, requeue with and
without abort, ATC, exceptions, finalization, task termination, priority,
mixed execution models, descriptor lifetime, shutdown, and cancellation.

The final evidence package passed:

- the release synchronization benchmark build and smoke run against the exact
  marker-verified custom RTS;
- `./scripts/test.sh`, including 103 behavioral programs, the native and
  lightweight semantic/termination matrices, connection race tests, fault
  hooks, and fresh external Alire consumers;
- `./scripts/prove.sh`: 993 library checks, 117 runtime-policy checks, and 30
  debug-ring checks proved with GNATprove 16.1 at level 1;
- `./scripts/stress.sh`, including eight registry rounds, seeds 1, 7, 42, and
  8,675,309, and the expected fatal fault-injection cases;
- `./scripts/check-tla.sh`: all three safe configurations completed (244, 212,
  and 42,625 distinct states), and all three deliberately broken
  configurations produced the expected counterexamples;
- `./scripts/test-sanitizer.sh`, including fiber lifecycle/switch checks and
  detection of the intentional stack violation; and
- the full arm64 Ubuntu 24.04 Docker lane with GNAT 16.1.0 and the native-AIO
  fallback forced.

The first Linux Docker attempt stopped in the pre-existing
`flyology_bench/tests/recording_smoke.adb` assertion that a 0.2 ms delayed
distribution must have a lower median than a 0.8 ms distribution. The branch
does not modify that crate. Isolated reruns in the retained image passed twice
and failed once under the virtualized timer/scheduler; the subsequent complete
Docker lane passed. This is recorded as timing-test instability, not evidence
for or against protected-object behavior.

Because no production optimization met the adjacent-measurement bar, there is
no new semantic fast path to qualify or merge. The useful result is a stricter,
broader benchmark plus the negative conclusion: generic protected-object
machinery is not an evidence-backed target here, and the narrower descriptor
reuse idea saved instructions without a reproducible throughput gain.
