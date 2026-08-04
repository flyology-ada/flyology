# Routed native-offload result, Linux/AArch64

This campaign supports the hypothesis on the recorded host. A bounded native
pool materially increased CPU-route throughput and reduced tail latency at
concurrency 32 and 128, while preserving low latency for a simultaneous
lightweight control route. At concurrency 1 the handoff had no throughput
benefit and was slightly slower for the shorter workloads.

The predeclared materiality threshold was a 50% throughput increase or p99
reduction at concurrency 32 or higher. All reported medians include seven
30-second trials; configuration order rotated and every measured response had
to succeed before the runner continued.

## Evidence

- [Generated full summary](../../build/http-comparison/docker-hybrid-results/20260804T152446Z/summary.md)
- [Metadata](../../build/http-comparison/docker-hybrid-results/20260804T152446Z/metadata.json)
- [Calibration](../../build/http-comparison/docker-hybrid-results/20260804T152446Z/calibration.json)
- [Raw oha observations](../../build/http-comparison/docker-hybrid-results/20260804T152446Z/runs/)
- [Process observations](../../build/http-comparison/docker-hybrid-results/20260804T152446Z/resources/)
- [Executor observations](../../build/http-comparison/docker-hybrid-results/20260804T152446Z/executor-stats/)

The campaign used GNAT 15.3.1, Alire 2.1.1, gprbuild 25.0.1, oha 1.7.0,
Linux/AArch64 in OrbStack, eight Flyology loops, server CPUs 0--7, client CPUs
8--15, two-second cooldowns, HTTP/1.1 cleartext loopback, concurrency
1/8/32/128, native pools of
1/2/4/8 workers, and queue capacity 128. Calibration produced 0.405 ms,
2.200 ms, and 9.620 ms observations for the nominal 0.5/2/10 ms targets.
The metadata records base revision `48fdb2365977e6f30a8db3cfb59df886367c8e66`
and a dirty tree because the implementation under test was intentionally not
committed before measurement.

## Result

At concurrency 32, the eight-worker pool changed the medians as follows:

| nominal CPU cost | inline req/s | hybrid req/s | change | inline p99 | hybrid p99 | p99 reduction |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.5 ms | 2,181.6 | 17,595.3 | +706.5% | 17.021 ms | 3.482 ms | 79.5% |
| 2 ms | 462.9 | 3,747.5 | +709.6% | 78.866 ms | 11.400 ms | 85.5% |
| 10 ms | 106.2 | 822.8 | +674.7% | 331.205 ms | 52.048 ms | 84.3% |

The throughput crossover occurred by concurrency 8 for every calibrated cost.
At concurrency 1, hybrid throughput changed by -4.3%, -1.3%, and +0.1% for the
three costs, respectively. This is the expected region where submission and
wakeup cost is not repaid by parallel work.

Eight workers produced the highest CPU-route throughput in this matrix. The
fully native reference remained faster: at concurrency 32 it reached 21,316.5,
4,554.3, and 1,036.0 req/s for the three costs. The hybrid configuration
therefore retained about 80--83% of fully native CPU throughput while keeping
request networking, parsing, routing, cancellation, and response I/O on the
lightweight lane.

The mixed-load result was stronger than the CPU-only result. With 10 ms CPU
requests at concurrency 32 and `/io-control` at concurrency 8, the control
route's median p99 fell from 333.717 ms inline to 0.350 ms with four native
workers, a 99.9% reduction. Four workers isolated the control route better than
eight (0.969 ms p99), while eight maximized CPU-route throughput. Pool sizing
therefore remains a latency-versus-throughput choice rather than a single
universal optimum.

For the 10 ms configuration, the inline server used 2 threads and 10.2 MiB peak
RSS; the eight-worker hybrid used 10 threads and 10.4 MiB; the fully native
reference used 257 threads and 13.4 MiB. Median sampled CPU time over each
same-shaped server run was 156.87, 1,039.70, and 1,475.88 seconds,
respectively; the larger values reflect concurrent use of the eight server
CPUs, not per-request CPU cost. Across the hybrid campaign the executor
accepted 28,619,233 submissions and recorded zero admission rejections,
execution failures, or abandoned results. Saturation reached 128 outstanding
operations; explicit overload behavior is covered by the behavioral test.

## Limits

This is one virtualized AArch64 Linux host, one deterministic integer workload,
cleartext loopback HTTP/1.1, and a maximum of eight server CPUs. It does not
establish results for TLS, allocation-heavy work, larger machines, bare metal,
or blocking foreign calls. The final campaign's context-switch fields came
from the Linux process leader and undercount worker switches; they are retained
as raw observations but are not used above. The sampler now aggregates all
`/proc/<pid>/task/*/status` entries for future campaigns.
