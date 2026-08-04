#!/usr/bin/env python3
"""Sample one server process without adding benchmark-library dependencies."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


if len(sys.argv) != 3:
    raise SystemExit("usage: sample_process.py PID OUTPUT.json")

pid = int(sys.argv[1])
output = Path(sys.argv[2])
samples: list[dict[str, float | int]] = []
stopping = False


def stop(_signum: int, _frame: object) -> None:
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def linux_sample() -> dict[str, float | int]:
    stat = Path(f"/proc/{pid}/stat").read_text().split()
    status: dict[str, str] = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            status[key] = value.strip()
    ticks = os.sysconf("SC_CLK_TCK")

    def kib(name: str) -> int:
        value = status.get(name, "0 kB").split()[0]
        return int(value)

    voluntary = 0
    involuntary = 0
    for task_status_path in Path(f"/proc/{pid}/task").glob("*/status"):
        task_status: dict[str, str] = {}
        try:
            task_lines = task_status_path.read_text().splitlines()
        except FileNotFoundError:
            continue
        for line in task_lines:
            if ":" in line:
                key, value = line.split(":", 1)
                task_status[key] = value.strip()
        voluntary += int(task_status.get("voluntary_ctxt_switches", "0"))
        involuntary += int(task_status.get("nonvoluntary_ctxt_switches", "0"))

    return {
        "elapsed_seconds": time.monotonic() - started,
        "cpu_seconds": (int(stat[13]) + int(stat[14])) / ticks,
        "rss_kib": kib("VmRSS"),
        "high_water_rss_kib": kib("VmHWM"),
        "threads": int(status.get("Threads", "0")),
        "voluntary_context_switches": voluntary,
        "involuntary_context_switches": involuntary,
    }


def portable_sample() -> dict[str, float | int]:
    row = subprocess.check_output(
        ["ps", "-o", "time=", "-o", "rss=", "-p", str(pid)], text=True
    ).split()
    parts = [float(value) for value in row[0].split(":")]
    cpu_seconds = sum(value * (60 ** index) for index, value in enumerate(reversed(parts)))
    return {
        "elapsed_seconds": time.monotonic() - started,
        "cpu_seconds": cpu_seconds,
        "rss_kib": int(row[1]),
        "high_water_rss_kib": int(row[1]),
        "threads": 0,
        "voluntary_context_switches": 0,
        "involuntary_context_switches": 0,
    }


started = time.monotonic()
while not stopping:
    try:
        samples.append(linux_sample() if sys.platform.startswith("linux") else portable_sample())
    except (FileNotFoundError, ProcessLookupError, subprocess.CalledProcessError):
        break
    time.sleep(0.1)

if samples:
    last = samples[-1]
    result = {
        "schema": 2,
        "pid": pid,
        "samples": len(samples),
        "elapsed_seconds": last["elapsed_seconds"],
        "cpu_seconds": last["cpu_seconds"],
        "max_rss_kib": max(sample["high_water_rss_kib"] for sample in samples),
        "max_threads": max(sample["threads"] for sample in samples),
        "voluntary_context_switches": last["voluntary_context_switches"],
        "involuntary_context_switches": last["involuntary_context_switches"],
    }
else:
    result = {"schema": 2, "pid": pid, "samples": 0}
output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
