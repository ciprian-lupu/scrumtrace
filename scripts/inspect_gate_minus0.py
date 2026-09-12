#!/usr/bin/env python3
"""Inspect a 30-second ScrumTrace session for Gate −0.

A pass here is not a GATE_LOG.md PASS. Do not invent PASS cells.

Usage:
  python3 scripts/inspect_gate_minus0.py --session ~/Movies/ScrumTrace/sessions/<id> \\
    --log ~/Library/Logs/ScrumTrace/agent.jsonl
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    LogWindowError,
    die_missing,
    emit,
    filter_rows_for_session,
    first_run_id,
    first_sample_types,
    ffprobe_bin,
    ffprobe_duration,
    is_json_number,
    read_json_object,
    read_jsonl_window,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--log", type=Path, default=None)
    parser.add_argument("--log-start-line", type=int, default=None)
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    archive = session / "archive"
    export = session / "export"
    mp4 = archive / "session.mp4"
    wav = archive / "audio.wav"
    layout = read_json_object(archive / "capture-layout.json")
    report: dict[str, object] = {
        "gate": "minus0",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
    }
    if not session.is_dir():
        return die_missing(report)

    probe = ffprobe_bin()
    mp4_duration = ffprobe_duration(mp4, probe) if probe else None
    wav_duration = ffprobe_duration(wav, probe) if probe else None
    wav_start = layout.get("wav_start_media_seconds") if layout else None
    samples: set[str] = set()
    if args.log is not None:
        log_path = args.log.expanduser()
        report["log"] = str(log_path)
        report["log_start_line"] = args.log_start_line
        try:
            rows = read_jsonl_window(log_path, args.log_start_line)
        except LogWindowError as exc:
            report["checks"] = {"log_window": False}
            return emit(
                report,
                [],
                status="blocked",
                blocked=True,
                blocked_reasons=[exc.reason],
            )
        manifest = read_json_object(session / "session.manifest.json") or {}
        session_id = str(manifest.get("session_id") or session.name)
        rows = filter_rows_for_session(rows, session_id)
        run_id = first_run_id(rows)
        report["session_id"] = session_id
        report["run_id"] = run_id
        samples = first_sample_types(rows)


    checks: dict[str, object] = {
        "archive_dir": archive.is_dir(),
        "export_dir": export.is_dir(),
        "session_mp4_exists": mp4.is_file(),
        "audio_wav_exists": wav.is_file(),
        "session_mp4_has_duration": mp4_duration is not None and mp4_duration > 0,
        "audio_wav_has_duration": wav_duration is not None and wav_duration > 0,
        "capture_layout_exists": layout is not None,
        "wav_start_present": is_json_number(wav_start),
        "first_sample_screen": "screen" in samples,
        "first_sample_audio": "audio" in samples,
        "first_sample_wav": "wav" in samples,
        "media_durations": {
            "session_mp4": mp4_duration,
            "audio_wav": wav_duration,
        },
        "first_samples": sorted(samples),
    }
    required = [
        "archive_dir",
        "export_dir",
        "session_mp4_exists",
        "audio_wav_exists",
    ]
    if probe is not None:
        required.extend(["session_mp4_has_duration", "audio_wav_has_duration"])
    if wav.is_file():
        required.extend(["capture_layout_exists", "wav_start_present"])
    if args.log is not None:
        required.extend(["first_sample_screen", "first_sample_audio", "first_sample_wav"])
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
