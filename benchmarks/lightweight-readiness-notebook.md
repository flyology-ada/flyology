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

## Persistent one-shot rearm

Host and toolchain are unchanged from the baseline above. This slice starts at
`24f3067437e1b0b0c54ef77a2f00d64639954b01`, after batched multi-source
registration merged. Downstream HTTP/1 profiles localized the next cost to the
remaining per-wait readiness lifecycle and to protected reads of stable
cancellation sources. The maintained fixture reproduced 126,729 requests/s in
an initial million-request, 16-loop, 256-connection run.

Two hypotheses were measured independently:

1. **Cache stable sources for one synchronous operation and use an atomic
   requested-state snapshot. Rejected.** Three adjacent baseline runs centered
   at 118,454 requests/s; four candidates centered at 117,616 requests/s
   (-0.71%). The candidate also increased aggregate system CPU in its first two
   trials. All source, cancellation, deadline, and check boundaries were kept,
   but the code was reverted because removing protected calls was not material.
2. **Retain the kernel's consumed one-shot registration and rearm it. Confirmed.**
   Darwin uses `EV_DISPATCH`, then `EV_ADD | EV_ENABLE` to rearm the disabled
   knote. Linux leaves a delivered `EPOLLONESHOT` registration disabled, frees
   its transient Ada watch record, and uses `EPOLL_CTL_MOD` on the next arm;
   `ENOENT` falls back to `EPOLL_CTL_ADD` after close or descriptor reuse.
   Orphaned, timed-out, cancelled, and aborted interests are still deleted, so
   an event from an older wait cannot satisfy a later wait generation. An
   initial Darwin experiment omitted `EV_ENABLE` and stalled; it was rejected
   before measurement and the focused rearm/reuse test covers that boundary.

The final comparison used separately built exact before/after binaries, each
linked against its own prepared custom RTS. The marker was checked before every
build. Commands for the 16-loop pairs were:

```sh
FLYOLOGY_LOOP_POOL_SIZE=16 /usr/bin/time -lp \
  /tmp/flyology-readiness-before CONNECTIONS
oha --no-tui --disable-color --http-version 1.1 \
  -j -n 300000 -c CONNECTIONS http://127.0.0.1:PORT/

FLYOLOGY_LOOP_POOL_SIZE=16 /usr/bin/time -lp \
  /tmp/flyology-readiness-after CONNECTIONS
oha --no-tui --disable-color --http-version 1.1 \
  -j -n 300000 -c CONNECTIONS http://127.0.0.1:PORT/
```

Three alternating pairs were run at 16 connections and five at 256. The
one-loop result is the median of three alternating pairs with the same commands
and `FLYOLOGY_LOOP_POOL_SIZE=1`.

| Loops | Connections | Before req/s | Rearm req/s | Delta |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 16 | 141,224 | 144,391 | +2.24% |
| 16 | 16 | 70,500 | 80,670 | +14.43% |
| 16 | 256 | 123,647 | 155,739 | +25.95% |

At 16 loops and 16 connections, median p50/p95/p99 changed from
210.541/414.417/568.917 microseconds to 184.792/345.042/540.333 microseconds
(-12.23%/-16.74%/-5.02%). Median server wall time fell 12.42%, aggregate system
CPU fell 10.85%, and involuntary context switches fell 30.92%.

The higher-concurrency short trials were bimodal: median p50 improved 40.61%,
while p95 and p99 did not improve consistently. The stable throughput and CPU
result is therefore the supported claim, not a tail-latency claim. A separate
million-request candidate completed at 145,935 requests/s with p50/p95/p99 of
1.502/3.402/7.101 milliseconds. A three-million-request profile completed at
140,328 requests/s; on one representative loop, 452 of 455 readiness waits
were in the single batched watch syscall, alongside 707 `recvfrom` samples.
Stable token/gate protected-lock contention remained visible, confirming that
the rejected atomic snapshot and the accepted kernel rearm address independent
costs.
