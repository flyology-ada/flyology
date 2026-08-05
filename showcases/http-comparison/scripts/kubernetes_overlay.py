#!/usr/bin/env python3
"""Build and verify a complete local-source overlay for Kubernetes runs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


KIND = "flyology-http-comparison-source-overlay"
SCHEMA = 1
MAX_ARCHIVE_SIZE = 900_000
MAX_SOURCE_SIZE = 32 * 1_024 * 1_024
ROOT_FILES = ("alire.toml", "flyology.gpr")
SOURCE_PREFIXES = ("src/", "runtime/", "scripts/", "showcases/")
GIT_PATHS = (*ROOT_FILES, "src", "runtime", "scripts", "showcases")
REQUIRED_FILES = {
    "alire.toml",
    "flyology.gpr",
    "scripts/find-alr.sh",
    "scripts/prepare-alire-rts.sh",
    "scripts/prepare-rts.sh",
    "showcases/alire.toml",
    "showcases/showcases.gpr",
    "showcases/prepare-alire.sh",
    "showcases/prepare-rts.sh",
    "showcases/http_plain_benchmark_server.adb",
    "showcases/http_application_benchmark_server.adb",
    "showcases/http_benchmark_runtime_probe.adb",
    "showcases/http_cpu_calibrator.adb",
    "showcases/http_cpu_work.ads",
    "showcases/http_cpu_work.adb",
    "showcases/http_hybrid_benchmark_server.adb",
    "showcases/http-comparison/workloads.conf",
    "showcases/http-comparison/application-workloads.conf",
    "showcases/http-comparison/scripts/build.sh",
    "showcases/http-comparison/scripts/run.sh",
    "showcases/http-comparison/scripts/collect_metadata.py",
}


class OverlayError(RuntimeError):
    """The overlay cannot prove a safe, complete source snapshot."""


def git(root: Path, *args: str) -> bytes:
    try:
        return subprocess.check_output(
            ("git", "-C", str(root), *args), stderr=subprocess.STDOUT
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "output", b"").decode(errors="replace").strip()
        raise OverlayError(f"git {' '.join(args)} failed: {detail}") from error


def split_nul(value: bytes) -> list[str]:
    return [item.decode() for item in value.split(b"\0") if item]


def is_selected(path: str) -> bool:
    return path in ROOT_FILES or path.startswith(SOURCE_PREFIXES)


def safe_relative(path: str) -> PurePosixPath:
    candidate = PurePosixPath(path)
    if (
        not path
        or candidate.is_absolute()
        or ".." in candidate.parts
        or "." in candidate.parts
        or str(candidate) != path
    ):
        raise OverlayError(f"unsafe overlay path: {path!r}")
    return candidate


def discover(root: Path) -> tuple[list[str], list[str]]:
    tracked = set(
        split_nul(git(root, "ls-files", "-z", "--cached", "--", *GIT_PATHS))
    )
    untracked = set(
        split_nul(
            git(
                root,
                "ls-files",
                "-z",
                "--others",
                "--exclude-standard",
                "--",
                *GIT_PATHS,
            )
        )
    )
    selected = {path for path in tracked | untracked if is_selected(path)}
    deleted = sorted(path for path in tracked if not os.path.lexists(root / path))
    present = sorted(selected - set(deleted))
    missing = sorted(REQUIRED_FILES - set(present))
    if missing:
        raise OverlayError("required overlay inputs are missing: " + ", ".join(missing))
    for path in present:
        safe_relative(path)
        mode = (root / path).lstat().st_mode
        if stat.S_ISLNK(mode):
            raise OverlayError(f"overlay input is a symlink: {path}")
        if not stat.S_ISREG(mode):
            raise OverlayError(f"overlay input is not a regular file: {path}")
    for path in deleted:
        safe_relative(path)
    return present, deleted


def current_dirty_paths(root: Path) -> list[str]:
    changed = set(
        split_nul(git(root, "diff", "--name-only", "-z", "HEAD", "--", *GIT_PATHS))
    )
    untracked = set(
        split_nul(
            git(
                root,
                "ls-files",
                "-z",
                "--others",
                "--exclude-standard",
                "--",
                *GIT_PATHS,
            )
        )
    )
    return sorted(path for path in changed | untracked if is_selected(path))


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def read_regular(root: Path, path: str) -> tuple[bytes, int]:
    absolute = root / path
    before = absolute.lstat()
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise OverlayError(f"overlay input changed type while reading: {path}")
    data = absolute.read_bytes()
    after = absolute.lstat()
    if (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise OverlayError(f"overlay input changed while reading: {path}")
    mode = 0o755 if before.st_mode & 0o111 else 0o644
    return data, mode


def content_digest(files: list[dict[str, Any]], deleted: list[str]) -> str:
    encoded = json.dumps(
        {"files": files, "deleted_paths": deleted},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return sha256(encoded)


def create_overlay(root: Path, archive: Path, manifest_path: Path) -> dict[str, Any]:
    root = root.resolve()
    paths, deleted = discover(root)
    payloads: dict[str, bytes] = {}
    files: list[dict[str, Any]] = []
    for path in paths:
        data, mode = read_regular(root, path)
        payloads[path] = data
        files.append(
            {"path": path, "size": len(data), "mode": mode, "sha256": sha256(data)}
        )

    archive.parent.mkdir(parents=True, exist_ok=True)
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as output:
                for item in files:
                    info = tarfile.TarInfo(item["path"])
                    info.size = item["size"]
                    info.mode = item["mode"]
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    output.addfile(info, io.BytesIO(payloads[item["path"]]))

    dirty_paths = current_dirty_paths(root)
    manifest: dict[str, Any] = {
        "schema": SCHEMA,
        "kind": KIND,
        "base_revision": git(root, "rev-parse", "HEAD").decode().strip(),
        "source_dirty": bool(dirty_paths),
        "dirty_paths": dirty_paths,
        "selected_roots": [*ROOT_FILES, *SOURCE_PREFIXES],
        "file_count": len(files),
        "deleted_paths": deleted,
        "content_sha256": content_digest(files, deleted),
        "archive_sha256": sha256(archive.read_bytes()),
        "files": files,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise OverlayError(f"cannot read overlay manifest: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA or value.get("kind") != KIND:
        raise OverlayError("unknown overlay manifest schema")
    files = value.get("files")
    deleted = value.get("deleted_paths")
    if not isinstance(files, list) or not isinstance(deleted, list):
        raise OverlayError("overlay manifest file lists are invalid")
    paths = [item.get("path") for item in files if isinstance(item, dict)]
    if (
        len(paths) != len(files)
        or not all(isinstance(path, str) for path in paths)
        or len(set(paths)) != len(paths)
    ):
        raise OverlayError("overlay manifest contains invalid or duplicate paths")
    if (
        not all(isinstance(path, str) for path in deleted)
        or len(set(deleted)) != len(deleted)
        or set(paths) & set(deleted)
    ):
        raise OverlayError("overlay manifest deletions are duplicate or overlap files")
    for path in [*paths, *deleted]:
        safe_relative(path)
    total_size = 0
    for item in files:
        if (
            not isinstance(item.get("size"), int)
            or item["size"] < 0
            or item.get("mode") not in (0o644, 0o755)
            or not is_sha256(item.get("sha256"))
        ):
            raise OverlayError(f"overlay manifest file metadata is invalid: {item.get('path')}")
        total_size += item["size"]
    if total_size > MAX_SOURCE_SIZE:
        raise OverlayError("overlay manifest exceeds the source-size limit")
    dirty_paths = value.get("dirty_paths")
    if (
        not isinstance(dirty_paths, list)
        or not all(isinstance(path, str) for path in dirty_paths)
        or len(set(dirty_paths)) != len(dirty_paths)
        or value.get("source_dirty") is not bool(dirty_paths)
    ):
        raise OverlayError("overlay manifest dirty state is invalid")
    for path in dirty_paths:
        safe_relative(path)
    if not is_sha256(value.get("archive_sha256")):
        raise OverlayError("overlay archive checksum is invalid")
    revision = value.get("base_revision")
    if (
        not isinstance(revision, str)
        or len(revision) not in (40, 64)
        or not all(character in "0123456789abcdef" for character in revision)
    ):
        raise OverlayError("overlay base revision is invalid")
    missing = sorted(REQUIRED_FILES - set(paths))
    if missing:
        raise OverlayError("overlay manifest omits required inputs: " + ", ".join(missing))
    if value.get("file_count") != len(files):
        raise OverlayError("overlay manifest file count does not match")
    if value.get("content_sha256") != content_digest(files, deleted):
        raise OverlayError("overlay content manifest checksum does not match")
    return value


def archive_payloads(archive: Path, manifest: dict[str, Any]) -> dict[str, bytes]:
    if archive.stat().st_size > MAX_ARCHIVE_SIZE:
        raise OverlayError("overlay archive exceeds the size limit")
    if sha256(archive.read_bytes()) != manifest.get("archive_sha256"):
        raise OverlayError("overlay archive checksum does not match")
    expected = {item["path"]: item for item in manifest["files"]}
    payloads: dict[str, bytes] = {}
    try:
        with tarfile.open(archive, mode="r:gz") as source:
            for member in source:
                safe_relative(member.name)
                if not member.isreg():
                    raise OverlayError(f"overlay archive member is not regular: {member.name}")
                if member.name in payloads:
                    raise OverlayError(f"duplicate overlay archive member: {member.name}")
                if member.name not in expected:
                    raise OverlayError(f"unexpected overlay archive member: {member.name}")
                if member.size != expected[member.name]["size"]:
                    raise OverlayError(f"overlay archive size differs for {member.name}")
                stream = source.extractfile(member)
                if stream is None:
                    raise OverlayError(f"cannot read overlay archive member: {member.name}")
                payloads[member.name] = stream.read()
    except (OSError, tarfile.TarError) as error:
        raise OverlayError(f"cannot read overlay archive: {error}") from error
    if set(payloads) != set(expected):
        omitted = sorted(set(expected) - set(payloads))
        extra = sorted(set(payloads) - set(expected))
        raise OverlayError(f"overlay archive membership differs: omitted={omitted}, extra={extra}")
    for path, data in payloads.items():
        item = expected[path]
        if len(data) != item.get("size") or sha256(data) != item.get("sha256"):
            raise OverlayError(f"overlay archive content differs for {path}")
    return payloads


def safe_destination(root: Path, relative: str) -> Path:
    safe_relative(relative)
    target = root.joinpath(*PurePosixPath(relative).parts)
    current = root
    for part in PurePosixPath(relative).parts[:-1]:
        current /= part
        if current.is_symlink():
            raise OverlayError(f"overlay destination parent is a symlink: {relative}")
    if target.is_symlink():
        raise OverlayError(f"overlay destination is a symlink: {relative}")
    return target


def extract_overlay(root: Path, payloads: dict[str, bytes], manifest: dict[str, Any]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for relative in manifest["deleted_paths"]:
        target = safe_destination(root, relative)
        if target.exists():
            if not target.is_file():
                raise OverlayError(f"deleted overlay path is not a file: {relative}")
            target.unlink()
    modes = {item["path"]: item["mode"] for item in manifest["files"]}
    for relative, data in payloads.items():
        target = safe_destination(root, relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".overlay-", dir=target.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(data)
            os.chmod(temporary, modes[relative])
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def verify_source(root: Path, manifest: dict[str, Any]) -> None:
    root = root.resolve()
    for item in manifest["files"]:
        path = item["path"]
        absolute = root / path
        if not absolute.exists() or absolute.is_symlink() or not absolute.is_file():
            raise OverlayError(f"source overlay file is missing or unsafe: {path}")
        data = absolute.read_bytes()
        mode = 0o755 if absolute.stat().st_mode & 0o111 else 0o644
        if len(data) != item["size"] or sha256(data) != item["sha256"] or mode != item["mode"]:
            raise OverlayError(f"source tree differs from overlay for {path}")
    for path in manifest["deleted_paths"]:
        if (root / path).exists():
            raise OverlayError(f"source deletion is absent from overlay: {path}")

    try:
        inside_git = git(root, "rev-parse", "--is-inside-work-tree").decode().strip() == "true"
    except OverlayError:
        inside_git = False
    if inside_git:
        present, deleted = discover(root)
        expected = [item["path"] for item in manifest["files"]]
        if present != expected or deleted != manifest["deleted_paths"]:
            raise OverlayError("source file set differs from overlay manifest")
        revision = git(root, "rev-parse", "HEAD").decode().strip()
        dirty = current_dirty_paths(root)
        if revision != manifest["base_revision"]:
            raise OverlayError("source revision differs from overlay manifest")
        if dirty != manifest["dirty_paths"] or bool(dirty) != manifest["source_dirty"]:
            raise OverlayError("source dirty state differs from overlay manifest")


def verify_overlay(
    archive: Path,
    manifest_path: Path,
    source_root: Path | None = None,
    extract_root: Path | None = None,
) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    payloads = archive_payloads(archive, manifest)
    if extract_root is not None:
        extract_overlay(extract_root, payloads, manifest)
    if source_root is not None:
        verify_source(source_root, manifest)
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--project-root", type=Path, required=True)
    create.add_argument("--archive", type=Path, required=True)
    create.add_argument("--manifest", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--archive", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--source-root", type=Path)
    verify.add_argument("--extract", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.command == "create":
            manifest = create_overlay(args.project_root, args.archive, args.manifest)
            print(
                f"created overlay with {manifest['file_count']} files "
                f"({manifest['archive_sha256']})"
            )
        else:
            manifest = verify_overlay(
                args.archive, args.manifest, args.source_root, args.extract
            )
            print(
                f"verified overlay with {manifest['file_count']} files "
                f"({manifest['archive_sha256']})"
            )
    except OverlayError as error:
        raise SystemExit(f"kubernetes overlay: {error}") from error


if __name__ == "__main__":
    main()
