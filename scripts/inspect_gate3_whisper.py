#!/usr/bin/env python3
"""Inspect archive transcript + pipeline-timing for Gate 3.

Does not treat the 5-minute / 20-second target as a fail. That cell stays
human-measured. Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate3_whisper.py --session ~/Movies/ScrumTrace/sessions/<id>
"""

from __future__ import annotations

import argparse
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    transcript_path = session / "archive" / "full_transcript.json"
    timing_path = session / "archive" / "pipeline-timing.json"
    layout_path = session / "archive" / "capture-layout.json"
    zip_path = session / "export" / "session-pack.zip"
    report: dict[str, object] = {
        "gate": "3",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
    }
    if not session.is_dir():
        return die_missing(report)

    transcript = read_json_object(transcript_path)
    timing = read_json_object(timing_path)
    layout = read_json_object(layout_path)
    if transcript is None or timing is None:
        report["checks"] = {
            "transcript_exists": transcript is not None,
            "timing_exists": timing is not None,
        }
        return emit(report, [], blocked=True)

    segments = transcript.get("segments")
    sources = transcript.get("sources")
    source_list = sources if isinstance(sources, list) else []
    source_names = {str(item) for item in source_list}
    whisper_wall = timing.get("whisper_wall_seconds")
    timing_sources = timing.get("whisper_sources")
    timing_source_list = timing_sources if isinstance(timing_sources, list) else []
    zip_members = zip_names(zip_path)
    expect_room = bool(layout and layout.get("microphone_wav"))
    expect_system = bool(layout and layout.get("system_audio_in_movie"))
    incomplete = bool(timing.get("whisper_incomplete"))
    dual_ok = True
    if expect_room and expect_system and not incomplete:
        dual_ok = "room" in source_names and "system" in source_names

    checks: dict[str, object] = {
        "transcript_exists": True,
        "timing_exists": True,
        "segments_nonempty": isinstance(segments, list) and len(segments) > 0,
        "sources_present": isinstance(sources, list) and len(source_list) > 0,
        "sources": source_list,
        "whisper_wall_seconds": whisper_wall,
        "whisper_wall_present": is_json_number(whisper_wall),
        "whisper_sources": timing_source_list,
        "whisper_incomplete": incomplete,
        "dual_pass_when_both_captured": dual_ok,
        "timing_not_in_zip": "pipeline-timing.json" not in zip_members
        and not any(name.endswith("pipeline-timing.json") for name in zip_members),
    }
    required = [
        "transcript_exists",
        "timing_exists",
        "segments_nonempty",
        "sources_present",
        "whisper_wall_present",
        "dual_pass_when_both_captured",
        "timing_not_in_zip",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
