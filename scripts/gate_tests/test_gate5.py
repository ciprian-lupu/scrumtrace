#!/usr/bin/env python3
"""Gate 5 tests: denied, invalid-key, retired-model, and evidence scenarios."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_gate5_provider.py"


def _write_session(
    session: Path,
    *,
    consent: dict[str, object] | None,
    tasks: list[dict[str, object]] | None = None,
    slices: list[dict[str, object]] | None = None,
    pipeline_status: str | None = None,
    transcript_segments: list[dict[str, object]] | None = None,
    export_files: dict[str, bytes] | None = None,
) -> None:
    archive = session / "archive"
    export = session / "export"
    archive.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, object] = {"session_id": session.name}
    if consent is not None:
        manifest["upload_consent"] = consent
    if tasks is not None:
        manifest["tasks"] = tasks
    if slices is not None:
        manifest["slices"] = slices
    if pipeline_status is not None:
        manifest["pipeline_status"] = pipeline_status
    (session / "session.manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    if transcript_segments is not None:
        (archive / "full_transcript.json").write_text(
            json.dumps({"segments": transcript_segments}), encoding="utf-8"
        )
    files = export_files or {"SESSION_BRIEF.html": b"<html></html>"}
    for name, payload in files.items():
        path = export / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)


def _write_log(rows: list[dict[str, object]]) -> Path:
    path = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-log-")) / "agent.jsonl"
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
    return path


def _run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        check=False,
        capture_output=True,
        text=True,
    )


def test_denied_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={
            "approved": False,
            "provider": "openai",
            "endpoint": "https://api.openai.com",
            "model": "gpt-4o",
        },
    )
    log = _write_log(
        [
            {"event": "consent_result", "approved": "0", "session": "s"},
            {"event": "export_ok", "session": "s"},
        ]
    )
    result = _run(
        ["denied", "--session", str(session), "--log", str(log), "--log-start-line", "1"]
    )
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["no_eval_after_denied_consent"] is True


def test_denied_eval_after_consent_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={
            "approved": False,
            "provider": "openai",
            "endpoint": "https://api.openai.com",
            "model": "gpt-4o",
        },
    )
    log = _write_log(
        [
            {"event": "consent_result", "approved": "0"},
            {"event": "eval_slice"},
        ]
    )
    result = _run(
        ["denied", "--session", str(session), "--log", str(log), "--log-start-line", "1"]
    )
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "no_eval_after_denied_consent" in report["failed"]


def test_denied_requires_log_start_line() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(session, consent={"approved": False, "provider": "x", "endpoint": "y", "model": "z"})
    log = _write_log([{"event": "consent_result", "approved": "0"}])
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "denied", "--session", str(session), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2


def test_invalid_key_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={
            "approved": True,
            "provider": "openai",
            "endpoint": "https://api.openai.com",
            "model": "gpt-4o",
        },
        pipeline_status="offline_failed",
        tasks=[{"task_id": "T1", "status": "needs_review"}],
    )
    log = _write_log([{"event": "consent_result", "approved": "1"}, {"event": "provider_error"}])
    result = _run(
        [
            "invalid-key",
            "--session",
            str(session),
            "--log",
            str(log),
            "--log-start-line",
            "1",
        ]
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_invalid_key_confirmed_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={
            "approved": True,
            "provider": "openai",
            "endpoint": "https://api.openai.com",
            "model": "gpt-4o",
        },
        pipeline_status="offline_failed",
        tasks=[{"task_id": "T1", "status": "confirmed", "confidence": 0.9}],
    )
    log = _write_log([{"event": "consent_result", "approved": "1"}])
    result = _run(
        [
            "invalid-key",
            "--session",
            str(session),
            "--log",
            str(log),
            "--log-start-line",
            "1",
        ]
    )
    assert result.returncode == 1
    assert "no_task_confirmed" in json.loads(result.stdout)["failed"]


def test_retired_model_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={
            "approved": True,
            "provider": "anthropic",
            "endpoint": "https://api.anthropic.com",
            "model": "claude-3-5-sonnet-20240620",
        },
    )
    log = _write_log([{"event": "consent_result", "approved": "1"}, {"event": "model_rejected"}])
    result = _run(
        [
            "retired-model",
            "--session",
            str(session),
            "--log",
            str(log),
            "--log-start-line",
            "1",
        ]
    )
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["is_retired_anthropic"] is True


def test_retired_model_provider_call_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={
            "approved": True,
            "provider": "anthropic",
            "endpoint": "https://api.anthropic.com",
            "model": "claude-3-5-sonnet-20240620",
        },
    )
    log = _write_log([{"event": "consent_result", "approved": "1"}, {"event": "eval_slice"}])
    result = _run(
        [
            "retired-model",
            "--session",
            str(session),
            "--log",
            str(log),
            "--log-start-line",
            "1",
        ]
    )
    assert result.returncode == 1
    assert "no_provider_call_events" in json.loads(result.stdout)["failed"]


def test_evidence_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={"approved": True, "provider": "openai", "endpoint": "x", "model": "y"},
        slices=[{"slice_id": "sl1", "start_media": 0.0, "end_media": 10.0}],
        tasks=[
            {
                "task_id": "T1",
                "status": "confirmed",
                "confidence": 0.8,
                "observed": "button broken",
                "stated": "save fails",
                "inferred": "regression",
                "evidence_media": ["shots/a.png"],
                "quotes": [
                    {
                        "text": "save does nothing",
                        "t_media_start": 1.0,
                        "t_media_end": 2.0,
                        "slice_id": "sl1",
                    }
                ],
            }
        ],
        transcript_segments=[{"start": 0.5, "end": 2.5, "text": "save does nothing today"}],
        export_files={"shots/a.png": b"png-bytes", "SESSION_BRIEF.html": b"<html></html>"},
    )
    result = _run(["evidence", "--session", str(session)])
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["confirmed_evidence_on_disk"] is True


def test_evidence_empty_tasks_block() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(session, consent={"approved": True, "provider": "x", "endpoint": "y", "model": "z"}, tasks=[])
    result = _run(["evidence", "--session", str(session)])
    assert result.returncode == 2
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"


def test_evidence_missing_file_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={"approved": True, "provider": "x", "endpoint": "y", "model": "z"},
        tasks=[
            {
                "task_id": "T1",
                "status": "confirmed",
                "confidence": 0.9,
                "observed": "x",
                "stated": "y",
                "evidence_media": ["shots/missing.png"],
                "quotes": [],
            }
        ],
    )
    result = _run(["evidence", "--session", str(session)])
    assert result.returncode == 1
    assert "confirmed_evidence_on_disk" in json.loads(result.stdout)["failed"]


def test_evidence_traversal_rejected() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={"approved": True, "provider": "x", "endpoint": "y", "model": "z"},
        tasks=[
            {
                "task_id": "T1",
                "status": "confirmed",
                "confidence": 0.9,
                "observed": "x",
                "stated": "y",
                "evidence_media": ["../archive/secret.png"],
                "quotes": [],
            }
        ],
    )
    result = _run(["evidence", "--session", str(session)])
    assert result.returncode == 1
    assert "confirmed_evidence_on_disk" in json.loads(result.stdout)["failed"]


def test_evidence_low_confidence_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate5-")) / "s"
    _write_session(
        session,
        consent={"approved": True, "provider": "x", "endpoint": "y", "model": "z"},
        tasks=[
            {
                "task_id": "T1",
                "status": "confirmed",
                "confidence": 0.5,
                "observed": "x",
                "stated": "y",
                "evidence_media": ["shots/a.png"],
                "quotes": [],
            }
        ],
        export_files={"shots/a.png": b"png"},
    )
    result = _run(["evidence", "--session", str(session)])
    assert result.returncode == 1
    assert "confirmed_min_confidence" in json.loads(result.stdout)["failed"]


def main() -> None:
    test_denied_pass()
    test_denied_eval_after_consent_fails()
    test_denied_requires_log_start_line()
    test_invalid_key_pass()
    test_invalid_key_confirmed_fails()
    test_retired_model_pass()
    test_retired_model_provider_call_fails()
    test_evidence_pass()
    test_evidence_empty_tasks_block()
    test_evidence_missing_file_fails()
    test_evidence_traversal_rejected()
    test_evidence_low_confidence_fails()
    print("test_gate5 ok")


if __name__ == "__main__":
    main()
