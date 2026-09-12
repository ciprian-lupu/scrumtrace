#!/usr/bin/env python3
"""Tests for inspect_agent_log_privacy.py."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_agent_log_privacy.py"


def _run(log: Path, markers: list[str] | None = None) -> subprocess.CompletedProcess[str]:
    cmd = [sys.executable, str(SCRIPT), "--log", str(log)]
    for marker in markers or []:
        cmd.extend(["--forbidden-value", marker])
    return subprocess.run(cmd, check=False, capture_output=True, text=True)


def test_forbidden_key_fails_without_echoing_secret() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "agent.jsonl"
        secret = "orchid lantern seven"
        log.write_text(
            json.dumps({"event": "note", "note": secret, "has_url": "1"}) + "\n",
            encoding="utf-8",
        )
        result = _run(log, [secret])
        assert result.returncode == 1, result.stdout + result.stderr
        assert secret not in result.stdout
        assert secret not in result.stderr
        report = json.loads(result.stdout)
        assert report["status"] == "fail"
        assert any(item["key"] == "note" for item in report["findings"])


def test_forbidden_value_fails_without_echoing() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "agent.jsonl"
        secret = "ST-G1-PAUSE-TOKEN-9F3C"
        log.write_text(
            json.dumps({"event": "x", "detail": f"saw {secret}"}) + "\n",
            encoding="utf-8",
        )
        result = _run(log, [secret])
        assert result.returncode == 1
        assert secret not in result.stdout
        assert secret not in result.stderr
        report = json.loads(result.stdout)
        assert any(item["reason"] == "forbidden_value" for item in report["findings"])


def test_has_url_is_allowed() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "agent.jsonl"
        log.write_text(
            json.dumps({"event": "front", "has_url": "1", "bundle": "com.apple.iWork.Keynote"})
            + "\n",
            encoding="utf-8",
        )
        result = _run(log, ["ST-G1-PAUSE-TOKEN-9F3C"])
        assert result.returncode == 0, result.stdout + result.stderr
        report = json.loads(result.stdout)
        assert report["status"] == "pass"


def test_missing_log_blocks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        missing = Path(tmp) / "missing.jsonl"
        result = _run(missing)
        assert result.returncode == 2
        report = json.loads(result.stdout)
        assert report["status"] == "blocked"


def main() -> None:
    test_forbidden_key_fails_without_echoing_secret()
    test_forbidden_value_fails_without_echoing()
    test_has_url_is_allowed()
    test_missing_log_blocks()
    print("test_agent_log_privacy ok")


if __name__ == "__main__":
    main()
