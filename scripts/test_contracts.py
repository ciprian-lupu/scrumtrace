#!/usr/bin/env python3
"""Contract tests that do not need a Mac."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_export_has_no_archive_and_no_tokens() -> None:
    export = ROOT / "samples" / "mock-session" / "export"
    assert export.exists()
    assert not (export / "archive").exists()
    assert not (export / "session.mp4").exists()
    assert not (export / "audio.wav").exists()
    assert not (export / "full_transcript.json").exists()
    forbidden = ["ATH-SAVE-DISABLED-0x9F", "STENCIL-4419"]
    for path in export.rglob("*"):
        if not path.is_file() or path.suffix.lower() in {".png", ".jpg", ".jpeg", ".mp4", ".zip"}:
            continue
        text = path.read_text(errors="ignore")
        for token in forbidden:
            assert token not in text, f"{token} leaked into {path}"
        assert "archive/" not in text, f"archive path leaked into {path}"


def test_agent_context_uses_export_relative_paths() -> None:
    ctx = (ROOT / "samples" / "mock-session" / "export" / "AGENT_CONTEXT.md").read_text()
    assert "![](shots/001.annotated.png)" in ctx
    assert "`media/task-02/clip.mp4`" in ctx
    assert "archive/" not in ctx
    assert "export/shots" not in ctx


def test_retired_anthropic_ids() -> None:
    settings = (ROOT / "ScrumTrace" / "App" / "AppSettings.swift").read_text()
    assert "claude-3-5" in settings
    assert "claude-3-7" in settings
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "isRetiredAnthropic" in processor


def test_json_schema_uses_standard_types() -> None:
    schema = (ROOT / "ScrumTrace" / "AI" / "EvaluationJSONSchema.swift").read_text()
    assert '"type": "object"' in schema
    assert '"type": "string"' in schema
    assert '"type": "number"' in schema
    assert '"type": "array"' in schema
    assert '"OBJECT"' not in schema
    assert '"STRING"' not in schema
    assert "agent_instructions_draft" in schema
    client = (ROOT / "ScrumTrace" / "AI" / "OpenAICompatibleClient.swift").read_text()
    assert "json_schema" in client
    assert "EvaluationJSONSchema.openaiStructured" in client


def test_html_escaper_order() -> None:
    renderer = (ROOT / "ScrumTrace" / "Export" / "SessionBriefRenderer.swift").read_text()
    amp = renderer.find('replacingOccurrences(of: "&"')
    lt = renderer.find('replacingOccurrences(of: "<"')
    assert 0 <= amp < lt, "escape & before <"


def test_zipper_never_deletes_archive() -> None:
    zipper = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    assert "ExportRel.isUnderExport" in zipper
    assert "allowList" in zipper
    assert '"-@"' in zipper
    assert "archive/session.mp4" not in zipper


def test_clip_exporter_macos14() -> None:
    clip = (ROOT / "ScrumTrace" / "Slicing" / "ClipExporter.swift").read_text()
    assert "exportAsynchronously" in clip
    assert "export(to:" not in clip
    assert "AVAssetExportPreset1280x720" in clip
    assert "tightenExportClips" in clip
    assert "AVAssetExportPreset640x480" in clip


def test_handoff_log_names_mp4_tools() -> None:
    log = (ROOT / "samples" / "mock-session" / "HANDOFF_LOG.md").read_text()
    assert "ffprobe" in log or "ffmpeg" in log
    assert "clip.mp4" in log
    assert "PNG" in log or "png" in log


def test_pause_gate_hold_to_talk() -> None:
    shot = (ROOT / "ScrumTrace" / "UI" / "ShotNoteWindow.swift").read_text()
    assert "abortTalk" in shot
    assert "scrumTraceCaptureGate" in shot
    hud = (ROOT / "ScrumTrace" / "UI" / "RecordingHUDWindow.swift").read_text()
    assert "allowsNewCapture" in hud


def main() -> None:
    test_export_has_no_archive_and_no_tokens()
    test_agent_context_uses_export_relative_paths()
    test_retired_anthropic_ids()
    test_json_schema_uses_standard_types()
    test_html_escaper_order()
    test_zipper_never_deletes_archive()
    test_clip_exporter_macos14()
    test_handoff_log_names_mp4_tools()
    test_pause_gate_hold_to_talk()
    print("contract tests ok")


if __name__ == "__main__":
    main()
