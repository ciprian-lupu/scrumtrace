from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def _write_gate1_fake_session(session: Path, *, layout: object | None) -> None:
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
    layout_path = archive / "capture-layout.json"
    if layout is None:
        layout_path.unlink(missing_ok=True)
    else:
        payload = layout if isinstance(layout, str) else json.dumps(layout)
        layout_path.write_text(payload, encoding="utf-8")


def _run_gate1(session: Path) -> subprocess.CompletedProcess[str]:
    script = ROOT / "scripts" / "inspect_gate1_session.py"
    return subprocess.run(
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


def _run(script: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts" / script), *args],
        check=False,
        capture_output=True,
        text=True,
    )

