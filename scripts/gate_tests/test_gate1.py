#!/usr/bin/env python3
"""Gate 1 tests: manual media proof, pause math, and ZIP leak scans."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from support import (
    GOOD_PAUSES,
    ROOT,
    TOKEN,
    _ffprobe_stub_env,
    _run_gate1,
    _write_gate1_fake_session,
)


def test_without_manual_flags_returns_manual_required() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-manual-")) / "s"
    _write_gate1_fake_session(session, pauses=GOOD_PAUSES)
    result = _run_gate1(session, env=_ffprobe_stub_env())
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "manual_required"


def test_manual_flags_plus_valid_artifacts_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-pass-")) / "s"
    _write_gate1_fake_session(session, pauses=GOOD_PAUSES)
    result = _run_gate1(session, manual=True, av_offset_ms="50", env=_ffprobe_stub_env())
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"
    assert report["failed"] == []


def test_offset_50_passes_and_50_1_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-offset-")) / "s"
    _write_gate1_fake_session(session, pauses=GOOD_PAUSES)
    env = _ffprobe_stub_env()
    ok = _run_gate1(session, manual=True, av_offset_ms="50", env=env)
    assert ok.returncode == 0, ok.stdout + ok.stderr
    bad = _run_gate1(session, manual=True, av_offset_ms="50.1", env=env)
    assert bad.returncode == 1, bad.stdout + bad.stderr
    report = json.loads(bad.stdout)
    assert "av_offset_within_target_ms" in report["failed"]


def test_two_pauses_fail() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-two-")) / "s"
    _write_gate1_fake_session(session, pauses=GOOD_PAUSES[:2])
    result = _run_gate1(session, manual=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "manifest_pause_count_ge_3" in report["failed"]


def test_open_pause_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-open-")) / "s"
    pauses = GOOD_PAUSES + [{"pause_wall": 70.0, "resume_wall": None, "duration": 1.0}]
    _write_gate1_fake_session(session, pauses=pauses, wall_seconds=1241.0)
    result = _run_gate1(session, manual=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "manifest_pauses_closed" in report["failed"]


def test_inconsistent_pause_duration_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-badpause-")) / "s"
    pauses = [
        {"pause_wall": 10.0, "resume_wall": 20.0, "duration": 9.0},
        *GOOD_PAUSES[1:],
    ]
    _write_gate1_fake_session(session, pauses=pauses)
    result = _run_gate1(session, manual=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "pause_durations_consistent" in report["failed"]


def test_token_in_deflated_zip_text_member_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-zip-")) / "s"
    _write_gate1_fake_session(session, pauses=GOOD_PAUSES, token_in_zip=True)
    result = _run_gate1(session, manual=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "export_missing_token" in report["failed"]


def test_token_in_movie_still_fails_ascii_scan() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-movie-")) / "s"
    _write_gate1_fake_session(session, pauses=GOOD_PAUSES, token_in_movie=True)
    result = _run_gate1(session, manual=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["session_mp4_no_ascii_token"] is False
    assert report["checks"]["audio_wav_no_ascii_passphrase"] is False


def test_wav_without_layout_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate1-nolayout-")) / "s"
    _write_gate1_fake_session(session, layout=None, pauses=GOOD_PAUSES)
    result = _run_gate1(session, manual=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "capture_layout_exists" in report["failed"]
    assert "wav_start_present" in report["failed"]


def test_shot_before_pause_flag_removed() -> None:
    script = (ROOT / "scripts" / "inspect_gate1_session.py").read_text(encoding="utf-8")
    assert "--shot-before-pause" not in script
    assert "no_new_shot_png_during_pause" not in script


def main() -> None:
    test_without_manual_flags_returns_manual_required()
    test_manual_flags_plus_valid_artifacts_pass()
    test_offset_50_passes_and_50_1_fails()
    test_two_pauses_fail()
    test_open_pause_fails()
    test_inconsistent_pause_duration_fails()
    test_token_in_deflated_zip_text_member_fails()
    test_token_in_movie_still_fails_ascii_scan()
    test_wav_without_layout_fails()
    test_shot_before_pause_flag_removed()
    print("test_gate1 ok")


if __name__ == "__main__":
    main()
