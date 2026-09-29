#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Estimate API-style token cost for Codex and Claude work in a workspace.

Place this script anywhere inside one repository. By default it finds that Git
repository and audits its parent directory, so the repository and all sister
repositories are included. Pass an explicit workspace path to override this.

The log scan is read-only. It discovers Codex sessions by working directory and
Git origin, so Codex worktrees are included, and discovers Claude Code logs,
including nested subagent/workflow JSONL files.

Usage examples:

    ./audit_ai_cost.py
    ./audit_ai_cost.py /path/to/workspace
    ./audit_ai_cost.py --group-by day
    ./audit_ai_cost.py --group-by week --since 2026-08-01
    ./audit_ai_cost.py --format json > usage.json
    ./audit_ai_cost.py --rebuild
    ./audit_ai_cost.py --no-claude

By default the script stores incremental cursors and daily calculations in
``WORKSPACE/.ai-usage-audit.json``. Subsequent runs read only new/appended JSONL
records. Use ``--no-state`` for a one-off full scan or ``--rebuild`` to replace
the stored calculation from logs that are still available.

Prices are current standard API list prices as of 2026-08-16. They are kept in
plain data structures below so that future price changes are easy to review.
This estimates a counterfactual API bill, not a ChatGPT/Codex/Claude subscription
charge. Server-side tool fees, taxes, negotiated discounts, and credits are not
included.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Iterable, TextIO
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


PRICING_DATE = "2026-08-16"
STATE_VERSION = 2
OPENAI_PRICING_URL = "https://developers.openai.com/api/docs/models/compare"
ANTHROPIC_PRICING_URL = "https://platform.claude.com/docs/en/about-claude/pricing"


@dataclasses.dataclass(frozen=True)
class Price:
    """USD per million tokens."""

    input: float
    cache_read: float
    output: float
    cache_write_5m: float | None = None
    cache_write_1h: float | None = None
    long_context_premium: bool = False

    @property
    def cache_write_default(self) -> float:
        return self.cache_write_5m if self.cache_write_5m is not None else self.input


# Current standard OpenAI API prices. OpenAI cache writes are 1.25x input.
OPENAI_PRICES: dict[str, Price] = {
    "gpt-5.6-sol": Price(5.00, 0.50, 30.00, 6.25, 6.25),
    "gpt-5.6-terra": Price(2.00, 0.20, 12.00, 2.50, 2.50),
    "gpt-5.6-luna": Price(0.20, 0.02, 1.20, 0.25, 0.25),
}


# Current first-party Claude API prices. Claude cache writes cost 1.25x (5m)
# or 2x (1h), and cache reads cost 0.1x. Older models marked below use the
# published >200K premium (2x input/cache and 4x output).
ANTHROPIC_PRICES: tuple[tuple[re.Pattern[str], str, Price], ...] = (
    (re.compile(r"claude-(?:fable|mythos)-5(?:$|-)", re.I), "Claude Fable/Mythos 5", Price(10, 1, 50, 12.5, 20)),
    (re.compile(r"claude-opus-(?:5|4[-.]8|4[-.]7|4[-.]6|4[-.]5)(?:$|-)", re.I), "Claude Opus 4.5-5", Price(5, 0.5, 25, 6.25, 10)),
    (re.compile(r"claude-(?:opus-4[-.]1|3-opus|opus-4)(?:$|-)", re.I), "Claude Opus 3-4.1", Price(15, 1.5, 75, 18.75, 30)),
    (re.compile(r"claude-sonnet-5(?:$|-)", re.I), "Claude Sonnet 5", Price(2, 0.2, 10, 2.5, 4)),
    (re.compile(r"claude-(?:sonnet-4[-.]6|sonnet-4[-.]5|sonnet-4|3[-.]7-sonnet|3[-.]5-sonnet)(?:$|-)", re.I), "Claude Sonnet 3.5-4.6", Price(3, 0.3, 15, 3.75, 6, True)),
    (re.compile(r"claude-haiku-4[-.]5(?:$|-)", re.I), "Claude Haiku 4.5", Price(1, 0.1, 5, 1.25, 2)),
    (re.compile(r"claude-3[-.]5-haiku(?:$|-)", re.I), "Claude Haiku 3.5", Price(0.8, 0.08, 4, 1, 1.6, True)),
    (re.compile(r"claude-3-haiku(?:$|-)", re.I), "Claude Haiku 3", Price(0.25, 0.025, 1.25, 0.3125, 0.5)),
)


CODEX_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


class Progress:
    """Render calculation progress without contaminating report output."""

    def __init__(self, enabled: bool, stream: TextIO = sys.stderr) -> None:
        self.enabled = enabled
        self.stream = stream
        self.interactive = enabled and stream.isatty()
        self.label = ""
        self.total: int | None = None
        self.unit = "items"
        self.started_at = 0.0
        self.last_rendered_at = 0.0
        self.rendered_width = 0

    def start(self, label: str, total: int | None = None, unit: str = "items") -> None:
        self.label = label
        self.total = total
        self.unit = unit
        self.started_at = time.monotonic()
        self.last_rendered_at = 0.0
        self.rendered_width = 0
        if self.interactive:
            self.update(0, force=True)
        elif self.enabled:
            print(f"{label}...", file=self.stream, flush=True)

    def update(self, completed: int, *, force: bool = False) -> None:
        if not self.interactive:
            return
        now = time.monotonic()
        complete = self.total is not None and completed >= self.total
        if not force and not complete and now - self.last_rendered_at < 0.1:
            return
        self.last_rendered_at = now
        count = f"{completed:,} {self.unit}"
        if self.total is not None:
            percent = 100 if self.total == 0 else min(100, completed * 100 // self.total)
            count = f"{completed:,}/{self.total:,} {self.unit} ({percent:3d}%)"
        self._render(f"{self.label}... {count}")

    def done(self, detail: str | None = None) -> None:
        if not self.enabled or not self.label:
            return
        elapsed = time.monotonic() - self.started_at
        suffix = f": {detail}" if detail else ""
        message = f"{self.label} done in {elapsed:.1f}s{suffix}"
        if self.interactive:
            self._render(message, newline=True)
        else:
            print(message, file=self.stream, flush=True)
        self.label = ""

    def _render(self, message: str, *, newline: bool = False) -> None:
        padded = message.ljust(self.rendered_width)
        self.stream.write("\r" + padded + ("\n" if newline else ""))
        self.stream.flush()
        self.rendered_width = 0 if newline else len(message)


@dataclasses.dataclass
class Usage:
    base_input: int = 0
    cache_read: int = 0
    cache_write_5m: int = 0
    cache_write_1h: int = 0
    cache_write_unspecified: int = 0
    output: int = 0
    reasoning_output: int = 0
    total_only: int = 0

    def add(self, other: "Usage") -> None:
        for field in dataclasses.fields(self):
            name = field.name
            setattr(self, name, getattr(self, name) + getattr(other, name))

    @property
    def cache_write(self) -> int:
        return self.cache_write_5m + self.cache_write_1h + self.cache_write_unspecified

    @property
    def input_total(self) -> int:
        return self.base_input + self.cache_read + self.cache_write

    @property
    def categorized_total(self) -> int:
        return self.input_total + self.output

    def as_dict(self) -> dict[str, int]:
        return {
            "input_tokens": self.input_total,
            "base_or_uncached_input_tokens": self.base_input,
            "cache_read_input_tokens": self.cache_read,
            "cache_write_input_tokens": self.cache_write,
            "cache_write_5m_input_tokens": self.cache_write_5m,
            "cache_write_1h_input_tokens": self.cache_write_1h,
            "cache_write_unspecified_input_tokens": self.cache_write_unspecified,
            "output_tokens": self.output,
            "reasoning_output_tokens": self.reasoning_output,
            "categorized_total_tokens": self.categorized_total,
            "unclassified_total_only_tokens": self.total_only,
        }

    def state_dict(self) -> dict[str, int]:
        return {field.name: getattr(self, field.name) for field in dataclasses.fields(self)}

    @classmethod
    def from_state(cls, value: dict[str, Any]) -> "Usage":
        return cls(
            **{
                field.name: int(value.get(field.name, 0) or 0)
                for field in dataclasses.fields(cls)
            }
        )


@dataclasses.dataclass
class ModelResult:
    provider: str
    logged_model: str
    priced_model: str | None
    usage: Usage = dataclasses.field(default_factory=Usage)
    cost_usd: float = 0.0
    requests: int = 0
    sessions: set[str] = dataclasses.field(default_factory=set)
    files: set[str] = dataclasses.field(default_factory=set)
    long_context_requests: int = 0
    unpriced_requests: int = 0

    @property
    def label(self) -> str:
        route = self.logged_model
        if self.priced_model and self.priced_model != self.logged_model:
            route += f" -> {self.priced_model}"
        return f"{self.provider} / {route}"

    def as_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "logged_model": self.logged_model,
            "priced_model": self.priced_model,
            "sessions": len(self.sessions),
            "log_files": len(self.files),
            "requests": self.requests,
            **self.usage.as_dict(),
            "long_context_requests": self.long_context_requests,
            "unpriced_requests": self.unpriced_requests,
            "estimated_cost_usd": round(self.cost_usd, 8),
        }

    def state_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "logged_model": self.logged_model,
            "priced_model": self.priced_model,
            "usage": self.usage.state_dict(),
            "cost_usd": self.cost_usd,
            "requests": self.requests,
            "sessions": sorted(self.sessions),
            "files": sorted(self.files),
            "long_context_requests": self.long_context_requests,
            "unpriced_requests": self.unpriced_requests,
        }

    @classmethod
    def from_state(cls, value: dict[str, Any]) -> "ModelResult":
        return cls(
            provider=str(value["provider"]),
            logged_model=str(value["logged_model"]),
            priced_model=value.get("priced_model"),
            usage=Usage.from_state(value.get("usage") or {}),
            cost_usd=float(value.get("cost_usd", 0) or 0),
            requests=int(value.get("requests", 0) or 0),
            sessions=set(value.get("sessions") or []),
            files=set(value.get("files") or []),
            long_context_requests=int(value.get("long_context_requests", 0) or 0),
            unpriced_requests=int(value.get("unpriced_requests", 0) or 0),
        )


@dataclasses.dataclass
class Audit:
    workspace_root: Path
    timezone: ZoneInfo
    daily: dict[str, dict[tuple[str, str], ModelResult]] = dataclasses.field(
        default_factory=lambda: collections.defaultdict(dict)
    )
    warnings: list[str] = dataclasses.field(default_factory=list)
    integrity: collections.Counter[str] = dataclasses.field(default_factory=collections.Counter)
    scope: dict[str, Any] = dataclasses.field(default_factory=dict)

    def result(
        self, day: str, provider: str, logged_model: str, priced_model: str | None
    ) -> ModelResult:
        key = (provider, logged_model)
        if key not in self.daily[day]:
            self.daily[day][key] = ModelResult(provider, logged_model, priced_model)
        elif self.daily[day][key].priced_model != priced_model:
            self.warnings.append(
                f"{provider} route {logged_model!r} mapped to conflicting price models"
            )
        return self.daily[day][key]

    def record(
        self,
        *,
        day: str,
        provider: str,
        logged_model: str,
        priced_model: str | None,
        usage: Usage,
        cost: float | None,
        session: str,
        path: Path,
        long_context: bool,
    ) -> None:
        result = self.result(day, provider, logged_model, priced_model)
        result.usage.add(usage)
        result.requests += 1
        result.sessions.add(session)
        result.files.add(str(path))
        if long_context:
            result.long_context_requests += 1
        if cost is None:
            result.unpriced_requests += 1
        else:
            result.cost_usd += cost


class StateResetNeeded(RuntimeError):
    """Raised when an incremental cursor is unsafe and a full rescan is needed."""


def containing_git_repository(path: Path) -> Path | None:
    """Return the nearest ancestor that contains a .git directory or file."""
    start = path.resolve(strict=False)
    for candidate in (start, *start.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def default_workspace_root(script: Path) -> Path:
    """Use the parent of the repository containing this script."""
    script_directory = script.resolve(strict=False).parent
    repository = containing_git_repository(script_directory)
    return repository.parent if repository else script_directory.parent


def local_timezone_name() -> str:
    """Best-effort portable IANA timezone discovery, falling back to UTC."""
    configured = os.environ.get("TZ")
    if configured:
        return configured.removeprefix(":")

    for localtime in (Path("/etc/localtime"), Path("/var/db/timezone/localtime")):
        try:
            resolved = localtime.resolve(strict=True)
        except OSError:
            continue
        parts = resolved.parts
        if "zoneinfo" in parts:
            index = parts.index("zoneinfo") + 1
            if index < len(parts):
                return "/".join(parts[index:])

    try:
        configured = Path("/etc/timezone").read_text(encoding="utf-8").strip()
        if configured:
            return configured
    except OSError:
        pass
    return "UTC"


def empty_state(root: Path, timezone: str, auto_review_model: str) -> dict[str, Any]:
    return {
        "version": STATE_VERSION,
        "workspace_root": str(root),
        "pricing_as_of": PRICING_DATE,
        "timezone": timezone,
        "codex_auto_review_model": auto_review_model,
        "files": {},
        "claude_seen_messages": {},
        "daily": {},
        "integrity": {},
    }


def load_state(
    path: Path,
    root: Path,
    timezone: str,
    auto_review_model: str,
    rebuild: bool,
) -> tuple[dict[str, Any], str | None]:
    fresh = empty_state(root, timezone, auto_review_model)
    if rebuild or not path.is_file():
        return fresh, None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return fresh, f"Ignoring unreadable state file {path}: {exc}"
    expected = {
        "version": STATE_VERSION,
        "workspace_root": str(root),
        "pricing_as_of": PRICING_DATE,
        "timezone": timezone,
        "codex_auto_review_model": auto_review_model,
    }
    mismatches = [key for key, wanted in expected.items() if value.get(key) != wanted]
    if mismatches:
        return fresh, "Rebuilding stored audit because these settings changed: " + ", ".join(mismatches)
    value.setdefault("files", {})
    value.setdefault("claude_seen_messages", {})
    value.setdefault("daily", {})
    value.setdefault("integrity", {})
    return value, None


def hydrate_audit(audit: Audit, state: dict[str, Any]) -> None:
    audit.integrity.update(
        {str(key): int(value) for key, value in (state.get("integrity") or {}).items()}
    )
    for day, records in (state.get("daily") or {}).items():
        for value in records:
            result = ModelResult.from_state(value)
            audit.daily[str(day)][(result.provider, result.logged_model)] = result


def persist_audit(path: Path, state: dict[str, Any], audit: Audit) -> None:
    state["daily"] = {
        day: [
            result.state_dict()
            for result in sorted(records.values(), key=lambda item: (item.provider, item.logged_model))
        ]
        for day, records in sorted(audit.daily.items())
    }
    state["integrity"] = dict(audit.integrity)
    state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    try:
        temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def iter_jsonl_delta(
    path: Path, file_state: dict[str, Any]
) -> Iterable[tuple[dict[str, Any] | None, int]]:
    stat = path.stat()
    offset = int(file_state.get("offset", 0) or 0)
    old_inode = file_state.get("inode")
    old_device = file_state.get("device")
    if offset and (
        stat.st_size < offset
        or (old_inode is not None and int(old_inode) != stat.st_ino)
        or (old_device is not None and int(old_device) != stat.st_dev)
    ):
        raise StateResetNeeded(f"log was replaced or truncated: {path}")

    last_complete = offset
    with path.open("rb") as handle:
        handle.seek(offset)
        while True:
            raw = handle.readline()
            if not raw:
                break
            if not raw.endswith(b"\n"):
                break
            last_complete = handle.tell()
            try:
                event = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                yield None, last_complete
                continue
            yield event, last_complete

    file_state.update(
        {
            "offset": last_complete,
            "inode": stat.st_ino,
            "device": stat.st_dev,
            "size_at_last_scan": stat.st_size,
            "mtime_ns_at_last_scan": stat.st_mtime_ns,
        }
    )


def parse_timestamp(value: Any) -> dt.datetime | None:
    if isinstance(value, (int, float)):
        try:
            return dt.datetime.fromtimestamp(value, tz=dt.timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str) or not value:
        return None
    candidate = value.replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def event_day(event: dict[str, Any], timezone: ZoneInfo, path: Path, audit: Audit) -> str:
    timestamp = parse_timestamp(event.get("timestamp"))
    if timestamp is None:
        audit.integrity["records_using_file_mtime_for_date"] += 1
        timestamp = dt.datetime.fromtimestamp(path.stat().st_mtime, tz=dt.timezone.utc)
    return timestamp.astimezone(timezone).date().isoformat()


def descendant(path: str | Path | None, root: Path) -> bool:
    if not path:
        return False
    try:
        candidate = Path(path).expanduser().resolve(strict=False)
        return candidate == root or root in candidate.parents
    except (OSError, RuntimeError):
        return False


def normalize_git_origin(origin: str | None) -> str | None:
    """Normalize common GitHub SSH/HTTPS forms for equality checks."""
    if not origin:
        return None
    value = origin.strip().rstrip("/")
    value = re.sub(r"^git@([^:]+):", r"\1/", value)
    value = re.sub(r"^(?:ssh|https?)://(?:git@)?", "", value)
    value = value.removesuffix(".git").lower()
    return value or None


def read_git_config_origins(config: Path) -> set[str]:
    origins: set[str] = set()
    try:
        section_is_origin = False
        for raw in config.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if line.startswith("["):
                section_is_origin = line.lower() == '[remote "origin"]'
            elif section_is_origin and line.lower().startswith("url") and "=" in line:
                normalized = normalize_git_origin(line.split("=", 1)[1])
                if normalized:
                    origins.add(normalized)
    except OSError:
        pass
    return origins


def discover_project_origins(root: Path, progress: Progress) -> set[str]:
    origins: set[str] = set()
    dotgits: list[Path] = []
    directories_seen = 0
    progress.start("Discovering workspace repositories", unit="directories")
    # Stop at each repository boundary. Descending into its checkout could find
    # vendored/dependency repositories whose origins are not project identities.
    for directory, dirnames, filenames in os.walk(root):
        directories_seen += 1
        progress.update(directories_seen)
        if ".git" in dirnames:
            dotgits.append(Path(directory) / ".git")
            dirnames[:] = []
            continue
        if ".git" in filenames:
            dotgits.append(Path(directory) / ".git")
            dirnames[:] = []
            continue
        dirnames[:] = [name for name in dirnames if name not in {".alire", "build", "obj"}]

    for dotgit in dotgits:
        if dotgit.is_dir():
            origins.update(read_git_config_origins(dotgit / "config"))
        elif dotgit.is_file():
            try:
                line = dotgit.read_text(encoding="utf-8", errors="replace").strip()
                if line.startswith("gitdir:"):
                    gitdir = Path(line.split(":", 1)[1].strip())
                    if not gitdir.is_absolute():
                        gitdir = dotgit.parent / gitdir
                    origins.update(read_git_config_origins(gitdir / "config"))
                    # A linked worktree's remote definitions live in the common dir.
                    common = gitdir / "commondir"
                    if common.is_file():
                        common_dir = Path(common.read_text().strip())
                        if not common_dir.is_absolute():
                            common_dir = gitdir / common_dir
                        origins.update(read_git_config_origins(common_dir / "config"))
            except OSError:
                pass
    progress.done(f"{len(dotgits):,} repositories")
    return origins


def latest_codex_state_db(codex_home: Path) -> Path:
    candidates = list(codex_home.glob("state_*.sqlite"))
    if not candidates:
        return codex_home / "state_5.sqlite"

    def key(path: Path) -> tuple[int, float]:
        match = re.search(r"state_(\d+)\.sqlite$", path.name)
        return (int(match.group(1)) if match else -1, path.stat().st_mtime)

    return max(candidates, key=key)


def normalized_codex_usage(value: dict[str, Any] | None) -> dict[str, int]:
    value = value or {}
    return {field: int(value.get(field, 0) or 0) for field in CODEX_FIELDS}


def openai_price_model(logged_model: str, auto_review_model: str) -> str | None:
    if logged_model == "codex-auto-review":
        return auto_review_model
    if logged_model in OPENAI_PRICES:
        return logged_model
    # Snapshot IDs keep the price of their base model.
    for model in OPENAI_PRICES:
        if logged_model.startswith(model + "-"):
            return model
    return None


def price_openai_usage(usage: Usage, model: str | None, long_context: bool) -> float | None:
    if not model or model not in OPENAI_PRICES:
        return None
    price = OPENAI_PRICES[model]
    input_multiplier = 2 if long_context else 1
    output_multiplier = 1.5 if long_context else 1
    return (
        usage.base_input * price.input * input_multiplier
        + usage.cache_read * price.cache_read * input_multiplier
        + usage.cache_write * price.cache_write_default * input_multiplier
        + usage.output * price.output * output_multiplier
    ) / 1_000_000


def audit_codex(
    audit: Audit,
    state: dict[str, Any],
    state_db: Path,
    origins: set[str],
    auto_review_model: str,
    progress: Progress,
) -> None:
    if not state_db.is_file():
        audit.warnings.append(f"Codex state database not found: {state_db}")
        return

    progress.start("Loading Codex sessions")
    try:
        conn = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT id, rollout_path, cwd, model, archived, git_origin_url
            FROM threads ORDER BY created_at, id
            """
        ).fetchall()
    except sqlite3.Error as exc:
        progress.done("failed")
        audit.warnings.append(f"Could not read Codex state database {state_db}: {exc}")
        return

    scoped = [
        row
        for row in rows
        if descendant(row["cwd"], audit.workspace_root)
        or normalize_git_origin(row["git_origin_url"]) in origins
    ]
    audit.scope["codex_state_db"] = str(state_db)
    audit.scope["codex_threads"] = len(scoped)
    audit.scope["codex_archived_threads"] = sum(int(row["archived"] or 0) for row in scoped)
    new_token_events = 0
    progress.done(f"{len(scoped):,} matching threads")
    progress.start("Scanning Codex logs", len(scoped), "threads")

    for index, row in enumerate(scoped, 1):
        progress.update(index - 1)
        rollout = Path(row["rollout_path"] or "")
        if not rollout.is_file():
            audit.integrity["codex_missing_rollout_files"] += 1
            progress.update(index)
            continue

        state_key = f"codex:{rollout}"
        file_state = state["files"].setdefault(state_key, {"provider": "Codex"})
        first_scan = int(file_state.get("offset", 0) or 0) == 0
        current_model = str(file_state.get("current_model") or row["model"] or "(unknown)")
        seen_turn_context = bool(file_state.get("seen_turn_context", False))
        previous_total = file_state.get("previous_total")
        session_had_usage = False

        try:
            iterator = iter_jsonl_delta(rollout, file_state)
            for event, end_offset in iterator:
                file_state["offset"] = end_offset
                if event is None:
                    audit.integrity["codex_malformed_json_lines"] += 1
                    continue

                if event.get("type") == "turn_context":
                    payload = event.get("payload") or {}
                    current_model = payload.get("model") or current_model
                    seen_turn_context = True
                    continue

                payload = event.get("payload") or {}
                if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                    continue
                info = payload.get("info") or {}
                total = normalized_codex_usage(info.get("total_token_usage"))
                last = normalized_codex_usage(info.get("last_token_usage"))

                # Forked rollouts inherit visible ancestor history before their own
                # first turn_context. Those calls belong to the ancestor session.
                if not seen_turn_context:
                    audit.integrity["codex_inherited_token_events_excluded"] += 1
                    continue
                # The same cumulative update can be emitted multiple times.
                if total == previous_total:
                    audit.integrity["codex_duplicate_token_events_excluded"] += 1
                    continue
                if previous_total and any(total[f] < previous_total[f] for f in CODEX_FIELDS):
                    audit.integrity["codex_cumulative_counter_decreases"] += 1
                previous_total = total

                categorized = last["input_tokens"] + last["output_tokens"]
                total_only = max(0, last["total_tokens"] - categorized)
                cache_read = min(last["cached_input_tokens"], last["input_tokens"])
                cache_write = min(
                    last["cache_write_input_tokens"],
                    max(0, last["input_tokens"] - cache_read),
                )
                uncached = max(0, last["input_tokens"] - cache_read - cache_write)
                usage = Usage(
                    base_input=uncached,
                    cache_read=cache_read,
                    cache_write_unspecified=cache_write,
                    output=last["output_tokens"],
                    reasoning_output=min(
                        last["reasoning_output_tokens"], last["output_tokens"]
                    ),
                    total_only=total_only,
                )
                priced_model = openai_price_model(current_model, auto_review_model)
                long_context = last["input_tokens"] > 272_000
                cost = price_openai_usage(usage, priced_model, long_context)
                audit.record(
                    day=event_day(event, audit.timezone, rollout, audit),
                    provider="Codex",
                    logged_model=current_model,
                    priced_model=priced_model,
                    usage=usage,
                    cost=cost,
                    session=str(row["id"]),
                    path=rollout,
                    long_context=long_context,
                )
                session_had_usage = True
                new_token_events += 1
        except OSError:
            audit.integrity["codex_unreadable_rollout_files"] += 1
            progress.update(index)
            continue

        file_state["current_model"] = current_model
        file_state["seen_turn_context"] = seen_turn_context
        file_state["previous_total"] = previous_total
        if first_scan and not seen_turn_context:
            audit.integrity["codex_sessions_without_turn_context"] += 1
        if first_scan and not session_had_usage:
            audit.integrity["codex_sessions_without_usage"] += 1
        progress.update(index)
    audit.scope["codex_new_token_events"] = new_token_events
    progress.done(f"{new_token_events:,} new token events")


def anthropic_price(model: str) -> tuple[str, Price] | None:
    for pattern, price_name, price in ANTHROPIC_PRICES:
        if pattern.search(model):
            return price_name, price
    return None


def claude_usage(event: dict[str, Any]) -> Usage:
    raw = (event.get("message") or {}).get("usage") or {}
    creation = raw.get("cache_creation") or {}
    creation_total = int(raw.get("cache_creation_input_tokens", 0) or 0)
    write_5m = int(creation.get("ephemeral_5m_input_tokens", 0) or 0)
    write_1h = int(creation.get("ephemeral_1h_input_tokens", 0) or 0)
    unspecified = max(0, creation_total - write_5m - write_1h)
    return Usage(
        base_input=int(raw.get("input_tokens", 0) or 0),
        cache_read=int(raw.get("cache_read_input_tokens", 0) or 0),
        cache_write_5m=write_5m,
        cache_write_1h=write_1h,
        cache_write_unspecified=unspecified,
        output=int(raw.get("output_tokens", 0) or 0),
    )


def claude_usage_fingerprint(event: dict[str, Any]) -> tuple[Any, ...]:
    usage = claude_usage(event)
    raw = (event.get("message") or {}).get("usage") or {}
    return (
        *dataclasses.astuple(usage),
        raw.get("service_tier"),
        raw.get("speed"),
        raw.get("inference_geo"),
    )


def price_claude_usage(event: dict[str, Any], usage: Usage) -> tuple[str | None, float | None, bool]:
    message = event.get("message") or {}
    model = str(message.get("model") or "(unknown)")
    match = anthropic_price(model)
    if match is None:
        return None, None, False
    price_name, base_price = match
    raw = message.get("usage") or {}
    speed = str(raw.get("speed") or "standard")
    service_tier = str(raw.get("service_tier") or "standard")
    inference_geo = str(raw.get("inference_geo") or "global")

    price = base_price
    if speed == "fast" and re.search(r"claude-(?:opus-5|opus-4[-.]8)(?:$|-)", model, re.I):
        price = Price(10, 1, 50, 12.5, 20, base_price.long_context_premium)

    long_context = price.long_context_premium and usage.input_total > 200_000
    input_multiplier = 2 if long_context else 1
    output_multiplier = 4 if long_context else 1
    tier_multiplier = 0.5 if service_tier == "batch" else 1
    geo_multiplier = 1.1 if inference_geo == "us" else 1

    cost = (
        usage.base_input * price.input * input_multiplier
        + usage.cache_read * price.cache_read * input_multiplier
        + usage.cache_write_5m * (price.cache_write_5m or price.input) * input_multiplier
        + usage.cache_write_1h * (price.cache_write_1h or price.input) * input_multiplier
        + usage.cache_write_unspecified * price.cache_write_default * input_multiplier
        + usage.output * price.output * output_multiplier
    ) / 1_000_000
    return price_name, cost * tier_multiplier * geo_multiplier, long_context


def claude_candidate_dirs(projects_dir: Path, root: Path) -> list[Path]:
    encoded = str(root).replace(os.sep, "-")
    try:
        return [path for path in projects_dir.iterdir() if path.is_dir() and path.name.startswith(encoded)]
    except OSError:
        return []


def audit_claude(
    audit: Audit, state: dict[str, Any], projects_dir: Path, progress: Progress
) -> None:
    if not projects_dir.is_dir():
        audit.warnings.append(f"Claude projects directory not found: {projects_dir}")
        return

    candidates: list[Path] = []
    progress.start("Discovering Claude logs", unit="files")
    for directory in claude_candidate_dirs(projects_dir, audit.workspace_root):
        for path in directory.rglob("*.jsonl"):
            candidates.append(path)
            progress.update(len(candidates))
    progress.done(f"{len(candidates):,} files")

    audit.scope["claude_projects_dir"] = str(projects_dir)
    audit.scope["claude_log_files"] = len(candidates)

    # Claude Code writes the same completed API message once for each content
    # block/branch representation. Message IDs are globally unique. Keep the
    # most complete usage record for each ID, including across subagent logs.
    messages: dict[tuple[str, str], tuple[dict[str, Any], Path]] = {}
    message_sessions: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    seen_messages: dict[str, Any] = state["claude_seen_messages"]

    progress.start("Scanning Claude logs", len(candidates), "files")
    for index, path in enumerate(candidates, 1):
        progress.update(index - 1)
        state_key = f"claude:{path}"
        file_state = state["files"].setdefault(state_key, {"provider": "Claude"})
        try:
            for event, end_offset in iter_jsonl_delta(path, file_state):
                file_state["offset"] = end_offset
                if event is None:
                    audit.integrity["claude_malformed_json_lines"] += 1
                    continue
                if event.get("type") != "assistant":
                    continue
                message = event.get("message") or {}
                usage_raw = message.get("usage")
                if not isinstance(usage_raw, dict):
                    continue
                model = str(message.get("model") or "(unknown)")
                if model == "<synthetic>" and claude_usage(event).categorized_total == 0:
                    audit.integrity["claude_zero_token_synthetic_records_excluded"] += 1
                    continue
                message_id = str(message.get("id") or event.get("uuid") or "")
                if not message_id:
                    audit.integrity["claude_usage_records_without_id"] += 1
                    continue
                key = (model, message_id)
                state_message_key = json.dumps(key, separators=(",", ":"))
                fingerprint = list(claude_usage_fingerprint(event))
                session = str(event.get("sessionId") or event.get("agentId") or path.parent.name)

                stored = seen_messages.get(state_message_key)
                if stored is not None:
                    if stored.get("fingerprint") == fingerprint:
                        audit.integrity["claude_duplicate_message_records_excluded"] += 1
                        continue
                    raise StateResetNeeded(
                        f"Claude message usage changed after it was stored: {message_id}"
                    )

                message_sessions[key].add(session)
                previous = messages.get(key)
                if previous is None:
                    messages[key] = (event, path)
                    continue
                previous_event, _ = previous
                if claude_usage_fingerprint(previous_event) == claude_usage_fingerprint(event):
                    audit.integrity["claude_duplicate_message_records_excluded"] += 1
                    continue

                audit.integrity["claude_conflicting_duplicate_message_records"] += 1
                # Streaming/interrupted records can grow. Retain the larger complete
                # usage record rather than billing both versions.
                if claude_usage(event).categorized_total > claude_usage(previous_event).categorized_total:
                    messages[key] = (event, path)
        except OSError:
            audit.integrity["claude_unreadable_log_files"] += 1
            progress.update(index)
            continue
        progress.update(index)

    for (model, _message_id), (event, path) in messages.items():
        usage = claude_usage(event)
        price_name, cost, long_context = price_claude_usage(event, usage)
        sessions = message_sessions[(model, _message_id)]
        session = sorted(sessions)[0] if sessions else path.parent.name
        audit.record(
            day=event_day(event, audit.timezone, path, audit),
            provider="Claude",
            logged_model=model,
            priced_model=price_name,
            usage=usage,
            cost=cost,
            session=session,
            path=path,
            long_context=long_context,
        )
        state_message_key = json.dumps((model, _message_id), separators=(",", ":"))
        seen_messages[state_message_key] = {
            "fingerprint": list(claude_usage_fingerprint(event)),
            "source_file": str(path),
        }

        raw = (event.get("message") or {}).get("usage") or {}
        tool_use = raw.get("server_tool_use") or {}
        audit.integrity["claude_web_search_requests_unpriced"] += int(
            tool_use.get("web_search_requests", 0) or 0
        )
        audit.integrity["claude_web_fetch_requests_unpriced"] += int(
            tool_use.get("web_fetch_requests", 0) or 0
        )
        if usage.cache_write_unspecified:
            audit.integrity["claude_requests_with_unspecified_cache_write_ttl"] += 1
        if raw.get("service_tier") not in (None, "standard", "batch"):
            audit.integrity["claude_requests_with_unhandled_service_tier"] += 1

    audit.scope["claude_new_unique_api_messages"] = len(messages)
    audit.scope["claude_stored_unique_api_messages"] = len(seen_messages)
    progress.done(f"{len(messages):,} new API messages")


def combined_usage(models: Iterable[ModelResult]) -> Usage:
    total = Usage()
    for model in models:
        total.add(model.usage)
    return total


def merge_model_results(results: Iterable[ModelResult]) -> list[ModelResult]:
    merged: dict[tuple[str, str], ModelResult] = {}
    for item in results:
        key = (item.provider, item.logged_model)
        if key not in merged:
            merged[key] = ModelResult(item.provider, item.logged_model, item.priced_model)
        target = merged[key]
        target.usage.add(item.usage)
        target.cost_usd += item.cost_usd
        target.requests += item.requests
        target.sessions.update(item.sessions)
        target.files.update(item.files)
        target.long_context_requests += item.long_context_requests
        target.unpriced_requests += item.unpriced_requests
    return sorted(merged.values(), key=lambda item: (item.provider, item.logged_model))


def period_rows(periods: dict[str, list[ModelResult]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for period, values in sorted(periods.items()):
        for item in merge_model_results(values):
            rows.append({"period": period, **item.as_dict()})
    return rows


def report_dict(
    audit: Audit,
    since: dt.date | None = None,
    until: dt.date | None = None,
    providers: set[str] | None = None,
) -> dict[str, Any]:
    selected_daily = {
        day: {
            key: result
            for key, result in records.items()
            if providers is None or result.provider in providers
        }
        for day, records in audit.daily.items()
        if (since is None or dt.date.fromisoformat(day) >= since)
        and (until is None or dt.date.fromisoformat(day) <= until)
    }
    selected_daily = {day: records for day, records in selected_daily.items() if records}
    all_daily_results = [
        result for records in selected_daily.values() for result in records.values()
    ]
    models = merge_model_results(all_daily_results)
    daily_periods = {
        day: list(records.values()) for day, records in selected_daily.items()
    }
    weekly_periods: dict[str, list[ModelResult]] = collections.defaultdict(list)
    for day, records in selected_daily.items():
        date = dt.date.fromisoformat(day)
        iso = date.isocalendar()
        weekly_periods[f"{iso.year}-W{iso.week:02d}"].extend(records.values())
    by_provider: dict[str, dict[str, Any]] = {}
    for provider in sorted({item.provider for item in models}):
        group = [item for item in models if item.provider == provider]
        usage = combined_usage(group)
        by_provider[provider] = {
            **usage.as_dict(),
            "estimated_cost_usd": round(sum(item.cost_usd for item in group), 8),
            "requests": sum(item.requests for item in group),
            "sessions": len({session for item in group for session in item.sessions}),
        }
    all_usage = combined_usage(models)
    return {
        "snapshot": dt.datetime.now(dt.timezone.utc).isoformat(),
        "pricing_as_of": PRICING_DATE,
        "pricing_sources": {
            "openai": OPENAI_PRICING_URL,
            "anthropic": ANTHROPIC_PRICING_URL,
        },
        "scope": {"workspace_root": str(audit.workspace_root), **audit.scope},
        "by_model": [item.as_dict() for item in models],
        "by_day": period_rows(daily_periods),
        "by_week": period_rows(weekly_periods),
        "by_provider": by_provider,
        "combined": {
            **all_usage.as_dict(),
            "estimated_cost_usd": round(sum(item.cost_usd for item in models), 8),
            "requests": sum(item.requests for item in models),
        },
        "integrity": dict(sorted(audit.integrity.items())),
        "warnings": audit.warnings,
        "date_filter": {
            "since": since.isoformat() if since else None,
            "until": until.isoformat() if until else None,
            "timezone": str(audit.timezone),
        },
        "notes": [
            "Cached/read input and cache writes are subsets/categories of input; reasoning is a subset of output.",
            "Claude message IDs and Codex cumulative counters are deduplicated before aggregation.",
            "The estimate uses current standard API list prices, not historical or subscription pricing.",
            "Server-side tool fees, taxes, discounts, and credits are excluded.",
        ],
    }


def fmt_int(value: int) -> str:
    return f"{value:,}"


def table(headers: list[str], rows: list[list[str]], right: set[int]) -> str:
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def render(row: list[str]) -> str:
        return "  ".join(
            value.rjust(widths[index]) if index in right else value.ljust(widths[index])
            for index, value in enumerate(row)
        ).rstrip()

    separator = ["-" * width for width in widths]
    return "\n".join([render(headers), render(separator), *(render(row) for row in rows)])


def print_text(report: dict[str, Any], group_by: str) -> None:
    print(f"AI usage audit for {report['scope']['workspace_root']}")
    print(f"Snapshot: {report['snapshot']} | pricing as of {report['pricing_as_of']}")
    print()

    headers = ["Route", "Sessions", "Requests", "Base input", "Cache read", "Cache write", "Output", "Cost USD"]
    rows: list[list[str]] = []
    for item in report["by_model"]:
        route = f"{item['provider']} / {item['logged_model']}"
        if item["priced_model"] and item["priced_model"] != item["logged_model"]:
            route += f" -> {item['priced_model']}"
        rows.append(
            [
                route,
                fmt_int(item["sessions"]),
                fmt_int(item["requests"]),
                fmt_int(item["base_or_uncached_input_tokens"]),
                fmt_int(item["cache_read_input_tokens"]),
                fmt_int(item["cache_write_input_tokens"]),
                fmt_int(item["output_tokens"]),
                f"${item['estimated_cost_usd']:,.2f}" if not item["unpriced_requests"] else f"${item['estimated_cost_usd']:,.2f}+",
            ]
        )
    print(table(headers, rows, set(range(1, len(headers)))))
    print()

    for provider, item in report["by_provider"].items():
        print(
            f"{provider}: ${item['estimated_cost_usd']:,.2f} across "
            f"{item['requests']:,} requests and {item['sessions']:,} sessions"
        )
    print(f"Combined estimated token cost: ${report['combined']['estimated_cost_usd']:,.2f}")

    if group_by in ("day", "week"):
        source = report["by_day" if group_by == "day" else "by_week"]
        print(f"\nSpend by {group_by} and model:")
        period_headers = [
            "Period",
            "Route",
            "Requests",
            "Base input",
            "Cache read",
            "Cache write",
            "Output",
            "Cost USD",
        ]
        period_data: list[list[str]] = []
        for item in source:
            route = f"{item['provider']} / {item['logged_model']}"
            if item["priced_model"] and item["priced_model"] != item["logged_model"]:
                route += f" -> {item['priced_model']}"
            period_data.append(
                [
                    item["period"],
                    route,
                    fmt_int(item["requests"]),
                    fmt_int(item["base_or_uncached_input_tokens"]),
                    fmt_int(item["cache_read_input_tokens"]),
                    fmt_int(item["cache_write_input_tokens"]),
                    fmt_int(item["output_tokens"]),
                    f"${item['estimated_cost_usd']:,.2f}"
                    + ("+" if item["unpriced_requests"] else ""),
                ]
            )
        print(table(period_headers, period_data, set(range(2, len(period_headers)))))

    total_only = report["combined"]["unclassified_total_only_tokens"]
    if total_only:
        print(f"Unclassified total-only tokens excluded from price: {total_only:,}")

    nonzero_integrity = {key: value for key, value in report["integrity"].items() if value}
    if nonzero_integrity:
        print("\nIntegrity / exclusions:")
        for key, value in nonzero_integrity.items():
            print(f"  {key}: {value:,}")
    if report["warnings"]:
        print("\nWarnings:")
        for warning in report["warnings"]:
            print(f"  - {warning}")

    print("\nPricing sources:")
    print(f"  OpenAI: {report['pricing_sources']['openai']}")
    print(f"  Anthropic: {report['pricing_sources']['anthropic']}")
    print("\nThis is a current-list-price API estimate; tool fees, taxes, discounts, credits, and subscription pricing are excluded.")


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_root = default_workspace_root(Path(__file__))
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "workspace_root",
        nargs="?",
        type=Path,
        default=default_root,
        help=(
            "workspace containing sibling repositories "
            "(default: parent of the Git repository containing this script)"
        ),
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument(
        "--group-by",
        choices=("summary", "day", "week"),
        default="summary",
        help="text report detail; JSON always includes daily and weekly breakdowns",
    )
    parser.add_argument("--since", type=dt.date.fromisoformat, help="report on/after YYYY-MM-DD")
    parser.add_argument("--until", type=dt.date.fromisoformat, help="report on/before YYYY-MM-DD")
    parser.add_argument(
        "--timezone",
        default=local_timezone_name(),
        help="IANA timezone used for daily/weekly buckets",
    )
    parser.add_argument("--codex-home", type=Path, default=Path.home() / ".codex")
    parser.add_argument("--codex-state-db", type=Path)
    parser.add_argument("--claude-projects", type=Path, default=Path.home() / ".claude" / "projects")
    parser.add_argument(
        "--codex-auto-review-model",
        default="gpt-5.6-luna",
        help="public model used to price the codex-auto-review route",
    )
    parser.add_argument("--no-codex", action="store_true", help="skip Codex logs")
    parser.add_argument("--no-claude", action="store_true", help="skip Claude Code logs")
    parser.add_argument(
        "--state",
        type=Path,
        help="incremental state JSON (default: WORKSPACE/.ai-usage-audit.json)",
    )
    parser.add_argument(
        "--no-state",
        action="store_true",
        help="perform a full read-only scan and do not load or write state",
    )
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="discard stored calculations and rebuild them from available logs",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit nonzero when logs are malformed, missing, or unpriced",
    )
    parser.add_argument(
        "--no-progress",
        action="store_true",
        help="suppress calculation progress written to stderr",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = args.workspace_root.expanduser().resolve(strict=False)
    if not root.is_dir():
        print(f"error: workspace root is not a directory: {root}", file=sys.stderr)
        return 2
    if args.since and args.until and args.since > args.until:
        print("error: --since must not be later than --until", file=sys.stderr)
        return 2
    try:
        timezone = ZoneInfo(args.timezone)
    except ZoneInfoNotFoundError:
        print(f"error: unknown IANA timezone: {args.timezone}", file=sys.stderr)
        return 2

    progress = Progress(not args.no_progress)
    state_path = (args.state or root / ".ai-usage-audit.json").expanduser()
    state, state_notice = load_state(
        state_path,
        root,
        args.timezone,
        args.codex_auto_review_model,
        args.rebuild or args.no_state,
    )
    origins = discover_project_origins(root, progress)

    reset_notice: str | None = None
    for attempt in range(2):
        audit = Audit(root, timezone)
        hydrate_audit(audit, state)
        if state_notice:
            audit.warnings.append(state_notice)
        if reset_notice:
            audit.warnings.append(reset_notice)
        audit.scope["normalized_git_origins"] = sorted(origins)
        audit.scope["incremental_state"] = None if args.no_state else str(state_path)
        audit.scope["state_mode"] = "disabled" if args.no_state else (
            "rebuilt" if args.rebuild or reset_notice else "incremental"
        )
        try:
            if not args.no_codex:
                state_db = args.codex_state_db or latest_codex_state_db(args.codex_home.expanduser())
                audit_codex(
                    audit,
                    state,
                    state_db.expanduser(),
                    origins,
                    args.codex_auto_review_model,
                    progress,
                )
            if not args.no_claude:
                audit_claude(audit, state, args.claude_projects.expanduser(), progress)
            break
        except StateResetNeeded as exc:
            progress.done("restarting from available logs")
            if attempt:
                print(f"error: incremental rebuild failed: {exc}", file=sys.stderr)
                return 2
            reset_notice = f"Incremental state was rebuilt because {exc}"
            state = empty_state(root, args.timezone, args.codex_auto_review_model)
    else:  # pragma: no cover - loop always breaks or returns
        return 2

    if not args.no_state:
        try:
            persist_audit(state_path, state, audit)
        except OSError as exc:
            audit.warnings.append(f"Could not write incremental state {state_path}: {exc}")

    providers = set()
    if not args.no_codex:
        providers.add("Codex")
    if not args.no_claude:
        providers.add("Claude")
    report = report_dict(audit, args.since, args.until, providers)
    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_text(report, args.group_by)

    if args.strict:
        unpriced = sum(
            item.unpriced_requests
            for records in audit.daily.values()
            for item in records.values()
            if item.provider in providers
        )
        bad_integrity = sum(
            value
            for key, value in audit.integrity.items()
            if "missing" in key or "malformed" in key or "unreadable" in key
        )
        if unpriced or bad_integrity or audit.warnings:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
