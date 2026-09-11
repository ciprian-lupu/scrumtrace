#!/usr/bin/env python3
"""Shared helpers for ScrumTrace gate inspectors.

Inspector exit 0 is not a GATE_LOG.md PASS. Do not invent PASS cells.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

MAX_ZIP_BYTES = 35 * 1024 * 1024
RETIRED_ANTHROPIC = ("claude-3-5", "claude-3.5", "claude-3-7", "claude-3.7")
IMAGE_TOKEN = "ATH-SAVE-DISABLED-0x9F"
VIDEO_TOKEN = "STENCIL-4419"
MD_LINK = re.compile(r"!\[\]\(([^)]+)\)|`((?:shots|media)/[^`]+)`")


def parse_json_line(raw: str) -> dict[str, object] | None:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.is_file():
        return []
    rows: list[dict[str, object]] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        row = parse_json_line(raw)
        if row is not None:
            rows.append(row)
    return rows


def read_json_object(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def is_json_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def event_name(row: dict[str, object]) -> str:
    return str(row.get("event") or row.get("name") or "")


def ffprobe_bin() -> str | None:
    return shutil.which("ffprobe")


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


def ffprobe_video_stream(path: Path, ffprobe: str) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=codec_name,profile,width,height",
                "-of",
                "json",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        data = json.loads(out.stdout or "{}")
    except (OSError, json.JSONDecodeError):
        return None
    streams = data.get("streams") if isinstance(data, dict) else None
    if not isinstance(streams, list) or not streams:
        return None
    stream = streams[0]
    return stream if isinstance(stream, dict) else None


def zip_names(path: Path) -> list[str]:
    if not path.is_file():
        return []
    try:
        out = subprocess.run(
            ["unzip", "-Z", "-1", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
        if out.returncode == 0:
            return [line.strip() for line in out.stdout.splitlines() if line.strip()]
    except OSError:
        pass
    try:
        with zipfile.ZipFile(path, "r") as zf:
            return [info.filename for info in zf.infolist() if not info.is_dir()]
    except (OSError, zipfile.BadZipFile):
        return []


def first_sample_types(rows: list[dict[str, object]]) -> set[str]:
    types: set[str] = set()
    for row in rows:
        if event_name(row) != "recorder_first_sample":
            continue
        sample = str(row.get("type") or "")
        if sample:
            types.add(sample)
    return types


def pause_windows(rows: list[dict[str, object]]) -> list[tuple[int, int | None]]:
    """Inclusive index ranges for pause_ok → resume_ok (resume may be missing)."""
    windows: list[tuple[int, int | None]] = []
    start: int | None = None
    for index, row in enumerate(rows):
        name = event_name(row)
        if name == "pause_ok" and start is None:
            start = index
        elif name == "resume_ok" and start is not None:
            windows.append((start, index))
            start = None
    if start is not None:
        windows.append((start, None))
    return windows


def in_pause_window(index: int, windows: list[tuple[int, int | None]]) -> bool:
    for start, end in windows:
        if index <= start:
            continue
        if end is None or index < end:
            return True
    return False


def markdown_media_paths(text: str) -> list[str]:
    paths: list[str] = []
    seen: set[str] = set()
    for match in MD_LINK.finditer(text):
        path = (match.group(1) or match.group(2) or "").strip()
        if not path or path in seen:
            continue
        seen.add(path)
        paths.append(path)
    return paths


def html_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def needs_html_escape(value: str) -> bool:
    return any(char in value for char in '&<>"')


def is_retired_anthropic(model: str) -> bool:
    lowered = model.lower()
    return any(token in lowered for token in RETIRED_ANTHROPIC)


def export_file_exists(session: Path, rel: str) -> bool:
    trimmed = rel.strip().lstrip("./")
    if not trimmed or trimmed.startswith("archive/"):
        return False
    if trimmed.startswith("export/"):
        return (session / trimmed).is_file()
    return (session / "export" / trimmed).is_file() or (session / trimmed).is_file()


def emit(report: dict[str, object], failed: list[str], *, blocked: bool = False) -> int:
    report["failed"] = failed
    report["blocked"] = blocked
    print(json.dumps(report, indent=2))
    if blocked:
        return 2
    return 1 if failed else 0


def die_missing(report: dict[str, object]) -> int:
    return emit(report, [], blocked=True)
