#!/usr/bin/env python3
"""Inspect a ScrumTrace session folder against Gate 1 pause-absence rules.

Usage:
  python3 scripts/inspect_gate1_session.py \\
    --session ~/Movies/ScrumTrace/sessions/<id> \\
    --token ST-G1-PAUSE-TOKEN-9F3C \\
    --passphrase 'orchid lantern seven' \\
    --shot-before-pause "$BEFORE"
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

MEDIA_SCRUB_NOTE = (
    "media rows require a manual scrub at each pause t_media (Part F.2)"
)


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
        return path.read_bytes()[:2_000_000].decode("utf-8", errors="replace")


def strings_bytes(data: bytes) -> str:
    if not data:
        return ""
    try:
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(data)
            path = Path(tmp.name)
        try:
            return strings_blob(path)
        finally:
            path.unlink(missing_ok=True)
    except OSError:
        return data[:2_000_000].decode("utf-8", errors="replace")


def contains(hay: str, needle: str) -> bool:
    if not needle:
        return False
    return needle.lower() in hay.lower()


def list_shot_pngs(folder: Path) -> tuple[list[str], list[str]]:
    if not folder.is_dir():
        return [], []
    raw: list[str] = []
    annotated: list[str] = []
    for entry in folder.iterdir():
        if entry.suffix.lower() != ".png":
            continue
        if entry.name.endswith(".annotated.png"):
            annotated.append(entry.name)
        else:
            raw.append(entry.name)
    return sorted(raw), sorted(annotated)


def ffprobe_duration(path: Path, ffprobe: str) -> float | None:
    if not path.is_file():
        return None
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        line = out.stdout.strip()
        if line:
            return float(line)
    except (OSError, ValueError):
        pass
    return None


def read_manifest(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def read_capture_layout(path: Path) -> dict[str, object] | None:
    """Load archive/capture-layout.json. Missing or unreadable → None (fail-closed)."""
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def is_json_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def wav_start_media_seconds(layout: dict[str, object] | None) -> int | float | None:
    """Return wav_start_media_seconds when it is a JSON number; otherwise None.

    No numeric range is enforced here (hardware-only). Absent, null, or
    non-numeric values fail closed via wav_start_present.
    """
    if layout is None:
        return None
    value = layout.get("wav_start_media_seconds")
    if not is_json_number(value):
        return None
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, float):
        return value
    return None


def gate1_required_keys(*, audio_wav_exists: bool, ffprobe_available: bool) -> list[str]:
    """Required check names. Layout/wav_start only when archive/audio.wav exists."""
    required = [
        "session_mp4_exists",
        "session_mp4_no_ascii_token",
        "audio_wav_exists",
        "audio_wav_no_ascii_token",
        "audio_wav_no_ascii_passphrase",
        "transcript_exists",
        "transcript_missing_token",
        "transcript_missing_passphrase",
        "events_exists",
        "events_missing_token",
        "export_missing_token",
        "export_missing_passphrase",
        "no_new_shot_png_during_pause",
        "manifest_pauses_closed",
        "manifest_pause_count_ge_3",
        "manifest_media_ge_1200",
        "capture_layout_exists",
        "wav_start_present",
    ]
    if not audio_wav_exists:
        required = [
            key
            for key in required
            if key not in ("capture_layout_exists", "wav_start_present")
        ]
    if ffprobe_available:
        required.extend(
            [
                "session_mp4_has_duration",
                "wav_within_half_second_of_mp4",
                "manifest_media_matches_durations",
            ]
        )
    return required


def manifest_media_matches(mp4_duration: float | None, manifest: dict[str, object] | None) -> bool:
    if mp4_duration is None or manifest is None:
        return False
    duration = manifest.get("duration")
    if not isinstance(duration, dict):
        return False
    media_seconds = duration.get("media_seconds")
    if not isinstance(media_seconds, (int, float)):
        return False
    return abs(float(media_seconds) - mp4_duration) <= 0.5


def manifest_pauses_closed(manifest: dict[str, object] | None) -> bool:
    if manifest is None:
        return False
    pauses = manifest.get("pauses")
    if not isinstance(pauses, list):
        return False
    return all(
        isinstance(pause, dict) and pause.get("resume_wall") is not None for pause in pauses
    )


def manifest_pause_count(manifest: dict[str, object] | None) -> int:
    if manifest is None:
        return 0
    pauses = manifest.get("pauses")
    if not isinstance(pauses, list):
        return 0
    return len(pauses)


def manifest_media_seconds(manifest: dict[str, object] | None) -> float | None:
    if manifest is None:
        return None
    duration = manifest.get("duration")
    if not isinstance(duration, dict):
        return None
    media_seconds = duration.get("media_seconds")
    if not isinstance(media_seconds, (int, float)) or isinstance(media_seconds, bool):
        return None
    return float(media_seconds)


def zip_member_text(zip_path: Path) -> str:
    text = ""
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                suffix = Path(info.filename).suffix.lower()
                try:
                    payload = zf.read(info)
                except (KeyError, RuntimeError, zipfile.BadZipFile):
                    continue
                if suffix in {".md", ".txt", ".html", ".json"}:
                    text += "\n" + payload.decode("utf-8", errors="replace")
                elif suffix in {".mp4", ".wav"}:
                    text += "\n" + strings_bytes(payload)
    except (OSError, zipfile.BadZipFile):
        return text
    return text


def collect_export_text(export: Path) -> str:
    export_text = ""
    if not export.is_dir():
        return export_text
    for walk_root, _, files in os.walk(export):
        for name in files:
            path = Path(walk_root) / name
            suffix = path.suffix.lower()
            if suffix in {".md", ".txt", ".html", ".json"}:
                export_text += "\n" + read_text(path)
            elif suffix == ".zip":
                export_text += "\n" + zip_member_text(path)
            elif suffix in {".mp4", ".wav"}:
                export_text += "\n" + strings_blob(path)
    return export_text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--passphrase", required=True)
    parser.add_argument(
        "--shot-before-pause",
        default="",
        help="Comma-separated PNG names that existed before the pause test (empty means none)",
    )
    args = parser.parse_args()

    session: Path = args.session.expanduser().resolve()
    token = args.token.strip()
    phrase = args.passphrase.strip()
    archive = session / "archive"
    export = session / "export"
    manifest_path = session / "session.manifest.json"

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
    layout_path = archive / "capture-layout.json"
    transcript = archive / "full_transcript.json"
    events = archive / "events.jsonl"
    shots = archive / "shots"
    zip_path = export / "session-pack.zip"
    layout = read_capture_layout(layout_path)
    wav_start = wav_start_media_seconds(layout)
    capture_layout_exists = layout is not None
    wav_start_present = wav_start is not None

    mp4_text = strings_blob(mp4) if mp4.is_file() else ""
    wav_text = strings_blob(wav) if wav.is_file() else ""
    transcript_text = read_text(transcript)
    events_text = read_text(events)
    export_text = collect_export_text(export)

    pngs, annotated_pngs = list_shot_pngs(shots)
    before = {name for name in args.shot_before_pause.split(",") if name}
    new_pngs = [name for name in pngs if name not in before]

    ffprobe = shutil.which("ffprobe")
    mp4_duration: float | None = None
    wav_duration: float | None = None
    session_mp4_has_duration: bool | None
    wav_within_half_second_of_mp4: bool | None
    manifest_media_matches_durations: bool | None

    if ffprobe is None:
        print("warning: ffprobe not found; skipping media duration checks", file=sys.stderr)
        session_mp4_has_duration = None
        wav_within_half_second_of_mp4 = None
        manifest_media_matches_durations = None
    else:
        mp4_duration = ffprobe_duration(mp4, ffprobe)
        wav_duration = ffprobe_duration(wav, ffprobe)
        session_mp4_has_duration = mp4_duration is not None and mp4_duration > 0
        if mp4_duration is None or wav_duration is None:
            wav_within_half_second_of_mp4 = False
        else:
            wav_within_half_second_of_mp4 = abs(wav_duration - mp4_duration) <= 0.5
        manifest = read_manifest(manifest_path)
        manifest_media_matches_durations = manifest_media_matches(mp4_duration, manifest)

    manifest = read_manifest(manifest_path)
    pause_count = manifest_pause_count(manifest)
    media_seconds = manifest_media_seconds(manifest)

    checks: dict[str, object] = {
        "session_mp4_exists": mp4.is_file(),
        "session_mp4_no_ascii_token": (not contains(mp4_text, token)) if mp4.is_file() else False,
        "audio_wav_exists": wav.is_file(),
        "audio_wav_no_ascii_token": (not contains(wav_text, token)) if wav.is_file() else False,
        "audio_wav_no_ascii_passphrase": (not contains(wav_text, phrase)) if wav.is_file() else False,
        "capture_layout_exists": capture_layout_exists,
        "wav_start_media_seconds": wav_start,
        "wav_start_present": wav_start_present,
        "transcript_exists": transcript.is_file(),
        "transcript_missing_token": not contains(transcript_text, token),
        "transcript_missing_passphrase": not contains(transcript_text, phrase),
        "events_exists": events.is_file(),
        "events_missing_token": not contains(events_text, token),
        "no_new_shot_png_during_pause": new_pngs == [],
        "export_missing_token": not contains(export_text, token),
        "export_missing_passphrase": not contains(export_text, phrase),
        "shot_pngs": pngs,
        "annotated_pngs": annotated_pngs,
        "new_pngs_after_marker": new_pngs,
        "zip_exists": zip_path.is_file(),
        "zip_bytes": zip_path.stat().st_size if zip_path.is_file() else 0,
        "media_durations": {
            "session_mp4": mp4_duration,
            "audio_wav": wav_duration,
        },
        "session_mp4_has_duration": session_mp4_has_duration,
        "wav_within_half_second_of_mp4": wav_within_half_second_of_mp4,
        "manifest_media_matches_durations": manifest_media_matches_durations,
        "manifest_pauses_closed": manifest_pauses_closed(manifest),
        "manifest_pause_count": pause_count,
        "manifest_pause_count_ge_3": pause_count >= 3,
        "manifest_media_seconds": media_seconds,
        "manifest_media_ge_1200": media_seconds is not None and media_seconds >= 1200,
    }
    required = gate1_required_keys(
        audio_wav_exists=wav.is_file(),
        ffprobe_available=ffprobe is not None,
    )
    failed = [key for key in required if checks.get(key) is not True]
    report["checks"] = checks
    report["required"] = required
    report["failed"] = failed
    print(json.dumps(report, indent=2))
    print(MEDIA_SCRUB_NOTE, file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
