#!/usr/bin/env python3
"""Gate 0 tests: Keynote hotkey evidence and overlay sequencing."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_gate0_log.py"


def _run(log: Path, start_line: int = 1) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
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
    path = Path(tempfile.mkdtemp(prefix="scrumtrace-gate0-")) / "agent.jsonl"
    run_id = "gate0-run"
    scoped = [{"event": "launch", "run_id": run_id}]
    scoped.extend({**row, "run_id": row.get("run_id", run_id)} for row in rows)
    path.write_text(
        "\n".join(json.dumps(row) for row in scoped) + "\n",
        encoding="utf-8",
    )
    return path


def _good_rows() -> list[dict[str, object]]:
    return [
        {"event": "menu_start"},
        {"event": "capture_area_picker", "action": "open", "mode": "record"},
        {"event": "capture_area_picker", "action": "confirm", "mode": "record"},
        {"event": "start_requested"},
        {"event": "hotkey_shot"},
        {
            "event": "hotkey_front",
            "action": "shot",
            "app_active": "0",
            "front": "com.apple.iWork.Keynote",
        },
        {
            "event": "shot_window_key",
            "app_active": "0",
            "front": "com.apple.iWork.Keynote",
        },
        {"event": "hotkey_pin"},
        {
            "event": "hotkey_front",
            "action": "pin",
            "app_active": "0",
            "front": "com.apple.iWork.Keynote",
        },
        {"event": "pin_ok"},
        {"event": "hotkey_pause"},
        {"event": "pause_ok"},
        {"event": "resume_ok"},
    ]


def test_empty_log_blocks() -> None:
    log = Path(tempfile.mkdtemp(prefix="scrumtrace-gate0-")) / "empty.jsonl"
    log.write_text("", encoding="utf-8")
    result = _run(log)
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"


def test_all_three_actions_over_keynote_pass() -> None:
    log = _write(_good_rows())
    result = _run(log)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"
    assert report["checks"]["hotkey_shot"] is True
    assert report["checks"]["hotkey_pin"] is True
    assert report["checks"]["hotkey_pause"] is True


def test_missing_pin_fails() -> None:
    rows = [row for row in _good_rows() if row.get("event") != "hotkey_pin"]
    rows = [
        row
        for row in rows
        if not (row.get("event") == "hotkey_front" and row.get("action") == "pin")
    ]
    rows = [row for row in rows if row.get("event") != "pin_ok"]
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["hotkey_pin"] is False


def test_wrong_frontmost_fails() -> None:
    rows = _good_rows()
    for row in rows:
        if row.get("event") == "hotkey_front" and row.get("action") == "shot":
            row["front"] = "com.apple.Safari"
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["shot_front_keynote_inactive"] is False


def test_app_active_fails() -> None:
    rows = _good_rows()
    for row in rows:
        if row.get("event") == "hotkey_front" and row.get("action") == "pin":
            row["app_active"] = "1"
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["pin_front_keynote_inactive"] is False
    assert report["checks"]["no_hotkey_activated_app"] is False


def test_missing_shot_window_key_fails() -> None:
    rows = [
        row for row in _good_rows() if row.get("event") != "shot_window_key"
    ]
    result = _run(_write(rows))
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["shot_window_key_keynote_inactive"] is False


def test_start_without_record_overlay_fails() -> None:
    rows = [
        {"event": "menu_start"},
        {"event": "start_requested"},
        {"event": "hotkey_shot"},
        {
            "event": "hotkey_front",
            "action": "shot",
            "app_active": "0",
            "front": "com.apple.iWork.Keynote",
        },
        {"event": "hotkey_pin"},
        {
            "event": "hotkey_front",
            "action": "pin",
            "app_active": "0",
            "front": "com.apple.iWork.Keynote",
        },
        {"event": "pin_ok"},
        {"event": "hotkey_pause"},
        {"event": "pause_ok"},
    ]
    log = _write(rows)
    result = _run(log)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["start_without_overlay"] == 1
    assert report["checks"]["overlay_sequence_ok"] is False


def test_requires_log_start_line() -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--log", "/tmp/x"],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0


def main() -> None:
    test_empty_log_blocks()
    test_all_three_actions_over_keynote_pass()
    test_missing_pin_fails()
    test_wrong_frontmost_fails()
    test_app_active_fails()
    test_missing_shot_window_key_fails()
    test_start_without_record_overlay_fails()
    test_requires_log_start_line()
    print("test_gate0 ok")


if __name__ == "__main__":
    main()
