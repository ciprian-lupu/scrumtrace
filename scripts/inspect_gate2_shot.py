#!/usr/bin/env python3
"""Inspect agent.jsonl for Gate 2 / Phase 2 paused-capture evidence.

Requires an explicit --log-start-line window. Within one pause window the log
must show refused Shot, Pin, and Hold-to-Talk attempts (or an in-flight talk
abort), prove Shot still works outside the pause, and reject persisted capture
actions that started during the pause.

A pass here is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate2_shot.py --session /path/to/session \\
    --log ~/Library/Logs/ScrumTrace/agent.jsonl --log-start-line N
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
    filter_rows_for_first_run,
    filter_rows_for_session,
    in_pause_window,
    pause_windows,
    read_json_object,
    read_jsonl_window,
)


def parse_t_media(row: dict[str, object]) -> float | None:
    raw = row.get("t_media")
    if isinstance(raw, bool) or not isinstance(raw, (int, float, str)):
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value):
        return None
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument(
        "--log-start-line",
        required=True,
        type=int,
        help="One-based inclusive start line for this gate run window",
    )
    args = parser.parse_args()
    path: Path = args.log.expanduser()
    report: dict[str, object] = {
        "gate": "2",
        "log": str(path),
        "exists": path.is_file(),
        "log_start_line": args.log_start_line,
        "checks": {},
    }
    if args.log_start_line < 1:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["log_start_line_must_be_positive"],
        )
    if not path.is_file():
        return die_missing(report)

    try:
        rows = read_jsonl_window(path, args.log_start_line)
    except LogWindowError as exc:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=[exc.reason],
        )

    if not rows:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["empty_log_window"],
        )
    try:
        rows, run_id = filter_rows_for_first_run(rows)
    except LogWindowError as exc:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=[exc.reason],
        )
    report["run_id"] = run_id
    session = args.session.expanduser().resolve()
    manifest = read_json_object(session / "session.manifest.json")
    if manifest is None:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["missing_session_manifest"],
        )
    session_id = str(manifest.get("session_id") or "")
    if not session_id:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["missing_session_id"],
        )
    rows = filter_rows_for_session(rows, session_id)
    report["session_id"] = session_id

    windows = pause_windows(rows)
    if not windows:
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["no_pause_window"],
        )

    # Use the first closed pause window when available; otherwise the first open one.
    closed = [window for window in windows if window[1] is not None]
    pause_start, pause_end = closed[0] if closed else windows[0]
    pause_row = rows[pause_start]
    pause_t_media = parse_t_media(pause_row)

    shot_ignored = 0
    pin_ignored = 0
    talk_start_fail = 0
    talk_press_before_pause = 0
    talk_abort_during_pause = 0
    shot_begin_during_pause = 0
    shot_save_during_pause_ok = 0
    shot_save_during_pause_bad = 0
    shot_save_missing_t_media = 0
    pin_ok_during_pause = 0
    talk_transcribe_during_pause = 0
    shot_save_outside_pause = 0
    interface_blocked_reasons: list[str] = []

    open_talk_before_pause = False
    for index, row in enumerate(rows):
        name = event_name(row)
        reason = str(row.get("reason") or "")
        inside = in_pause_window(index, [(pause_start, pause_end)])

        if index < pause_start and name == "talk_press":
            open_talk_before_pause = True
            talk_press_before_pause += 1
        if index < pause_start and name in {"talk_release", "talk_abort", "talk_transcribe_begin"}:
            open_talk_before_pause = False

        if inside:
            if name in {"shot_ignored", "shot_fail"} and reason == "paused":
                shot_ignored += 1
            elif name == "pin_ignored" and reason == "paused":
                pin_ignored += 1
            elif name == "talk_start_fail" and reason == "paused":
                talk_start_fail += 1
            elif name == "talk_abort":
                talk_abort_during_pause += 1
            elif name == "shot_begin":
                shot_begin_during_pause += 1
            elif name == "shot_save":
                t_media = parse_t_media(row)
                if t_media is None:
                    shot_save_missing_t_media += 1
                    interface_blocked_reasons.append("shot_save_missing_t_media")
                elif pause_t_media is None:
                    interface_blocked_reasons.append("pause_ok_missing_t_media")
                elif t_media < pause_t_media:
                    shot_save_during_pause_ok += 1
                else:
                    shot_save_during_pause_bad += 1
            elif name == "pin_ok":
                pin_ok_during_pause += 1
            elif name in {
                "talk_transcribe_begin",
                "talk_transcribe_ok",
                "talk_transcribe_empty",
                "talk_transcribe_fail",
            }:
                talk_transcribe_during_pause += 1
        else:
            if name == "shot_save":
                shot_save_outside_pause += 1

    talk_path_refused = talk_start_fail >= 1
    talk_path_inflight = (
        talk_press_before_pause >= 1
        and open_talk_before_pause is False
        and talk_abort_during_pause >= 1
    ) or (talk_press_before_pause >= 1 and talk_abort_during_pause >= 1)
    # In-flight path: talk_press before pause_ok, talk_abort before resume_ok.
    inflight_ok = False
    if talk_press_before_pause >= 1 and talk_abort_during_pause >= 1:
        inflight_ok = True

    checks: dict[str, object] = {
        "pause_windows": len(windows),
        "pause_start_index": pause_start,
        "pause_end_index": pause_end,
        "pause_t_media": pause_t_media,
        "shot_ignored_while_paused": shot_ignored >= 1,
        "pin_ignored_while_paused": pin_ignored >= 1,
        "talk_refused_or_aborted_while_paused": talk_path_refused or inflight_ok,
        "talk_start_fail_paused": talk_start_fail,
        "talk_press_before_pause": talk_press_before_pause,
        "talk_abort_during_pause": talk_abort_during_pause,
        "no_shot_begin_during_pause": shot_begin_during_pause == 0,
        "no_bad_shot_save_during_pause": shot_save_during_pause_bad == 0,
        "shot_save_during_pause_predated": shot_save_during_pause_ok,
        "no_pin_ok_during_pause": pin_ok_during_pause == 0,
        "no_talk_transcribe_during_pause": talk_transcribe_during_pause == 0,
        "shot_save_outside_pause": shot_save_outside_pause >= 1,
        "counts": {
            "shot_ignored": shot_ignored,
            "pin_ignored": pin_ignored,
            "talk_start_fail": talk_start_fail,
            "shot_begin_during_pause": shot_begin_during_pause,
            "shot_save_during_pause_ok": shot_save_during_pause_ok,
            "shot_save_during_pause_bad": shot_save_during_pause_bad,
            "shot_save_missing_t_media": shot_save_missing_t_media,
            "pin_ok_during_pause": pin_ok_during_pause,
            "talk_transcribe_during_pause": talk_transcribe_during_pause,
            "shot_save_outside_pause": shot_save_outside_pause,
        },
    }
    report["checks"] = checks

    if interface_blocked_reasons:
        # Missing capture-time fields cannot be invented here; needs A06b Swift logging.
        unique = sorted(set(interface_blocked_reasons))
        report["interface_blocked"] = "INTERFACE_BLOCKED"
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["INTERFACE_BLOCKED", *unique],
        )

    attempt_required = [
        "shot_ignored_while_paused",
        "pin_ignored_while_paused",
        "talk_refused_or_aborted_while_paused",
        "shot_save_outside_pause",
    ]
    violation_required = [
        "no_shot_begin_during_pause",
        "no_bad_shot_save_during_pause",
        "no_pin_ok_during_pause",
        "no_talk_transcribe_during_pause",
    ]
    required = attempt_required + violation_required
    report["required"] = required
    missing_attempts = [key for key in attempt_required if checks.get(key) is not True]
    violations = [key for key in violation_required if checks.get(key) is not True]
    if missing_attempts:
        return emit(
            report,
            missing_attempts + violations,
            status="blocked",
            blocked=True,
            blocked_reasons=["missing_required_pause_attempts", *missing_attempts],
        )
    if violations:
        return emit(report, violations, status="fail")
    return emit(report, [], status="pass")


if __name__ == "__main__":
    sys.exit(main())
