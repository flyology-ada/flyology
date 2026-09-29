# Lightweight task lifecycle measurements

This report records the task-lifecycle benchmark design, the bottleneck
investigation, and the controlled runtime change retained from the measurements.
The numbers are observations from one development host, not performance
thresholds or portability claims.

## Reproduction and phase boundaries

Run:

```sh
./showcases/run_task_lifecycle.sh 5 /tmp/flyology-task-lifecycle.csv
```

The recorded host was arm64 Darwin 25F84 (macOS 26.5.2) with Alire GNAT
16.1.0. The runtime used the native project default, round-robin automatic
placement, one or four configured execution groups, and a requested 16 KiB
task stack. GNARL adds its conservative alternate-stack allowance, so the
observed effective usable lightweight stack was 48 KiB.

The benchmark does not create sockets or files. For every measured task it
records a timestamp immediately before allocation and another at the first
body statement. A protected start barrier proves that all task bodies started.
The environment task then records one release timestamp and opens the body
gate; each task records completion immediately before returning. Only after
every completion is observed does the benchmark deallocate task objects. Each
`Unchecked_Deallocation` call is timed separately and in aggregate. Finally,
the benchmark polls `Flyology.Observability.Stack_Pool` until live stacks,
arenas, usable bytes, and reserved bytes equal their pre-batch baseline.

Cold mode retains the complete burst until the body-completion barrier. Warm
mode keeps one same-size lightweight anchor alive and churns a window of 32
tasks. This reuses a live arena but still releases the arena after the anchor,
so it does not create a historical-peak cache. The contention cases use four
prestarted native harness tasks to invoke lightweight allocation and
deallocation concurrently. Harness startup and finalization are outside the
measured phases. Assertions verify exact-once body execution and complete
return of reclaimable stack state; timing never determines pass or failure.

CSV rows contain phase wall time and throughput, p50/p95/p99 per-task latency,
RSS, virtual memory, thread count, stack/arena peaks, mappings, unmappings,
reuse and discard totals, topology, runtime configuration, and host/toolchain
identity. Human-readable summaries go to standard error.

## Creation and destruction paths read

Creation enters patched `System.Task_Primitives.Operations.Create_Task`, calls
`System.Flyology.Scheduler.Create`, selects or lazily creates the execution
group, allocates `Fiber` and `Context` metadata, obtains a guarded stack slot,
registers the ATCB in the sharded hash table, links the fiber into its group,
enqueues it, and wakes the poller. Task-body return remains ordinary GNARL:
`Task_Wrapper` completes Ada termination and master notification before the
fiber publishes `Finished` and switches back to its scheduler.

Dynamic task-object deallocation enters GNARL `Finalize_TCB`, which calls
`Scheduler.Destroy`. A finished fiber is removed from the registry and group,
its stack is protected and discarded, an empty arena is unmapped, and its
context and fiber metadata are freed. If destruction races a running or
migrating fiber, the existing deferred-reap protocol leaves the scheduler as
the exclusive reaper.

## Ranked hypotheses

1. **Linear execution-group membership removal.** Fibers were inserted at the
   group-list head but reaping scanned from that head. Deallocating an array in
   allocation order therefore produced a falsifiable quadratic pattern. The
   prediction was that an intrusive previous link would reduce 10,000-task
   finalization wall time without changing creation, stack counts, or Ada
   outcomes.
2. **Empty stack-arena unlink.** Releasing an empty arena scanned the arena
   list. The prediction was a smaller finalization reduction proportional to
   arena count, with identical mappings, unmappings, guards, and reuse.
3. **Stack protection/discard and metadata allocation.** Each lifecycle pays
   `mprotect`, `madvise`, allocation, and occasional `munmap`. The falsifiable
   signal was sampler time in those calls and a cold/warm gap after list
   removal.
4. **Topology-lock traffic for existing groups.** If topology serialization
   dominated, four concurrent creators would stop scaling and multiple groups
   would materially change creation latency. Creator-count and group-count
   sweeps test that prediction.
5. **A bounded empty-arena cache.** Reusing an empty mapping could reduce cold
   churn, but it would retain a historical peak unless tightly bounded. The
   existing live-anchor warm case measures the attainable reuse benefit without
   adding such a cache, so no cache experiment was needed.

## Controlled results

Five cold, one-group runs at 10,000 lightweight tasks were taken before and
after changing only group membership to an intrusive doubly linked list.

| Runtime | Finalization median | Run range | Median throughput | p99 range |
| --- | ---: | ---: | ---: | ---: |
| Baseline singly linked group list | 1.271 s | 1.228–1.314 s | 7,870 tasks/s | 316–508 us |
| Intrusive O(1) group unlink | 0.883 s | 0.862–0.902 s | 11,324 tasks/s | 206–243 us |

The retained change reduced the median by 30.5% and increased median
finalization throughput by 43.9%. All runs mapped and unmapped 278 arenas,
reused 9,722 slots, discarded 10,000 stacks, returned to zero live stacks, and
ran every body once. Creation stayed within its observed spread.

At 1,000 lightweight tasks with four automatic groups, five cold runs had a
0.0130 s median creation time and 0.00774 s median finalization time. They
peaked at 1,000 stacks, 28 arenas, 49,152,000 usable stack bytes, roughly
117 MB of guarded-stack reservation, and roughly 34 MB RSS. Warm 32-task churn
at the same total count had a 0.00159 s median finalization time, one arena,
and 1,000 reused stack placements. These runs cover the smaller maintained
scale independently of the 10,000-task evidence used to select the change.

The arena previous-link experiment was then applied on top of the group change.
Its median was 0.876 s with a 0.865–0.895 s range, compared with 0.883 s and a
0.862–0.902 s range without it. The 0.8% median difference was below the noise
floor and the ranges overlapped, so that experiment was reverted.

Warm one-group churn reused one arena for all 10,000 tasks: one mapping, one
unmapping, and 10,000 placements in an existing arena. Four representative
runs plus one noisy host-scheduling outlier placed median creation near 90,265
tasks/s. Median finalization was 0.0165 s, or about 605,000 tasks/s; typical
p99 deallocation latency was below 6 us. This isolates why keeping a live arena
is effective for bounded steady-state churn without justifying retention of an
empty arena.

At 10,000 cold tasks, serial automatic placement over four groups had a 0.853 s
median finalization time; explicit four-group placement had 0.860 s. Those
values were close to each other and to the one-group retained result, so group
count is not presented as a serial lifecycle optimization.

Four concurrent creators on one group produced a median cold creation time of
0.0954 s (about 104,807 tasks/s) and median finalization of 0.749 s (about
13,347 tasks/s). The tradeoff was latency: finalization p99 rose from roughly
0.2 ms in serial runs to several milliseconds. In warm 32-task churn, four
creators reduced median finalization throughput to about 209,000 tasks/s versus
about 605,000 tasks/s serially. Contention can improve cold aggregate throughput
through parallel system calls, but it is not a general latency or churn win.

The 10,000-task cold resource sample was approximately 317 MB RSS, 421 GB
virtual size, two threads for one serial group or five for four groups, 10,000
live stacks, and 278 arenas. The virtual reservation is dominated by guarded
stack layout and does not imply equal resident memory. Four harness creators
raised thread peaks to six and nine respectively.

Three bounded 1,000-task native references created 1,001 process threads at the
sample barrier. Median creation was 0.0523 s and median task-object
finalization was 0.00520 s. Native rows do not use the Flyology stack pool and
were not run at 10,000 tasks because the lightweight lifecycle, not host thread
limits, is the target of this investigation.

One safe 20,000-task four-group run reached 20,000 live stacks and 556 arenas,
approximately 632 MB RSS, and 423 GB virtual size. Creation took 0.280 s, but
finalization took 3.99 s. A one-second macOS `sample` during a repeat placed
most main-thread samples in GNARL `Free_Task` and
`Remove_From_All_Tasks_List`; Flyology stack destruction samples were divided
among `mprotect`, `madvise`, and `munmap`. This identifies GNARL's global task
list as the remaining large-scale limit. Changing that list would broaden the
versioned GNARL patch and ATCB boundary, so it was not attempted here.

## Creation follow-up experiments

Creation was investigated separately after retaining the reap improvement. A
fresh seven-run, one-group baseline at 10,000 lightweight tasks placed serial
cold creation at a 0.129 s median and serial warm creation at 0.112 s. Four
prestarted creators produced 0.101 s cold and 0.0861 s warm medians. The
four-creator result shows available parallelism, but its wider ranges require
paired comparisons rather than conclusions from independently built runs.

A one-second sample during 100,000 bounded warm tasks attributed 82
main-thread samples below `Contexts.Create` to `mprotect`, 70 below
`Poller.Wake` to `kevent64`, and only a small number to Flyology `Fiber` and
`Context` allocation. This made stack protection and poller notification the
leading mechanisms and rejected metadata combination as the first experiment.

The following controlled changes were tested and reverted:

- **Creation wake only on an empty-to-nonempty ready transition.** Initial
  10,000-task runs suggested a 3–7% warm or contended improvement, but cold
  serial results were mixed. At 100,000 warm tasks, four-creator medians were
  0.867 s before, 0.801 s with the change, and 0.728 s after reverting and
  rebuilding the baseline. The reversal outperformed the candidate, so the
  apparent win was host-phase noise rather than retained evidence.
- **Intrusive free-slot chain inside a stack arena.** Removing the bitmap slot
  scan changed warm medians by roughly 2–4%, with overlapping ranges, while
  the cold serial median regressed. The scan is not a demonstrated bottleneck
  at the maintained stack size and arena capacity.
- **Automatic-placement topology ticket.** Nine interleaved
  automatic-versus-explicit pairs found explicit placement 3–5% faster in warm
  cases but 1–3% slower in cold cases. The direction changed with mode, so an
  already-created-group fast path was not justified.
- **Protect a reserved existing-arena slot outside the pool lock.** An
  independently built candidate initially appeared 10% faster serially and
  25% faster with four creators. A decisive comparison preserved baseline and
  candidate executables and alternated eleven 100,000-task runs per creator
  count. The candidate's serial median was 1.138 s versus 1.124 s baseline and
  it won 4 of 11 pairs. With four creators its median was 0.916 s versus 0.964
  s, but it won only 6 of 11 pairs and its mean paired wall-time delta was 4.2%
  worse because of latency outliers. Reservation rollback and atomic success
  accounting therefore added complexity without a consistent scalability win.

No creation change was retained. Per-task guarded-stack protection and the
ordinary GNARL allocation/activation path remain real costs, but these
experiments do not support weakening guards, adding a parallel lifecycle, or
accepting a contention-only tradeoff with unstable latency.

## Safety of the retained change

The retained field is an intrusive previous pointer inside Flyology's private
`Fiber`, not the ATCB or public ABI. Link and unlink operations remain under the
same execution-group lock. They validate the head, previous, and next links
before mutation and clear both links after removal. Creation and migration use
one shared link helper; reap and migration use one shared unlink helper.

No ownership or state transition changed. Registry removal, ready/timer/I/O
removal, member counts, dedicated reservations, stack destruction, deferred
reap, and object freeing retain their previous order. Migration still unlinks
under the source lock and links under the target lock after the existing shard
and topology coordination. Guarded stacks, descriptor generations, Ada
masters, activation, abort, exceptions, finalization ordering, and lazy event
startup are unaffected.

## Remaining limits

- Cold finalization still includes GNARL global task-list removal and guarded
  stack system calls. The 20,000-task result is not linear scaling.
- The benchmark records body completion immediately before return; GNARL
  wrapper termination occurs afterward and is included in task-object
  deallocation when necessary.
- Observable reap time after deallocation is often near zero because a finished
  dynamic task is normally reaped synchronously inside `Finalize_TCB`. The
  separate pool barrier still catches deferred scheduler-side reap.
- Native measurements are bounded reference rows only. They are not used to
  choose the lightweight runtime change.
- Results are from arm64 Darwin. Linux and x86-64 require their normal Docker,
  sanitizer, and architecture-specific validation before making cross-platform
  performance claims.

## Verification performed

The retained tree was checked with:

```text
sh -n showcases/run_task_lifecycle.sh scripts/showcases.sh scripts/test.sh scripts/coverage.sh
git diff --check
./tests/bin/lifecycle_churn_smoke
./scripts/test.sh
./scripts/stress.sh
./scripts/test-sanitizer.sh
./scripts/test-linux-docker.sh
FLYOLOGY_LIFECYCLE_SMALL=5 FLYOLOGY_LIFECYCLE_LARGE=10 \
  FLYOLOGY_LIFECYCLE_NATIVE=3 \
  ./showcases/run_task_lifecycle.sh 1 \
  /tmp/flyology-task-lifecycle-final.csv
```

The full Darwin suite passed all ordinary tests, the cross-group conformance
and 28-case termination matrix, runtime-preparation failure checks, and external
native/lightweight consumers. The short stress campaign passed four seeds plus
the fault and deferred-final-reap cases. AddressSanitizer passed fiber switching,
repeated destruction, lifecycle, server, and expected stack-violation coverage.
Native arm64 Linux Docker passed its ABI probes, behavioral suite, termination
matrix, lifecycle churn test, and external consumers; the test image was removed
by the runner. The benchmark driver was also run end to end with reduced smoke
counts, and every CSV row had the same field count as its header.

`./scripts/showcases.sh` was also attempted, but the unchanged
`lightweight_file_io` showcase parked its 256 writers and did not finish within
30 seconds on this Darwin host. A process sample showed the environment task
waiting for its Ada master and the event loop idle in `kevent64`; no sampled
stack entered the changed creation/reap membership path. The 64-writer file
correctness case passed in both the Darwin and Linux full suites. The complete
showcase collection is therefore not reported as passing.
