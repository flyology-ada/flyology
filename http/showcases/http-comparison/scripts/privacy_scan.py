#!/usr/bin/env python3
"""Reject private infrastructure identifiers in a sanitized result bundle."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit("usage: privacy_scan.py RESULT_DIRECTORY")

root = Path(sys.argv[1])
tokens = {
    token.strip()
    for token in os.environ.get("HTTP_BENCH_PRIVATE_TOKENS", "").splitlines()
    if len(token.strip()) >= 4
}
patterns = {
    "provider identifier": re.compile(r"\bprovider(?:ID|_id)\b", re.IGNORECASE),
    "Kubernetes node field": re.compile(r'\b(?:nodeName|node_name)\b'),
    "cloud instance URI": re.compile(
        r"\b(?:aws|azure|gce|digitalocean|openstack)://", re.IGNORECASE
    ),
}
scanned = 0
findings: list[dict[str, str]] = []
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.name == "privacy-scan.json":
        continue
    try:
        content = path.read_text()
    except UnicodeDecodeError:
        continue
    scanned += 1
    relative = str(path.relative_to(root))
    for token in tokens:
        if token in content:
            findings.append({"file": relative, "kind": "private input token"})
            break
    for kind, pattern in patterns.items():
        if pattern.search(content):
            findings.append({"file": relative, "kind": kind})

result = {
    "schema": 1,
    "files_scanned": scanned,
    "private_tokens_checked": len(tokens),
    "findings": findings,
    "passed": not findings,
}
(root / "privacy-scan.json").write_text(
    json.dumps(result, indent=2, sort_keys=True) + "\n"
)
if findings:
    raise SystemExit("privacy scan rejected the sanitized result bundle")
print(f"privacy scan passed ({scanned} text files)")
