# Ada HTTP server comparison

This harness compares Flyology with maintained Ada HTTP stacks under two
separate contracts. It does not treat the two tiers as interchangeable.

| Tier | Flyology | Other servers | Measured path |
| --- | --- | --- | --- |
| Plain HTTP engine | lightweight and native handlers | AWS 25.2.0, EWS 1.11.0 | direct request callback, no router or middleware |
| Application server | lightweight and native handlers | ServletAda 1.8.2 over AWS and EWS | router/container/servlet dispatch |

Every server receives HTTP/1.1 cleartext requests and returns the same status,
content type, and body bytes. The runner verifies that contract before taking a
measurement. TLS is deliberately absent: it would primarily compare provider
configuration and crypto rather than HTTP dispatch. The default workload uses
persistent connections; optional connection churn is recorded separately.

The website publishes an [August 2026 development snapshot](https://flyology.org/journal/2026-08-http-comparison/)
from this harness. It includes the aggregate tables, metadata, and raw result
bundle. The short Docker campaign is labeled as preliminary throughout.

## Reproduce it in Docker

Docker is the supported entry point on macOS and the most convenient entry
point on Linux. The image pins Alire 2.1.1, GNAT 15.3.1, gprbuild 25.0.1, oha
1.7.0, and each Ada dependency in its adapter manifest. Downloads for Alire and
oha are checked against architecture-specific SHA-256 values.

Run a response-contract smoke test and keep no image:

```sh
HTTP_BENCH_VERIFY_ONLY=1 \
  ./showcases/http-comparison/scripts/run-linux-docker.sh
```

Run the maintained local comparison profile:

```sh
HTTP_BENCH_TRIALS=7 \
HTTP_BENCH_DURATION=30s \
HTTP_BENCH_WARMUP=5s \
HTTP_BENCH_CONCURRENCIES="1 8 32" \
HTTP_BENCH_COOLDOWN=20 \
HTTP_BENCH_INCLUDE_CHURN=1 \
HTTP_BENCH_SERVER_CPUSET="0-7" \
HTTP_BENCH_CLIENT_CPUSET="8-15" \
  ./showcases/http-comparison/scripts/run-linux-docker.sh
```

Set `HTTP_BENCH_TIERS=plain` or `HTTP_BENCH_TIERS=application` to run one tier.
Adjust or omit the two CPU sets for machines that do not expose 16 CPUs.
Set `FLYOLOGY_HTTP_BENCH_KEEP_IMAGE=1` while iterating to retain the image.
On native Linux, `./showcases/run_http_comparison.sh` builds and runs the same
matrix without Docker. `HTTP_BENCH_SKIP_BUILD=1` reuses an existing build.

Treat concurrency 128 and above as a separate saturation probe. EWS's single
selector can exceed the five-second request deadline there on this harness;
the strict runner records the raw failing observation and stops rather than
mixing timed-out requests into a throughput comparison. Set, for example,
`HTTP_BENCH_CONCURRENCIES=128` when the error boundary itself is the subject of
the run, and test higher levels in separate invocations because a failed level
ends its campaign immediately.

Results are written below `build/http-comparison/`. Each timestamped directory
contains:

- `metadata.json`: host, kernel, architecture, revision, dirty state, tools,
  pinned server versions, loop count, and campaign settings;
- `runs/*.json`: unmodified oha observations;
- `resources/*.json`: sampled process CPU time, high-water RSS, thread count,
  and context-switch totals;
- `logs/`: server output, kept out of the request path;
- `summary.csv`, `resources.csv`, and `summary.md`: medians across complete
  trials, plus throughput ranges and context-switch totals in CSV.

## Workload contracts

The source-of-truth workload files are `workloads.conf` and
`application-workloads.conf`.

| Tier | Route | Response |
| --- | --- | --- |
| Plain | `/plaintext` | `200 text/plain`, exact 13-byte `Hello, World!` |
| Plain | `/response-1k` | `200 application/octet-stream`, exactly 1,024 `x` bytes |
| Application | `/benchmark/route.html` | `200 text/plain`, exact 13-byte `Hello, World!` after framework routing |

The adapters disable per-request logging. Flyology plain uses the raw HTTP
connection handler; Flyology application uses its router and exchange API. AWS
plain uses its callback API. EWS plain uses its dynamic handler API. The
application competitors use one identical ServletAda servlet. The EWS adapter
uses the same public container/request/response flow as ServletAda's backend,
but sets EWS tracing to false because the stock backend hard-codes per-request
tracing on. ServletAda 1.8.2 currently resolves AWS 25.0.0 for that adapter;
the plain AWS adapter remains on 25.2.0. Capacity is
set to the same value where the server exposes it. EWS has a single selector
task and no equivalent worker-capacity setting, so that architectural fact is
left intact and recorded rather than hidden behind a custom pool.

## Reading the results

Use the median requests per second to compare throughput and p50/p90/p99/p99.9
to compare latency shape. Do not rank servers from a one-second smoke run or a
single trial. A useful result has all of the following:

- seven or more trials, with alternating server order and a cooldown;
- zero request errors and only HTTP 200 responses;
- a stable throughput range rather than a single lucky peak;
- enough duration to reach a steady CPU and memory state;
- the raw JSON and metadata kept with any published table.

The Docker command uses loopback, so the load generator competes with the
server for CPU and the container runtime can add noise. It is suitable for
repeatable development comparisons, not a universal performance claim. For a
publishable machine result, run the native Linux harness on an otherwise idle,
fixed-frequency host, reserve separate CPUs for the load generator and server,
and repeat on at least one second architecture. Report the kernel, CPU model,
power settings, and CPU placement alongside the generated metadata.

The comparison answers how these exact fixtures behave on the recorded host.
It does not establish production suitability, protocol completeness, or a
general ranking of the projects.
