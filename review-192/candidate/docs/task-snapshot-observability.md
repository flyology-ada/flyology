# Lightweight task snapshot observability

This report records the task-list API design and its measured lock impact. The
results are observations from one development host, not performance thresholds
or portability claims.

## API and locking model

`Flyology.Observability.Snapshot_Tasks` copies a bounded prefix of one execution
group's membership into a caller-owned `Task_Snapshot_Array`. Records contain a
process-lifetime instance ID, scheduler state, GNARL base priority, diagnostic
flags, and usable guarded-stack bytes. They contain no ATCB, fiber, registry, or
task-control pointer. List order is unspecified, only the returned prefix is
overwritten, and the separately returned total exposes truncation.

The runtime already maintains one intrusive membership list per execution
group. Enumeration does not add another list. It takes the existing topology
lock and selected group lock in the same order as the aggregate
`Flyology.Observability.Snapshot`, copies at most the caller's capacity, then
releases both. It allocates nothing and invokes no callback while locked. The
locked work is therefore `O(min(group members, capacity))`.

Task creation did not gain a lock acquisition. It already takes the task's
registry-shard lock, then the destination group lock, to publish the fiber. A
per-shard sequence is advanced while that existing shard lock is held. The
shard number occupies the high bits of the instance ID, so concurrent shards
do not need a new global atomic or mutex. Exhaustion fails rather than reusing
an ID; gaps are allowed. The ID is stored in private fiber metadata, remains
stable across migration, and is not derived from an ATCB address.

`Current_Task_Instance` lets a lightweight task obtain that same ID. It reads
the event thread's exclusively owned current-fiber field while user code is
running and acquires no topology, registry, or group lock. Native tasks,
including the environment task, receive `No_Task_Instance`.

## Reproduction

Run:

```sh
./showcases/run_task_snapshot_contention.sh 5 \
  /tmp/flyology-task-snapshot-contention.csv
```

The recorded host was arm64 Darwin 25F84 (macOS 26.5.2) with Alire GNAT
16.1.0. The generated runtime used the native project default, one configured
execution group, round-robin automatic placement, no loop-thread placement,
no sanitizer, and no test faults. Every lightweight task requested a 16 KiB
Ada stack.

The benchmark parks all but one member in group zero. The remaining member
increments a counter and executes `delay 0.0`, providing a continuously
runnable probe. Adjacent windows with no observer establish its local baseline.
A native task then calls either `Snapshot_Tasks` or the existing aggregate
group `Snapshot`. The saturated case calls continuously for 200 ms. The
periodic case calls at 100 Hz for one second. Five fresh processes are used for
each case. CSV contains per-call p50/p95/p99/maximum latency, call throughput,
and runnable-probe throughput relative to adjacent baseline windows.

Assertions, not timing, validate complete membership, bounded counts, and
unique nonzero identities. Generated CSV stays outside the repository.

## Saturated contention results

The following values are five-run medians; parentheses show the run range.
This phase is deliberately abusive: the native observer immediately attempts
to reacquire the locks after every call.

| Members | Operation/capacity | Calls/s | p99 | Runnable rate vs baseline |
| ---: | --- | ---: | ---: | ---: |
| 1,000 | task / 1 | 6.00 M (5.52–6.01 M) | 3.00 us (2.92–3.21) | 69.2% (66.5–70.1) |
| 10,000 | task / 1 | 6.09 M (5.46–6.40 M) | 2.96 us (2.33–3.13) | 69.6% (67.2–71.3) |
| 1,000 | task / 32 | 3.99 M (3.68–4.20 M) | 4.13 us (2.08–4.79) | 38.7% (30.0–46.7) |
| 10,000 | task / 32 | 3.89 M (3.75–4.14 M) | 3.54 us (2.29–4.71) | 37.4% (32.6–42.7) |
| 1,000 | task / 1,000 | 151.7 k (142.1–160.9 k) | 10.38 us (9.75–11.25) | 0.73% (0.42–2.71) |
| 10,000 | task / 10,000 | 14.7 k (14.0–15.1 k) | 112.71 us (88.79–147.58) | 0.008% (0.001–0.009) |
| 1,000 | aggregate group | 138.3 k (137.0–142.7 k) | 10.21 us (9.71–10.50) | 0.42% (0.25–0.51) |
| 10,000 | aggregate group | 12.9 k (12.5–12.9 k) | 132.63 us (92.54–200.58) | 0.003% (0.001–0.009) |

The falsifiable design claim holds: one- and 32-record task snapshots have
similar throughput and p99 at 1,000 and 10,000 members because the list walk is
bounded by capacity. Complete enumeration scales with membership and can
starve a runnable member when called without pause. The existing aggregate
snapshot shows the same full-list behavior.

## Periodic contention results

At 100 Hz, each run made 100 observations. Values are five-run medians with the
runnable-rate range in parentheses.

| Members | Capacity | p99 call latency | Runnable rate vs baseline |
| ---: | ---: | ---: | ---: |
| 1,000 | 32 | 12.58 us | 100.6% (99.0–108.4) |
| 10,000 | 32 | 17.04 us | 100.7% (87.5–102.8) |
| 1,000 | 1,000 | 105.00 us | 98.5% (97.4–102.4) |
| 10,000 | 10,000 | 439.04 us | 97.4% (89.8–99.0) |

The 32-record cases do not show a consistent runnable-throughput loss above
run-to-run noise. Complete 10,000-record snapshots show a modest median loss
and wider spread. One run had a 1.04 ms p99, 5.88 ms maximum, and 89.8%
runnable rate. The practical policy is therefore to request small bounded
prefixes at a diagnostic cadence, not continuously copy complete large groups.

## Creation overhead experiment

The new identity assignment executes under a lock creation already held. To
measure its local cost, two otherwise identical one-group executables were
preserved: one advanced and composed the per-shard identity, and one omitted
only that work. Nine 10,000-task pairs alternated executable order.

| Mode | No identity assignment median (range) | Identity assignment median (range) | Candidate wins |
| --- | ---: | ---: | ---: |
| Cold | 0.13484 s (0.12469–0.14734) | 0.13258 s (0.12701–0.15039) | 4 of 9 |
| Warm | 0.11111 s (0.10872–0.18498) | 0.11146 s (0.10643–0.17707) | 4 of 9 |

Directions changed by pair and mode, and ranges overlap. The experiment does
not demonstrate a creation regression from identity assignment. More
importantly, inspection confirms that no mutex or atomic acquisition was added.

## Correctness and safety coverage

Focused tests establish that:

- native-only observation remains inert and self-query returns no identity;
- three waiting lightweight tasks report distinct nonzero IDs, expected states
  and flags, and each task's self-query ID occurs in the group snapshot;
- a smaller caller buffer truncates without overwriting its tail and reports
  complete membership separately;
- identities remain stable between snapshots and change when GNARL reuses a
  task-object address;
- normal return leaves an empty membership snapshot after task-object
  deallocation, while existing lifecycle churn coverage still exercises
  unhandled exception, abort, partial activation failure, and deferred reap.

Migration, activation, Ada masters, abort, exceptions, finalization ordering,
descriptor generations, guarded stacks, and deferred-reap ownership are not
changed. Snapshot records are copies, so callers cannot retain runtime-owned
addresses or act on a reused ATCB.

## Remaining limits

- Enumeration is per execution group. A process-wide view must query the
  configured/created groups and merge copied records outside runtime locks.
- List order is deliberately unspecified; the API is diagnostic, not a stable
  cursor protocol. A truncated call may observe a different prefix later.
- Snapshot latency includes waiting to acquire locks as well as copy time; it
  is an upper bound on lock hold, not a direct lock-hold trace.
- Measurements are from arm64 Darwin. Other hosts require their normal
  architecture-specific validation before cross-platform performance claims.

## Verification performed

The retained tree was checked with:

```text
sh -n showcases/run_task_snapshot_contention.sh scripts/showcases.sh
git diff --check
./scripts/docs.sh
./scripts/prove.sh
./scripts/test.sh
./scripts/stress.sh
./scripts/test-sanitizer.sh
./scripts/test-linux-docker.sh
FLYOLOGY_SNAPSHOT_SMALL=100 FLYOLOGY_SNAPSHOT_LARGE=1000 \
  FLYOLOGY_SNAPSHOT_WINDOW=0.050 \
  FLYOLOGY_SNAPSHOT_PERIODIC_WINDOW=0.100 \
  ./showcases/run_task_snapshot_contention.sh 1 \
  /tmp/flyology-task-snapshot-final-smoke.csv
```

GNATdoc completed without undocumented-entity warnings and both SPARK proof
campaigns proved all reported checks. The Darwin behavioral suite passed both
project defaults, focused observability/lifecycle tests, the termination
matrix, runtime-preparation validation, and external consumers.
Short stress passed four deterministic seeds, deferred-final-reap coverage,
and expected fatal fault cases. AddressSanitizer passed fiber switching,
lifecycle, server, and expected stack-violation coverage. Native arm64 Linux
passed its syscall/epoll ABI probe, behavioral suite, lifecycle churn and
address reuse, termination matrix, and external consumers; the Docker image
was removed by the runner. The final reduced benchmark produced 14 rows, each
with the same 26 fields as its CSV header.
