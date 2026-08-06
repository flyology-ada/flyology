#!/usr/bin/env python3
"""Fail a campaign immediately when a measured oha run is not all HTTP 200."""

from __future__ import annotations

import json
import sys
from pathlib import Path


result = json.loads(Path(sys.argv[1]).read_text())
summary = result["summary"]
statuses = result["statusCodeDistribution"]
errors = result["errorDistribution"]
if summary["successRate"] != 1.0 or set(statuses) != {"200"} or errors:
    raise SystemExit(
        f"invalid measured run: success={summary['successRate']} "
        f"statuses={statuses} errors={errors}"
    )
