#!/usr/bin/env python3
"""Gate 3 tests: complete transcription evidence and named target row."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_gate3_whisper.py"


def _write_session(
    session: Path,
    *,
    layout: dict[str, object] | None = None,
    transcript: dict[str, object] | None = None,
    timing: dict[str, object] | None = None,
    leak_timing_in_zip: bool = False,
) -> None:
    archive = session / "archive"
    export = session / "export"
    archive.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    if layout is not None:
        (archive / "capture-layout.json").write_text(json.dumps(layout), encoding="utf-8")
    if transcript is not None:
        (archive / "full_transcript.json").write_text(
            json.dumps(transcript), encoding="utf-8"
        )
    if timing is not None:
        (archive / "pipeline-timing.json").write_text(json.dumps(timing), encoding="utf-8")
    with zipfile.ZipFile(export / "session-pack.zip", "w") as zf:
        zf.writestr("SESSION_BRIEF.html", "<html></html>")
        if leak_timing_in_zip:
            zf.writestr("pipeline-timing.json", json.dumps(timing or {}))


def _good() -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    layout = {"microphone_wav": True, "system_audio_in_movie": True}
    transcript = {
        "segments": [{"start": 0, "end": 1, "text": "hello"}],
        "sources": ["room", "system"],
    }
    timing = {
        "whisper_wall_seconds": 12.0,
        "whisper_sources": ["room", "system"],
        "whisper_incomplete": False,
    }
    return layout, transcript, timing


def _run(session: Path, extra: list[str] | None = None) -> subprocess.CompletedProcess[str]:
    args = [sys.executable, str(SCRIPT), "--session", str(session)]
    if extra:
        args.extend(extra)
    return subprocess.run(args, check=False, capture_output=True, text=True)


def test_missing_layout_blocks() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    _, transcript, timing = _good()
    _write_session(session, layout=None, transcript=transcript, timing=timing)
    result = _run(session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"])
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"


def test_incomplete_true_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    timing["whisper_incomplete"] = True
    _write_session(session, layout=layout, transcript=transcript, timing=timing)
    result = _run(session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "whisper_incomplete_false" in report["failed"]


def test_missing_expected_source_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    transcript["sources"] = ["room"]
    timing["whisper_sources"] = ["room"]
    _write_session(session, layout=layout, transcript=transcript, timing=timing)
    result = _run(session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "both_sources_when_both_captured" in report["failed"]


def test_timing_transcript_source_mismatch_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    timing["whisper_sources"] = ["room"]
    _write_session(session, layout=layout, transcript=transcript, timing=timing)
    result = _run(session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "timing_sources_match_transcript" in report["failed"]


def test_zero_negative_nan_wall_fail() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    for bad in (0, -1, float("nan"), float("inf")):
        timing["whisper_wall_seconds"] = bad
        _write_session(session, layout=layout, transcript=transcript, timing=timing)
        result = _run(
            session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"]
        )
        assert result.returncode == 1, bad
        report = json.loads(result.stdout)
        assert "whisper_wall_finite_positive" in report["failed"]


def test_timing_leaked_in_zip_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    _write_session(
        session,
        layout=layout,
        transcript=transcript,
        timing=timing,
        leak_timing_in_zip=True,
    )
    result = _run(session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "timing_absent_from_export_and_zip" in report["failed"]


def test_without_named_target_returns_manual_required() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    _write_session(session, layout=layout, transcript=transcript, timing=timing)
    result = _run(session)
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "manual_required"


def test_named_target_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate3-")) / "s"
    layout, transcript, timing = _good()
    _write_session(session, layout=layout, transcript=transcript, timing=timing)
    result = _run(session, ["--target-media-seconds", "300", "--target-wall-seconds", "12"])
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"


def main() -> None:
    test_missing_layout_blocks()
    test_incomplete_true_fails()
    test_missing_expected_source_fails()
    test_timing_transcript_source_mismatch_fails()
    test_zero_negative_nan_wall_fail()
    test_timing_leaked_in_zip_fails()
    test_without_named_target_returns_manual_required()
    test_named_target_pass()
    print("test_gate3 ok")


if __name__ == "__main__":
    main()
