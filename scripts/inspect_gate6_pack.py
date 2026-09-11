#!/usr/bin/env python3
"""Inspect export/ + measured zip for Gate 6.

Finder reveal is hardware. Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate6_pack.py --session ~/Movies/ScrumTrace/sessions/<id>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    MAX_ZIP_BYTES,
    die_missing,
    emit,
    export_file_exists,
    html_escape,
    is_json_number,
    markdown_media_paths,
    needs_html_escape,
    read_json_object,
    read_text,
    zip_names,
)


def collect_escape_samples(manifest: dict[str, object]) -> list[str]:
    samples: list[str] = []
    tasks = manifest.get("tasks")
    if isinstance(tasks, list):
        for task in tasks:
            if not isinstance(task, dict):
                continue
            for key in ("title", "observed", "stated", "inferred", "agent_instructions"):
                value = task.get(key)
                if isinstance(value, str) and needs_html_escape(value):
                    samples.append(value)
    shots = manifest.get("shots")
    if isinstance(shots, list):
        for shot in shots:
            if not isinstance(shot, dict):
                continue
            note = shot.get("note")
            if isinstance(note, str) and needs_html_escape(note):
                samples.append(note)
    return samples


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    export = session / "export"
    zip_path = export / "session-pack.zip"
    context_path = export / "AGENT_CONTEXT.md"
    brief_path = export / "SESSION_BRIEF.html"
    omitted_path = export / "OMITTED.md"
    manifest = read_json_object(session / "session.manifest.json")
    export_manifest = read_json_object(export / "session.manifest.json")
    timing = read_json_object(session / "archive" / "pipeline-timing.json")
    report: dict[str, object] = {
        "gate": "6",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
    }
    if not session.is_dir() or not export.is_dir() or manifest is None:
        return die_missing(report)
    if not context_path.is_file() or not brief_path.is_file():
        report["checks"] = {
            "agent_context": context_path.is_file(),
            "session_brief": brief_path.is_file(),
        }
        return emit(report, [], blocked=True)

    members = zip_names(zip_path)
    zip_bytes = zip_path.stat().st_size if zip_path.is_file() else 0
    timing_bytes = timing.get("zip_bytes") if timing else None
    omitted = manifest.get("omitted")
    omitted_list = omitted if isinstance(omitted, list) else []
    omitted_md = read_text(omitted_path)
    omitted_named = True
    for item in omitted_list:
        if not isinstance(item, dict):
            omitted_named = False
            continue
        path = str(item.get("path") or "")
        if path and path not in omitted_md:
            omitted_named = False
    context = read_text(context_path)
    brief = read_text(brief_path)
    missing_ctx: list[str] = []
    for rel in markdown_media_paths(context):
        if not export_file_exists(session, rel):
            missing_ctx.append(rel)
    archive_in_zip = any("archive" in name.split("/") for name in members)
    timing_in_zip = any(name.endswith("pipeline-timing.json") for name in members)
    escape_samples = collect_escape_samples(manifest)
    escaped_ok = True
    for sample in escape_samples:
        if html_escape(sample) not in brief:
            escaped_ok = False
            break

    checks: dict[str, object] = {
        "export_dir": True,
        "agent_context": True,
        "session_brief": True,
        "zip_exists": zip_path.is_file(),
        "zip_bytes": zip_bytes,
        "zip_le_35mb": zip_path.is_file() and zip_bytes <= MAX_ZIP_BYTES,
        "timing_zip_bytes": timing_bytes,
        "timing_zip_bytes_present": is_json_number(timing_bytes),
        "zip_has_no_archive": not archive_in_zip,
        "zip_has_no_pipeline_timing": not timing_in_zip,
        "omitted_count": len(omitted_list),
        "omitted_md_iff_dropped": (
            omitted_path.is_file() if omitted_list else not omitted_path.is_file()
        ),
        "omitted_paths_named": omitted_named if omitted_list else True,
        "context_paths_exist": missing_ctx == [],
        "missing_context_paths": missing_ctx,
        "html_escape_applicable": bool(escape_samples),
        "html_specials_escaped": escaped_ok,
        "export_manifest": export_manifest is not None,
        "zip_members": members[:40],
    }
    required = [
        "agent_context",
        "session_brief",
        "zip_exists",
        "zip_le_35mb",
        "zip_has_no_archive",
        "zip_has_no_pipeline_timing",
        "omitted_md_iff_dropped",
        "omitted_paths_named",
        "context_paths_exist",
        "html_specials_escaped",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
