#!/usr/bin/env python3
"""Inspect a 30-second ScrumTrace session for Gate −0.

A pass here is not a GATE_LOG.md PASS. Do not invent PASS cells.

Usage:
  python3 scripts/inspect_gate_minus0.py --session ~/Movies/ScrumTrace/sessions/<id> \\
    --log ~/Library/Logs/ScrumTrace/agent.jsonl --log-start-line N
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    LogWindowError,
    die_missing,
    emit,
    event_name,
    filter_rows_for_first_run,
    filter_rows_for_session,
    first_sample_types,
    ffprobe_bin,
    ffprobe_duration,
    is_json_number,
    read_json_object,
    read_jsonl_window,
)

FATAL_EVENTS = {
    "capture_write_fail",
    "capture_stream_fail",
    "start_fail",
    "stop_capture_fail",
}


def finite_nonnegative(value: object) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    number = float(value)
    return math.isfinite(number) and number >= 0.0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--log-start-line", required=True, type=int)
    args = parser.parse_args()

    session: Path = args.session.expanduser().resolve()
    archive = session / "archive"
    export = session / "export"
    mp4 = archive / "session.mp4"
    wav = archive / "audio.wav"
    events = archive / "events.jsonl"
    layout_path = archive / "capture-layout.json"
    manifest_path = session / "session.manifest.json"
    layout = read_json_object(layout_path)
    manifest = read_json_object(manifest_path)

    report: dict[str, object] = {
        "gate": "minus0",
        "session": str(session),
        "exists": session.is_dir(),
        "log": str(args.log),
        "log_start_line": args.log_start_line,
        "checks": {},
    }
    if not session.is_dir():
        return die_missing(report)

    if args.log_start_line < 1:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["log_start_line_must_be_positive"],
        )

    probe = ffprobe_bin()
    if probe is None:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["ffprobe_unavailable"],
        )

    try:
        rows = read_jsonl_window(args.log.expanduser(), args.log_start_line)
        rows, run_id = filter_rows_for_first_run(rows)
    except LogWindowError as exc:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=[exc.reason],
        )

    session_id = str((manifest or {}).get("session_id") or session.name)
    rows = filter_rows_for_session(rows, session_id)
    report["session_id"] = session_id
    report["run_id"] = run_id

    mp4_duration = ffprobe_duration(mp4, probe)
    wav_duration = ffprobe_duration(wav, probe)
    wav_start = None
    if layout is not None:
        wav_start = layout.get("wav_start_media_seconds")
        if wav_start is None:
            wav_start = layout.get("wav_start_media_seconds")

    media_seconds = None
    if manifest is not None:
        duration = manifest.get("duration")
        if isinstance(duration, dict):
            media_seconds = duration.get("media_seconds")

    samples = first_sample_types(rows)
    # Also accept recorder_first_sample event naming from the app log schema.
    for row in rows:
        if event_name(row) == "recorder_first_sample":
            kind = str(row.get("type") or row.get("sample") or "")
            if kind:
                samples.add(kind)

    event_names = [event_name(row) for row in rows]
    has_start_ok = "start_ok" in event_names
    has_stop_ok = "stop_capture_ok" in event_names
    fatal_hits = sorted({name for name in event_names if name in FATAL_EVENTS})

    mp4_ok = (
        isinstance(mp4_duration, (int, float))
        and not isinstance(mp4_duration, bool)
        and math.isfinite(float(mp4_duration))
        and float(mp4_duration) >= 30.0
    )
    wav_ok = (
        isinstance(wav_duration, (int, float))
        and not isinstance(wav_duration, bool)
        and math.isfinite(float(wav_duration))
        and float(wav_duration) >= 30.0
    )
    duration_delta_ok = False
    if (
        isinstance(mp4_duration, (int, float))
        and isinstance(wav_duration, (int, float))
        and not isinstance(mp4_duration, bool)
        and not isinstance(wav_duration, bool)
        and math.isfinite(float(mp4_duration))
        and math.isfinite(float(wav_duration))
    ):
        duration_delta_ok = abs(float(mp4_duration) - float(wav_duration)) <= 0.5

    manifest_media_ok = False
    manifest_matches_mp4 = False
    if (
        isinstance(media_seconds, (int, float))
        and not isinstance(media_seconds, bool)
        and math.isfinite(float(media_seconds))
    ):
        manifest_media_ok = float(media_seconds) >= 30.0
        if (
            isinstance(mp4_duration, (int, float))
            and not isinstance(mp4_duration, bool)
            and math.isfinite(float(mp4_duration))
        ):
            manifest_matches_mp4 = abs(float(media_seconds) - float(mp4_duration)) <= 0.5

    checks: dict[str, object] = {
        "archive_dir": archive.is_dir(),
        "export_dir": export.is_dir(),
        "manifest_exists": manifest is not None,
        "session_mp4_exists": mp4.is_file(),
        "audio_wav_exists": wav.is_file(),
        "events_exist": events.is_file(),
        "capture_layout_exists": layout is not None,
        "ffprobe_available": True,
        "session_mp4_duration_ge_30": mp4_ok,
        "audio_wav_duration_ge_30": wav_ok,
        "mp4_wav_duration_delta_le_0_5": duration_delta_ok,
        "manifest_media_seconds_ge_30": manifest_media_ok,
        "manifest_media_matches_mp4": manifest_matches_mp4,
        "wav_start_finite_nonnegative": finite_nonnegative(wav_start),
        "first_sample_screen": "screen" in samples,
        "first_sample_audio": "audio" in samples,
        "first_sample_wav": "wav" in samples,
        "start_ok": has_start_ok,
        "stop_capture_ok": has_stop_ok,
        "no_fatal_capture_events": not fatal_hits,
        "media_durations": {
            "session_mp4": mp4_duration,
            "audio_wav": wav_duration,
            "manifest_media_seconds": media_seconds,
            "wav_start_media_seconds": wav_start,
        },
        "first_samples": sorted(samples),
        "fatal_events": fatal_hits,
    }
    required = [
        "archive_dir",
        "export_dir",
        "manifest_exists",
        "session_mp4_exists",
        "audio_wav_exists",
        "events_exist",
        "capture_layout_exists",
        "ffprobe_available",
        "session_mp4_duration_ge_30",
        "audio_wav_duration_ge_30",
        "mp4_wav_duration_delta_le_0_5",
        "manifest_media_seconds_ge_30",
        "manifest_media_matches_mp4",
        "wav_start_finite_nonnegative",
        "first_sample_screen",
        "first_sample_audio",
        "first_sample_wav",
        "start_ok",
        "stop_capture_ok",
        "no_fatal_capture_events",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
