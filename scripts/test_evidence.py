#!/usr/bin/env python3
"""EvidenceValidator + export-relative path contracts (Linux)."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def normalize(text: str) -> str:
    return " ".join(text.lower().split())


def quote_matches(quote: str, start: float, end: float, segments: list[tuple[float, float, str]]) -> bool:
    needle = normalize(quote)
    if not needle:
        return False
    return any(seg_end >= start and seg_start <= end and needle in normalize(text) for seg_start, seg_end, text in segments)


def test_quote_window() -> None:
    segments = [(10.0, 14.0, "this does nothing it should store the athlete")]
    assert quote_matches("this does nothing", 10.5, 13.0, segments)
    assert not quote_matches("invented passphrase", 10.5, 13.0, segments)


def test_export_rel_in_swift() -> None:
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func toExportRoot" in models
    assert "func isUnderExport" in models
    zipper = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    assert "allowList" in zipper
    assert '"-@"' in zipper
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func handoffPath" in models
    assert "func omittedHandoffPath" in models
    clip = (ROOT / "ScrumTrace" / "Slicing" / "ClipExporter.swift").read_text()
    assert "tightenExportClips" in clip
    assert "AVAssetExportPreset640x480" in clip
    assert "AVVideoProfileLevelH264MainAutoLevel" in clip
    assert "writeMainProfileClip" in clip
    shot = (ROOT / "ScrumTrace" / "UI" / "ShotNoteWindow.swift").read_text()
    assert "lockFocus" not in shot
    assert "bitmapImageRepForCachingDisplay" in shot
    jpeg = (ROOT / "ScrumTrace" / "AI" / "AIProviderProtocol.swift").read_text()
    assert "lockFocus" not in jpeg
    projector = (ROOT / "ScrumTrace" / "Export" / "ExportProjector.swift").read_text()
    assert "lockFocus" not in projector
    assert "omittedHandoffPath" in projector
    assert "JPEG transcode failed" in projector


def test_frame_ref_basename_resolves() -> None:
    from tempfile import TemporaryDirectory

    def candidates(path: str) -> list[str]:
        name = Path(path).name
        stem = Path(name).stem
        return [
            path,
            f"archive/shots/{name}",
            f"archive/shots/{stem}.png",
            f"archive/shots/{stem}.annotated.png",
            f"export/shots/{stem}.jpg",
            f"export/shots/{stem}.annotated.jpg",
        ]

    def resolve(path: str, root: Path) -> str | None:
        seen: set[str] = set()
        for rel in candidates(path):
            if rel in seen:
                continue
            seen.add(rel)
            if (root / rel).is_file():
                return rel
        return None

    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        shot = root / "archive" / "shots" / "001.png"
        shot.parent.mkdir(parents=True)
        shot.write_bytes(b"png")
        assert resolve("001.png", root) == "archive/shots/001.png"
        assert resolve("missing.png", root) is None

    validator = (ROOT / "ScrumTrace" / "AI" / "EvidenceValidator.swift").read_text()
    assert "func resolvePath" in validator
    assert "func applyExportEvidence" in validator
    assert "archive/shots/" in validator
    slicer = (ROOT / "ScrumTrace" / "Slicing" / "MeetingSlicer.swift").read_text()
    assert "clipMaxDuration" in slicer
    plist = (ROOT / "ScrumTrace" / "App" / "Info.plist").read_text()
    assert "NSAccessibilityUsageDescription" in plist


def test_brief_shell_tokens_are_filled() -> None:
    shell = (ROOT / "ScrumTrace" / "Export" / "Resources" / "brief.shell.html").read_text()
    tokens = set(re.findall(r"\{\{[A-Z0-9_]+\}\}", shell))
    gen = (ROOT / "scripts" / "generate_mock_session.py").read_text()
    for token in tokens:
        assert token in gen, f"generate_mock_session.py missing {token}"
    html = (ROOT / "samples" / "mock-session" / "export" / "SESSION_BRIEF.html").read_text()
    assert "{{" not in html


def test_mock_clip_ffprobe() -> None:
    import json
    import subprocess

    clip = ROOT / "samples" / "mock-session" / "export" / "media" / "task-02" / "clip.mp4"
    assert clip.is_file()
    probe = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,width,height",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(clip),
        ],
        text=True,
    )
    data = json.loads(probe)
    stream = data["streams"][0]
    assert stream["codec_name"] == "h264"
    assert int(stream["width"]) == 1280
    assert int(stream["height"]) == 720
    duration = float(data["format"]["duration"])
    assert 15.0 <= duration <= 17.0, duration


def test_mock_agent_context_paths_exist() -> None:
    export = ROOT / "samples" / "mock-session" / "export"
    ctx = (export / "AGENT_CONTEXT.md").read_text()
    for rel in re.findall(r"!\[\]\(([^)]+)\)", ctx):
        assert (export / rel).is_file(), f"missing {rel}"
    for rel in re.findall(r"`(media/[^`]+)`", ctx):
        assert (export / rel).is_file(), f"missing {rel}"


def test_mock_pack_zip_is_export_only() -> None:
    import zipfile

    export = ROOT / "samples" / "mock-session" / "export"
    zip_path = export / "session-pack.zip"
    assert zip_path.is_file()
    assert zip_path.stat().st_size <= 35 * 1024 * 1024
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
    assert names, "session-pack.zip is empty"
    for name in names:
        assert "archive/" not in name, name
        assert not name.startswith("..")
        assert (export / name).is_file(), name


def main() -> None:
    test_quote_window()
    test_export_rel_in_swift()
    test_frame_ref_basename_resolves()
    test_brief_shell_tokens_are_filled()
    test_mock_clip_ffprobe()
    test_mock_agent_context_paths_exist()
    test_mock_pack_zip_is_export_only()
    print("evidence contracts ok")


if __name__ == "__main__":
    main()
