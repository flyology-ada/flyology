#!/usr/bin/env python3
"""Summarize repeated oha JSON trials without discarding the raw observations."""

from __future__ import annotations

import csv
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit("usage: summarize.py RESULT_DIRECTORY")

root = Path(sys.argv[1])
groups: dict[tuple[str, str, int, str], list[dict[str, float]]] = defaultdict(list)
for path in sorted((root / "runs").glob("*.json")):
    fields = path.stem.split("__")
    if len(fields) != 5:
        continue
    _trial, server, workload, concurrency, connection_mode = fields
    data = json.loads(path.read_text())
    summary = data["summary"]
    latency = data["latencyPercentiles"]
    groups[(server, workload, int(concurrency[1:]), connection_mode)].append(
        {
            "requests_per_second": summary["requestsPerSec"],
            "success_rate": summary["successRate"],
            "p50_ms": latency["p50"] * 1_000,
            "p90_ms": latency["p90"] * 1_000,
            "p99_ms": latency["p99"] * 1_000,
            "p999_ms": latency["p99.9"] * 1_000,
        }
    )

columns = [
    "server", "workload", "concurrency", "connection_mode", "trials",
    "median_requests_per_second", "min_requests_per_second", "max_requests_per_second",
    "median_p50_ms", "median_p90_ms", "median_p99_ms", "median_p999_ms",
    "minimum_success_rate",
]
rows: list[dict[str, str | int | float]] = []
for key, observations in sorted(groups.items()):
    server, workload, concurrency, connection_mode = key
    values = lambda name: [item[name] for item in observations]
    rows.append(
        {
            "server": server,
            "workload": workload,
            "concurrency": concurrency,
            "connection_mode": connection_mode,
            "trials": len(observations),
            "median_requests_per_second": statistics.median(values("requests_per_second")),
            "min_requests_per_second": min(values("requests_per_second")),
            "max_requests_per_second": max(values("requests_per_second")),
            "median_p50_ms": statistics.median(values("p50_ms")),
            "median_p90_ms": statistics.median(values("p90_ms")),
            "median_p99_ms": statistics.median(values("p99_ms")),
            "median_p999_ms": statistics.median(values("p999_ms")),
            "minimum_success_rate": min(values("success_rate")),
        }
    )

with (root / "summary.csv").open("w", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=columns)
    writer.writeheader()
    writer.writerows(rows)

resource_groups: dict[str, list[dict[str, float | int]]] = defaultdict(list)
for path in sorted((root / "resources").glob("trial-*.json")):
    _, _, server = path.stem.split("-", 2)
    data = json.loads(path.read_text())
    if data.get("samples", 0):
        resource_groups[server].append(data)

resource_columns = [
    "server", "trials", "median_cpu_seconds", "median_max_rss_kib",
    "maximum_threads", "median_voluntary_context_switches",
    "median_involuntary_context_switches",
]
resource_rows: list[dict[str, str | int | float]] = []
for server, observations in sorted(resource_groups.items()):
    values = lambda name: [item[name] for item in observations]
    resource_rows.append(
        {
            "server": server,
            "trials": len(observations),
            "median_cpu_seconds": statistics.median(values("cpu_seconds")),
            "median_max_rss_kib": statistics.median(values("max_rss_kib")),
            "maximum_threads": max(values("max_threads")),
            "median_voluntary_context_switches": statistics.median(
                values("voluntary_context_switches")
            ),
            "median_involuntary_context_switches": statistics.median(
                values("involuntary_context_switches")
            ),
        }
    )

with (root / "resources.csv").open("w", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=resource_columns)
    writer.writeheader()
    writer.writerows(resource_rows)

with (root / "summary.md").open("w") as output:
    output.write("# HTTP comparison summary\n\n")
    output.write("Medians are across complete trials; raw oha JSON remains in `runs/`.\n\n")
    output.write("| Server | Workload | c | Connections | Trials | req/s | p50 ms | p99 ms | p99.9 ms |\n")
    output.write("| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |\n")
    for row in rows:
        output.write(
            f"| {row['server']} | {row['workload']} | {row['concurrency']} | "
            f"{row['connection_mode']} | {row['trials']} | "
            f"{row['median_requests_per_second']:.1f} | "
            f"{row['median_p50_ms']:.3f} | {row['median_p99_ms']:.3f} | "
            f"{row['median_p999_ms']:.3f} |\n"
        )
    output.write("\n## Process resources\n\n")
    output.write(
        "Samples cover all warmups and workloads for that server in a trial. "
        "Compare servers only within the same tier.\n\n"
    )
    output.write("| Server | Trials | CPU s | Max RSS MiB | Max threads |\n")
    output.write("| --- | ---: | ---: | ---: | ---: |\n")
    for row in resource_rows:
        output.write(
            f"| {row['server']} | {row['trials']} | "
            f"{row['median_cpu_seconds']:.2f} | "
            f"{row['median_max_rss_kib'] / 1024:.1f} | "
            f"{row['maximum_threads']} |\n"
        )

print(root / "summary.md")
