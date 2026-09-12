from __future__ import annotations

import tempfile

import json
import subprocess
import sys
import zipfile
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from support import ROOT, _run

def test_inspect_minus0_fails_without_movie() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-minus0-empty-"))
    (session / "archive").mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(parents=True, exist_ok=True)
    result = _run("inspect_gate_minus0.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["session_mp4_exists"] is False


def test_inspect_minus0_requires_first_samples_when_log_given() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-minus0-samples-"))
    archive = session / "archive"
    archive.mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(parents=True, exist_ok=True)
    (archive / "session.mp4").write_bytes(b"ftyp")
    (archive / "audio.wav").write_bytes(b"RIFF")
    (archive / "capture-layout.json").write_text(
        json.dumps({"wav_start_media_seconds": 0.0}),
        encoding="utf-8",
    )
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "minus0.jsonl")
    log.write_text(json.dumps({"event": "launch"}) + "\n", encoding="utf-8")
    result = _run(
        "inspect_gate_minus0.py",
        ["--session", str(session), "--log", str(log)],
    )
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["first_sample_screen"] is False
    assert "first_sample_screen" in report["failed"]



def main() -> None:
    test_inspect_minus0_fails_without_movie()
    test_inspect_minus0_requires_first_samples_when_log_given()
    print("test_gate_minus0 ok")


if __name__ == "__main__":
    main()
