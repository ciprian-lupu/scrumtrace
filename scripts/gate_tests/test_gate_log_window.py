#!/usr/bin/env python3
"""A02 tests: explicit gate-run log window behavior."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (  # noqa: E402
    LogWindowError,
    filter_rows_for_session,
    first_run_id,
    read_jsonl_window,
)


class LogWindowHelperTests(unittest.TestCase):
    def test_ignores_events_before_marker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "agent.jsonl"
            log.write_text(
                json.dumps({"event": "shot_save"})
                + "\n"
                + json.dumps({"event": "launch", "run_id": "run-b"})
                + "\n"
                + json.dumps({"event": "shot_ignored", "reason": "paused"})
                + "\n",
                encoding="utf-8",
            )
            rows = read_jsonl_window(log, 2)
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["event"], "launch")
            self.assertNotIn("shot_save", [r["event"] for r in rows])

    def test_old_pass_before_marker_cannot_satisfy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "agent.jsonl"
            log.write_text(
                json.dumps({"event": "first_sample", "type": "screen"})
                + "\n"
                + json.dumps({"event": "launch", "run_id": "new"})
                + "\n",
                encoding="utf-8",
            )
            rows = read_jsonl_window(log, 2)
            types = {str(r.get("type") or "") for r in rows if r.get("event") == "first_sample"}
            self.assertNotIn("screen", types)

    def test_marker_beyond_eof_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "agent.jsonl"
            log.write_text("{}\n", encoding="utf-8")
            with self.assertRaises(LogWindowError):
                read_jsonl_window(log, 5)

    def test_negative_marker_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "agent.jsonl"
            log.write_text("{}\n", encoding="utf-8")
            with self.assertRaises(LogWindowError):
                read_jsonl_window(log, 0)

    def test_session_filter_rejects_other_session(self) -> None:
        rows = [
            {"event": "launch", "session": "sess-a", "run_id": "r1"},
            {"event": "eval_slice", "session": "sess-b"},
            {"event": "shot_save"},
        ]
        filtered = filter_rows_for_session(rows, "sess-a")
        self.assertEqual(len(filtered), 2)
        self.assertEqual(first_run_id(filtered), "r1")


class AggregateRequiresMarkerTests(unittest.TestCase):
    def test_log_without_start_line_exits_2(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "agent.jsonl"
            log.write_text("{}\n", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "inspect_all_gates.py"),
                    "--log",
                    str(log),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["status"], "blocked")
            self.assertIn("log_requires_log_start_line", payload["blocked_reasons"])


class Gate2WindowIntegrationTests(unittest.TestCase):
    def test_pre_marker_violation_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "agent.jsonl"
            log.write_text(
                json.dumps({"event": "pause_ok"})
                + "\n"
                + json.dumps({"event": "shot_save"})
                + "\n"
                + json.dumps({"event": "resume_ok"})
                + "\n"
                + json.dumps({"event": "shot_save", "t_media": 1.0})
                + "\n"
                + json.dumps({"event": "pause_ok", "t_media": 5.0})
                + "\n"
                + json.dumps({"event": "shot_ignored", "reason": "paused"})
                + "\n"
                + json.dumps({"event": "talk_start_fail", "reason": "paused"})
                + "\n"
                + json.dumps({"event": "pin_ignored", "reason": "paused"})
                + "\n"
                + json.dumps({"event": "resume_ok"})
                + "\n",
                encoding="utf-8",
            )
            # Start at line 4 so the earlier shot_save during pause is ignored.
            # Line 4 is the outside-pause shot_save that proves Shot still works.
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "inspect_gate2_shot.py"),
                    "--log",
                    str(log),
                    "--log-start-line",
                    "4",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "pass")


if __name__ == "__main__":
    unittest.main()
