#!/usr/bin/env python3
"""Aggregate runner tests for inspect_all_gates.py (A11)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGG = ROOT / "scripts" / "inspect_all_gates.py"

STUB_PASS = '''#!/usr/bin/env python3
import json, sys
print(json.dumps({"status":"pass","failed":[],"blocked_reasons":[],"manual_checks":[],"gate":"stub"}))
sys.exit(0)
'''

STUB_BLOCKED = '''#!/usr/bin/env python3
import json, sys
print(json.dumps({"status":"blocked","failed":[],"blocked_reasons":["need_artifacts"],"manual_checks":[]}))
sys.exit(2)
'''

STUB_MANUAL = '''#!/usr/bin/env python3
import json, sys
print(json.dumps({"status":"manual_required","failed":[],"blocked_reasons":["need_human"],"manual_checks":["scrub"]}))
sys.exit(2)
'''

STUB_FAIL = '''#!/usr/bin/env python3
import json, sys
print(json.dumps({"status":"fail","failed":["bad"],"blocked_reasons":[],"manual_checks":[]}))
sys.exit(1)
'''

STUB_MALFORMED = '''#!/usr/bin/env python3
import sys
print("not-json")
sys.exit(0)
'''

STUB_GATE5 = '''#!/usr/bin/env python3
import json, sys
print(json.dumps({"status":"pass","failed":[],"blocked_reasons":[],"manual_checks":[],"scenario":sys.argv[1] if len(sys.argv)>1 else ""}))
sys.exit(0)
'''


def _write_stubs(directory: Path, mapping: dict[str, str]) -> None:
    for name, body in mapping.items():
        path = directory / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


def _run(extra: list[str], *, scripts_dir: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if scripts_dir is not None:
        env["SCRUMTRACE_GATE_SCRIPTS"] = str(scripts_dir)
    return subprocess.run(
        [sys.executable, str(AGG), *extra],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def test_inspect_all_gates_mock_only() -> None:
    result = _run(["--mock-only"])
    assert result.returncode == 0, result.stdout + result.stderr
    summary = json.loads(result.stdout)
    assert summary["gates"]["minus1"]["status"] == "pass"
    assert "Do not invent GATE_LOG.md cells" in summary["note"]


def test_child_exit_0_malformed_json_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        scripts = Path(tmp)
        _write_stubs(
            scripts,
            {
                "inspect_gate_minus1.py": STUB_MALFORMED,
            },
        )
        result = _run(["--mock-only"], scripts_dir=scripts)
        assert result.returncode == 1, result.stdout + result.stderr
        summary = json.loads(result.stdout)
        assert summary["gates"]["minus1"]["status"] == "fail"
        assert "malformed_inspector_output" in summary["gates"]["minus1"]["failed"]


def test_child_exit_2_is_blocked() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        scripts = Path(tmp)
        _write_stubs(
            scripts,
            {
                "inspect_gate_minus1.py": STUB_PASS,
                "inspect_gate_minus0.py": STUB_BLOCKED,
                "inspect_gate0_log.py": STUB_PASS,
                "inspect_gate1_session.py": STUB_PASS,
                "inspect_gate2_shot.py": STUB_PASS,
                "inspect_gate3_whisper.py": STUB_PASS,
                "inspect_gate4_slicer.py": STUB_PASS,
                "inspect_gate5_provider.py": STUB_GATE5,
                "inspect_gate6_pack.py": STUB_PASS,
            },
        )
        session = Path(tmp) / "session"
        session.mkdir()
        log = Path(tmp) / "agent.jsonl"
        log.write_text("{}\n", encoding="utf-8")
        result = _run(
            [
                "--session",
                str(session),
                "--log",
                str(log),
                "--log-start-line",
                "1",
                "--token",
                "T",
                "--passphrase",
                "P",
                "--manual-video-scrub-ok",
                "--manual-audio-scrub-ok",
                "--av-offset-ms",
                "1",
                "--ptt-temp-deleted-ok",
            ],
            scripts_dir=scripts,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        summary = json.loads(result.stdout)
        assert summary["gates"]["minus0"]["status"] == "blocked"
        assert "minus0" in summary["blocked"]


def test_strict_fails_on_blocked_or_manual() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        scripts = Path(tmp)
        _write_stubs(
            scripts,
            {
                "inspect_gate_minus1.py": STUB_PASS,
                "inspect_gate_minus0.py": STUB_PASS,
                "inspect_gate0_log.py": STUB_PASS,
                "inspect_gate1_session.py": STUB_MANUAL,
                "inspect_gate2_shot.py": STUB_PASS,
                "inspect_gate3_whisper.py": STUB_PASS,
                "inspect_gate4_slicer.py": STUB_PASS,
                "inspect_gate5_provider.py": STUB_GATE5,
                "inspect_gate6_pack.py": STUB_PASS,
            },
        )
        artifact = {
            "minus0": {
                "session": str(Path(tmp) / "s0"),
                "log": str(Path(tmp) / "log.jsonl"),
                "log_start_line": 1,
            },
            "0": {"log": str(Path(tmp) / "log.jsonl"), "log_start_line": 1},
            "1/2": {
                "session": str(Path(tmp) / "s1"),
                "log": str(Path(tmp) / "log.jsonl"),
                "log_start_line": 1,
                "token": "T",
                "passphrase": "P",
                "manual_video_scrub_ok": True,
                "manual_audio_scrub_ok": True,
                "av_offset_ms": 1,
                "ptt_temp_deleted_ok": True,
            },
            "3": {
                "session": str(Path(tmp) / "s3"),
                "target_media_seconds": 300,
                "target_wall_seconds": 12,
            },
            "4": {"session": str(Path(tmp) / "s4"), "chrome_playback_ok": True},
            "5": {
                "denied": {
                    "session": str(Path(tmp) / "d"),
                    "log": str(Path(tmp) / "log.jsonl"),
                    "log_start_line": 1,
                },
                "invalid_key": {
                    "session": str(Path(tmp) / "i"),
                    "log": str(Path(tmp) / "log.jsonl"),
                    "log_start_line": 1,
                },
                "retired_model": {
                    "session": str(Path(tmp) / "r"),
                    "log": str(Path(tmp) / "log.jsonl"),
                    "log_start_line": 1,
                },
                "evidence": {"session": str(Path(tmp) / "e")},
            },
            "6": {"session": str(Path(tmp) / "s6")},
        }
        for path in [
            Path(tmp) / "s0",
            Path(tmp) / "s1",
            Path(tmp) / "s3",
            Path(tmp) / "s4",
            Path(tmp) / "d",
            Path(tmp) / "i",
            Path(tmp) / "r",
            Path(tmp) / "e",
            Path(tmp) / "s6",
        ]:
            path.mkdir()
        (Path(tmp) / "log.jsonl").write_text("{}\n", encoding="utf-8")
        map_path = Path(tmp) / "map.json"
        map_path.write_text(json.dumps(artifact), encoding="utf-8")
        result = _run(
            ["--artifact-map", str(map_path), "--strict"],
            scripts_dir=scripts,
        )
        assert result.returncode == 1, result.stdout + result.stderr
        summary = json.loads(result.stdout)
        assert summary["gates"]["1"]["status"] == "manual_required"
        assert "1" in summary["manual_required"]


def test_minus0_failure_stops_guided_later_gates() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        scripts = Path(tmp)
        _write_stubs(
            scripts,
            {
                "inspect_gate_minus1.py": STUB_PASS,
                "inspect_gate_minus0.py": STUB_FAIL,
                "inspect_gate0_log.py": STUB_PASS,
                "inspect_gate1_session.py": STUB_PASS,
                "inspect_gate2_shot.py": STUB_PASS,
                "inspect_gate3_whisper.py": STUB_PASS,
                "inspect_gate4_slicer.py": STUB_PASS,
                "inspect_gate5_provider.py": STUB_GATE5,
                "inspect_gate6_pack.py": STUB_PASS,
            },
        )
        session = Path(tmp) / "session"
        session.mkdir()
        log = Path(tmp) / "agent.jsonl"
        log.write_text("{}\n", encoding="utf-8")
        result = _run(
            [
                "--guided",
                "--session",
                str(session),
                "--log",
                str(log),
                "--log-start-line",
                "1",
                "--token",
                "T",
                "--passphrase",
                "P",
            ],
            scripts_dir=scripts,
        )
        assert result.returncode == 1, result.stdout + result.stderr
        summary = json.loads(result.stdout)
        assert summary["gates"]["minus0"]["status"] == "fail"
        for name in ("0", "1", "2", "3", "4", "5", "6"):
            assert summary["gates"][name]["status"] == "blocked"
            assert "skipped_after_minus0_failure" in summary["gates"][name]["blocked_reasons"]


def test_gate1_blocked_prevents_gates_3_to_6() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        scripts = Path(tmp)
        _write_stubs(
            scripts,
            {
                "inspect_gate_minus1.py": STUB_PASS,
                "inspect_gate_minus0.py": STUB_PASS,
                "inspect_gate0_log.py": STUB_PASS,
                "inspect_gate1_session.py": STUB_BLOCKED,
                "inspect_gate2_shot.py": STUB_PASS,
                "inspect_gate3_whisper.py": STUB_PASS,
                "inspect_gate4_slicer.py": STUB_PASS,
                "inspect_gate5_provider.py": STUB_GATE5,
                "inspect_gate6_pack.py": STUB_PASS,
            },
        )
        session = Path(tmp) / "session"
        session.mkdir()
        log = Path(tmp) / "agent.jsonl"
        log.write_text("{}\n", encoding="utf-8")
        result = _run(
            [
                "--session",
                str(session),
                "--log",
                str(log),
                "--log-start-line",
                "1",
                "--token",
                "T",
                "--passphrase",
                "P",
            ],
            scripts_dir=scripts,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        summary = json.loads(result.stdout)
        assert summary["gates"]["1"]["status"] == "blocked"
        for name in ("3", "4", "5", "6"):
            assert summary["gates"][name]["status"] == "blocked"
            assert "blocked_until_gate1_pass" in summary["gates"][name]["blocked_reasons"]
        assert summary["gates"]["2"]["status"] == "pass"


def test_all_synthetic_passes_return_zero() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        scripts = Path(tmp)
        _write_stubs(
            scripts,
            {
                "inspect_gate_minus1.py": STUB_PASS,
                "inspect_gate_minus0.py": STUB_PASS,
                "inspect_gate0_log.py": STUB_PASS,
                "inspect_gate1_session.py": STUB_PASS,
                "inspect_gate2_shot.py": STUB_PASS,
                "inspect_gate3_whisper.py": STUB_PASS,
                "inspect_gate4_slicer.py": STUB_PASS,
                "inspect_gate5_provider.py": STUB_GATE5,
                "inspect_gate6_pack.py": STUB_PASS,
            },
        )
        for name in ("s0", "s1", "s3", "s4", "d", "i", "r", "e", "s6"):
            (Path(tmp) / name).mkdir()
        log = Path(tmp) / "log.jsonl"
        log.write_text("{}\n", encoding="utf-8")
        artifact = {
            "minus0": {
                "session": str(Path(tmp) / "s0"),
                "log": str(log),
                "log_start_line": 1,
            },
            "0": {"log": str(log), "log_start_line": 1},
            "1/2": {
                "session": str(Path(tmp) / "s1"),
                "log": str(log),
                "log_start_line": 1,
                "token": "T",
                "passphrase": "P",
                "manual_video_scrub_ok": True,
                "manual_audio_scrub_ok": True,
                "av_offset_ms": 1,
                "ptt_temp_deleted_ok": True,
            },
            "3": {
                "session": str(Path(tmp) / "s3"),
                "target_media_seconds": 300,
                "target_wall_seconds": 12,
            },
            "4": {"session": str(Path(tmp) / "s4"), "chrome_playback_ok": True},
            "5": {
                "denied": {
                    "session": str(Path(tmp) / "d"),
                    "log": str(log),
                    "log_start_line": 1,
                },
                "invalid_key": {
                    "session": str(Path(tmp) / "i"),
                    "log": str(log),
                    "log_start_line": 1,
                },
                "retired_model": {
                    "session": str(Path(tmp) / "r"),
                    "log": str(log),
                    "log_start_line": 1,
                },
                "evidence": {"session": str(Path(tmp) / "e")},
            },
            "6": {"session": str(Path(tmp) / "s6")},
        }
        map_path = Path(tmp) / "map.json"
        map_path.write_text(json.dumps(artifact), encoding="utf-8")
        result = _run(
            ["--artifact-map", str(map_path), "--strict"],
            scripts_dir=scripts,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        summary = json.loads(result.stdout)
        assert summary["failed"] == []
        assert summary["blocked"] == []
        assert summary["manual_required"] == []
        for name in ("minus1", "minus0", "0", "1", "2", "3", "4", "5", "6"):
            assert summary["gates"][name]["status"] == "pass"


def main() -> None:
    test_inspect_all_gates_mock_only()
    test_child_exit_0_malformed_json_fails()
    test_child_exit_2_is_blocked()
    test_strict_fails_on_blocked_or_manual()
    test_minus0_failure_stops_guided_later_gates()
    test_gate1_blocked_prevents_gates_3_to_6()
    test_all_synthetic_passes_return_zero()
    print("test_all_gates ok")


if __name__ == "__main__":
    main()
