#!/usr/bin/env python3
"""Regression tests for Kubernetes local-source overlay completeness."""

from __future__ import annotations

import copy
import gzip
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

import kubernetes_overlay as overlay


class KubernetesOverlayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project_root = Path(__file__).resolve().parents[3]
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.archive = cls.root / "overlay.tar.gz"
        cls.manifest_path = cls.root / "overlay.json"
        cls.manifest = overlay.create_overlay(
            cls.project_root, cls.archive, cls.manifest_path
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def test_fixture_sources_and_dirty_state_are_recorded(self) -> None:
        paths = {item["path"] for item in self.manifest["files"]}
        self.assertIn("showcases/http_plain_benchmark_server.adb", paths)
        self.assertIn("showcases/http-comparison/servers/rust/Cargo.lock", paths)
        self.assertIn("src/flyology-http-server.adb", paths)
        self.assertIn("runtime/ada/s-flysch.adb", paths)
        self.assertEqual(
            self.manifest["source_dirty"], bool(self.manifest["dirty_paths"])
        )
        self.assertEqual(
            self.manifest["dirty_paths"],
            overlay.current_dirty_paths(self.project_root),
        )
        self.assertEqual(
            self.manifest["base_revision"],
            overlay.git(self.project_root, "rev-parse", "HEAD").decode().strip(),
        )
        overlay.verify_overlay(
            self.archive, self.manifest_path, source_root=self.project_root
        )

    def test_fixture_mutation_and_omission_fail(self) -> None:
        extracted = self.root / self._testMethodName
        overlay.verify_overlay(
            self.archive, self.manifest_path, extract_root=extracted
        )
        fixture = extracted / "showcases/http_plain_benchmark_server.adb"
        fixture.write_text(fixture.read_text() + "\n-- omitted local mutation\n")
        with self.assertRaises(overlay.OverlayError):
            overlay.verify_source(extracted, self.manifest)
        fixture.unlink()
        with self.assertRaises(overlay.OverlayError):
            overlay.verify_source(extracted, self.manifest)

    def test_overlay_reconstructs_source_on_base_revision(self) -> None:
        checkout = self.root / self._testMethodName
        subprocess.run(
            (
                "git",
                "clone",
                "--no-local",
                "--no-checkout",
                str(self.project_root),
                str(checkout),
            ),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            (
                "git",
                "-C",
                str(checkout),
                "checkout",
                "--detach",
                self.manifest["base_revision"],
            ),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        overlay.verify_overlay(
            self.archive,
            self.manifest_path,
            source_root=checkout,
            extract_root=checkout,
        )

    def test_benchmark_metadata_records_overlay_provenance(self) -> None:
        environment = os.environ.copy()
        environment["HTTP_BENCH_OVERLAY_MANIFEST"] = str(self.manifest_path)
        output = subprocess.check_output(
            (
                sys.executable,
                str(self.project_root / "showcases/http-comparison/scripts/collect_metadata.py"),
            ),
            env=environment,
            text=True,
        )
        provenance = json.loads(output)["source_overlay"]
        self.assertTrue(provenance["applied"])
        self.assertEqual(provenance["archive_sha256"], self.manifest["archive_sha256"])
        self.assertEqual(provenance["content_sha256"], self.manifest["content_sha256"])

    def malicious_archive(self, member: tarfile.TarInfo) -> tuple[Path, Path]:
        archive = self.root / f"{self._testMethodName}.tar.gz"
        with archive.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w") as output:
                    output.addfile(member, io.BytesIO(b"x"))
        manifest = copy.deepcopy(self.manifest)
        manifest["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest_path = self.root / f"{self._testMethodName}.json"
        manifest_path.write_text(json.dumps(manifest))
        return archive, manifest_path

    def test_path_traversal_archive_fails(self) -> None:
        member = tarfile.TarInfo("../escape")
        member.size = 1
        archive, manifest = self.malicious_archive(member)
        with self.assertRaises(overlay.OverlayError):
            overlay.verify_overlay(archive, manifest)

    def test_symlink_archive_fails(self) -> None:
        member = tarfile.TarInfo("showcases/http_plain_benchmark_server.adb")
        member.type = tarfile.SYMTYPE
        member.linkname = "/tmp/escape"
        member.size = 0
        archive, manifest = self.malicious_archive(member)
        with self.assertRaises(overlay.OverlayError):
            overlay.verify_overlay(archive, manifest)


if __name__ == "__main__":
    unittest.main()
