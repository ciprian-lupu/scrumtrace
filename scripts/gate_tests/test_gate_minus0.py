#!/usr/bin/env python3
"""Gate −0 tests: require a complete 30-second capture proof."""

from __future__ import annotations

import contextlib
import json
import sys
import tempfile
import unittest.mock as mock
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import inspect_gate_minus0 as mod  # noqa: E402


def _write_session(
    root: Path,
    *,
    media_seconds: float = 30.0,
    wav_start: object = 0.0,
) -> Path:
    archive = root / "archive"
    export = root / "export"
    archive.mkdir(parents=True)
    export.mkdir(parents=True)
    (archive / "session.mp4").write_bytes(b"ftyp")
    (archive / "audio.wav").write_bytes(b"RIFF")
    (archive / "events.jsonl").write_text("{}\n", encoding="utf-8")
    (archive / "capture-layout.json").write_text(
        json.dumps({"wav_start_media_seconds": wav_start}),
        encoding="utf-8",
    )
    (root / "session.manifest.json").write_text(
        json.dumps(
            {
                "session_id": "sess-minus0",
                "duration": {"media_seconds": media_seconds},
            }
        ),
        encoding="utf-8",
    )
    return root


GOOD_LOG = [
    {"event": "launch", "run_id": "run-1", "session": "sess-minus0"},
    {"event": "start_ok", "session": "sess-minus0"},
    {"event": "recorder_first_sample", "type": "screen", "session": "sess-minus0"},
    {"event": "recorder_first_sample", "type": "audio", "session": "sess-minus0"},
    {"event": "recorder_first_sample", "type": "wav", "session": "sess-minus0"},
    {"event": "stop_capture_ok", "session": "sess-minus0"},
]


def _write_log(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")


def _run(
    session: Path,
    log: Path,
    *,
    start_line: int = 1,
    durations: dict[str, float] | None = None,
    probe: str | None = "/usr/bin/ffprobe",
) -> tuple[int, dict[str, object]]:
    durations = durations or {
        str(session / "archive" / "session.mp4"): 30.0,
        str(session / "archive" / "audio.wav"): 30.0,
    }

    def fake_duration(path: Path, _probe: str) -> float | None:
        return durations.get(str(path))

    argv = [
        "inspect_gate_minus0.py",
        "--session",
        str(session),
        "--log",
        str(log),
        "--log-start-line",
        str(start_line),
    ]
    buf = StringIO()
    with mock.patch.object(mod, "ffprobe_bin", return_value=probe):
        with mock.patch.object(mod, "ffprobe_duration", side_effect=fake_duration):
            with mock.patch.object(sys, "argv", argv):
                with contextlib.redirect_stdout(buf):
                    code = mod.main()
    return code, json.loads(buf.getvalue())


def test_requires_log_start_line() -> None:
    import subprocess

    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "inspect_gate_minus0.py"), "--session", "/tmp", "--log", "/tmp/x"],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0


def test_29_9_seconds_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _write_session(Path(tmp) / "sess", media_seconds=29.9)
        log = Path(tmp) / "agent.jsonl"
        _write_log(log, GOOD_LOG)
        code, report = _run(
            session,
            log,
            durations={
                str(session / "archive" / "session.mp4"): 29.9,
                str(session / "archive" / "audio.wav"): 29.9,
            },
        )
        assert code == 1, report
        assert report["checks"]["session_mp4_duration_ge_30"] is False


def test_30_seconds_passes_duration() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _write_session(Path(tmp) / "sess", media_seconds=30.0)
        log = Path(tmp) / "agent.jsonl"
        _write_log(log, GOOD_LOG)
        code, report = _run(session, log)
        assert code == 0, report
        assert report["checks"]["session_mp4_duration_ge_30"] is True
        assert report["checks"]["audio_wav_duration_ge_30"] is True


def test_invalid_wav_start_fails() -> None:
    for bad in (float("nan"), float("inf"), True, -0.1):
        with tempfile.TemporaryDirectory() as tmp:
            session = _write_session(Path(tmp) / "sess", wav_start=bad)
            log = Path(tmp) / "agent.jsonl"
            _write_log(log, GOOD_LOG)
            code, report = _run(session, log)
            assert code == 1, report
            assert report["checks"]["wav_start_finite_nonnegative"] is False


def test_missing_first_sample_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _write_session(Path(tmp) / "sess")
        log = Path(tmp) / "agent.jsonl"
        rows = [row for row in GOOD_LOG if row.get("type") != "wav"]
        _write_log(log, rows)
        code, report = _run(session, log)
        assert code == 1, report
        assert report["checks"]["first_sample_wav"] is False


def test_fatal_event_after_samples_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _write_session(Path(tmp) / "sess")
        log = Path(tmp) / "agent.jsonl"
        rows = list(GOOD_LOG)
        rows.insert(-1, {"event": "capture_write_fail", "session": "sess-minus0"})
        _write_log(log, rows)
        code, report = _run(session, log)
        assert code == 1, report
        assert report["checks"]["no_fatal_capture_events"] is False


def test_ffprobe_missing_blocks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _write_session(Path(tmp) / "sess")
        log = Path(tmp) / "agent.jsonl"
        _write_log(log, GOOD_LOG)
        code, report = _run(session, log, probe=None)
        assert code == 2, report
        assert report["status"] == "blocked"
        assert "ffprobe_unavailable" in report["blocked_reasons"]


def main() -> None:
    test_requires_log_start_line()
    test_29_9_seconds_fails()
    test_30_seconds_passes_duration()
    test_invalid_wav_start_fails()
    test_missing_first_sample_fails()
    test_fatal_event_after_samples_fails()
    test_ffprobe_missing_blocks()
    print("test_gate_minus0 ok")


if __name__ == "__main__":
    main()
