#!/usr/bin/env python3
"""Inspect Gate 5 provider scenarios: denied, invalid-key, retired-model, evidence.

Gate 5 cannot pass from one happy-path session. Each subcommand validates one
scenario. Aggregate wiring of all four directories is TASK A11.

Inspector pass is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate5_provider.py denied --session PATH --log PATH --log-start-line N
  python3 scripts/inspect_gate5_provider.py invalid-key --session PATH --log PATH --log-start-line N
  python3 scripts/inspect_gate5_provider.py retired-model --session PATH --log PATH --log-start-line N
  python3 scripts/inspect_gate5_provider.py evidence --session PATH
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    LogWindowError,
    die_missing,
    emit,
    event_name,
    export_file_exists,
    filter_rows_for_first_run,
    filter_rows_for_session,
    is_json_number,
    is_retired_anthropic,
    read_json_object,
    read_jsonl_window,
)

PROVIDER_CALL_EVENTS = {
    "eval_slice",
    "provider_call",
    "provider_request",
    "provider_response",
}
FAILED_PIPELINE = {"offline_failed", "needs_review"}
CONFIRMED_MIN_CONFIDENCE = 0.55


def normalize(text: str) -> str:
    return " ".join(text.lower().split())


def load_rows(log: Path, start_line: int) -> tuple[list[dict[str, object]] | None, str | None]:
    try:
        return read_jsonl_window(log, start_line), None
    except LogWindowError as exc:
        return None, exc.reason


def consent_dict(manifest: dict[str, object]) -> dict[str, object]:
    raw = manifest.get("upload_consent")
    return raw if isinstance(raw, dict) else {}


def task_list(manifest: dict[str, object]) -> list[dict[str, object]]:
    tasks = manifest.get("tasks")
    if not isinstance(tasks, list):
        return []
    return [task for task in tasks if isinstance(task, dict)]


def slice_list(manifest: dict[str, object]) -> list[dict[str, object]]:
    slices = manifest.get("slices")
    if not isinstance(slices, list):
        return []
    return [item for item in slices if isinstance(item, dict)]


def local_export_usable(session: Path) -> bool:
    export = session / "export"
    if not export.is_dir():
        return False
    zip_path = export / "session-pack.zip"
    docs = list(export.glob("*.md")) + list(export.glob("*.html")) + list(export.glob("*.txt"))
    return zip_path.is_file() or bool(docs)


def quote_in_transcript(quote: dict[str, object], segments: list[object]) -> bool:
    needle = normalize(str(quote.get("text") or ""))
    if not needle:
        return False
    start = quote.get("t_media_start")
    end = quote.get("t_media_end")
    if not is_json_number(start) or not is_json_number(end):
        return False
    if float(end) < float(start):
        return False
    for item in segments:
        if not isinstance(item, dict):
            continue
        seg_start = item.get("start")
        seg_end = item.get("end")
        text = str(item.get("text") or "")
        if not is_json_number(seg_start) or not is_json_number(seg_end):
            continue
        if float(seg_end) >= float(start) and float(seg_start) <= float(end):
            if needle in normalize(text):
                return True
    return False


def quote_inside_slice(quote: dict[str, object], slices: list[dict[str, object]]) -> bool:
    start = quote.get("t_media_start")
    end = quote.get("t_media_end")
    if not is_json_number(start) or not is_json_number(end):
        return False
    source = quote.get("slice_id") or quote.get("source_slice")
    for item in slices:
        slice_id = item.get("slice_id") or item.get("id")
        if source is not None and str(slice_id) != str(source):
            continue
        s0 = item.get("start_media")
        s1 = item.get("end_media")
        if not is_json_number(s0) or not is_json_number(s1):
            continue
        if float(start) >= float(s0) and float(end) <= float(s1):
            return True
    return False


def base_report(session: Path, scenario: str) -> dict[str, object]:
    return {
        "gate": "5",
        "scenario": scenario,
        "session": str(session),
        "exists": session.is_dir(),
        "checks": {},
        # Contract-facing symbols kept in this module:
        # no_eval_after_denied_consent, confirmed_evidence_on_disk, is_retired_anthropic
    }


def require_log_window(args: argparse.Namespace, report: dict[str, object]) -> tuple[list[dict[str, object]] | None, int]:
    if args.log is None or args.log_start_line is None:
        return None, emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["log_and_log_start_line_required"],
        )
    if args.log_start_line < 1:
        return None, emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["log_start_line_must_be_positive"],
        )
    report["log"] = str(args.log.expanduser())
    report["log_start_line"] = args.log_start_line
    rows, reason = load_rows(args.log.expanduser(), args.log_start_line)
    if reason is not None:
        return None, emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=[reason],
        )
    assert rows is not None
    try:
        rows, run_id = filter_rows_for_first_run(rows)
    except LogWindowError as exc:
        return None, emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=[exc.reason],
        )
    report["run_id"] = run_id
    return rows, 0


def scenario_denied(session: Path, manifest: dict[str, object], args: argparse.Namespace) -> int:
    report = base_report(session, "denied")
    rows, code = require_log_window(args, report)
    if rows is None:
        return code
    session_id = str(manifest.get("session_id") or session.name)
    rows = filter_rows_for_session(rows, session_id)
    report["session_id"] = session_id

    consent = consent_dict(manifest)
    approved = consent.get("approved")
    denied_manifest = approved is False or str(approved) in {"0", "false", "False"}
    has_provider = bool(consent.get("provider"))
    has_endpoint = bool(consent.get("endpoint"))
    has_model = bool(consent.get("model"))

    consent_denied_logged = False
    eval_after_deny = 0
    denied_seen = False
    for row in rows:
        name = event_name(row)
        if name == "consent_result" and str(row.get("approved") or "") == "0":
            consent_denied_logged = True
            denied_seen = True
        elif denied_seen and name in PROVIDER_CALL_EVENTS:
            eval_after_deny += 1

    no_eval_after_denied_consent = eval_after_deny == 0
    export_ok = local_export_usable(session)

    checks = {
        "denied_consent_in_manifest": denied_manifest,
        "consent_has_provider": has_provider,
        "consent_has_endpoint": has_endpoint,
        "consent_has_model": has_model,
        "consent_result_denied_logged": consent_denied_logged,
        "no_eval_after_denied_consent": no_eval_after_denied_consent,
        "local_export_usable": export_ok,
    }
    required = list(checks)
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed, status="fail" if failed else "pass")


def scenario_invalid_key(session: Path, manifest: dict[str, object], args: argparse.Namespace) -> int:
    report = base_report(session, "invalid-key")
    rows, code = require_log_window(args, report)
    if rows is None:
        return code
    session_id = str(manifest.get("session_id") or session.name)
    rows = filter_rows_for_session(rows, session_id)
    report["session_id"] = session_id

    consent = consent_dict(manifest)
    approved = consent.get("approved") is True or str(consent.get("approved") or "") in {
        "1",
        "true",
        "True",
    }
    has_dest = bool(consent.get("provider") and consent.get("endpoint") and consent.get("model"))

    crash = any(event_name(row) in {"provider_crash", "fatal", "uncaught"} for row in rows)
    pipeline = str(manifest.get("pipeline_status") or "")
    slices = slice_list(manifest)
    slice_failed = [
        item
        for item in slices
        if str(item.get("analysis_status") or item.get("status") or "") in FAILED_PIPELINE
    ]
    offline_or_review = pipeline in FAILED_PIPELINE or bool(slice_failed)

    tasks = task_list(manifest)
    wrongly_confirmed = [
        task
        for task in tasks
        if str(task.get("status") or "") == "confirmed"
    ]
    export_ok = local_export_usable(session)

    checks = {
        "consent_approved_for_destination": approved and has_dest,
        "no_provider_crash": not crash,
        "pipeline_or_slices_offline_or_review": offline_or_review,
        "no_task_confirmed": wrongly_confirmed == [],
        "local_export_usable": export_ok,
        "wrongly_confirmed": [str(task.get("task_id") or "?") for task in wrongly_confirmed],
    }
    required = [
        "consent_approved_for_destination",
        "no_provider_crash",
        "pipeline_or_slices_offline_or_review",
        "no_task_confirmed",
        "local_export_usable",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed, status="fail" if failed else "pass")


def scenario_retired_model(session: Path, manifest: dict[str, object], args: argparse.Namespace) -> int:
    report = base_report(session, "retired-model")
    rows, code = require_log_window(args, report)
    if rows is None:
        return code
    session_id = str(manifest.get("session_id") or session.name)
    rows = filter_rows_for_session(rows, session_id)
    report["session_id"] = session_id

    consent = consent_dict(manifest)
    provider = str(consent.get("provider") or "")
    model = str(consent.get("model") or "")
    retired = is_retired_anthropic(model)
    provider_anthropic = provider.lower() in {"anthropic", "claude"}
    provider_calls = [row for row in rows if event_name(row) in PROVIDER_CALL_EVENTS]
    export_ok = local_export_usable(session)

    checks = {
        "provider_is_anthropic": provider_anthropic,
        "model_is_retired_anthropic": retired,
        "is_retired_anthropic": retired,  # contract-facing alias
        "no_provider_call_events": provider_calls == [],
        "local_export_usable": export_ok,
    }
    required = [
        "provider_is_anthropic",
        "model_is_retired_anthropic",
        "no_provider_call_events",
        "local_export_usable",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed, status="fail" if failed else "pass")


def scenario_evidence(session: Path, manifest: dict[str, object]) -> int:
    report = base_report(session, "evidence")
    tasks = task_list(manifest)
    slices = slice_list(manifest)
    transcript = read_json_object(session / "archive" / "full_transcript.json")
    segments: list[object] = []
    if transcript is not None:
        raw = transcript.get("segments")
        if isinstance(raw, list):
            segments = raw

    if not tasks:
        report["checks"] = {"tasks_present": False}
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["empty_task_list"],
        )

    confirmed_missing: list[str] = []
    low_confidence: list[str] = []
    inferred_only = 0
    bad_quotes = 0
    confirmed_with_failed_quote = 0

    for task in tasks:
        status = str(task.get("status") or "")
        task_id = str(task.get("task_id") or "?")
        evidence = task.get("evidence_media")
        paths = evidence if isinstance(evidence, list) else []
        quotes = task.get("quotes")
        quote_list = quotes if isinstance(quotes, list) else []

        if status == "confirmed":
            confidence = task.get("confidence")
            if not is_json_number(confidence) or float(confidence) < CONFIRMED_MIN_CONFIDENCE:
                low_confidence.append(task_id)
            existing = [
                str(path)
                for path in paths
                if isinstance(path, str) and export_file_exists(session, path)
            ]
            if not existing:
                confirmed_missing.append(task_id)
            inferred = normalize(str(task.get("inferred") or ""))
            observed = normalize(str(task.get("observed") or ""))
            stated = normalize(str(task.get("stated") or ""))
            if inferred and not observed and not stated:
                inferred_only += 1
            elif inferred and inferred in {observed, stated} and not (observed and stated):
                # Inferred copied into confirmed fields without independent evidence.
                if not existing:
                    inferred_only += 1
            for quote in quote_list:
                if not isinstance(quote, dict):
                    bad_quotes += 1
                    continue
                if not quote_in_transcript(quote, segments) or not quote_inside_slice(
                    quote, slices
                ):
                    bad_quotes += 1
                    confirmed_with_failed_quote += 1
        elif status == "needs_review":
            # Failed quotes are allowed only in needs_review.
            continue
        else:
            for quote in quote_list:
                if isinstance(quote, dict) and not quote_in_transcript(quote, segments):
                    # Non-review statuses must not carry failed quotes as confirmation proof.
                    if status == "confirmed":
                        confirmed_with_failed_quote += 1

    confirmed_evidence_on_disk = confirmed_missing == []
    checks = {
        "tasks_present": True,
        "task_count": len(tasks),
        "confirmed_min_confidence": low_confidence == [],
        "low_confidence_tasks": low_confidence,
        "confirmed_evidence_on_disk": confirmed_evidence_on_disk,
        "confirmed_missing": confirmed_missing,
        "inferred_not_alone": inferred_only == 0,
        "confirmed_quotes_valid": bad_quotes == 0 and confirmed_with_failed_quote == 0,
        "bad_quotes": bad_quotes,
    }
    required = [
        "tasks_present",
        "confirmed_min_confidence",
        "confirmed_evidence_on_disk",
        "inferred_not_alone",
        "confirmed_quotes_valid",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed, status="fail" if failed else "pass")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="scenario", required=True)

    def add_log_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--session", required=True, type=Path)
        p.add_argument("--log", required=True, type=Path)
        p.add_argument("--log-start-line", required=True, type=int)

    p_denied = sub.add_parser("denied")
    add_log_args(p_denied)
    p_invalid = sub.add_parser("invalid-key")
    add_log_args(p_invalid)
    p_retired = sub.add_parser("retired-model")
    add_log_args(p_retired)
    p_evidence = sub.add_parser("evidence")
    p_evidence.add_argument("--session", required=True, type=Path)

    args = parser.parse_args()
    session: Path = args.session.expanduser().resolve()
    report = base_report(session, str(args.scenario))
    if not session.is_dir():
        return die_missing(report)
    manifest = read_json_object(session / "session.manifest.json")
    if manifest is None:
        return die_missing(report)

    if args.scenario == "denied":
        return scenario_denied(session, manifest, args)
    if args.scenario == "invalid-key":
        return scenario_invalid_key(session, manifest, args)
    if args.scenario == "retired-model":
        return scenario_retired_model(session, manifest, args)
    if args.scenario == "evidence":
        return scenario_evidence(session, manifest)
    raise AssertionError(f"unhandled scenario {args.scenario}")


if __name__ == "__main__":
    sys.exit(main())
