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


class LogWindowError(Exception):
    """Raised when a gate-run log window cannot be applied."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def read_jsonl_window(path: Path, start_line: int | None) -> list[dict[str, object]]:
    """Read JSONL rows from a one-based inclusive start line.

    ``start_line is None`` preserves whole-file behavior for direct child CLIs.
    A marker past EOF raises ``LogWindowError`` so callers can exit 2.
    """
    if start_line is None:
        return read_jsonl(path)
    if start_line < 1:
        raise LogWindowError("log_start_line_must_be_positive")
    if not path.is_file():
        return []
    raw_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if start_line > len(raw_lines) + 1:
        # start_line == len+1 means "empty window at EOF" (valid empty run).
        # Anything larger is beyond EOF.
        raise LogWindowError("log_start_line_beyond_eof")
    if start_line == len(raw_lines) + 1:
        return []
    rows: list[dict[str, object]] = []
    for raw in raw_lines[start_line - 1 :]:
        row = parse_json_line(raw)
        if row is not None:
            rows.append(row)
    return rows


def filter_rows_for_session(
    rows: list[dict[str, object]], session_id: str
) -> list[dict[str, object]]:
    """Keep rows that omit session or match session_id."""
    matched: list[dict[str, object]] = []
    for row in rows:
        value = row.get("session") or row.get("session_id")
        if value is None or value == "":
            matched.append(row)
            continue
        if str(value) == session_id:
            matched.append(row)
    return matched


def first_run_id(rows: list[dict[str, object]]) -> str | None:
    for row in rows:
        name = event_name(row)
        if name in {"launch", "app_launch", "session_start"}:
            run = row.get("run_id") or row.get("run")
            if run:
                return str(run)
    return None


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


class ZipInventory:
    """Typed ZIP inventory for Gate 6 (and helpers).

    ``state`` is one of ``missing``, ``valid``, or ``corrupt``.
    """

    def __init__(
        self,
        *,
        state: str,
        names: list[str] | None = None,
        size: int = 0,
        symlink_members: list[str] | None = None,
        reason: str | None = None,
    ) -> None:
        if state not in {"missing", "valid", "corrupt"}:
            raise ValueError(f"invalid zip inventory state: {state!r}")
        self.state = state
        self.names = list(names or [])
        self.size = size
        self.symlink_members = list(symlink_members or [])
        self.reason = reason

    def as_dict(self) -> dict[str, object]:
        return {
            "state": self.state,
            "names": list(self.names),
            "size": self.size,
            "symlink_members": list(self.symlink_members),
            "reason": self.reason,
        }


def zip_inventory(path: Path) -> ZipInventory:
    """Return a typed inventory distinguishing missing / valid / corrupt ZIPs."""
    if not path.is_file():
        return ZipInventory(state="missing", reason="missing")
    try:
        size = path.stat().st_size
    except OSError as exc:
        return ZipInventory(state="corrupt", reason=f"stat_failed:{exc}")
    try:
        with zipfile.ZipFile(path, "r") as zf:
            bad = zf.testzip()
            if bad is not None:
                return ZipInventory(
                    state="corrupt",
                    size=size,
                    reason=f"crc_failed:{bad}",
                )
            names: list[str] = []
            symlinks: list[str] = []
            for info in zf.infolist():
                if info.is_dir():
                    continue
                names.append(info.filename)
                # ZIP symlink: external_attr high bits look like a Unix symlink,
                # or create_system=3 with mode S_IFLNK. Also treat linkname payloads.
                is_symlink = False
                if info.external_attr >> 16:
                    mode = info.external_attr >> 16
                    if (mode & 0o170000) == 0o120000:
                        is_symlink = True
                if is_symlink:
                    symlinks.append(info.filename)
            return ZipInventory(
                state="valid",
                names=names,
                size=size,
                symlink_members=symlinks,
            )
    except zipfile.BadZipFile:
        return ZipInventory(state="corrupt", size=size, reason="bad_zip")
    except OSError as exc:
        return ZipInventory(state="corrupt", size=size, reason=f"unreadable:{exc}")


def zip_names(path: Path) -> list[str]:
    """Return member names for a readable ZIP; missing/corrupt → [].

    Implemented through ``zip_inventory`` without changing the public return type.
    """
    inventory = zip_inventory(path)
    if inventory.state != "valid":
        return []
    return list(inventory.names)


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
    """Return True only for a non-empty regular file contained under export/.

    Rejects empty paths, absolute paths, control characters, ``..`` components,
    symlinks (including inside-export symlink hops), and zero-byte files.
    Does not fall back to ``session / rel``.
    """
    if not isinstance(rel, str):
        return False
    if rel == "" or rel.strip() == "":
        return False
    if "\x00" in rel or "\n" in rel or "\r" in rel:
        return False
    # Absolute paths (POSIX or Windows drive) are rejected before resolution.
    if rel.startswith(("/", "\\")) or (len(rel) >= 2 and rel[1] == ":"):
        return False

    trimmed = rel.strip()
    # Drop a single leading "./" only; do not treat this as containment.
    while trimmed.startswith("./"):
        trimmed = trimmed[2:]
    if not trimmed:
        return False

    if trimmed.startswith("export/"):
        trimmed = trimmed[len("export/") :]
    if not trimmed:
        return False

    parts = trimmed.replace("\\", "/").split("/")
    if any(part == ".." for part in parts):
        return False
    if any(part == "" for part in parts):
        return False

    try:
        export_root = (session / "export").resolve(strict=False)
    except OSError:
        return False

    # Walk components without following symlinks. Any symlink hop is rejected
    # even when the ultimate target would still sit inside export/.
    cursor = export_root
    for part in parts:
        cursor = cursor / part
        try:
            if cursor.is_symlink():
                return False
        except OSError:
            return False

    try:
        # resolve(strict=False) still follows symlinks for the final path; we
        # already rejected symlink components above, so this only canonicalizes
        # real directories.
        candidate = cursor.resolve(strict=False)
        candidate.relative_to(export_root)
    except (OSError, ValueError):
        return False

    try:
        if not candidate.is_file() or candidate.is_symlink():
            return False
        if candidate.stat().st_size <= 0:
            return False
    except OSError:
        return False
    return True


def emit(
    report: dict[str, object],
    failed: list[str],
    *,
    status: str | None = None,
    blocked: bool = False,
    blocked_reasons: list[str] | None = None,
    manual_checks: list[str] | None = None,
) -> int:
    """Emit the Section 3 inspector result schema and return the exit code.

    ``status`` must be one of ``pass``, ``fail``, ``blocked``, or
    ``manual_required``. Callers should pass it explicitly. When omitted for
    compatibility with existing inspectors, ``blocked=True`` maps to
    ``blocked`` (never ``manual_required``), a non-empty ``failed`` list maps
    to ``fail``, and otherwise ``pass``.
    """
    allowed = {"pass", "fail", "blocked", "manual_required"}
    if status is None:
        if blocked:
            status = "blocked"
        elif failed:
            status = "fail"
        else:
            status = "pass"
    if status not in allowed:
        raise ValueError(f"invalid inspector status: {status!r}")
    # Never infer manual_required from a Boolean alone.
    if blocked and status == "manual_required":
        # Explicit manual_required wins; blocked flag is informational only.
        pass
    elif blocked and status not in {"blocked", "manual_required"}:
        raise ValueError("blocked=True requires status blocked or manual_required")

    report = dict(report)
    report["status"] = status
    report["failed"] = list(failed)
    report["blocked_reasons"] = list(blocked_reasons or [])
    report["manual_checks"] = list(manual_checks or [])
    # Preserve legacy boolean for older aggregate readers during migration.
    report["blocked"] = status in {"blocked", "manual_required"}
    print(json.dumps(report, indent=2))
    if status in {"blocked", "manual_required"}:
        return 2
    return 1 if status == "fail" or failed else 0


def die_missing(report: dict[str, object]) -> int:
    return emit(report, [], status="blocked", blocked=True, blocked_reasons=["missing_artifacts"])

