from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from support import ROOT, _write_gate1_fake_session, _run_gate1, _run

def test_inspect_gate1_fails_when_token_is_in_movie() -> None:
    script = ROOT / "scripts" / "inspect_gate1_session.py"
    session = Path("/tmp/scrumtrace-inspect-gate1")
    archive = session / "archive"
    export = session / "export"
    shots = archive / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    (archive / "session.mp4").write_bytes(b"xxxx ST-G1-PAUSE-TOKEN-9F3C yyyy")
    (archive / "audio.wav").write_bytes(b"RIFF....orchid lantern seven")
    (archive / "full_transcript.json").write_text("{}", encoding="utf-8")
    (archive / "events.jsonl").write_text("{}\n", encoding="utf-8")
    (session / "session.manifest.json").write_text(
        json.dumps({"duration": {"media_seconds": 1}, "pauses": []}),
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "--session",
            str(session),
            "--token",
            "ST-G1-PAUSE-TOKEN-9F3C",
            "--passphrase",
            "orchid lantern seven",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["session_mp4_no_ascii_token"] is False
    assert report["checks"]["audio_wav_no_ascii_passphrase"] is False


def test_inspect_gate1_fails_when_wav_exists_without_layout() -> None:
    session = Path("/tmp/scrumtrace-inspect-gate1-no-layout")
    _write_gate1_fake_session(session, layout=None)
    result = _run_gate1(session)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["capture_layout_exists"] is False
    assert report["checks"]["wav_start_media_seconds"] is None
    assert report["checks"]["wav_start_present"] is False
    assert "capture_layout_exists" in report["required"]
    assert "wav_start_present" in report["required"]
    assert "capture_layout_exists" in report["failed"]
    assert "wav_start_present" in report["failed"]


def test_inspect_gate1_reports_wav_start_when_layout_present() -> None:
    session = Path("/tmp/scrumtrace-inspect-gate1-with-layout")
    _write_gate1_fake_session(
        session,
        layout={
            "microphone_wav": True,
            "system_audio_in_movie": True,
            "wav_start_media_seconds": 0.12,
        },
    )
    result = _run_gate1(session)
    report = json.loads(result.stdout)
    assert report["checks"]["capture_layout_exists"] is True
    assert report["checks"]["wav_start_media_seconds"] == 0.12
    assert report["checks"]["wav_start_present"] is True
    assert "capture_layout_exists" in report["required"]
    assert "wav_start_present" in report["required"]
    assert "capture_layout_exists" not in report["failed"]
    assert "wav_start_present" not in report["failed"]


def test_inspect_gate1_fails_when_pause_count_or_duration_short() -> None:
    session = Path("/tmp/scrumtrace-inspect-gate1-short")
    _write_gate1_fake_session(
        session,
        layout={
            "microphone_wav": True,
            "system_audio_in_movie": True,
            "wav_start_media_seconds": 0.0,
        },
    )
    result = _run_gate1(session)
    report = json.loads(result.stdout)
    assert result.returncode == 1
    assert report["checks"]["manifest_pause_count_ge_3"] is False
    assert report["checks"]["manifest_media_ge_1200"] is False
    assert "manifest_pause_count_ge_3" in report["required"]
    assert "manifest_media_ge_1200" in report["required"]
    assert "manifest_pause_count_ge_3" in report["failed"]
    assert "manifest_media_ge_1200" in report["failed"]



def main() -> None:
    test_inspect_gate1_fails_when_token_is_in_movie()
    test_inspect_gate1_fails_when_wav_exists_without_layout()
    test_inspect_gate1_reports_wav_start_when_layout_present()
    test_inspect_gate1_fails_when_pause_count_or_duration_short()
    print("test_gate1 ok")


if __name__ == "__main__":
    main()
