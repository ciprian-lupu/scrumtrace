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
    clip = (ROOT / "ScrumTrace" / "Slicing" / "ClipExporter.swift").read_text()
    assert "tightenExportClips" in clip
    assert "AVAssetExportPreset640x480" in clip


def test_brief_shell_tokens_are_filled() -> None:
    shell = (ROOT / "ScrumTrace" / "Export" / "Resources" / "brief.shell.html").read_text()
    tokens = set(re.findall(r"\{\{[A-Z0-9_]+\}\}", shell))
    gen = (ROOT / "scripts" / "generate_mock_session.py").read_text()
    for token in tokens:
        assert token in gen, f"generate_mock_session.py missing {token}"
    html = (ROOT / "samples" / "mock-session" / "export" / "SESSION_BRIEF.html").read_text()
    assert "{{" not in html


def main() -> None:
    test_quote_window()
    test_export_rel_in_swift()
    test_brief_shell_tokens_are_filled()
    print("evidence contracts ok")


if __name__ == "__main__":
    main()
