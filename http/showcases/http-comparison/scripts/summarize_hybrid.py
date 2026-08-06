#!/usr/bin/env python3
"""Summarize routed inline, hybrid, fully native, and mixed-load trials."""

from __future__ import annotations

import csv
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit("usage: summarize_hybrid.py RESULT_DIRECTORY")

root = Path(sys.argv[1])


def observation(path: Path) -> dict[str, float]:
    data = json.loads(path.read_text())
    summary = data["summary"]
    latency = data["latencyPercentiles"]
    return {
        "requests_per_second": summary["requestsPerSec"],
        "success_rate": summary["successRate"],
        "p50_ms": latency["p50"] * 1_000,
        "p90_ms": latency["p90"] * 1_000,
        "p99_ms": latency["p99"] * 1_000,
        "p999_ms": latency["p99.9"] * 1_000,
    }


groups: dict[tuple[str, int, int, int, str, int], list[dict[str, float]]] = (
    defaultdict(list)
)
for path in sorted((root / "runs").glob("*.json")):
    fields = path.stem.split("__")
    if len(fields) != 7:
        continue
    _trial, variant, target, workers, queue, workload, concurrency = fields
    groups[
        (
            variant,
            int(target.removeprefix("us")),
            int(workers.removeprefix("w")),
            int(queue.removeprefix("q")),
            workload,
            int(concurrency.removeprefix("c")),
        )
    ].append(observation(path))

columns = [
    "variant", "target_us", "workers", "queue_capacity", "workload",
    "concurrency", "trials", "median_requests_per_second",
    "min_requests_per_second", "max_requests_per_second",
    "median_p50_ms", "median_p90_ms", "median_p99_ms", "median_p999_ms",
    "minimum_success_rate",
]
rows: list[dict[str, str | int | float]] = []
for key, observations in sorted(groups.items()):
    variant, target_us, workers, queue_capacity, workload, concurrency = key
    values = lambda name: [item[name] for item in observations]
    rows.append(
        {
            "variant": variant,
            "target_us": target_us,
            "workers": workers,
            "queue_capacity": queue_capacity,
            "workload": workload,
            "concurrency": concurrency,
            "trials": len(observations),
            "median_requests_per_second": statistics.median(
                values("requests_per_second")
            ),
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

resource_groups: dict[tuple[str, int, int, int], list[dict[str, float | int]]] = (
    defaultdict(list)
)
for path in sorted((root / "resources").glob("*.json")):
    fields = path.stem.split("__")
    if len(fields) != 5:
        continue
    _trial, variant, target, workers, queue = fields
    data = json.loads(path.read_text())
    if data.get("samples", 0):
        resource_groups[
            (
                variant,
                int(target.removeprefix("us")),
                int(workers.removeprefix("w")),
                int(queue.removeprefix("q")),
            )
        ].append(data)

resource_columns = [
    "variant", "target_us", "workers", "queue_capacity", "trials",
    "median_cpu_seconds", "median_max_rss_kib", "maximum_threads",
    "median_voluntary_context_switches", "median_involuntary_context_switches",
]
resource_rows: list[dict[str, str | int | float]] = []
for key, observations in sorted(resource_groups.items()):
    variant, target_us, workers, queue_capacity = key
    values = lambda name: [item[name] for item in observations]
    resource_rows.append(
        {
            "variant": variant,
            "target_us": target_us,
            "workers": workers,
            "queue_capacity": queue_capacity,
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

inline_cpu = {
    (int(row["target_us"]), int(row["concurrency"])): row
    for row in rows
    if row["variant"] == "inline" and row["workload"] == "cpu"
}
comparisons: list[dict[str, str | int | float]] = []
for key, baseline in sorted(inline_cpu.items()):
    target_us, concurrency = key
    candidates = [
        row
        for row in rows
        if row["variant"] == "hybrid"
        and row["workload"] == "cpu"
        and row["target_us"] == target_us
        and row["concurrency"] == concurrency
    ]
    if not candidates:
        continue
    best = max(candidates, key=lambda row: row["median_requests_per_second"])
    throughput_improvement = (
        best["median_requests_per_second"]
        / baseline["median_requests_per_second"]
        - 1
    ) * 100
    p99_reduction = (
        1 - best["median_p99_ms"] / baseline["median_p99_ms"]
    ) * 100
    comparisons.append(
        {
            "target_us": target_us,
            "concurrency": concurrency,
            "best_workers": best["workers"],
            "inline_requests_per_second": baseline[
                "median_requests_per_second"
            ],
            "hybrid_requests_per_second": best["median_requests_per_second"],
            "throughput_improvement_percent": throughput_improvement,
            "inline_p99_ms": baseline["median_p99_ms"],
            "hybrid_p99_ms": best["median_p99_ms"],
            "p99_reduction_percent": p99_reduction,
            "material_at_c32_plus": (
                "yes"
                if concurrency >= 32
                and (throughput_improvement >= 50 or p99_reduction >= 50)
                else "no"
            ),
        }
    )

mixed_inline = next(
    (
        row
        for row in rows
        if row["variant"] == "inline" and row["workload"] == "mixed-control"
    ),
    None,
)
mixed_comparison: dict[str, str | int | float] | None = None
if mixed_inline:
    mixed_candidates = [
        row
        for row in rows
        if row["variant"] == "hybrid"
        and row["workload"] == "mixed-control"
        and row["target_us"] == mixed_inline["target_us"]
    ]
    if mixed_candidates:
        mixed_best = min(mixed_candidates, key=lambda row: row["median_p99_ms"])
        mixed_reduction = (
            1 - mixed_best["median_p99_ms"] / mixed_inline["median_p99_ms"]
        ) * 100
        mixed_comparison = {
            "target_us": mixed_inline["target_us"],
            "control_concurrency": mixed_inline["concurrency"],
            "best_workers": mixed_best["workers"],
            "inline_control_p99_ms": mixed_inline["median_p99_ms"],
            "hybrid_control_p99_ms": mixed_best["median_p99_ms"],
            "control_p99_reduction_percent": mixed_reduction,
            "material": "yes" if mixed_reduction >= 50 else "no",
        }

comparison_columns = [
    "target_us", "concurrency", "best_workers", "inline_requests_per_second",
    "hybrid_requests_per_second", "throughput_improvement_percent",
    "inline_p99_ms", "hybrid_p99_ms", "p99_reduction_percent",
    "material_at_c32_plus",
]
with (root / "comparison.csv").open("w", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=comparison_columns)
    writer.writeheader()
    writer.writerows(comparisons)

stats_rows: list[dict[str, str | int]] = []
for path in sorted((root / "executor-stats").glob("*.json")):
    fields = path.stem.split("__")
    if len(fields) != 5:
        continue
    trial, variant, target, workers, queue = fields
    item = json.loads(path.read_text())
    stats_rows.append(
        {
            "trial": int(trial.removeprefix("trial-")),
            "variant": variant,
            "target_us": int(target.removeprefix("us")),
            "workers": int(workers.removeprefix("w")),
            "queue_capacity": int(queue.removeprefix("q")),
            **item,
        }
    )
if stats_rows:
    with (root / "executor-stats.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(stats_rows[0]))
        writer.writeheader()
        writer.writerows(stats_rows)

stats_groups: dict[tuple[str, int, int, int], list[dict[str, str | int]]] = (
    defaultdict(list)
)
for item in stats_rows:
    stats_groups[
        (
            str(item["variant"]),
            int(item["target_us"]),
            int(item["workers"]),
            int(item["queue_capacity"]),
        )
    ].append(item)

with (root / "summary.md").open("w") as output:
    output.write("# Routed native-offload benchmark summary\n\n")
    output.write(
        "Medians include every complete trial. Raw oha JSON is retained in "
        "`runs/`; success is required to be 100%. See "
        "[`metadata.json`](metadata.json), "
        "[`calibration.json`](calibration.json), [`runs/`](runs/), "
        "[`resources/`](resources/), and "
        "[`executor-stats/`](executor-stats/) for the evidence.\n\n"
    )
    output.write(
        "| Variant | target us | workers | queue | workload | c | trials | "
        "req/s | p50 ms | p90 ms | p99 ms | p99.9 ms |\n"
    )
    output.write(
        "| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | "
        "---: | ---: | ---: |\n"
    )
    for row in rows:
        output.write(
            f"| {row['variant']} | {row['target_us']} | {row['workers']} | "
            f"{row['queue_capacity']} | {row['workload']} | "
            f"{row['concurrency']} | {row['trials']} | "
            f"{row['median_requests_per_second']:.1f} | "
            f"{row['median_p50_ms']:.3f} | {row['median_p90_ms']:.3f} | "
            f"{row['median_p99_ms']:.3f} | {row['median_p999_ms']:.3f} |\n"
        )
    output.write("\n## Process resources\n\n")
    output.write(
        "The context-switch columns below are aggregate process values for "
        "campaigns produced by the current sampler. Campaigns made with the "
        "earlier schema-1 sampler retain process-leader values and should not "
        "use those columns for cross-variant conclusions.\n\n"
    )
    output.write(
        "| Variant | target us | workers | queue | CPU s | RSS MiB | threads | "
        "vol ctx | invol ctx |\n"
    )
    output.write(
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
    )
    for row in resource_rows:
        output.write(
            f"| {row['variant']} | {row['target_us']} | {row['workers']} | "
            f"{row['queue_capacity']} | {row['median_cpu_seconds']:.2f} | "
            f"{row['median_max_rss_kib'] / 1024:.1f} | "
            f"{row['maximum_threads']} | "
            f"{row['median_voluntary_context_switches']:.0f} | "
            f"{row['median_involuntary_context_switches']:.0f} |\n"
        )
    if stats_groups:
        output.write("\n## Executor admission and lifecycle\n\n")
        output.write(
            "Counts are summed across the recorded server instances for a "
            "configuration; peak is the maximum outstanding operation count.\n\n"
        )
        output.write(
            "| Variant | target us | workers | queue | accepted | rejected | "
            "failed | abandoned | peak |\n"
        )
        output.write(
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        )
        for key, observations in sorted(stats_groups.items()):
            variant, target_us, workers, queue_capacity = key
            output.write(
                f"| {variant} | {target_us} | {workers} | {queue_capacity} | "
                f"{sum(int(item['accepted']) for item in observations)} | "
                f"{sum(int(item['rejected']) for item in observations)} | "
                f"{sum(int(item['failed']) for item in observations)} | "
                f"{sum(int(item['abandoned']) for item in observations)} | "
                f"{max(int(item['peak']) for item in observations)} |\n"
            )
    output.write("\n## Derived inline-to-hybrid comparisons\n\n")
    output.write(
        "The selected pool is the highest-throughput hybrid row for each "
        "cost and concurrency; all pool rows remain above. Positive p99 "
        "reduction is better.\n\n"
    )
    output.write(
        "| target us | c | workers | inline req/s | hybrid req/s | "
        "throughput change | inline p99 ms | hybrid p99 ms | p99 reduction | "
        "material at c32+ |\n"
    )
    output.write(
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | "
        "--- |\n"
    )
    for item in comparisons:
        output.write(
            f"| {item['target_us']} | {item['concurrency']} | "
            f"{item['best_workers']} | "
            f"{item['inline_requests_per_second']:.1f} | "
            f"{item['hybrid_requests_per_second']:.1f} | "
            f"{item['throughput_improvement_percent']:+.1f}% | "
            f"{item['inline_p99_ms']:.3f} | {item['hybrid_p99_ms']:.3f} | "
            f"{item['p99_reduction_percent']:+.1f}% | "
            f"{item['material_at_c32_plus']} |\n"
        )
    if mixed_comparison:
        output.write("\n## Mixed-load control-route isolation\n\n")
        output.write(
            f"At the {mixed_comparison['target_us']} us CPU target and control "
            f"concurrency {mixed_comparison['control_concurrency']}, the best "
            f"hybrid pool used {mixed_comparison['best_workers']} workers. "
            f"Control p99 changed from "
            f"{mixed_comparison['inline_control_p99_ms']:.3f} ms inline to "
            f"{mixed_comparison['hybrid_control_p99_ms']:.3f} ms, a "
            f"{mixed_comparison['control_p99_reduction_percent']:.1f}% "
            f"reduction (material: {mixed_comparison['material']}).\n"
        )
    material = any(
        item["material_at_c32_plus"] == "yes" for item in comparisons
    ) or (mixed_comparison is not None and mixed_comparison["material"] == "yes")
    output.write("\n## Threshold verdict\n\n")
    output.write(
        "The predeclared 50% threshold "
        + ("was reached" if material else "was not reached")
        + " in this campaign. Interpret that verdict only for the recorded "
        "host, calibration, duration, and CPU placement.\n"
    )

print(root / "summary.md")
