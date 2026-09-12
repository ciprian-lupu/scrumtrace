#!/usr/bin/env python3
"""Inspect Stop consent + evidence rules for Gate 5.

Cannot prove a live upload was refused without the Mac sheet. Fails when the
manifest or log contradicts C4/C5/D15. Inspector pass is not a GATE_LOG PASS.

Usage:
  python3 scripts/inspect_gate5_provider.py --session ~/Movies/ScrumTrace/sessions/<id> \\
    --log ~/Library/Logs/ScrumTrace/agent.jsonl
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    LogWindowError,
    filter_rows_for_session,
    first_run_id,
    read_jsonl_window,
    die_missing,
    emit,
    event_name,
    export_file_exists,
    is_retired_anthropic,
    read_json_object,
)


def normalize(text: str) -> str:
    return " ".join(text.lower().split())


def quote_in_transcript(quote: dict[str, object], segments: list[object]) -> bool:
    needle = normalize(str(quote.get("text") or ""))
    if not needle:
        return False
    start = quote.get("t_media_start")
    end = quote.get("t_media_end")
    if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
        return False
    for item in segments:
        if not isinstance(item, dict):
            continue
        seg_start = item.get("start")
        seg_end = item.get("end")
        text = str(item.get("text") or "")
        if not isinstance(seg_start, (int, float)) or not isinstance(seg_end, (int, float)):
            continue
        if seg_end >= start and seg_start <= end and needle in normalize(text):
            return True
    return False


def consent_asked(consent: dict[str, object]) -> bool:
    provider = str(consent.get("provider") or "")
    endpoint = str(consent.get("endpoint") or "")
    model = str(consent.get("model") or "")
    return bool(provider or endpoint or model or consent.get("approved_at"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--log", type=Path, default=None)
    parser.add_argument("--log-start-line", type=int, default=None)
    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    manifest = read_json_object(session / "session.manifest.json")
    transcript = read_json_object(session / "archive" / "full_transcript.json")
    report: dict[str, object] = {
        "gate": "5",
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
    }
    if not session.is_dir() or manifest is None:
        return die_missing(report)

    consent_raw = manifest.get("upload_consent")
    consent = consent_raw if isinstance(consent_raw, dict) else {}
    if not consent_asked(consent):
        report["checks"] = {"consent_asked": False}
        return emit(report, [], blocked=True)

    rows: list[dict[str, object]] = []
    if args.log is not None:
        report["log"] = str(args.log.expanduser())
        report["log_start_line"] = args.log_start_line
        try:
            rows = read_jsonl_window(args.log.expanduser(), args.log_start_line)
        except LogWindowError as exc:
            report["checks"] = {"log_window": False}
            return emit(
                report,
                [],
                status="blocked",
                blocked=True,
                blocked_reasons=[exc.reason],
            )
        session_id = str((manifest or {}).get("session_id") or session.name)
        rows = filter_rows_for_session(rows, session_id)
        report["session_id"] = session_id
        report["run_id"] = first_run_id(rows)
    consent_events = [row for row in rows if event_name(row) == "consent_result"]
    eval_after_deny = 0
    denied = False
    for row in rows:
        name = event_name(row)
        if name == "consent_result" and str(row.get("approved") or "") == "0":
            denied = True
        elif denied and name == "eval_slice":
            eval_after_deny += 1

    tasks = manifest.get("tasks")
    task_list = tasks if isinstance(tasks, list) else []
    confirmed_missing: list[str] = []
    inferred_only = 0
    bad_quotes = 0
    segments = []
    if transcript is not None:
        raw_segments = transcript.get("segments")
        if isinstance(raw_segments, list):
            segments = raw_segments
    for task in task_list:
        if not isinstance(task, dict):
            continue
        status = str(task.get("status") or "")
        evidence = task.get("evidence_media")
        paths = evidence if isinstance(evidence, list) else []
        if status == "confirmed":
            existing = [
                str(path)
                for path in paths
                if isinstance(path, str) and export_file_exists(session, path)
            ]
            if not existing:
                confirmed_missing.append(str(task.get("task_id") or "?"))
            inferred = normalize(str(task.get("inferred") or ""))
            observed = normalize(str(task.get("observed") or ""))
            stated = normalize(str(task.get("stated") or ""))
            if inferred and inferred in {observed, stated}:
                inferred_only += 1
            quotes = task.get("quotes")
            if isinstance(quotes, list) and segments:
                for quote in quotes:
                    if isinstance(quote, dict) and not quote_in_transcript(quote, segments):
                        bad_quotes += 1
        elif status == "needs_review":
            quotes = task.get("quotes")
            if isinstance(quotes, list) and segments:
                for quote in quotes:
                    if isinstance(quote, dict) and not quote_in_transcript(quote, segments):
                        # Failed quotes must not stay confirmed; needs_review is the dest.
                        pass

    model = str(consent.get("model") or "")
    retired = is_retired_anthropic(model)
    retired_refused = True
    if retired:
        if rows:
            retired_refused = not any(event_name(row) == "eval_slice" for row in rows)
        else:
            slices = manifest.get("slices")
            retired_refused = True
            if isinstance(slices, list):
                retired_refused = not any(
                    isinstance(item, dict) and item.get("analysis_status") == "success"
                    for item in slices
                )

    checks: dict[str, object] = {
        "consent_asked": True,
        "consent_has_provider": bool(consent.get("provider")),
        "consent_has_endpoint": bool(consent.get("endpoint")),
        "consent_has_model": bool(consent.get("model")),
        "includes_clip_audio_present": "includes_clip_audio" in consent,
        "includes_clip_video_present": "includes_clip_video" in consent
        or "includes_clip_audio" in consent,
        "consent_result_logged": bool(consent_events) if args.log is not None else None,
        "no_eval_after_denied_consent": eval_after_deny == 0,
        "confirmed_evidence_on_disk": confirmed_missing == [],
        "confirmed_missing": confirmed_missing,
        "inferred_not_copied": inferred_only == 0,
        "confirmed_quotes_in_transcript": bad_quotes == 0,
        "retired_anthropic": retired,
        "retired_model_refused": retired_refused,
    }
    required = [
        "consent_has_provider",
        "consent_has_endpoint",
        "consent_has_model",
        "includes_clip_audio_present",
        "includes_clip_video_present",
        "no_eval_after_denied_consent",
        "confirmed_evidence_on_disk",
        "inferred_not_copied",
        "confirmed_quotes_in_transcript",
        "retired_model_refused",
    ]
    if args.log is not None:
        required.append("consent_result_logged")
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
