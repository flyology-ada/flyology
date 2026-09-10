#!/usr/bin/env python3

"""Classify the official TLC release without trusting its asset digest."""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_REPOSITORY = "tlaplus/tlaplus"
DEFAULT_TAG = "v1.8.0"
DEFAULT_ASSET = "tla2tools.jar"
DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


class ReleasePolicyError(Exception):
    """The official release metadata cannot be classified safely."""


def require_boolean(metadata: dict[str, Any], field: str) -> bool:
    value = metadata.get(field)
    if not isinstance(value, bool):
        raise ReleasePolicyError(f"release field {field!r} is not a boolean")
    return value


def classify_release(
    metadata: Any,
    expected_tag: str = DEFAULT_TAG,
    expected_asset: str = DEFAULT_ASSET,
    release_tag: bool = False,
) -> dict[str, str]:
    if not isinstance(metadata, dict):
        raise ReleasePolicyError("release metadata is not a JSON object")
    if metadata.get("tag_name") != expected_tag:
        raise ReleasePolicyError(f"release tag is not {expected_tag!r}")
    if require_boolean(metadata, "draft"):
        raise ReleasePolicyError("the official release is still a draft")

    prerelease = require_boolean(metadata, "prerelease")
    immutable = require_boolean(metadata, "immutable")
    published_at = metadata.get("published_at")
    if not isinstance(published_at, str) or not published_at:
        raise ReleasePolicyError("release field 'published_at' is missing")

    assets = metadata.get("assets")
    if not isinstance(assets, list):
        raise ReleasePolicyError("release field 'assets' is not an array")
    matching_assets = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == expected_asset
    ]
    if len(matching_assets) != 1:
        raise ReleasePolicyError(
            f"release must contain exactly one {expected_asset!r} asset"
        )

    asset = matching_assets[0]
    if asset.get("state") != "uploaded":
        raise ReleasePolicyError(f"release asset {expected_asset!r} is not uploaded")
    digest = asset.get("digest")
    if not isinstance(digest, str) or DIGEST_PATTERN.fullmatch(digest) is None:
        raise ReleasePolicyError(
            f"release asset {expected_asset!r} has no valid SHA-256 digest"
        )

    if prerelease and not release_tag:
        release_phase = "prerelease"
        run_tla = "false"
        checksum_policy = "deferred"
    else:
        release_phase = "prerelease" if prerelease else "final"
        run_tla = "true"
        checksum_policy = "strict-pinned-sha256"

    return {
        "release_phase": release_phase,
        "prerelease": str(prerelease).lower(),
        "release_tag": str(release_tag).lower(),
        "release_immutable": str(immutable).lower(),
        "published_asset_digest": digest,
        "run_tla": run_tla,
        "checksum_policy": checksum_policy,
    }


def load_release_metadata(
    metadata_path: Path | None,
    repository: str,
    tag: str,
) -> Any:
    if metadata_path is not None:
        try:
            return json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ReleasePolicyError(f"cannot read release metadata: {error}") from error

    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise ReleasePolicyError("repository must have the form owner/name")
    quoted_tag = urllib.parse.quote(tag, safe="")
    url = f"https://api.github.com/repos/{repository}/releases/tags/{quoted_tag}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "flyology-tlc-release-policy",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, headers=headers), timeout=30
        ) as response:
            return json.load(response)
    except (OSError, UnicodeError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise ReleasePolicyError(f"cannot fetch official release metadata: {error}") from error


def append_outputs(path: Path, outputs: dict[str, str]) -> None:
    try:
        with path.open("a", encoding="utf-8") as output_file:
            for key, value in outputs.items():
                output_file.write(f"{key}={value}\n")
    except OSError as error:
        raise ReleasePolicyError(f"cannot write GitHub Actions outputs: {error}") from error


def append_summary(path: Path, tag: str, outputs: dict[str, str]) -> None:
    if outputs["run_tla"] == "false":
        summary = (
            f"TLC {tag} is an official prerelease; the TLA+ gate is deferred while "
            "its artifact may change. The published digest is observed only and is not trusted."
        )
    elif outputs["release_phase"] == "prerelease":
        summary = (
            f"TLC {tag} is an official prerelease, but this Flyology release-tag run "
            "requires the harness's strict pinned SHA-256 verification."
        )
    else:
        summary = (
            f"TLC {tag} is final; the TLA+ gate will run with the harness's strict pinned "
            "SHA-256 verification."
        )
    try:
        with path.open("a", encoding="utf-8") as summary_file:
            summary_file.write(f"### TLC release policy\n\n{summary}\n")
    except OSError as error:
        raise ReleasePolicyError(f"cannot write GitHub Actions summary: {error}") from error


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--tag", default=DEFAULT_TAG)
    parser.add_argument("--asset", default=DEFAULT_ASSET)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    release_tag_text = os.environ.get("FLYOLOGY_RELEASE_TAG", "false")
    if release_tag_text not in ("false", "true"):
        raise ReleasePolicyError("FLYOLOGY_RELEASE_TAG is not a boolean")
    metadata = load_release_metadata(
        arguments.metadata, arguments.repository, arguments.tag
    )
    outputs = classify_release(
        metadata,
        arguments.tag,
        arguments.asset,
        release_tag=release_tag_text == "true",
    )
    for key, value in outputs.items():
        print(f"{key}={value}")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        append_outputs(Path(github_output), outputs)
    github_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if github_summary:
        append_summary(Path(github_summary), arguments.tag, outputs)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReleasePolicyError as error:
        print(f"tlc-release-policy: {error}", file=sys.stderr)
        sys.exit(1)
