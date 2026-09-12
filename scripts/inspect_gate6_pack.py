#!/usr/bin/env python3
"""Inspect export/ + measured zip for Gate 6.

Validates ZIP inventory, required documents, path allow-list, size/timing
parity, omission bookkeeping, AGENT_CONTEXT media links, and HTML escaping.

Finder reveal is hardware. Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate6_pack.py --session ~/Movies/ScrumTrace/sessions/<id>
"""

from __future__ import annotations

import argparse
import math
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
    zip_inventory,
)

REQUIRED_ZIP_DOCS = {
    "AGENT_CONTEXT.md",
    "SESSION_BRIEF.html",
    "AGENT_PROMPT.txt",
    "session.manifest.json",
}
ALLOWED_PREFIXES = ("shots/", "media/")
ALLOWED_FILES = REQUIRED_ZIP_DOCS | {"OMITTED.md", "full_transcript.json", "transcript.json"}


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


def normalize_omitted_path(path: str) -> str:
    cleaned = path.replace("\\", "/").lstrip("./")
    if cleaned.startswith("export/"):
        cleaned = cleaned[len("export/") :]
    return cleaned


def member_allowed(name: str) -> bool:
    cleaned = name.replace("\\", "/").lstrip("./")
    if cleaned in ALLOWED_FILES:
        return True
    return any(cleaned.startswith(prefix) for prefix in ALLOWED_PREFIXES)


def member_rejected(name: str) -> str | None:
    cleaned = name.replace("\\", "/").lstrip("./")
    if name.startswith("/") or cleaned.startswith("/") or re_is_abs(name):
        return "absolute"
    parts = [part for part in cleaned.split("/") if part not in {"", "."}]
    if ".." in parts:
        return "traversal"
    if "archive" in parts:
        return "archive_component"
    if cleaned == "pipeline-timing.json" or cleaned.endswith("/pipeline-timing.json"):
        return "pipeline_timing"
    if not member_allowed(cleaned):
        return "not_allowlisted"
    return None


def re_is_abs(name: str) -> bool:
    if name.startswith(("/", "\\")):
        return True
    return len(name) >= 2 and name[1] == ":"


def omitted_entries(raw: object) -> list[dict[str, object]]:
    if not isinstance(raw, list):
        return []
    return [item for item in raw if isinstance(item, dict)]


def manifest_has_archive_paths(manifest: dict[str, object] | None) -> bool:
    if manifest is None:
        return False

    def walk(value: object) -> bool:
        if isinstance(value, str):
            cleaned = value.replace("\\", "/")
            return "archive/" in cleaned or cleaned.startswith("archive")
        if isinstance(value, list):
            return any(walk(item) for item in value)
        if isinstance(value, dict):
            return any(walk(item) for item in value.values())
        return False

    return walk(manifest)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    export = session / "export"
    zip_path = export / "session-pack.zip"
    context_path = export / "AGENT_CONTEXT.md"
    brief_path = export / "SESSION_BRIEF.html"
    prompt_path = export / "AGENT_PROMPT.txt"
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

    inventory = zip_inventory(zip_path)
    report["zip_inventory"] = inventory.as_dict()
    if inventory.state == "missing":
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["zip_missing"],
        )
    if inventory.state == "corrupt":
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["zip_corrupt", inventory.reason or "corrupt"],
        )

    members = inventory.names
    missing_docs = sorted(doc for doc in REQUIRED_ZIP_DOCS if doc not in members)
    reject_reasons: dict[str, str] = {}
    for name in members:
        reason = member_rejected(name)
        if reason is not None:
            reject_reasons[name] = reason
    symlink_members = list(inventory.symlink_members)
    for name in symlink_members:
        reject_reasons.setdefault(name, "symlink")

    zip_bytes = inventory.size
    timing_bytes = timing.get("zip_bytes") if isinstance(timing, dict) else None
    timing_bytes_positive = (
        isinstance(timing_bytes, int)
        and not isinstance(timing_bytes, bool)
        and timing_bytes > 0
        and math.isfinite(float(timing_bytes))
    )
    timing_bytes_match = timing_bytes_positive and timing_bytes == zip_bytes

    canonical_omitted = omitted_entries(manifest.get("omitted"))
    projected_omitted = omitted_entries(
        export_manifest.get("omitted") if isinstance(export_manifest, dict) else None
    )
    timing_omitted_count = timing.get("omitted_count") if isinstance(timing, dict) else None
    omitted_md = read_text(omitted_path) if omitted_path.is_file() else ""
    omitted_md_iff_dropped = (
        omitted_path.is_file() if canonical_omitted else not omitted_path.is_file()
    )

    def omitted_represented(entries: list[dict[str, object]]) -> bool:
        for item in entries:
            path = normalize_omitted_path(str(item.get("path") or ""))
            reason = str(item.get("reason") or "")
            if not path or path not in omitted_md:
                return False
            if reason and reason not in omitted_md:
                return False
        return True

    omitted_paths_named = omitted_represented(canonical_omitted) if canonical_omitted else True
    projected_match = (
        {
            normalize_omitted_path(str(item.get("path") or ""))
            for item in canonical_omitted
        }
        == {
            normalize_omitted_path(str(item.get("path") or ""))
            for item in projected_omitted
        }
    )
    omitted_count_match = True
    if timing_omitted_count is not None:
        omitted_count_match = (
            is_json_number(timing_omitted_count)
            and int(timing_omitted_count) == len(canonical_omitted)
        )

    context = read_text(context_path) if context_path.is_file() else ""
    brief = read_text(brief_path) if brief_path.is_file() else ""
    missing_ctx: list[str] = []
    for rel in markdown_media_paths(context):
        if not export_file_exists(session, rel):
            missing_ctx.append(rel)

    escape_samples = collect_escape_samples(manifest)
    escaped_ok = True
    if escape_samples:
        for sample in escape_samples:
            if html_escape(sample) not in brief:
                escaped_ok = False
                break
    else:
        # Special characters must be present to claim an escaping pass.
        escaped_ok = False

    export_manifest_no_archive = not manifest_has_archive_paths(export_manifest)

    checks: dict[str, object] = {
        "zip_state": inventory.state,
        "zip_exists": True,
        "zip_valid": True,
        "required_docs_present": missing_docs == [],
        "missing_docs": missing_docs,
        "zip_members_allowed": reject_reasons == {},
        "rejected_members": reject_reasons,
        "zip_has_no_symlink": symlink_members == [],
        "zip_bytes": zip_bytes,
        "zip_le_35mb": zip_bytes <= MAX_ZIP_BYTES,
        "timing_zip_bytes": timing_bytes,
        "timing_zip_bytes_positive": timing_bytes_positive,
        "timing_zip_bytes_match": timing_bytes_match,
        "omitted_count": len(canonical_omitted),
        "omitted_md_iff_dropped": omitted_md_iff_dropped,
        "omitted_paths_named": omitted_paths_named,
        "projected_omitted_match": projected_match,
        "timing_omitted_count_match": omitted_count_match,
        "context_paths_exist": missing_ctx == [],
        "missing_context_paths": missing_ctx,
        "html_escape_samples": len(escape_samples),
        "html_specials_escaped": escaped_ok,
        "export_manifest_no_archive_paths": export_manifest_no_archive,
        "agent_context_export_file": context_path.is_file(),
        "session_brief_export_file": brief_path.is_file(),
        "agent_prompt_export_file": prompt_path.is_file(),
        "zip_members": members[:80],
        # Legacy aliases kept for older readers/contracts.
        "zip_has_no_archive": all(
            reason != "archive_component" for reason in reject_reasons.values()
        ),
        "zip_has_no_pipeline_timing": all(
            reason != "pipeline_timing" for reason in reject_reasons.values()
        ),
    }
    required = [
        "zip_valid",
        "required_docs_present",
        "zip_members_allowed",
        "zip_has_no_symlink",
        "zip_le_35mb",
        "timing_zip_bytes_positive",
        "timing_zip_bytes_match",
        "omitted_md_iff_dropped",
        "omitted_paths_named",
        "projected_omitted_match",
        "timing_omitted_count_match",
        "context_paths_exist",
        "html_specials_escaped",
        "export_manifest_no_archive_paths",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed, status="fail" if failed else "pass")


if __name__ == "__main__":
    sys.exit(main())
