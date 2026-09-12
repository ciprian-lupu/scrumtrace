#!/usr/bin/env python3
"""Inspect archive transcript + pipeline-timing for Gate 3.

Requires a complete dual-aware transcription. The 5-minute / <20 s wall target
remains a recorded measurement row: without --target-media-seconds and
--target-wall-seconds the inspector returns manual_required for that row.

Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate3_whisper.py --session ~/Movies/ScrumTrace/sessions/<id> \\
    --target-media-seconds 300 --target-wall-seconds 18
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    die_missing,
    emit,
    is_json_number,
    read_json_object,
    zip_names,
)


def finite_positive(value: object) -> bool:
    if not is_json_number(value):
        return False
    number = float(value)
    return math.isfinite(number) and number > 0.0


def timing_leaked_in_export(export: Path, zip_members: list[str]) -> bool:
    if (export / "pipeline-timing.json").is_file():
        return True
    for name in zip_members:
        normalized = name.replace("\\", "/").lstrip("./")
        if normalized == "pipeline-timing.json" or normalized.endswith(
            "/pipeline-timing.json"
        ):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument(
        "--target-media-seconds",
        default=None,
        type=float,
        help="Named target media duration for the 5-minute row (optional)",
    )
    parser.add_argument(
        "--target-wall-seconds",
        default=None,
        type=float,
        help="Named Whisper wall seconds for the <20 s target row (optional)",
    )
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    archive = session / "archive"
    export = session / "export"
    transcript_path = archive / "full_transcript.json"
    timing_path = archive / "pipeline-timing.json"
    layout_path = archive / "capture-layout.json"
    zip_path = export / "session-pack.zip"
    report: dict[str, object] = {
        "gate": "3",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
        "target": {
            "media_seconds": args.target_media_seconds,
            "wall_seconds": args.target_wall_seconds,
            "note": "5-minute media / <20 s wall is a recorded target, not a guarantee",
        },
    }
    if not session.is_dir():
        return die_missing(report)

    transcript = read_json_object(transcript_path)
    timing = read_json_object(timing_path)
    layout = read_json_object(layout_path)
    layout_exists = layout is not None
    if not layout_exists or transcript is None or timing is None:
        report["checks"] = {
            "capture_layout_exists": layout_exists,
            "transcript_exists": transcript is not None,
            "timing_exists": timing is not None,
        }
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["missing_layout_or_transcript_or_timing"],
        )

    segments = transcript.get("segments")
    sources = transcript.get("sources")
    source_list = sources if isinstance(sources, list) else []
    source_names = {str(item) for item in source_list}
    whisper_wall = timing.get("whisper_wall_seconds")
    timing_sources = timing.get("whisper_sources")
    timing_source_list = timing_sources if isinstance(timing_sources, list) else []
    timing_source_names = {str(item) for item in timing_source_list}
    zip_members = zip_names(zip_path)
    expect_room = bool(layout.get("microphone_wav"))
    expect_system = bool(layout.get("system_audio_in_movie"))
    incomplete_raw = timing.get("whisper_incomplete")
    incomplete_false = incomplete_raw is False

    room_ok = (not expect_room) or ("room" in source_names)
    system_ok = (not expect_system) or ("system" in source_names)
    both_ok = True
    if expect_room and expect_system:
        both_ok = "room" in source_names and "system" in source_names

    sources_match = (
        isinstance(timing_sources, list)
        and isinstance(sources, list)
        and timing_source_names == source_names
        and len(source_names) > 0
    )

    wall_positive = finite_positive(whisper_wall)
    timing_absent_from_export = not timing_leaked_in_export(export, zip_members)

    target_named = (
        args.target_media_seconds is not None and args.target_wall_seconds is not None
    )
    target_media_ok = False
    target_wall_ok = False
    if target_named:
        target_media_ok = (
            finite_positive(args.target_media_seconds)
            and float(args.target_media_seconds) >= 300.0
        )
        # Recorded target: Whisper wall < 20 s for a 5-minute clip.
        target_wall_ok = (
            finite_positive(args.target_wall_seconds)
            and float(args.target_wall_seconds) < 20.0
            and wall_positive
            and abs(float(args.target_wall_seconds) - float(whisper_wall)) <= 0.5
        )

    checks: dict[str, object] = {
        "capture_layout_exists": True,
        "transcript_exists": True,
        "timing_exists": True,
        "whisper_incomplete_false": incomplete_false,
        "whisper_incomplete": incomplete_raw,
        "whisper_wall_seconds": whisper_wall,
        "whisper_wall_finite_positive": wall_positive,
        "segments_nonempty": isinstance(segments, list) and len(segments) > 0,
        "sources_nonempty": isinstance(sources, list) and len(source_list) > 0,
        "sources": source_list,
        "whisper_sources": timing_source_list,
        "timing_sources_match_transcript": sources_match,
        "room_present_when_microphone_wav": room_ok,
        "system_present_when_system_audio": system_ok,
        "dual_pass_when_both_captured": both_ok,
        "timing_absent_from_export_and_zip": timing_absent_from_export,
        "target_named": target_named,
        "target_media_ge_300": target_media_ok if target_named else None,
        "target_wall_under_20": target_wall_ok if target_named else None,
    }
    required = [
        "capture_layout_exists",
        "whisper_incomplete_false",
        "whisper_wall_finite_positive",
        "segments_nonempty",
        "sources_nonempty",
        "timing_sources_match_transcript",
        "room_present_when_microphone_wav",
        "system_present_when_system_audio",
        "dual_pass_when_both_captured",
        "timing_absent_from_export_and_zip",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    if failed:
        return emit(report, failed, status="fail")
    if not target_named:
        return emit(
            report,
            [],
            status="manual_required",
            blocked=True,
            blocked_reasons=["missing_named_whisper_target_run"],
            manual_checks=["target-media-seconds", "target-wall-seconds"],
        )
    if not target_media_ok or not target_wall_ok:
        return emit(
            report,
            [
                key
                for key, ok in (
                    ("target_media_ge_300", target_media_ok),
                    ("target_wall_under_20", target_wall_ok),
                )
                if not ok
            ],
            status="fail",
        )
    return emit(report, [], status="pass")


if __name__ == "__main__":
    sys.exit(main())
