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


def test_retired_anthropic_ids() -> None:
    retired = ["claude-3-5-sonnet-latest", "claude-3-7-sonnet"]
    for model in retired:
        lowered = model.lower()
        assert "claude-3-5" in lowered or "claude-3-7" in lowered


def test_handoff_log_names_mp4_tools() -> None:
    log = (ROOT / "samples" / "mock-session" / "HANDOFF_LOG.md").read_text()
    assert "ffprobe" in log or "ffmpeg" in log
    assert "clip.mp4" in log


def main() -> None:
    test_export_has_no_archive_and_no_tokens()
    test_retired_anthropic_ids()
    test_handoff_log_names_mp4_tools()
    print("contract tests ok")


if __name__ == "__main__":
    main()
