from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

TOKEN = "ST-G1-PAUSE-TOKEN-9F3C"
PASSPHRASE = "orchid lantern seven"

GOOD_PAUSES = [
    {"pause_wall": 10.0, "resume_wall": 20.0, "duration": 10.0},
    {"pause_wall": 30.0, "resume_wall": 40.0, "duration": 10.0},
    {"pause_wall": 50.0, "resume_wall": 60.0, "duration": 10.0},
]


def _write_gate1_fake_session(
    session: Path,
    *,
    layout: object | None = ...,
    pauses: list[dict[str, object]] | None = None,
    media_seconds: float = 1200.0,
    wall_seconds: float | None = None,
    token_in_movie: bool = False,
    token_in_zip: bool = False,
) -> None:
    archive = session / "archive"
    export = session / "export"
    shots = archive / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    mp4 = f"xxxx {TOKEN} yyyy" if token_in_movie else "xxxx clean-mp4 yyyy"
    wav = f"RIFF....{PASSPHRASE}" if token_in_movie else "RIFF....clean-wav"
    (archive / "session.mp4").write_bytes(mp4.encode())
    (archive / "audio.wav").write_bytes(wav.encode())
    (archive / "full_transcript.json").write_text("{}", encoding="utf-8")
    (archive / "events.jsonl").write_text("{}\n", encoding="utf-8")
    if pauses is None:
        pauses = []
    if wall_seconds is None:
        wall_seconds = media_seconds + sum(float(p.get("duration") or 0) for p in pauses)
    (session / "session.manifest.json").write_text(
        json.dumps(
            {
                "duration": {
                    "media_seconds": media_seconds,
                    "wall_seconds": wall_seconds,
                },
                "pauses": pauses,
            }
        ),
        encoding="utf-8",
    )
    layout_path = archive / "capture-layout.json"
    if layout is None:
        layout_path.unlink(missing_ok=True)
    elif layout is ...:
        layout_path.write_text(
            json.dumps(
                {
                    "microphone_wav": True,
                    "system_audio_in_movie": True,
                    "wav_start_media_seconds": 0.0,
                }
            ),
            encoding="utf-8",
        )
    else:
        payload = layout if isinstance(layout, str) else json.dumps(layout)
        layout_path.write_text(payload, encoding="utf-8")
    with zipfile.ZipFile(export / "session-pack.zip", "w") as zf:
        zf.writestr("notes.txt", f"leak {TOKEN}" if token_in_zip else "ok")


def _run_gate1(
    session: Path,
    *,
    manual: bool = False,
    av_offset_ms: str | None = None,
    extra: list[str] | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    script = ROOT / "scripts" / "inspect_gate1_session.py"
    args = [
        sys.executable,
        str(script),
        "--session",
        str(session),
        "--token",
        TOKEN,
        "--passphrase",
        PASSPHRASE,
    ]
    if manual:
        args.extend(
            [
                "--manual-video-scrub-ok",
                "--manual-audio-scrub-ok",
                "--ptt-temp-deleted-ok",
                "--av-offset-ms",
                av_offset_ms if av_offset_ms is not None else "12",
            ]
        )
    elif av_offset_ms is not None:
        args.extend(["--av-offset-ms", av_offset_ms])
    if extra:
        args.extend(extra)
    return subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def _run(script: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts" / script), *args],
        check=False,
        capture_output=True,
        text=True,
    )


def _ffprobe_stub_env(duration: str = "1200.0") -> dict[str, str]:
    import os
    import tempfile
    from pathlib import Path as P

    bindir = P(tempfile.mkdtemp(prefix="scrumtrace-ffprobe-"))
    stub = bindir / "ffprobe"
    stub.write_text(f"#!/bin/sh\necho {duration}\n", encoding="utf-8")
    stub.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{bindir}:{env.get('PATH', '')}"
    return env
