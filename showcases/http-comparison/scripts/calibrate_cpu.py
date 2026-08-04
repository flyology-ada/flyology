#!/usr/bin/env python3
"""Calibrate the shared CPU fixture to requested per-call durations."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("binary", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--targets-us", nargs="+", type=int, required=True)
parser.add_argument("--cpuset")
args = parser.parse_args()

pattern = re.compile(r"seconds=([0-9.Ee+-]+).*checksum=([0-9]+)")


def measure(iterations: int, repetitions: int = 5) -> tuple[float, int]:
    command = [str(args.binary), str(iterations), str(repetitions)]
    if args.cpuset:
        command = ["taskset", "-c", args.cpuset, *command]
    output = subprocess.check_output(command, text=True)
    match = pattern.search(output)
    if not match:
        raise SystemExit(f"unexpected calibrator output: {output!r}")
    return float(match.group(1)), int(match.group(2))


calibration: list[dict[str, int | float]] = []
previous_iterations = 10_000
for target_us in args.targets_us:
    target_seconds = target_us / 1_000_000
    iterations = previous_iterations
    for _ in range(10):
        seconds, _checksum = measure(iterations)
        if seconds <= 0:
            iterations *= 10
            continue
        ratio = target_seconds / seconds
        if 0.97 <= ratio <= 1.03:
            break
        ratio = max(0.2, min(5.0, ratio))
        iterations = max(1, round(iterations * ratio))
    seconds, checksum = measure(iterations, repetitions=9)
    calibration.append(
        {
            "target_us": target_us,
            "iterations": iterations,
            "observed_us": seconds * 1_000_000,
            "checksum": checksum,
        }
    )
    previous_iterations = iterations

args.output.write_text(
    json.dumps({"schema": 1, "calibration": calibration}, indent=2) + "\n"
)
