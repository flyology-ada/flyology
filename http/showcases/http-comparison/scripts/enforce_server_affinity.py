#!/usr/bin/env python3
"""Apply and verify one Linux CPU set across every server thread."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def parse_cpuset(value: str) -> set[int]:
    result: set[int] = set()
    for item in value.split(","):
        bounds = item.split("-", 1)
        try:
            first = int(bounds[0])
            last = int(bounds[-1])
        except ValueError as exc:
            raise ValueError(f"invalid CPU set: {value}") from exc
        if first < 0 or last < first:
            raise ValueError(f"invalid CPU set: {value}")
        result.update(range(first, last + 1))
    if not result:
        raise ValueError("CPU set must not be empty")
    return result


def task_cpuset(status_path: Path) -> set[int]:
    for line in status_path.read_text().splitlines():
        if line.startswith("Cpus_allowed_list:"):
            return parse_cpuset(line.split(":", 1)[1].strip())
    raise RuntimeError(f"missing Cpus_allowed_list in {status_path}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: enforce_server_affinity.py PID CPUSET")

    pid = int(sys.argv[1])
    requested_text = sys.argv[2]
    requested = parse_cpuset(requested_text)
    process_root = Path(f"/proc/{pid}")
    if not process_root.exists():
        raise SystemExit(f"server process {pid} does not exist")

    subprocess.run(
        ["taskset", "-a", "-p", "-c", requested_text, str(pid)],
        check=True,
        stdout=subprocess.DEVNULL,
    )

    checked = 0
    mismatches: list[str] = []
    for status_path in sorted((process_root / "task").glob("*/status")):
        try:
            actual = task_cpuset(status_path)
        except FileNotFoundError:
            continue
        checked += 1
        if actual != requested:
            mismatches.append(
                f"tid {status_path.parent.name}: "
                f"expected {requested_text}, observed "
                f"{','.join(str(cpu) for cpu in sorted(actual))}"
            )

    if checked == 0:
        raise SystemExit(f"server process {pid} has no observable threads")
    if mismatches:
        raise SystemExit("server CPU affinity mismatch:\n" + "\n".join(mismatches))
    print(f"verified {checked} server threads on CPUs {requested_text}")


if __name__ == "__main__":
    main()
