#!/usr/bin/env python3
"""Inspect a ScrumTrace session folder against Gate 1 pause-absence rules.

ASCII scans are leak diagnostics only. Closing Gate 1 also requires explicit
human media scrub flags and a measured A/V offset.

A pass here is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate1_session.py \\
    --session ~/Movies/ScrumTrace/sessions/<id> \\
    --token ST-G1-PAUSE-TOKEN-9F3C \\
    --passphrase 'orchid lantern seven' \\
    --manual-video-scrub-ok \\
    --manual-audio-scrub-ok \\
    --av-offset-ms 12.0 \\
    --ptt-temp-deleted-ok
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import emit

MEDIA_SCRUB_NOTE = (
    "ASCII media scans are diagnostics only; visual/audio absence requires "
    "manual scrub flags (Part F.2)"
)
# Measured A/V sync target — not a product guarantee.
AV_OFFSET_TARGET_MS = 50.0
PAUSE_WALL_TOLERANCE_S = 0.010
MEDIA_WALL_PAUSE_TOLERANCE_S = 0.5


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


def finite_positive(value: object) -> bool:
    if not is_json_number(value):
        return False
    number = float(value)
    return math.isfinite(number) and number > 0.0


def finite_nonnegative(value: object) -> bool:
    if not is_json_number(value):
        return False
    number = float(value)
    return math.isfinite(number) and number >= 0.0


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
        "manifest_pauses_closed",
        "manifest_pause_count_ge_3",
        "manifest_media_ge_1200",
        "pause_durations_consistent",
        "media_matches_wall_minus_pauses",
        "capture_layout_exists",
        "wav_start_present",
        "av_offset_finite_nonnegative",
        "av_offset_within_target_ms",
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


def pause_entries(manifest: dict[str, object] | None) -> list[dict[str, object]]:
    if manifest is None:
        return []
    pauses = manifest.get("pauses")
    if not isinstance(pauses, list):
        return []
    return [pause for pause in pauses if isinstance(pause, dict)]


def manifest_pauses_closed(manifest: dict[str, object] | None) -> bool:
    pauses = pause_entries(manifest)
    if not pauses:
        return False
    return all(pause.get("resume_wall") is not None for pause in pauses)


def manifest_pause_count(manifest: dict[str, object] | None) -> int:
    return len(pause_entries(manifest))


def manifest_media_seconds(manifest: dict[str, object] | None) -> float | None:
    if manifest is None:
        return None
    duration = manifest.get("duration")
    if not isinstance(duration, dict):
        return None
    media_seconds = duration.get("media_seconds")
    if not is_json_number(media_seconds):
        return None
    return float(media_seconds)


def manifest_wall_seconds(manifest: dict[str, object] | None) -> float | None:
    if manifest is None:
        return None
    duration = manifest.get("duration")
    if not isinstance(duration, dict):
        return None
    wall_seconds = duration.get("wall_seconds")
    if not is_json_number(wall_seconds):
        return None
    return float(wall_seconds)


def pause_durations_consistent(manifest: dict[str, object] | None) -> bool:
    """Every closed pause has finite positive duration matching resume−pause within 10 ms."""
    pauses = pause_entries(manifest)
    if len(pauses) < 3:
        return False
    for pause in pauses:
        pause_wall = pause.get("pause_wall")
        resume_wall = pause.get("resume_wall")
        duration = pause.get("duration")
        if resume_wall is None:
            return False
        if not finite_nonnegative(pause_wall) or not finite_nonnegative(resume_wall):
            return False
        if not finite_positive(duration):
            return False
        expected = float(resume_wall) - float(pause_wall)
        if expected <= 0 or not math.isfinite(expected):
            return False
        if abs(float(duration) - expected) > PAUSE_WALL_TOLERANCE_S:
            return False
    return True


def summed_pause_seconds(manifest: dict[str, object] | None) -> float | None:
    pauses = pause_entries(manifest)
    if not pauses:
        return None
    total = 0.0
    for pause in pauses:
        duration = pause.get("duration")
        if not finite_positive(duration):
            return None
        total += float(duration)
    return total


def media_matches_wall_minus_pauses(manifest: dict[str, object] | None) -> bool:
    """media_seconds ≈ wall_seconds − Σ pause durations."""
    media = manifest_media_seconds(manifest)
    wall = manifest_wall_seconds(manifest)
    pauses = summed_pause_seconds(manifest)
    if media is None or wall is None or pauses is None:
        return False
    if not math.isfinite(media) or not math.isfinite(wall) or not math.isfinite(pauses):
        return False
    expected = wall - pauses
    return abs(media - expected) <= MEDIA_WALL_PAUSE_TOLERANCE_S


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


def parse_av_offset_ms(raw: str | None) -> float | None:
    if raw is None or raw == "":
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    if not math.isfinite(value):
        return None
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--passphrase", required=True)
    parser.add_argument(
        "--manual-video-scrub-ok",
        action="store_true",
        help="Human confirms paused video frames omit the on-screen token",
    )
    parser.add_argument(
        "--manual-audio-scrub-ok",
        action="store_true",
        help="Human confirms paused audio omits the spoken passphrase",
    )
    parser.add_argument(
        "--av-offset-ms",
        default=None,
        help=(
            "Measured A/V offset in milliseconds at the Gate 1 sync mark "
            f"(target ≤ {AV_OFFSET_TARGET_MS:g} ms, not a guarantee)"
        ),
    )
    parser.add_argument(
        "--ptt-temp-deleted-ok",
        action="store_true",
        help="Human confirms Hold-to-Talk temp audio was deleted after pause abort",
    )
    args = parser.parse_args()

    session: Path = args.session.expanduser().resolve()
    token = args.token.strip()
    phrase = args.passphrase.strip()
    archive = session / "archive"
    export = session / "export"
    manifest_path = session / "session.manifest.json"

    manual_video = bool(args.manual_video_scrub_ok)
    manual_audio = bool(args.manual_audio_scrub_ok)
    ptt_temp_ok = bool(args.ptt_temp_deleted_ok)
    av_offset = parse_av_offset_ms(args.av_offset_ms)
    human_complete = (
        manual_video and manual_audio and ptt_temp_ok and av_offset is not None
    )

    report: dict[str, object] = {
        "gate": "1",
        "session": str(session),
        "token": token,
        "passphrase": phrase,
        "exists": session.is_dir(),
        "archive_dir": archive.is_dir(),
        "export_dir": export.is_dir(),
        "checks": {},
        "manual": {
            "video_scrub_ok": manual_video,
            "audio_scrub_ok": manual_audio,
            "ptt_temp_deleted_ok": ptt_temp_ok,
            "av_offset_ms": av_offset,
            "av_offset_target_ms": AV_OFFSET_TARGET_MS,
            "av_offset_note": (
                f"≤ {AV_OFFSET_TARGET_MS:g} ms is a measured target, not a guarantee"
            ),
        },
    }
    if not session.is_dir():
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["missing_session"],
        )

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

    ffprobe = shutil.which("ffprobe")
    mp4_duration: float | None = None
    wav_duration: float | None = None
    session_mp4_has_duration: bool | None
    wav_within_half_second_of_mp4: bool | None
    manifest_media_matches_durations: bool | None

    if ffprobe is None:
        print(
            "warning: ffprobe not found; skipping media duration checks",
            file=sys.stderr,
        )
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
        manifest_early = read_manifest(manifest_path)
        manifest_media_matches_durations = manifest_media_matches(
            mp4_duration, manifest_early
        )

    manifest = read_manifest(manifest_path)
    pause_count = manifest_pause_count(manifest)
    media_seconds = manifest_media_seconds(manifest)
    wall_seconds = manifest_wall_seconds(manifest)
    pause_sum = summed_pause_seconds(manifest)

    av_offset_finite_nonnegative = av_offset is not None and av_offset >= 0.0
    # Strict upper bound: 50.0 passes; anything larger fails the measured target.
    av_offset_within_target = (
        av_offset_finite_nonnegative
        and av_offset is not None
        and av_offset <= AV_OFFSET_TARGET_MS
    )

    checks: dict[str, object] = {
        "session_mp4_exists": mp4.is_file(),
        "session_mp4_no_ascii_token": (
            (not contains(mp4_text, token)) if mp4.is_file() else False
        ),
        "audio_wav_exists": wav.is_file(),
        "audio_wav_no_ascii_token": (
            (not contains(wav_text, token)) if wav.is_file() else False
        ),
        "audio_wav_no_ascii_passphrase": (
            (not contains(wav_text, phrase)) if wav.is_file() else False
        ),
        "capture_layout_exists": capture_layout_exists,
        "wav_start_media_seconds": wav_start,
        "wav_start_present": wav_start_present,
        "transcript_exists": transcript.is_file(),
        "transcript_missing_token": not contains(transcript_text, token),
        "transcript_missing_passphrase": not contains(transcript_text, phrase),
        "events_exists": events.is_file(),
        "events_missing_token": not contains(events_text, token),
        "export_missing_token": not contains(export_text, token),
        "export_missing_passphrase": not contains(export_text, phrase),
        "shot_pngs": pngs,
        "annotated_pngs": annotated_pngs,
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
        "manifest_wall_seconds": wall_seconds,
        "manifest_pause_sum_seconds": pause_sum,
        "manifest_media_ge_1200": media_seconds is not None and media_seconds >= 1200,
        "pause_durations_consistent": pause_durations_consistent(manifest),
        "media_matches_wall_minus_pauses": media_matches_wall_minus_pauses(manifest),
        "av_offset_ms": av_offset,
        "av_offset_finite_nonnegative": av_offset_finite_nonnegative,
        "av_offset_within_target_ms": av_offset_within_target,
        "manual_video_scrub_ok": manual_video,
        "manual_audio_scrub_ok": manual_audio,
        "ptt_temp_deleted_ok": ptt_temp_ok,
    }
    required = gate1_required_keys(
        audio_wav_exists=wav.is_file(),
        ffprobe_available=ffprobe is not None,
    )
    failed = [key for key in required if checks.get(key) is not True]
    report["checks"] = checks
    report["required"] = required
    print(MEDIA_SCRUB_NOTE, file=sys.stderr)

    if not human_complete:
        missing_manual: list[str] = []
        if not manual_video:
            missing_manual.append("manual-video-scrub-ok")
        if not manual_audio:
            missing_manual.append("manual-audio-scrub-ok")
        if av_offset is None:
            missing_manual.append("av-offset-ms")
        if not ptt_temp_ok:
            missing_manual.append("ptt-temp-deleted-ok")
        return emit(
            report,
            failed,
            status="manual_required",
            blocked=True,
            blocked_reasons=["missing_manual_assertions"],
            manual_checks=missing_manual,
        )

    if failed:
        return emit(report, failed, status="fail")
    return emit(report, [], status="pass")


if __name__ == "__main__":
    sys.exit(main())
