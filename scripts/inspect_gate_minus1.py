#!/usr/bin/env python3
"""Inspect the Phase -1 mock export pack.

This is the only gate that can close on Linux. It does not write GATE_LOG.md.

Usage:
  python3 scripts/inspect_gate_minus1.py
  python3 scripts/inspect_gate_minus1.py --export samples/mock-session/export
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import IMAGE_TOKEN, VIDEO_TOKEN, emit, read_text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--export",
        type=Path,
        default=ROOT / "samples" / "mock-session" / "export",
    )
    parser.add_argument(
        "--handoff",
        type=Path,
        default=ROOT / "samples" / "mock-session" / "HANDOFF_LOG.md",
    )
    args = parser.parse_args()
    export: Path = args.export.expanduser().resolve()
    handoff: Path = args.handoff.expanduser().resolve()
    report: dict[str, object] = {
        "gate": "minus1",
        "export": str(export),
        "exists": export.is_dir(),
        "checks": {},
    }
    if not export.is_dir():
        return emit(report, ["export_dir"])

    leaked = False
    archive_leaked = False
    for path in export.rglob("*"):
        if not path.is_file() or path.suffix.lower() in {".png", ".jpg", ".jpeg", ".mp4", ".zip"}:
            continue
        text = read_text(path)
        if IMAGE_TOKEN in text or VIDEO_TOKEN in text:
            leaked = True
        if "archive/" in text:
            archive_leaked = True

    ctx = read_text(export / "AGENT_CONTEXT.md")
    checks = {
        "export_dir": True,
        "no_archive_folder": not (export / "archive").exists(),
        "no_master_movie": not (export / "session.mp4").exists(),
        "no_master_wav": not (export / "audio.wav").exists(),
        "agent_context": (export / "AGENT_CONTEXT.md").is_file(),
        "session_brief": (export / "SESSION_BRIEF.html").is_file(),
        "agent_prompt": (export / "AGENT_PROMPT.txt").is_file(),
        "manifest": (export / "session.manifest.json").is_file(),
        "handoff_log": handoff.is_file(),
        "image_evidence": (export / "shots" / "001.annotated.png").is_file()
        or (export / "shots" / "001.png").is_file(),
        "clip_evidence": (export / "media" / "task-02" / "clip.mp4").is_file(),
        "tokens_absent_from_text": not leaked,
        "no_archive_paths": not archive_leaked,
        "context_links_shot": "![](shots/001.annotated.png)" in ctx
        or "![](shots/001.png)" in ctx,
        "context_links_clip": "`media/task-02/clip.mp4`" in ctx,
    }
    required = [
        "export_dir",
        "no_archive_folder",
        "no_master_movie",
        "no_master_wav",
        "agent_context",
        "session_brief",
        "agent_prompt",
        "manifest",
        "handoff_log",
        "image_evidence",
        "clip_evidence",
        "tokens_absent_from_text",
        "no_archive_paths",
        "context_links_shot",
        "context_links_clip",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
