#!/usr/bin/env python3
"""Tests for scripts/autopilot.py and automation/task-graph.json."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
AUTOPILOT = ROOT / "scripts" / "autopilot.py"
GRAPH_PATH = ROOT / "automation" / "task-graph.json"

FIXED_INVENTORY = [
    "O00",
    "O01",
    "A01",
    "A02",
    "A02b",
    "A03",
    "A04",
    "A05",
    "A06",
    "A07",
    "A08",
    "A09",
    "A10",
    "A11",
    "B01",
    "B02",
    "B03",
    "B04",
    "C01",
    "C02",
    "C03",
    "C04",
    "D01",
    "D02",
    "D03",
    "D04",
    "D05",
    "D06",
    "D07",
    "D08",
    "E01-standards",
    "E01-spec",
    "E01-security",
    "E02",
    "E03",
    "F01-linux",
    "F01-mac",
    "F02",
    "F03",
    "F04",
    "G01",
    "G02",
    "G03",
]


def load_ap(state_dir: Path):
    env = os.environ.copy()
    env["SCRUMTRACE_AUTOPILOT_HOME"] = str(state_dir)
    # Import a fresh module copy bound to this state dir.
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        f"autopilot_{state_dir.name}", AUTOPILOT
    )
    assert spec and spec.loader
    # Ensure child import sees the env var.
    old = os.environ.get("SCRUMTRACE_AUTOPILOT_HOME")
    os.environ["SCRUMTRACE_AUTOPILOT_HOME"] = str(state_dir)
    try:
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        if old is None:
            os.environ.pop("SCRUMTRACE_AUTOPILOT_HOME", None)
        else:
            os.environ["SCRUMTRACE_AUTOPILOT_HOME"] = old
    mod.STATE_DIR = state_dir
    mod.STATE_PATH = state_dir / "state.json"
    return mod


def run_cli(state_dir: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["SCRUMTRACE_AUTOPILOT_HOME"] = str(state_dir)
    return subprocess.run(
        [sys.executable, str(AUTOPILOT), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


class GraphSchemaTests(unittest.TestCase):
    def test_fixed_inventory_exact(self) -> None:
        graph = json.loads(GRAPH_PATH.read_text(encoding="utf-8"))
        self.assertEqual(graph["fixed_inventory"], FIXED_INVENTORY)
        self.assertEqual([t["id"] for t in graph["tasks"]], FIXED_INVENTORY)

    def test_validate_graph_accepts_repo_graph(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ap = load_ap(Path(tmp))
            graph = ap.load_graph()
            self.assertEqual(len(graph["tasks"]), 43)

    def test_missing_inventory_id_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ap = load_ap(Path(tmp))
            graph = json.loads(GRAPH_PATH.read_text(encoding="utf-8"))
            graph["tasks"] = [t for t in graph["tasks"] if t["id"] != "A03"]
            with self.assertRaises(ap.AutopilotError):
                ap.validate_graph(graph)

    def test_cycle_detection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ap = load_ap(Path(tmp))
            graph = json.loads(GRAPH_PATH.read_text(encoding="utf-8"))
            by = {t["id"]: t for t in graph["tasks"]}
            by["O00"]["dependencies"] = ["O01"]
            by["O01"]["dependencies"] = ["O00"]
            with self.assertRaises(ap.AutopilotError):
                ap.validate_graph(graph)

    def test_builder_reviewer_must_differ(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ap = load_ap(Path(tmp))
            graph = json.loads(GRAPH_PATH.read_text(encoding="utf-8"))
            graph["tasks"][0]["reviewer_model"] = graph["tasks"][0]["builder_model"]
            with self.assertRaises(ap.AutopilotError):
                ap.validate_graph(graph)


class ReadyAndOwnershipTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.ap = load_ap(self.tmp)
        head = self.ap.git_head()
        self.assertEqual(self.ap.main(["init", "--base", head]), 0)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_ready_starts_at_o00_only(self) -> None:
        out = run_cli(self.tmp, ["ready", "--json"])
        self.assertEqual(out.returncode, 0, out.stderr)
        payload = json.loads(out.stdout)
        self.assertEqual(payload["ready"], ["O00"])

    def test_parallel_ready_never_overlaps_owned_paths(self) -> None:
        # After O00+O01 integrated, wave-1 A01 and A02b may be jointly ready;
        # force A02 integrated too and ensure ready set has no owned overlap.
        state = self.ap.load_state()
        for tid in ["O00", "O01", "A01"]:
            self.ap.task_entry(state, tid)["status"] = "integrated"
        # Leave A02 not integrated so A03 not ready; A02b depends only on O01.
        self.ap.save_state(state)
        ready = self.ap.ready_tasks(self.ap.load_graph(), self.ap.load_state())
        graph = self.ap.load_graph()
        owned_sets = [
            list(self.ap.resolve_task(graph, self.ap.load_state(), tid)["owned_paths"])
            for tid in ready
        ]
        for i, left in enumerate(owned_sets):
            for j, right in enumerate(owned_sets):
                if i >= j:
                    continue
                if left and right:
                    self.assertFalse(self.ap.owned_overlap(left, right), (ready[i], ready[j]))

    def test_mac_blocked_dependency_does_not_block_independent_linux(self) -> None:
        state = self.ap.load_state()
        for tid in ["O00", "O01"]:
            self.ap.task_entry(state, tid)["status"] = "integrated"
        self.ap.task_entry(state, "A02b")["status"] = "needs_mac_worker"
        self.ap.save_state(state)
        ready = self.ap.ready_tasks(self.ap.load_graph(), self.ap.load_state())
        self.assertIn("A01", ready)
        self.assertNotIn("A02b", ready)
        # B01 depends on A11+A02b so must not be ready.
        self.assertNotIn("B01", ready)


class RecordAndBlockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.ap = load_ap(self.tmp)
        self.head = self.ap.git_head()
        self.assertEqual(self.ap.main(["init", "--base", self.head]), 0)
        self.assertEqual(
            self.ap.main(
                [
                    "start",
                    "O00",
                    "--branch",
                    "cursor/o00-0397",
                    "--base",
                    self.head,
                ]
            ),
            0,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_unowned_changed_file_rejects_record(self) -> None:
        results = self.tmp / "results.json"
        results.write_text(
            json.dumps(
                {
                    "commands": [
                        {
                            "command": "python3 scripts/test_autopilot.py",
                            "exit_code": 0,
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        with mock.patch.object(
            self.ap,
            "git_changed_paths",
            return_value=["README.md"],
        ):
            with self.assertRaises(SystemExit):
                self.ap.main(
                    [
                        "record",
                        "O00",
                        "--commit",
                        self.head,
                        "--results",
                        str(results),
                    ]
                )

    def test_unknown_blocker_rejected(self) -> None:
        evidence = self.tmp / "ev.txt"
        evidence.write_text("blocked", encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.ap.main(
                [
                    "block",
                    "O00",
                    "--reason-code",
                    "not_a_real_blocker",
                    "--evidence",
                    str(evidence),
                ]
            )

    def test_undeclared_blocker_rejected(self) -> None:
        evidence = self.tmp / "ev.txt"
        evidence.write_text("blocked", encoding="utf-8")
        # O00 allows only authz_denied
        with self.assertRaises(SystemExit):
            self.ap.main(
                [
                    "block",
                    "O00",
                    "--reason-code",
                    "tcc",
                    "--evidence",
                    str(evidence),
                ]
            )

    def test_automatable_cannot_use_human_blocker(self) -> None:
        evidence = self.tmp / "ev.txt"
        evidence.write_text("blocked", encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.ap.main(
                [
                    "block",
                    "O00",
                    "--reason-code",
                    "product_decision",
                    "--evidence",
                    str(evidence),
                ]
            )

    def test_secret_fields_rejected(self) -> None:
        with self.assertRaises(self.ap.AutopilotError):
            self.ap.reject_secret_fields({"api_key": "secret"})
        with self.assertRaises(self.ap.AutopilotError):
            self.ap.reject_secret_fields({"nested": {"transcript": "hi"}})

    def test_argv_redaction(self) -> None:
        redacted = self.ap.redact_argv(
            ["cmd", "--token", "abc", "--password=secret", "ok"]
        )
        self.assertEqual(redacted[2], "[REDACTED]")
        self.assertIn("[REDACTED]", redacted)


class SpawnAndPassTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.ap = load_ap(self.tmp)
        self.head = self.ap.git_head()
        self.assertEqual(self.ap.main(["init", "--base", self.head]), 0)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_spawn_child_blocks_parent_completion(self) -> None:
        state = self.ap.load_state()
        for tid in ["O00", "O01", "A01", "A02"]:
            self.ap.task_entry(state, tid)["status"] = "integrated"
        self.ap.task_entry(state, "A06")["status"] = "reviewed"
        self.ap.task_entry(state, "A06")["children"] = ["A06b"]
        self.ap.task_entry(state, "A06b")["status"] = "in_progress"
        ownership = {
            "id": "A06b",
            "title": "repair",
            "dependencies": ["A06"],
            "wave": 2,
            "builder_model": "composer",
            "reviewer_model": "grok",
            "owned_paths": ["scripts/inspect_gate2_shot.py"],
            "forbidden_paths": [],
            "focused_tests": [],
            "environment": "linux",
            "classification": "automatable",
            "human_evidence_allowed": False,
            "allowed_blockers": [],
            "expected_commit_subject": "fix: a06b",
            "acceptance_artifacts": [],
            "integration_commands": [],
            "spawn_allowed": [],
        }
        state.setdefault("spawned", {})["A06b"] = ownership
        self.ap.save_state(state)
        wave = self.tmp / "wave.json"
        wave.write_text("{}", encoding="utf-8")
        with mock.patch.object(self.ap, "run_commands", return_value=[]):
            with self.assertRaises(SystemExit):
                self.ap.main(
                    [
                        "integrate",
                        "A06",
                        "--develop-sha",
                        self.head,
                        "--wave-results",
                        str(wave),
                    ]
                )

    def test_pass_requires_clean_tree_and_order(self) -> None:
        # Dirty tree rejects pass-start.
        dirty = ROOT / ".scrumtrace-autopilot-test-dirty"
        dirty.write_text("x", encoding="utf-8")
        try:
            with self.assertRaises(SystemExit):
                self.ap.main(
                    ["pass-start", "--number", "1", "--sha", self.head, "--model", "composer"]
                )
        finally:
            dirty.unlink(missing_ok=True)

        # Wrong model for pass 1
        with mock.patch.object(self.ap, "ensure_clean_tree"):
            with self.assertRaises(SystemExit):
                self.ap.main(
                    ["pass-start", "--number", "1", "--sha", self.head, "--model", "grok"]
                )

    def test_confirm_requires_distinct_models_and_pass3(self) -> None:
        with self.assertRaises(SystemExit):
            self.ap.main(
                [
                    "confirm",
                    "--model",
                    "composer",
                    "--sha",
                    self.head,
                    "--result",
                    "AUTOMATABLE_SCOPE_CONFIRMED",
                ]
            )

    def test_handoff_refuses_outside_state_dir(self) -> None:
        with self.assertRaises(SystemExit):
            self.ap.main(
                [
                    "handoff",
                    "--mode",
                    "automatable",
                    "--output",
                    str(ROOT / "HANDOFF.md"),
                ]
            )

    def test_verify_automatable_fails_before_passes(self) -> None:
        code = self.ap.main(["verify", "--mode", "automatable"])
        self.assertEqual(code, 1)

    def test_corrupt_state_rejected(self) -> None:
        self.ap.STATE_PATH.write_text("{", encoding="utf-8")
        with self.assertRaises(self.ap.AutopilotError):
            self.ap.load_state()

    def test_truncated_state_rejected(self) -> None:
        self.ap.STATE_PATH.write_text("   \n", encoding="utf-8")
        with self.assertRaises(self.ap.AutopilotError):
            self.ap.load_state()


class OperatorAndReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.ap = load_ap(self.tmp)
        self.head = self.ap.git_head()
        self.assertEqual(self.ap.main(["init", "--base", self.head]), 0)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_operator_requires_same_sha_artifact(self) -> None:
        artifact = self.tmp / "artifact.bin"
        artifact.write_bytes(b"abc")
        results = {
            "command_digest": "d" * 64,
            "exit_code": 0,
            "source_sha": "0" * 40,
            "artifact_path": str(artifact),
            "artifact_sha256": self.ap.sha256_file(artifact),
            "artifact_bytes": 3,
            "machine": "test",
            "environment": "linux",
            "manual_state": "pass",
        }
        path = self.tmp / "op.json"
        path.write_text(json.dumps(results), encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.ap.main(["record-operator", "F01-linux", "--results", str(path)])

    def test_release_mode_requires_fg_artifacts(self) -> None:
        # Even with fake integrated automatable work, release still fails.
        state = self.ap.load_state()
        graph = self.ap.load_graph()
        for tid in graph["fixed_inventory"]:
            task = self.ap.resolve_task(graph, state, tid)
            if task["classification"] == "automatable":
                self.ap.task_entry(state, tid)["status"] = "integrated"
        state["passes"] = {
            "1": {"status": "finished", "sha": self.head},
            "2": {"status": "finished", "sha": self.head},
            "3": {"status": "finished", "sha": self.head},
        }
        state["confirmations"] = {
            "composer": {
                "result": "AUTOMATABLE_SCOPE_CONFIRMED",
                "sha": self.head,
            },
            "grok": {
                "result": "AUTOMATABLE_SCOPE_CONFIRMED",
                "sha": self.head,
            },
        }
        self.ap.save_state(state)
        with mock.patch.object(self.ap, "remote_sha", return_value=self.head):
            ok, errors = self.ap.release_verify(graph, self.ap.load_state())
        self.assertFalse(ok)
        self.assertTrue(any("F01-linux" in e or "release task" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
