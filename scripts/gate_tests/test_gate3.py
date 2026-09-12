from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from support import ROOT, _run

def test_inspect_gate3_blocked_without_transcript() -> None:
    session = Path("/tmp/scrumtrace-gate3-empty")
    (session / "archive").mkdir(parents=True, exist_ok=True)
    result = _run("inspect_gate3_whisper.py", ["--session", str(session)])
    assert result.returncode == 2


def test_inspect_gate3_fails_when_dual_pass_missing() -> None:
    session = Path("/tmp/scrumtrace-gate3-dual")
    archive = session / "archive"
    archive.mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(parents=True, exist_ok=True)
    (archive / "full_transcript.json").write_text(
        json.dumps({"segments": [{"start": 0, "end": 1, "text": "hi"}], "sources": ["room"]}),
        encoding="utf-8",
    )
    (archive / "pipeline-timing.json").write_text(
        json.dumps({"whisper_wall_seconds": 12.0, "whisper_sources": ["room"], "whisper_incomplete": False}),
        encoding="utf-8",
    )
    (archive / "capture-layout.json").write_text(
        json.dumps({"microphone_wav": True, "system_audio_in_movie": True}),
        encoding="utf-8",
    )
    result = _run("inspect_gate3_whisper.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["dual_pass_when_both_captured"] is False



def main() -> None:
    test_inspect_gate3_blocked_without_transcript()
    test_inspect_gate3_fails_when_dual_pass_missing()
    print("test_gate3 ok")


if __name__ == "__main__":
    main()
