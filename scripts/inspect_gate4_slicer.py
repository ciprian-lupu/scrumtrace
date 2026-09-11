#!/usr/bin/env python3
"""Inspect slicer + measured pack fields for Gate 4.

Chrome playback is hardware. Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate4_slicer.py --session ~/Movies/ScrumTrace/sessions/<id>
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
    ffprobe_bin,
    ffprobe_video_stream,
    is_json_number,
    read_json_object,
)


def clip_paths(session: Path, manifest: dict[str, object]) -> list[Path]:
    found: list[Path] = []
    slices = manifest.get("slices")
    if isinstance(slices, list):
        for item in slices:
            if not isinstance(item, dict):
                continue
            for key in ("export_clip_path", "clip_path"):
                rel = item.get(key)
                if not isinstance(rel, str) or not rel:
                    continue
                for candidate in (session / rel, session / "export" / rel):
                    if candidate.is_file():
                        found.append(candidate)
                        break
    media = session / "export" / "media"
    if media.is_dir():
        found.extend(sorted(media.rglob("clip.mp4")))
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in found:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append(resolved)
    return unique


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    manifest = read_json_object(session / "session.manifest.json")
    timing = read_json_object(session / "archive" / "pipeline-timing.json")
    report: dict[str, object] = {
        "gate": "4",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
    }
    if not session.is_dir() or manifest is None:
        return die_missing(report)

    slices = manifest.get("slices")
    slice_list = slices if isinstance(slices, list) else []
    if not slice_list:
        report["checks"] = {"slice_count": 0}
        return emit(report, [], blocked=True)

    clips = clip_paths(session, manifest)
    probe = ffprobe_bin()
    clip_720p = False
    stream_info: dict[str, object] | None = None
    if probe and clips:
        stream_info = ffprobe_video_stream(clips[0], probe)
        if stream_info is not None:
            width = stream_info.get("width")
            height = stream_info.get("height")
            codec = str(stream_info.get("codec_name") or "")
            clip_720p = width == 1280 and height == 720 and codec == "h264"
    zip_bytes = timing.get("zip_bytes") if timing else None

    checks: dict[str, object] = {
        "slice_count": len(slice_list),
        "candidate_windows_le_12": len(slice_list) <= 12,
        "clip_exists": bool(clips),
        "clip_paths": [str(path) for path in clips],
        "clip_720p_h264": clip_720p if probe and clips else None,
        "clip_stream": stream_info,
        "zip_bytes": zip_bytes,
        "zip_bytes_present": is_json_number(zip_bytes),
    }
    required = ["candidate_windows_le_12", "clip_exists", "zip_bytes_present"]
    if probe and clips:
        required.append("clip_720p_h264")
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
