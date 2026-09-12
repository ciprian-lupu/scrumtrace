#!/usr/bin/env python3
"""Gate 2 tests: paused Shot/Pin/Talk attempts and capture-time saves."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_gate2_shot.py"


def _run(log: Path, start_line: int = 1) -> subprocess.CompletedProcess[str]:
    session = log.parent / "gate2-session"
    session.mkdir(exist_ok=True)
    (session / "session.manifest.json").write_text(
        json.dumps({"session_id": "gate2-session"}),
        encoding="utf-8",
    )
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--session",
            str(session),
            "--log",
            str(log),
            "--log-start-line",
            str(start_line),
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def _write(rows: list[dict[str, object]]) -> Path:
    path = Path(tempfile.mkdtemp(prefix="scrumtrace-gate2-")) / "agent.jsonl"
    run_id = "gate2-run"
    scoped = [{"event": "launch", "run_id": run_id}]
    scoped.extend(
        {
            **row,
            "run_id": row.get("run_id", run_id),
            "session": row.get("session", "gate2-session"),
        }
        for row in rows
    )
    path.write_text(
        "\n".join(json.dumps(row) for row in scoped) + "\n",
        encoding="utf-8",
    )
    return path


def _refused_rows(*, inflight_talk: bool = False) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = [
        {"event": "shot_save", "t_media": 1.0},
    ]
    if inflight_talk:
        rows.append({"event": "talk_press"})
    rows.extend(
        [
            {"event": "pause_ok", "t_media": 5.0},
            {"event": "shot_ignored", "reason": "paused"},
            {"event": "pin_ignored", "reason": "paused"},
        ]
    )
    if inflight_talk:
        rows.append({"event": "talk_abort"})
    else:
        rows.append({"event": "talk_start_fail", "reason": "paused"})
    rows.append({"event": "resume_ok"})
    return rows


def test_missing_log_start_line_exits_2() -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--log", "/tmp/missing.jsonl"],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2


def test_pause_with_no_attempts_blocks() -> None:
    log = _write(
        [
            {"event": "pause_ok", "t_media": 5.0},
            {"event": "resume_ok"},
            {"event": "shot_save", "t_media": 6.0},
        ]
    )
    result = _run(log)
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"
    assert "missing_required_pause_attempts" in report["blocked_reasons"]


def test_missing_pin_blocks() -> None:
    rows = [row for row in _refused_rows() if row.get("event") != "pin_ignored"]
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"
    assert report["checks"]["pin_ignored_while_paused"] is False


def test_refused_shot_pin_talk_passes() -> None:
    log = _write(_refused_rows())
    result = _run(log)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"


def test_inflight_talk_abort_passes() -> None:
    log = _write(_refused_rows(inflight_talk=True))
    result = _run(log)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"
    assert report["checks"]["talk_refused_or_aborted_while_paused"] is True


def test_shot_save_during_pause_without_t_media_blocks_interface() -> None:
    rows = _refused_rows()
    rows.insert(-1, {"event": "shot_save"})
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"
    assert "INTERFACE_BLOCKED" in report["blocked_reasons"]


def test_pre_pause_shot_save_during_pause_passes() -> None:
    rows = _refused_rows()
    rows.insert(-1, {"event": "shot_save", "t_media": 4.5})
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"
    assert report["checks"]["shot_save_during_pause_predated"] == 1


def test_new_shot_save_during_pause_fails() -> None:
    rows = _refused_rows()
    rows.insert(-1, {"event": "shot_save", "t_media": 5.5})
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "fail"
    assert "no_bad_shot_save_during_pause" in report["failed"]


def test_pin_ok_during_pause_fails() -> None:
    rows = _refused_rows()
    rows.insert(-1, {"event": "pin_ok", "t_media": 5.2})
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "no_pin_ok_during_pause" in report["failed"]


def test_talk_transcribe_during_pause_fails() -> None:
    rows = _refused_rows()
    rows.insert(-1, {"event": "talk_transcribe_begin"})
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "no_talk_transcribe_during_pause" in report["failed"]


def test_shot_begin_during_pause_fails() -> None:
    rows = _refused_rows()
    rows.insert(-1, {"event": "shot_begin"})
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "no_shot_begin_during_pause" in report["failed"]


def main() -> None:
    test_missing_log_start_line_exits_2()
    test_pause_with_no_attempts_blocks()
    test_missing_pin_blocks()
    test_refused_shot_pin_talk_passes()
    test_inflight_talk_abort_passes()
    test_shot_save_during_pause_without_t_media_blocks_interface()
    test_pre_pause_shot_save_during_pause_passes()
    test_new_shot_save_during_pause_fails()
    test_pin_ok_during_pause_fails()
    test_talk_transcribe_during_pause_fails()
    test_shot_begin_during_pause_fails()
    print("test_gate2 ok")


if __name__ == "__main__":
    main()
