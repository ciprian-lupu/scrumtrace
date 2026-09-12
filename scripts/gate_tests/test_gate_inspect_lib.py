#!/usr/bin/env python3
"""A01 tests: export evidence path containment and emit schema."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import emit, export_file_exists  # noqa: E402


class ExportContainmentTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.session = Path(self._tmp.name)
        self.export = self.session / "export"
        self.shots = self.export / "shots"
        self.shots.mkdir(parents=True)
        self.inside = self.shots / "inside.png"
        self.inside.write_bytes(b"png-bytes")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_positive_shots_inside(self) -> None:
        self.assertTrue(export_file_exists(self.session, "shots/inside.png"))
        self.assertTrue(export_file_exists(self.session, "export/shots/inside.png"))

    def test_rejects_parent_traversal(self) -> None:
        outside = self.session / "outside.png"
        outside.write_bytes(b"secret")
        self.assertFalse(export_file_exists(self.session, "../outside.png"))

    def test_rejects_nested_traversal(self) -> None:
        outside = self.session / "outside.png"
        outside.write_bytes(b"secret")
        self.assertFalse(export_file_exists(self.session, "shots/../../outside.png"))

    def test_rejects_absolute_path(self) -> None:
        self.assertFalse(export_file_exists(self.session, "/tmp/outside.png"))

    def test_rejects_export_to_archive_escape(self) -> None:
        archive = self.session / "archive"
        archive.mkdir()
        movie = archive / "session.mp4"
        movie.write_bytes(b"ftyp")
        self.assertFalse(export_file_exists(self.session, "export/../archive/session.mp4"))

    def test_rejects_symlink_to_outside(self) -> None:
        outside = self.session / "outside.png"
        outside.write_bytes(b"secret")
        link = self.shots / "linked.png"
        link.symlink_to(outside)
        self.assertFalse(export_file_exists(self.session, "shots/linked.png"))

    def test_rejects_symlink_to_inside_export(self) -> None:
        # Even an in-export symlink is rejected: evidence must be a real file.
        link = self.shots / "alias.png"
        link.symlink_to(self.inside)
        self.assertFalse(export_file_exists(self.session, "shots/alias.png"))

    def test_rejects_zero_byte_file(self) -> None:
        empty = self.shots / "empty.png"
        empty.write_bytes(b"")
        self.assertFalse(export_file_exists(self.session, "shots/empty.png"))

    def test_rejects_empty_and_control_chars(self) -> None:
        self.assertFalse(export_file_exists(self.session, ""))
        self.assertFalse(export_file_exists(self.session, "shots/in\x00side.png"))
        self.assertFalse(export_file_exists(self.session, "shots/in\nside.png"))
        self.assertFalse(export_file_exists(self.session, "shots/in\rside.png"))

    def test_does_not_fall_back_to_session_root(self) -> None:
        # A file living at session/foo is not export evidence.
        (self.session / "foo.png").write_bytes(b"nope")
        self.assertFalse(export_file_exists(self.session, "foo.png"))


class EmitSchemaTests(unittest.TestCase):
    def _capture(self, **kwargs):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = emit({"gate": "1", "checks": {}}, **kwargs)
        payload = json.loads(buf.getvalue())
        return code, payload

    def test_pass_schema(self) -> None:
        code, payload = self._capture(failed=[], status="pass")
        self.assertEqual(code, 0)
        self.assertEqual(payload["status"], "pass")
        self.assertEqual(payload["failed"], [])
        self.assertEqual(payload["blocked_reasons"], [])
        self.assertEqual(payload["manual_checks"], [])

    def test_fail_schema(self) -> None:
        code, payload = self._capture(failed=["a"], status="fail")
        self.assertEqual(code, 1)
        self.assertEqual(payload["status"], "fail")
        self.assertEqual(payload["failed"], ["a"])

    def test_blocked_not_inferred_as_manual(self) -> None:
        code, payload = self._capture(failed=[], blocked=True)
        self.assertEqual(code, 2)
        self.assertEqual(payload["status"], "blocked")
        self.assertNotEqual(payload["status"], "manual_required")

    def test_explicit_manual_required(self) -> None:
        code, payload = self._capture(
            failed=[],
            status="manual_required",
            blocked=True,
            manual_checks=["listen"],
        )
        self.assertEqual(code, 2)
        self.assertEqual(payload["status"], "manual_required")
        self.assertEqual(payload["manual_checks"], ["listen"])

    def test_rejects_unknown_status(self) -> None:
        with self.assertRaises(ValueError):
            emit({"gate": "1"}, [], status="maybe")


if __name__ == "__main__":
    unittest.main()
