# Lightweight readiness optimization notebook

This notebook records adjacent measurements for the custom-RTS TCP fixture.
Every supported runner invocation prepares `build/rts` and fails closed unless
`build/rts/.flyology-rts-root` exists before compilation or execution.

## Fixture

`scripts/run-tcp-readiness-benchmark.sh LOOPS CONNECTIONS REQUESTS OUTPUT`
uses `oha 1.7.0` against persistent HTTP/1.1 loopback connections. Each server
handler is an explicit lightweight task and owns a bounded admitted
`Flyology.IO.Connections.Connection`. Its reads include the connection-close,
server-shutdown, and a never-fired token descriptor in the same kernel wait as
the socket, plus the operation deadline.

Record the host, commit, exact sweep commands, `oha` throughput and latency,
`/usr/bin/time -lp` CPU/context-switch data, scheduler counters, and profile or
system-call evidence below. Keep rejected hypotheses with their adjacent delta.

## Baseline

Host: Apple Silicon (`arm64`), macOS 26.5.2 (25F84), GNAT 16.1.0,
`oha 1.7.0`. Baseline commit: `1acfd593`. Compiler switches are in
`benchmarks/tcp_readiness_benchmark.gpr` and include `-O3`. The fixture was
built and run only with the prepared RTS whose marker contains
`Flyology prepared RTS version 1`.

The initial 300,000-request sweep used these exact commands:

```sh
for connections in 1 4 16 64 128; do
  ./scripts/run-tcp-readiness-benchmark.sh \
    1 "$connections" 300000 \
    "build/tcp-readiness/baseline-l1-c${connections}.json"
done
for connections in 1 16 128; do
  ./scripts/run-tcp-readiness-benchmark.sh \
    16 "$connections" 300000 \
    "build/tcp-readiness/baseline-l16-c${connections}.json"
done
```

| Loops | Connections | Requests/s | p50 | p95 | p99 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 38,631 | 24.666 us | 37.791 us | 54.000 us |
| 1 | 4 | 105,558 | 36.416 us | 53.084 us | 64.917 us |
| 1 | 16 | 101,088 | 164.750 us | 187.583 us | 228.333 us |
| 1 | 128 | 69,424 | 1.706 ms | 2.520 ms | 4.345 ms |
| 16 | 1 | 19,705 | noisy | noisy | noisy |
| 16 | 16 | 57,003 | 264.333 us | 514.500 us | 841.083 us |
| 16 | 128 | 97,472 | 1.213 ms | 2.504 ms | 4.730 ms |

A two-million-request 16-loop, 16-connection baseline measured 52,988.9
requests/s, with p50/p95/p99/p99.9 of 269.709/629.667/998.500/2,777.000
microseconds. A three-second `sample` capture showed each loop repeatedly in
three `kevent64` paths: one call per source from `Wait_IO_Many`, one delete per
orphaned source from `Remove_IO_Waits_Locked`, and the actual blocking poll.
The sample recorded 41,346 `kevent64` stack occurrences.

## Hypotheses and adjacent results

1. **Batch per-wait kqueue changes and avoid deleting the delivered one-shot
   interest. Confirmed.** Darwin now submits one change list for all new
   sources and one receipt-producing delete list for the remaining orphaned
   sources. The scheduler deduplicates identical pairs before either call.
   Linux retains its `epoll_ctl` state machine behind the same transaction and
   rollback contract. One-shot behavior and registrations remain scoped to a
   single wait; no interest survives for reuse by a later fiber.
2. **Remove finite deadlines. Rejected.** Downstream adjacent million-request
   candidates measured 87,882 and 96,539 requests/s around a finite-deadline
   baseline of 95,278. Deadlines remain bounded and unchanged.
3. **Omit a stable cancellation descriptor. Rejected.** Omitting only the
   handler token produced 80,717 and 102,236 requests/s around 97,747, without
   a stable gain. Socket, close, shutdown, and token sources remain present.
4. **Multiply listener portals with separate one-loop processes. Rejected.**
   The controlled downstream sweep fell from about 50,000 requests/s at 16
   connections to about 30,000 at 128 and 256. No portal change was made.
5. **Change scheduler wakes or connection placement. Not supported by the
   adjacent evidence.** The profile localized the dominant removable work to
   readiness registration and cancellation. Scheduling and placement policy
   remain unchanged.

For the adjacent comparison, the exact `1acfd593` binary and optimized binary
were built from separate worktrees with their own custom RTS trees. Five
alternating pairs used 16 loops, 16 persistent connections, and 300,000
requests per trial:

```sh
FLYOLOGY_LOOP_POOL_SIZE=16 /usr/bin/time -lp \
  /tmp/tcp_readiness_before 16
oha --no-tui --disable-color --http-version 1.1 \
  -j -n 300000 -c 16 http://127.0.0.1:PORT/

FLYOLOGY_LOOP_POOL_SIZE=16 /usr/bin/time -lp \
  /tmp/tcp_readiness_after 16
oha --no-tui --disable-color --http-version 1.1 \
  -j -n 300000 -c 16 http://127.0.0.1:PORT/
```

| Median of five | `1acfd593` | Optimized | Delta |
| --- | ---: | ---: | ---: |
| Requests/s | 55,616.6 | 72,092.2 | +29.63% |
| p50 | 271.375 us | 199.041 us | -26.65% |
| p99 | 854.416 us | 660.875 us | -22.65% |
| Server real time | 5.65 s | 4.34 s | -23.19% |
| Server user time | 1.54 s | 1.31 s | -14.94% |
| Server system CPU | 64.49 s | 45.56 s | -29.36% |
| Involuntary context switches | 565,496 | 417,089 | -26.25% |
| Instructions retired | 33.50 billion | 28.42 billion | -15.17% |
| Cycles elapsed | 219.59 billion | 155.77 billion | -29.06% |

macOS `/usr/bin/time -lp` reports aggregate CPU across the 16 loop threads, so
system CPU can exceed wall time. The paired server always completed exactly
300,000 sends and receives. An additional two-million-request optimized run
measured 70,093.3 requests/s (+32.28%), with p50/p95/p99/p99.9 improved by
28.43%/21.23%/15.31%/37.25%. Its three-second sample showed one batched watch
and one batched cancellation call per multi-source wait; it recorded 37,977
`kevent64` stack occurrences while completing requests at the higher rate.

## Retained Darwin one-shots

Host: Apple Silicon (`arm64`), macOS 26.5.2 (25F84), GNAT 16.1.0,
Alire 2.1.1, and `oha 1.7.0`. Baseline commit: `24f3067`. Accepted
implementation commit: `4aa7292`. Every binary used an `-O3` benchmark build
linked with the prepared RTS whose `.flyology-rts-root` contained exactly
`Flyology prepared RTS version 1`; each server reported the requested runtime
pool size before load began. Diagnostic profiles and optimized measurement
binaries were kept separate from the ordinary library build.

The baseline sweep preserved the first optimized binary at
`/tmp/flyology-tcp-readiness-baseline-24f3067` and ran three 200,000-request
trials at every point:

```sh
for rep in 1 2 3; do
  for loops in 1 16; do
    for connections in 1 16 64 128; do
      FLYOLOGY_LOOP_POOL_SIZE="$loops" /usr/bin/time -lp \
        /tmp/flyology-tcp-readiness-baseline-24f3067 "$connections"
      oha --no-tui --disable-color --http-version 1.1 \
        -j -n 200000 -c "$connections" http://127.0.0.1:PORT/
    done
  done
done
```

The controlled candidate left an orphaned Darwin `EV_ONESHOT` knote armed
after its last scheduler waiter detached. It retained no scheduler link or
fiber address. The knote can yield at most one unmatched readiness hint and is
removed by descriptor close. Linux was deliberately excluded from this
retention rule because its epoll implementation also owns an allocated
registration record; it continues to delete orphaned interests. The accepted
implementation exposes that platform capability explicitly rather than using
the experiment's global constant.

Median request rates from the short sweep were:

| Loops | Connections | Baseline req/s | Retained req/s | Delta |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 41,876.3 | 48,145.5 | +14.97% |
| 1 | 16 | 138,506.7 | 132,446.4 | -4.38% |
| 1 | 64 | 133,635.1 | 137,087.5 | +2.58% |
| 1 | 128 | 113,687.0 | 127,634.7 | +12.27% |
| 16 | 1 | 41,281.1 | 38,393.6 | -6.99% |
| 16 | 16 | 70,475.6 | 144,805.2 | +105.47% |
| 16 | 64 | 109,555.1 | 143,704.4 | +31.17% |
| 16 | 128 | 115,771.9 | 140,951.0 | +21.75% |

The low-concurrency points are noisy and include regressions, so they are not
used to claim a universal improvement. Five alternating 500,000-request pairs
provide the adjacent comparison at the motivating multi-loop point and a
single-loop control:

| Median of five | 1 loop, c16 baseline | 1 loop, c16 retained | 16 loops, c128 baseline | 16 loops, c128 retained |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | 131,188.4 | 129,399.4 (-1.36%) | 118,521.4 | 140,875.0 (+18.86%) |
| p95 | 168.959 us | 166.166 us (-1.65%) | 2,127.583 us | 1,002.500 us (-52.88%) |
| Server real time | 3.98 s | 4.03 s | 4.39 s | 3.72 s |
| Server system CPU | 2.63 s | 2.77 s | 42.53 s | 8.36 s |
| Involuntary context switches | 1,934 | 1,979 | 369,232 | 464,101 |
| Instructions retired | 27.59 billion | 25.93 billion | 36.79 billion | 32.70 billion |
| Cycles elapsed | 12.39 billion | 12.59 billion | 148.74 billion | 33.83 billion |

The approximate aggregate CPU occupancy at 16 loops fell from 63.4% to 17.4%
of available loop-thread time, computed from `(user + system) / real / 16`.
This is a host resource measure, not an internal loop-utilization clock.
Context switches increased, so the gain is attributed to cheaper control
work, not to fewer scheduler handoffs.

A separate two-million-request retained run completed at 142,666.9 requests/s
with p50/p95/p99 of 889.417/1,048.459/1,689.500 microseconds. It reported
1,994,407 dispatches, 1,793,551 poll batches, and 1,994,260 delivered poll
events. The design has no readiness cache, so cached-readiness hits are zero.
Delivered events did not exceed dispatches; no excess event wave or busy loop
was visible, although the uninstrumented performance build does not count
post-resume `EAGAIN` results separately.

Matching three-second `sample` captures used one-million-request, 16-loop,
128-connection runs. The baseline achieved 106,317.5 requests/s and contained
both `Watch_Many -> kevent64` and `Remove_IO_Waits_Locked -> Cancel_Many ->
kevent64`; the retained run achieved 134,444.5 requests/s and contained the
watch path but no cancellation path. Total `kevent64` samples fell from 14,251
to 12,422 while `recvfrom` samples remained 5,813 versus 5,869. Structurally,
Darwin readiness control therefore falls from one watch plus one delete
transaction per suspended multi-source operation to one watch and no delete;
the blocking scheduler wait remains unchanged.

The same profile runs exposed these maintained scheduler counters:

| One-million-request run | Dispatches | Poll batches | Poll events |
| --- | ---: | ---: | ---: |
| Baseline | 914,781 | 139,481 | 914,365 |
| Retained | 989,708 | 722,054 | 989,088 |

Dispatches are the available proxy for initial fiber runs plus readiness
resumes; the maintained counters do not separate suspends from resumes. They
also do not count watch/delete calls, post-resume `EAGAIN`, or stale/false
wakes. Consequently, watch/delete cost is reported only as the proven poller
control shape and sampled stacks, not as an invented exact per-request count:
one batched watch per suspended operation in both variants, one batched delete
per detached operation in the baseline, and no detach-time delete on Darwin in
the retained design. Cached-readiness hits are exactly zero because this design
has no readiness cache.

The final platform-capability implementation was rebuilt from source and ran
the 16-loop, 128-connection, 200,000-request fixture at 142,656.3 requests/s,
consistent with the retained-one-shot experiment.

Correctness qualification for `4aa7292` used `./scripts/test.sh`. It passed
both project defaults, 103 behavioral programs, native/lightweight semantic
and termination matrices, timeout and abort rearming, simultaneous read/write,
descriptor close and reuse, cancellation/deadline races, TLS direction changes,
server shutdown, loop lifecycle, fault seams, and fresh external consumers.
The existing `Wait_Any` batch test specifically places data after a timed-out
wait and before reattachment, while the reuse case closes the timed-out
descriptor before creating and waiting on its replacement generation.

Additional local qualification completed as follows:

- `./scripts/stress.sh` passed all maintained short stress seeds and fault
  cases.
- `./scripts/test-sanitizer.sh` passed the dedicated ASan fiber-switch and
  expected stack-violation tests.
- `./scripts/prove.sh` passed all reported project, runtime-policy, and debug
  SPARK checks.
- `./scripts/check-tla.sh` passed all safe models and found each required
  counterexample for the deliberately broken variants. TLC required an
  unrestricted local RMI socket after the sandboxed attempt was denied.
- `./scripts/docs.sh` completed and generated the API search indexes. It also
  emitted the repository's existing undocumented generic-formal warnings in
  the allocation-contract and element-adapter units; this change adds no
  public API entity.
- The native-architecture Linux/AArch64 GNAT 16.1.0 Docker suite passed on a
  clean rerun with the native-AIO fallback forced, including the Linux poller,
  descriptor, wait, TLS, semantic-matrix, and external-consumer tests. An
  initial run timed out in the unrelated `pool_reduction_smoke`; the same test
  and complete suite passed on the adjacent rerun.
- A separate run allowed and explicitly required io_uring. The host selected
  backend 2 (native AIO) instead, so the io_uring-required run failed closed in
  `files_smoke`; io_uring qualification was unavailable on this host rather
  than reported as passing.
- `./scripts/test-alire-runtime-matrix.sh` could not start its first Flyology
  build because the current Alire 2.1 index no longer resolved its pinned
  `gnat_native=13.2.2` selection. This is recorded as an external toolchain
  availability failure rather than a successful matrix run.

### Rejected or deferred candidates

1. **Retain orphaned epoll registrations. Rejected.** Linux registration
   records are process-owned allocations and can outlive a closed numeric FD
   without an explicit lifetime notification. Keeping them would permit
   unbounded bookkeeping growth and ambiguous reuse recovery.
2. **Persistent connection-lifetime registration with waiter slots and cached
   readiness. Deferred.** A connection may be operated by different tasks and
   loops over its lifetime. Correct unregister, migration, close, generation,
   and foreign-thread handoff would require a new cross-loop ownership
   protocol. The smaller kernel-owned Darwin change already demonstrates a
   material multi-loop gain without introducing that state machine.
3. **Persistent cancellation, shutdown, and deadline registrations. Not
   implemented.** No source was removed. Darwin merely permits an undelivered
   one-shot for any direction to expire by one event or descriptor close;
   Linux and failed-watch rollback retain eager cancellation. Deadlines remain
   scheduler-heap entries with their original precedence and responsiveness.
4. **Enable/disable, dispatch/rearm, desired-interest tables, and readiness
   caching. Deferred.** They still require control syscalls or generation-tagged
   lifetime state. No adjacent evidence showed that their added machinery was
   needed after eliminating the demonstrated delete transaction.
