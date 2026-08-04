#!/usr/bin/env python3
"""Emit stable host and benchmark metadata as JSON."""

from __future__ import annotations

import json
import os
import platform
import subprocess
import sys
from pathlib import Path


def command(*args: str) -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"


root = Path(__file__).resolve().parents[3]
git_status = command("git", "-C", str(root), "status", "--porcelain")
git_revision = os.environ.get(
    "HTTP_BENCH_GIT_REVISION",
    command("git", "-C", str(root), "rev-parse", "HEAD"),
)
git_dirty_env = os.environ.get("HTTP_BENCH_GIT_DIRTY")
loops_env = os.environ.get("HTTP_BENCH_LOOPS")
metadata = {
    "schema": 1,
    "mode": os.environ.get("HTTP_BENCH_MODE", "local"),
    "platform": platform.platform(),
    "machine": platform.machine(),
    "processor": platform.processor() or "unavailable",
    "logical_cpus": os.cpu_count(),
    "kernel": (
        command("uname", "-srmv")
        if os.environ.get("HTTP_BENCH_REDACT_HOST", "0") == "1"
        else command("uname", "-a")
    ),
    "hostname_redacted": os.environ.get("HTTP_BENCH_REDACT_HOST", "0") == "1",
    "git_revision": git_revision,
    "git_dirty": (
        git_dirty_env == "1" if git_dirty_env is not None
        else git_status not in ("", "unavailable")
    ),
    "oha_version": command("oha", "--version"),
    "alire_version": command("alr", "--version").splitlines()[0],
    "gnat_version": os.environ.get("HTTP_BENCH_GNAT_VERSION", "15.3.1"),
    "gprbuild_version": os.environ.get("HTTP_BENCH_GPRBUILD_VERSION", "25.0.1"),
    "duration": os.environ.get("HTTP_BENCH_DURATION", "10s"),
    "warmup_duration": os.environ.get("HTTP_BENCH_WARMUP", "2s"),
    "concurrencies": os.environ.get("HTTP_BENCH_CONCURRENCIES", "1 8 32 128").split(),
    "trials": int(os.environ.get("HTTP_BENCH_TRIALS", "3")),
    "capacity": int(os.environ.get("HTTP_BENCH_CAPACITY", "256")),
    "flyology_loops": int(loops_env or str(os.cpu_count() or 1)),
    "client_cpuset": os.environ.get("HTTP_BENCH_CLIENT_CPUSET", "unrestricted"),
    "server_cpuset": os.environ.get("HTTP_BENCH_SERVER_CPUSET", "unrestricted"),
    "tiers": os.environ.get("HTTP_BENCH_TIERS", "plain application").split(),
    "hybrid": {
        "workers": os.environ.get("HTTP_HYBRID_WORKERS", "").split(),
        "queue_capacity": os.environ.get("HTTP_HYBRID_QUEUE_CAPACITY"),
        "target_cost_us": os.environ.get("HTTP_HYBRID_TARGETS_US", "").split(),
        "cooldown_seconds": os.environ.get("HTTP_HYBRID_COOLDOWN"),
        "mixed_load": os.environ.get("HTTP_HYBRID_MIXED"),
        "mixed_start_offset_seconds": 0.2,
        "mixed_cpu_concurrency": os.environ.get(
            "HTTP_HYBRID_MIXED_CPU_CONCURRENCY"
        ),
        "mixed_control_concurrency": os.environ.get(
            "HTTP_HYBRID_MIXED_CONTROL_CONCURRENCY"
        ),
    },
    "server_versions": {
        "aws_plain": "25.2.0",
        "ews_plain": "1.11.0",
        "servletada": "1.8.2",
        "servletada_aws_backend": "25.0.0",
        "servletada_ews_backend": "1.11.0",
    },
    "build": {
        "flyology": "release (-O3)",
        "adapters": "Alire release/performance",
        "transport": "HTTP/1.1 cleartext",
    },
}
json.dump(metadata, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
