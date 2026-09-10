#!/usr/bin/env python3

"""Regression tests for the CI boundary around mutable TLC prereleases."""

import importlib.util
import json
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path
from unittest import mock


sys.dont_write_bytecode = True

PROJECT_ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = PROJECT_ROOT / "scripts" / "check-tlc-release.py"
WORKFLOW_PATH = PROJECT_ROOT / ".github" / "workflows" / "ci.yml"
BUILD_ROOT = PROJECT_ROOT / "build"
BUILD_ROOT.mkdir(exist_ok=True)

module_spec = importlib.util.spec_from_file_location("tlc_release_policy", POLICY_PATH)
assert module_spec is not None and module_spec.loader is not None
policy = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(policy)


def release_metadata(*, prerelease: bool, immutable: bool) -> dict[str, object]:
    return {
        "tag_name": "v1.8.0",
        "draft": False,
        "prerelease": prerelease,
        "immutable": immutable,
        "published_at": "2026-09-10T19:17:52Z",
        "assets": [
            {
                "name": "tla2tools.jar",
                "state": "uploaded",
                "digest": (
                    "sha256:957b23b2bb31d08f19346e105e23585f93fea9a139a712b0ac347eedaf26afea"
                ),
            }
        ],
    }


def expect_policy_error(metadata: object, description: str) -> None:
    try:
        policy.classify_release(metadata)
    except policy.ReleasePolicyError:
        return
    raise AssertionError(f"{description} did not fail closed")


prerelease = policy.classify_release(
    release_metadata(prerelease=True, immutable=False)
)
assert prerelease["release_phase"] == "prerelease"
assert prerelease["run_tla"] == "false"
assert prerelease["checksum_policy"] == "deferred"
assert prerelease["release_immutable"] == "false"
assert prerelease["release_tag"] == "false"

tag_prerelease = policy.classify_release(
    release_metadata(prerelease=True, immutable=False),
    release_tag=True,
)
assert tag_prerelease["release_phase"] == "prerelease"
assert tag_prerelease["release_tag"] == "true"
assert tag_prerelease["run_tla"] == "true"
assert tag_prerelease["checksum_policy"] == "strict-pinned-sha256"

# A final release always reaches the existing strict harness verification,
# even if GitHub has not made the release record itself immutable.
final_metadata = release_metadata(prerelease=False, immutable=False)
final_metadata["assets"][0]["digest"] = "sha256:" + "0" * 64
final_release = policy.classify_release(final_metadata)
assert final_release["release_phase"] == "final"
assert final_release["run_tla"] == "true"
assert final_release["checksum_policy"] == "strict-pinned-sha256"
assert final_release["published_asset_digest"] == "sha256:" + "0" * 64

incomplete = release_metadata(prerelease=True, immutable=False)
del incomplete["immutable"]
expect_policy_error(incomplete, "missing official release state")

ambiguous = release_metadata(prerelease=True, immutable=False)
ambiguous["assets"].append(deepcopy(ambiguous["assets"][0]))
expect_policy_error(ambiguous, "duplicate TLC asset")

invalid_digest = release_metadata(prerelease=True, immutable=False)
invalid_digest["assets"][0]["digest"] = "sha256:not-a-digest"
expect_policy_error(invalid_digest, "malformed TLC digest")

draft = release_metadata(prerelease=True, immutable=False)
draft["draft"] = True
expect_policy_error(draft, "draft release")

with mock.patch.object(
    policy.urllib.request,
    "urlopen",
    side_effect=policy.urllib.error.URLError("fixture network failure"),
):
    try:
        policy.load_release_metadata(None, "tlaplus/tlaplus", "v1.8.0")
    except policy.ReleasePolicyError:
        pass
    else:
        raise AssertionError("release metadata network failure did not fail closed")

with tempfile.TemporaryDirectory(
    prefix="tlc-release-policy.", dir=BUILD_ROOT
) as temporary_directory:
    temporary_root = Path(temporary_directory)
    metadata_path = temporary_root / "release.json"
    output_path = temporary_root / "github-output"
    metadata_path.write_text(
        json.dumps(release_metadata(prerelease=True, immutable=False)),
        encoding="utf-8",
    )
    completed = subprocess.run(
        [sys.executable, str(POLICY_PATH), "--metadata", str(metadata_path)],
        check=False,
        capture_output=True,
        encoding="utf-8",
        env={"GITHUB_OUTPUT": str(output_path)},
    )
    assert completed.returncode == 0, completed.stderr
    emitted_outputs = dict(
        line.split("=", 1)
        for line in output_path.read_text(encoding="utf-8").splitlines()
    )
    assert emitted_outputs == prerelease

    tag_output_path = temporary_root / "tag-github-output"
    tag_completed = subprocess.run(
        [sys.executable, str(POLICY_PATH), "--metadata", str(metadata_path)],
        check=False,
        capture_output=True,
        encoding="utf-8",
        env={
            "FLYOLOGY_RELEASE_TAG": "true",
            "GITHUB_OUTPUT": str(tag_output_path),
        },
    )
    assert tag_completed.returncode == 0, tag_completed.stderr
    emitted_tag_outputs = dict(
        line.split("=", 1)
        for line in tag_output_path.read_text(encoding="utf-8").splitlines()
    )
    assert emitted_tag_outputs == tag_prerelease

    invalid_trigger = subprocess.run(
        [sys.executable, str(POLICY_PATH), "--metadata", str(metadata_path)],
        check=False,
        capture_output=True,
        encoding="utf-8",
        env={"FLYOLOGY_RELEASE_TAG": "not-a-boolean"},
    )
    assert invalid_trigger.returncode == 1
    assert "FLYOLOGY_RELEASE_TAG is not a boolean" in invalid_trigger.stderr

    metadata_path.write_text("{", encoding="utf-8")
    malformed = subprocess.run(
        [sys.executable, str(POLICY_PATH), "--metadata", str(metadata_path)],
        check=False,
        capture_output=True,
        encoding="utf-8",
    )
    assert malformed.returncode == 1
    assert "cannot read release metadata" in malformed.stderr

workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
release_job_start = workflow.index("  tlc_release:\n")
tla_job_start = workflow.index("  tla:\n", release_job_start)
release_job = workflow[release_job_start:tla_job_start]
tla_job = workflow[tla_job_start:]
assert "id: release" in release_job
assert "python3 ./scripts/check-tlc-release.py" in release_job
assert "FLYOLOGY_RELEASE_TAG: ${{ startsWith(github.ref, 'refs/tags/') }}" in release_job
for output in prerelease:
    assert f"{output}: ${{{{ steps.release.outputs.{output} }}}}" in release_job

assert "needs: tlc_release" in tla_job
assert "if: always()" in tla_job
assert "- name: Require TLC release classification" in tla_job
assert "if: needs.tlc_release.result != 'success'" in tla_job
assert "exit 1" in tla_job
assert "- name: Report authorized prerelease deferral" in tla_job
assert "needs.tlc_release.result == 'success'" in tla_job
assert "needs.tlc_release.outputs.run_tla == 'false'" in tla_job
assert "::notice title=TLC prerelease gate deferred::" in tla_job

assert "./bin/flyology-tla toolchain install" in tla_job
assert "./bin/flyology-tla toolchain verify" in tla_job
assert "run: ./scripts/check-tla.sh" in tla_job
assert "ref: dea289018a3eef2ac2aeab7a5ee8bc4e287fe231" in tla_job
assert "tla2tools-1.8.0" not in tla_job
assert "continue-on-error" not in tla_job
assert "|| true" not in tla_job

strict_steps = tla_job[tla_job.index("- name: Check out sources") :]
assert "published_asset_digest" not in strict_steps

strict_condition = "if: needs.tlc_release.outputs.run_tla == 'true'"
for step_name in (
    "Check out sources",
    "Check out the reviewed TLA+ harness",
    "Install Alire",
    "Select toolchain",
    "Configure Flyology index",
    "Build the TLA+ harness and provision its toolchain",
    "Check TLA+ models and replay implementation traces",
):
    step_start = tla_job.index(f"- name: {step_name}")
    next_step = tla_job.find("\n      - name:", step_start + 1)
    step = tla_job[step_start : next_step if next_step >= 0 else len(tla_job)]
    assert strict_condition in step, f"{step_name} does not honor strict TLA policy"

select_start = tla_job.index("- name: Select toolchain")
select_end = tla_job.index("\n      - name:", select_start + 1)
select_step = tla_job[select_start:select_end]
assert "            gprbuild=26.0.1" in select_step

print("TLC release policy tests passed.")
