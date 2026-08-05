# HTTP server comparison

This harness compares Flyology with maintained Ada and Rust HTTP stacks under
two separate contracts. It does not treat the two tiers as interchangeable.

| Tier | Flyology | Other servers | Measured path |
| --- | --- | --- | --- |
| Plain HTTP engine | lightweight and native handlers | AWS 25.2.0, EWS 1.11.0, hyper 1.11.0 | direct request callback or service, no router or middleware |
| Application server | lightweight and native handlers | ServletAda 1.8.2 over AWS and EWS, axum 0.8.9, Actix Web 4.14.0 | router/container/framework dispatch |

Every server receives HTTP/1.1 cleartext requests and returns the same status,
content type, and body bytes. The runner verifies that contract before taking a
measurement. TLS is deliberately absent: it would primarily compare provider
configuration and crypto rather than HTTP dispatch. The default workload uses
persistent connections; optional connection churn is recorded separately.

The Rust fixtures are an aspirational extension to the maintained harness.
hyper is kept in the plain tier because its project describes it as a low-level
HTTP building block.
axum and Actix Web stay in the application tier because both exercise framework
routing before returning the body. The selected versions were current releases
on 2026-08-04 according to the projects' release records and crates.io:
[hyper 1.11.0](https://github.com/hyperium/hyper/releases/tag/v1.11.0),
[axum 0.8.9](https://github.com/tokio-rs/axum/releases/tag/axum-v0.8.9), and
[Actix Web 4.14.0](https://github.com/actix/actix-web/releases/tag/web-v4.14.0).
Rust 1.97.1 is fixed by `rust-toolchain.toml`; direct dependencies use exact
versions and `Cargo.lock` fixes the complete transitive graph.

The first two August 2026 HTTP journal entries predate this extension and are
superseded because their builds linked one event loop while reporting 16. The
[corrected follow-up](https://flyology.org/journal/2026-08-http-comparison-correction/)
publishes tier-separated aggregate results from the verified harness. Its
historical raw ignored outputs were not retained, so the checked-in aggregates
cannot be independently regenerated from the published artifacts; its method
record identifies reachable source equivalents without claiming a rerun.

## Reproduce it in Docker

Docker is the supported entry point on macOS and the most convenient entry
point on Linux. The image pins Alire 2.1.1, GNAT 15.3.1, gprbuild 25.0.1, oha
1.7.0, Rust 1.97.1, the locked Rust graph, and each Ada dependency in its
adapter manifest. Downloads for Alire and oha are checked against
architecture-specific SHA-256 values. Rust fixtures use Cargo's release
profile, thin LTO, one code-generation unit, stripped symbols, and
`panic = "abort"` behavior.

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
HTTP_BENCH_CONCURRENCIES=1 \
HTTP_BENCH_COOLDOWN=20 \
HTTP_BENCH_INCLUDE_CHURN=1 \
HTTP_BENCH_LOOPS=16 \
HTTP_BENCH_SERVER_CPUSET="0-7" \
HTTP_BENCH_CLIENT_CPUSET="8-15" \
HTTP_BENCH_RUST_WORKERS=8 \
  ./showcases/http-comparison/scripts/run-linux-docker.sh
```

Run higher concurrency separately as a saturation probe:

```sh
HTTP_BENCH_TRIALS=1 \
HTTP_BENCH_DURATION=1s \
HTTP_BENCH_WARMUP=1s \
HTTP_BENCH_CONCURRENCIES="8 32 128" \
HTTP_BENCH_COOLDOWN=0 \
HTTP_BENCH_LOOPS=16 \
HTTP_BENCH_SERVER_CPUSET="0-7" \
HTTP_BENCH_CLIENT_CPUSET="8-15" \
HTTP_BENCH_RUST_WORKERS=8 \
HTTP_BENCH_SATURATION_PROBE=1 \
  ./showcases/http-comparison/scripts/run-linux-docker.sh
```

Set `HTTP_BENCH_TIERS=plain` or `HTTP_BENCH_TIERS=application` to run one tier.
Adjust or omit the two CPU sets for machines that do not expose 16 CPUs.
Set the loop count explicitly for a comparison campaign. The build and runner
both fail unless the linked runtime reports that exact count; metadata records
the requested and observed values separately. The maintained 16-vCPU profile
uses 16 Flyology loops and confines all server threads to CPUs `0-7`, matching
the corrected local validation that exposed the earlier accidental one-loop
build. This is a recorded profile, not a claim that 16 is optimal on every
host.
`HTTP_BENCH_RUST_WORKERS` fixes the Tokio or Actix Web worker count; if omitted,
the fixtures use the process's available parallelism after CPU affinity is
applied.
Set `FLYOLOGY_HTTP_BENCH_KEEP_IMAGE=1` while iterating to retain the image.
On native Linux, `./showcases/run_http_comparison.sh` builds and runs the same
matrix without Docker. `HTTP_BENCH_SKIP_BUILD=1` reuses an existing build.
The build fails if the benchmark probe does not observe the requested compiled
loop count. When CPU sets are configured, the runner reapplies the server set
to every live server thread after readiness and warmup and stops on any mask
mismatch.

## Reproduce it on Kubernetes

The Kubernetes runner builds and runs the same revision in parallel on one
ARM64 node and one AMD64 node. Select ready, lightly loaded nodes after reviewing
capacity, allocated requests, live node metrics, roles, taints, pressure
conditions, CPU topology, and memory. Pass node names through the environment;
the script does not record them in benchmark output:

```sh
HTTP_BENCH_ARM64_NODE=<selected-arm64-node> \
HTTP_BENCH_AMD64_NODE=<selected-amd64-node> \
HTTP_BENCH_TRIALS=7 \
HTTP_BENCH_DURATION=30s \
HTTP_BENCH_WARMUP=5s \
HTTP_BENCH_COOLDOWN=20 \
HTTP_BENCH_CONCURRENCIES=1 \
HTTP_BENCH_LOOPS=16 \
HTTP_BENCH_RUST_WORKERS=8 \
  ./showcases/http-comparison/scripts/run-kubernetes.sh
```

The selected `HTTP_BENCH_GIT_REVISION` defaults to local `HEAD` and must be
reachable from `HTTP_BENCH_GIT_REPOSITORY`; the repository defaults to the
public Flyology remote and may be changed for a fork. With the local overlay
enabled, the selected revision must resolve locally to the current `HEAD`.
Branches, tags, symbolic revisions, and detached commits are resolved to their
commit id before any cluster command. To benchmark another revision, check it
out before building the overlay or set `HTTP_BENCH_LOCAL_OVERLAY=0` to use the
repository revision without local changes.

By default the runner packages all Git-tracked and unignored local files needed
from the root project plus `src/`, `runtime/`, `scripts/`, and `showcases/` as a
temporary ConfigMap overlay. This applies uncommitted Flyology server/runtime
work symmetrically with competitor fixture changes without pushing it. A
manifest records every
file checksum, deletion, base revision, dirty path, content checksum, and archive
checksum. The runner verifies that manifest against the working tree before
contacting the cluster, and the pod verifies it again before building. Symlinks,
non-regular files, unsafe archive paths, stale sources, and oversized ConfigMaps
are rejected. Set `HTTP_BENCH_LOCAL_OVERLAY=0` to measure the repository
revision alone. Git-ignored generated build directories are excluded.

Validate overlay completeness locally without cluster credentials:

```sh
HTTP_BENCH_OVERLAY_DRY_RUN=1 \
  ./showcases/http-comparison/scripts/run-kubernetes.sh
python3 showcases/http-comparison/scripts/test_kubernetes_overlay.py
```

Verify a copied timestamped bundle independently of its parent results tree:

```sh
python3 showcases/http-comparison/scripts/kubernetes_overlay.py verify-bundle \
  --result-root build/http-comparison/kubernetes-results/RUN/ARCH/TIMESTAMP
```

Use `HTTP_BENCH_ARM64_CONCURRENCIES` or
`HTTP_BENCH_AMD64_CONCURRENCIES` when one architecture has a lower verified
saturation boundary. `HTTP_BENCH_ARCHES=arm64` or `amd64` runs only one side.

The default pod requests and limits 16 CPUs and 8 GiB, while the runner pins
server and client processes to CPUs `0-7` and `8-15`. Confirm the cluster's CPU
manager and cgroup behavior before relying on that division. The script copies
results and logs below the ignored `build/http-comparison/kubernetes-results/`
directory. A small collector sidecar keeps partial observations available when
a benchmark process fails. The runner waits for every selected architecture,
copies complete or partial artifacts, privacy-scans the sanitized bundle, then
deletes and verifies removal of its temporary namespace on success, failure, or
interruption. `cleanup.json` and `privacy-scan.json` retain sanitized proof of
those checks. Keep raw node inventories separate and private; do not add node
names, addresses, provider identifiers, labels, or unrelated workload details
to a published result bundle.

Treat higher concurrency as a separate saturation probe rather than a common
ranking. Set `HTTP_BENCH_SATURATION_PROBE=1` for those runs. The runner keeps an
invalid raw observation and continues the probe, while `summarize.py` excludes
every group that fails the strict 100% HTTP 200 gate and records the details in
`excluded.csv`. EWS's single
selector can exceed the five-second request deadline there on this harness;
the strict gate prevents timed-out requests from entering a throughput
comparison. Set, for example,
`HTTP_BENCH_CONCURRENCIES=128` when the error boundary itself is the subject of
the run, and test higher levels in separate invocations.

Results are written below `build/http-comparison/`. Each timestamped directory
contains:

- `metadata.json`: host, kernel, architecture, revision, dirty state, source
  overlay archive/content/manifest checksums, tools, pinned server versions,
  requested and observed loop counts, and campaign settings;
- `overlay-manifest.json`: every overlaid or deleted source path and its content
  checksum for Kubernetes runs using the local overlay. It is copied into the
  same timestamped directory before metadata is generated, and metadata binds
  the exact manifest file by SHA-256;
- `runs/*.json`: unmodified oha observations;
- `resources/*.json`: sampled process CPU time, high-water RSS, thread count,
  and context-switch totals;
- `logs/`: server output, kept out of the request path;
- `summary.csv`, `resources.csv`, and `summary.md`: medians across complete
  trials, plus throughput ranges and context-switch totals in CSV.
- `excluded.csv`: saturation observations rejected by the 100% success gate;
- `privacy-scan.json` and `cleanup.json`: sanitized privacy and teardown checks
  for Kubernetes campaigns.

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
hyper plain fixture uses its HTTP/1 connection service without application
routing. The Ada application competitors use one identical ServletAda servlet;
axum and Actix Web each use one exact routed GET. The EWS adapter
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
- the raw JSON and metadata archived with any new published table.

The August 2026 correction journal is a historical exception: only its
aggregates and method record remain, while the raw JSON and complete metadata
were left under ignored `build/` output and are unavailable. Do not treat those
aggregates as independently regenerable. A new final-branch table requires a
complete rerun with a retained and sanitized raw bundle.

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

## Routed native-offload experiment

The hybrid runner tests a separate question from the cross-server comparison:
whether a lightweight routed Flyology application benefits from sending only
selected CPU work to a bounded native executor. All variants use the same
deterministic allocation-free integer workload and exact response bytes:

| Variant | Request lane | CPU operation | Response I/O |
| --- | --- | --- | --- |
| `inline` | lightweight | request task | request task |
| `hybrid` | lightweight | bounded native pool | original request task |
| `fully-native` | native | request task | request task |

The fixture provides `/io-control`, `/cpu-inline`, `/cpu-native` in the hybrid
variant, and `/executor-stats`. Before measuring, the runner calibrates the
operation near 0.5, 2, and 10 ms on the server CPU set and verifies byte-for-byte
identity between inline and offloaded results. It rejects any oha observation
with a failed request or a non-200 response instead of including it in reported
throughput. Executor rejection counts remain in `executor-stats/`.

Run the response contract only:

```sh
HTTP_HYBRID_VERIFY_ONLY=1 \
HTTP_HYBRID_TARGETS_US=500 \
HTTP_HYBRID_WORKERS=1 \
  ./showcases/http-comparison/scripts/run-linux-docker-hybrid.sh
```

Run the final matrix:

```sh
HTTP_BENCH_LOOPS=8 \
HTTP_BENCH_SERVER_CPUSET="0-7" \
HTTP_BENCH_CLIENT_CPUSET="8-15" \
HTTP_HYBRID_CONCURRENCIES="1 8 32 128" \
HTTP_HYBRID_WORKERS="1 2 4 8" \
HTTP_HYBRID_QUEUE_CAPACITY=128 \
HTTP_HYBRID_TARGETS_US="500 2000 10000" \
HTTP_HYBRID_TRIALS=7 \
HTTP_HYBRID_DURATION=30s \
HTTP_HYBRID_WARMUP=5s \
HTTP_HYBRID_COOLDOWN=2 \
HTTP_HYBRID_MIXED=1 \
HTTP_HYBRID_MIXED_CPU_CONCURRENCY=32 \
HTTP_HYBRID_MIXED_CONTROL_CONCURRENCY=8 \
  ./showcases/http-comparison/scripts/run-linux-docker-hybrid.sh
```

Each trial rotates the inline, pool-size, and fully native server order. Mixed
load runs only for the heaviest calibrated cost: one oha process sustains the
CPU route while another measures `/io-control`. Results contain calibration,
metadata, unmodified oha JSON, process resources, executor statistics, CSV, and
Markdown summaries under `build/http-comparison/docker-hybrid-results/`.

The materiality rule is fixed before a final run: at concurrency 32 or higher,
the hypothesis receives support if a zero-error hybrid configuration improves
CPU-route throughput by at least 50%, reduces CPU-route p99 by at least 50%, or
reduces mixed-load control-route p99 by at least 50% relative to inline. Every
worker count remains in the summary, including rejected or slower choices; the
conclusion must also report thread, RSS, CPU-time, and context-switch costs.
