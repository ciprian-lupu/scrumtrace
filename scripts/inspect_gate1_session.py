#!/usr/bin/env python3
"""Inspect a ScrumTrace session folder against Gate 1 pause-absence rules.

Usage:
  python3 scripts/inspect_gate1_session.py \\
    --session ~/Movies/ScrumTrace/sessions/<id> \\
    --token ST-G1-PAUSE-TOKEN-9F3C \\
    --passphrase 'orchid lantern seven'
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def strings_blob(path: Path) -> str:
    if not path.is_file():
        return ""
    try:
        out = subprocess.run(
            ["strings", "-n", "6", str(path)],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
        )
        return out.stdout
    except OSError:
        return path.read_bytes()[: 2_000_000].decode("utf-8", errors="replace")


def contains(hay: str, needle: str) -> bool:
    if not needle:
        return False
    return needle.lower() in hay.lower()


def list_pngs(folder: Path) -> list[str]:
    if not folder.is_dir():
        return []
    return sorted(p.name for p in folder.iterdir() if p.suffix.lower() == ".png")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--passphrase", required=True)
    parser.add_argument("--shot-before-pause", default="", help="PNG names that existed before the pause test")
    args = parser.parse_args()

    session: Path = args.session.expanduser().resolve()
    token = args.token.strip()
    phrase = args.passphrase.strip()
    archive = session / "archive"
    export = session / "export"

    report: dict[str, object] = {
        "session": str(session),
        "token": token,
        "passphrase": phrase,
        "exists": session.is_dir(),
        "archive_dir": archive.is_dir(),
        "export_dir": export.is_dir(),
        "checks": {},
    }
    if not session.is_dir():
        print(json.dumps(report, indent=2))
        return 2

    mp4 = archive / "session.mp4"
    wav = archive / "audio.wav"
    transcript = archive / "full_transcript.json"
    events = archive / "events.jsonl"
    shots = archive / "shots"
    zip_path = export / "session-pack.zip"

    mp4_text = strings_blob(mp4) if mp4.is_file() else ""
    wav_text = strings_blob(wav) if wav.is_file() else ""
    transcript_text = read_text(transcript)
    events_text = read_text(events)
    export_text = ""
    for walk_root, _, files in os.walk(export):
        for name in files:
            path = Path(walk_root) / name
            if path.suffix.lower() in {".md", ".txt", ".html", ".json"}:
                export_text += "\n" + read_text(path)
            elif path.suffix.lower() in {".zip", ".mp4", ".wav"}:
                export_text += "\n" + strings_blob(path)

    pngs = list_pngs(shots)
    before = {n for n in args.shot_before_pause.split(",") if n}
    new_pngs = [n for n in pngs if n not in before] if before else []

    checks = {
        "session_mp4_exists": mp4.is_file(),
        "session_mp4_missing_token": (not contains(mp4_text, token)) if mp4.is_file() else False,
        "audio_wav_exists": wav.is_file(),
        "audio_wav_missing_token": (not contains(wav_text, token)) if wav.is_file() else False,
        "audio_wav_missing_passphrase": (not contains(wav_text, phrase)) if wav.is_file() else False,
        "transcript_missing_token": not contains(transcript_text, token),
        "transcript_missing_passphrase": not contains(transcript_text, phrase),
        "events_missing_token": not contains(events_text, token),
        "no_new_shot_png_during_pause": (new_pngs == []) if before else None,
        "export_missing_token": not contains(export_text, token),
        "export_missing_passphrase": not contains(export_text, phrase),
        "shot_pngs": pngs,
        "new_pngs_after_marker": new_pngs,
        "zip_exists": zip_path.is_file(),
        "zip_bytes": zip_path.stat().st_size if zip_path.is_file() else 0,
    }
    report["checks"] = checks
    print(json.dumps(report, indent=2))

    required = [
        "session_mp4_missing_token",
        "audio_wav_missing_token",
        "audio_wav_missing_passphrase",
        "transcript_missing_token",
        "transcript_missing_passphrase",
        "events_missing_token",
        "export_missing_token",
        "export_missing_passphrase",
    ]
    failed = [key for key in required if checks.get(key) is not True]
    if before and checks.get("no_new_shot_png_during_pause") is not True:
        failed.append("no_new_shot_png_during_pause")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
