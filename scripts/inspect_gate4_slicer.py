#!/usr/bin/env python3
"""Inspect slicer outputs and measured pack fields for Gate 4.

Requires real clip files, ffprobe measurements, ZIP size parity, and an
explicit --chrome-playback-ok flag to close the manual playback row.

Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate4_slicer.py --session ~/Movies/ScrumTrace/sessions/<id> \\
    --chrome-playback-ok
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    die_missing,
    emit,
    export_file_exists,
    ffprobe_bin,
    ffprobe_video_stream,
    is_json_number,
    read_json_object,
)

MAX_SLICE_SECONDS = 25.0


def finite_nonnegative(value: object) -> bool:
    if not is_json_number(value):
        return False
    number = float(value)
    return math.isfinite(number) and number >= 0.0


def ffprobe_audio_codec(path: Path, ffprobe: str) -> str | None:
    if not path.is_file():
        return None
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=codec_name",
                "-of",
                "json",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        data = __import__("json").loads(out.stdout or "{}")
    except (OSError, ValueError):
        return None
    streams = data.get("streams") if isinstance(data, dict) else None
    if not isinstance(streams, list) or not streams:
        return None
    stream = streams[0]
    if not isinstance(stream, dict):
        return None
    codec = stream.get("codec_name")
    return str(codec) if codec else None


def slice_ranges_ok(slices: list[object]) -> tuple[bool, list[dict[str, object]]]:
    details: list[dict[str, object]] = []
    if not slices:
        return False, details
    for item in slices:
        if not isinstance(item, dict):
            return False, details
        start = item.get("start_media")
        end = item.get("end_media")
        ok = (
            finite_nonnegative(start)
            and finite_nonnegative(end)
            and float(end) >= float(start)
            and (float(end) - float(start)) <= MAX_SLICE_SECONDS
        )
        details.append(
            {
                "start_media": start,
                "end_media": end,
                "duration": (
                    float(end) - float(start)
                    if finite_nonnegative(start) and finite_nonnegative(end)
                    else None
                ),
                "ok": ok,
            }
        )
        if not ok:
            return False, details
    return True, details


def first_contained_clip(session: Path, slices: list[object]) -> Path | None:
    export = session / "export"
    for item in slices:
        if not isinstance(item, dict):
            continue
        for key in ("export_clip_path", "clip_path"):
            rel = item.get(key)
            if not isinstance(rel, str) or not rel:
                continue
            # Normalize export-relative paths.
            cleaned = rel[len("export/") :] if rel.startswith("export/") else rel
            if export_file_exists(session, cleaned):
                return (export / cleaned).resolve()
    media = export / "media"
    if media.is_dir():
        for path in sorted(media.rglob("*.mp4")):
            try:
                rel = str(path.relative_to(export))
            except ValueError:
                continue
            if export_file_exists(session, rel):
                return path.resolve()
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument(
        "--chrome-playback-ok",
        action="store_true",
        help="Human confirms primary clip plays in Chrome",
    )
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    export = session / "export"
    zip_path = export / "session-pack.zip"
    manifest = read_json_object(session / "session.manifest.json")
    timing = read_json_object(session / "archive" / "pipeline-timing.json")
    report: dict[str, object] = {
        "gate": "4",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
        "manual": {"chrome_playback_ok": bool(args.chrome_playback_ok)},
    }
    if not session.is_dir() or manifest is None:
        return die_missing(report)

    slices = manifest.get("slices")
    slice_list = slices if isinstance(slices, list) else []
    if not slice_list:
        report["checks"] = {
            "slice_count": 0,
            "candidate_windows_le_12": False,
        }
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["empty_slices"],
        )

    ranges_ok, range_details = slice_ranges_ok(slice_list)
    slice_count = len(slice_list)
    count_ok = 1 <= slice_count <= 12
    # Keep historical contract name candidate_windows_le_12.
    candidate_windows_le_12 = slice_count <= 12

    clip = first_contained_clip(session, slice_list)
    clip_exists = clip is not None and clip.is_file() and clip.stat().st_size > 0
    probe = ffprobe_bin()
    if probe is None:
        report["checks"] = {
            "slice_count": slice_count,
            "candidate_windows_le_12": candidate_windows_le_12,
            "slice_ranges_ok": ranges_ok,
            "clip_exists": clip_exists,
            "ffprobe_available": False,
        }
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["ffprobe_missing"],
        )

    stream_info: dict[str, object] | None = None
    audio_codec: str | None = None
    clip_720p_h264 = False
    ffprobe_ok = False
    if clip_exists and clip is not None:
        stream_info = ffprobe_video_stream(clip, probe)
        audio_codec = ffprobe_audio_codec(clip, probe)
        ffprobe_ok = stream_info is not None
        if stream_info is not None:
            width = stream_info.get("width")
            height = stream_info.get("height")
            codec = str(stream_info.get("codec_name") or "")
            clip_720p_h264 = width == 1280 and height == 720 and codec == "h264"

    zip_exists = zip_path.is_file()
    zip_valid = False
    zip_size = 0
    if zip_exists:
        try:
            with zipfile.ZipFile(zip_path, "r") as zf:
                bad = zf.testzip()
                zip_valid = bad is None
            zip_size = zip_path.stat().st_size
        except (OSError, zipfile.BadZipFile):
            zip_valid = False

    zip_bytes = timing.get("zip_bytes") if isinstance(timing, dict) else None
    zip_bytes_positive = (
        isinstance(zip_bytes, int)
        and not isinstance(zip_bytes, bool)
        and zip_bytes > 0
    )
    zip_bytes_match = zip_bytes_positive and zip_valid and zip_bytes == zip_size

    checks: dict[str, object] = {
        "slice_count": slice_count,
        "candidate_windows_le_12": candidate_windows_le_12,
        "slice_count_1_to_12": count_ok,
        "slice_ranges_ok": ranges_ok,
        "slice_range_details": range_details,
        "clip_exists": clip_exists,
        "clip_path": str(clip) if clip is not None else None,
        "ffprobe_ok": ffprobe_ok,
        "clip_720p_h264": clip_720p_h264,
        "clip_stream": stream_info,
        "clip_profile": (
            stream_info.get("profile") if isinstance(stream_info, dict) else None
        ),
        "clip_audio_codec": audio_codec,
        "session_pack_zip_exists": zip_exists,
        "session_pack_zip_valid": zip_valid,
        "zip_bytes": zip_bytes,
        "zip_bytes_positive": zip_bytes_positive,
        "zip_size": zip_size,
        "zip_bytes_match_file": zip_bytes_match,
        "chrome_playback_ok": bool(args.chrome_playback_ok),
    }
    required = [
        "slice_count_1_to_12",
        "candidate_windows_le_12",
        "slice_ranges_ok",
        "clip_exists",
        "ffprobe_ok",
        "clip_720p_h264",
        "session_pack_zip_exists",
        "session_pack_zip_valid",
        "zip_bytes_positive",
        "zip_bytes_match_file",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    if failed:
        return emit(report, failed, status="fail")
    if not args.chrome_playback_ok:
        return emit(
            report,
            [],
            status="manual_required",
            blocked=True,
            blocked_reasons=["missing_chrome_playback_ok"],
            manual_checks=["chrome-playback-ok"],
        )
    return emit(report, [], status="pass")


if __name__ == "__main__":
    sys.exit(main())
