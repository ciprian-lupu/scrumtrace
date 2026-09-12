#!/usr/bin/env python3
"""Inspect ScrumTrace agent.jsonl for Gate 0 Keynote hotkey evidence.

Requires an explicit --log-start-line window. Proves Shot/Pin/Pause happened
while Keynote stayed frontmost and ScrumTrace stayed inactive, and preserves
Start-overlay sequencing checks.

A pass here is not a GATE_LOG.md PASS.

Usage:
  python3 scripts/inspect_gate0_log.py --log ~/Library/Logs/ScrumTrace/agent.jsonl \\
    --log-start-line N
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    LogWindowError,
    emit,
    filter_rows_for_first_run,
    read_jsonl_window,
)

KEYNOTE = "com.apple.iWork.Keynote"


def record_overlay_step(mode: str, awaiting_start: bool) -> bool:
    if not awaiting_start:
        return False
    return mode == "record"


def front_ok(row: dict[str, object]) -> bool:
    return (
        str(row.get("app_active") or "") == "0"
        and str(row.get("front") or "") == KEYNOTE
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--log-start-line", required=True, type=int)
    args = parser.parse_args()
    path: Path = args.log.expanduser()
    report: dict[str, object] = {
        "gate": "0",
        "log": str(path),
        "log_start_line": args.log_start_line,
        "exists": path.is_file(),
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
        return emit(
            report,
            [],
            status="blocked",
            blocked=True,
            blocked_reasons=["missing_log"],
        )

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

    hotkey_shot = 0
    hotkey_pin = 0
    hotkey_pause = 0
    shot_front_ok = 0
    pin_front_ok = 0
    shot_front_bad = 0
    pin_front_bad = 0
    shot_key_ok = 0
    shot_key_bad = 0
    pause_ok = 0
    pin_ok = 0
    picker_open = 0
    picker_confirm = 0
    picker_cancel = 0
    menu_start = 0
    start_requested = 0
    start_without_overlay = 0
    awaiting_overlay = False
    saw_open = False
    saw_confirm = False
    hotkey_activated_app = 0

    for row in rows:
        name = str(row.get("event") or row.get("name") or "")
        action = str(row.get("action") or "")
        mode = str(row.get("mode") or "")
        if name == "hotkey_shot":
            hotkey_shot += 1
        elif name == "hotkey_pin":
            hotkey_pin += 1
        elif name == "hotkey_pause":
            hotkey_pause += 1
        elif name == "hotkey_front":
            if str(row.get("app_active") or "") == "1":
                hotkey_activated_app += 1
            if action == "shot":
                if front_ok(row):
                    shot_front_ok += 1
                else:
                    shot_front_bad += 1
            elif action == "pin":
                if front_ok(row):
                    pin_front_ok += 1
                else:
                    pin_front_bad += 1
        elif name == "shot_window_key":
            if front_ok(row):
                shot_key_ok += 1
            else:
                shot_key_bad += 1
        elif name in {"pause_ok", "resume_ok"}:
            pause_ok += 1
        elif name == "pin_ok":
            pin_ok += 1
        elif name == "menu_start":
            menu_start += 1
            awaiting_overlay = True
            saw_open = False
            saw_confirm = False
        elif name == "capture_area_picker":
            if action == "open":
                picker_open += 1
                if record_overlay_step(mode, awaiting_overlay):
                    saw_open = True
            elif action == "confirm":
                picker_confirm += 1
                if record_overlay_step(mode, awaiting_overlay):
                    saw_confirm = True
            elif action == "cancel":
                picker_cancel += 1
                awaiting_overlay = False
        elif name == "start_requested":
            start_requested += 1
            if awaiting_overlay and not (saw_open and saw_confirm):
                start_without_overlay += 1
            awaiting_overlay = False

    checks: dict[str, object] = {
        "hotkey_shot": hotkey_shot == 1,
        "hotkey_pin": hotkey_pin == 1,
        "hotkey_pause": hotkey_pause == 1,
        "shot_front_keynote_inactive": shot_front_ok >= 1 and shot_front_bad == 0,
        "pin_front_keynote_inactive": pin_front_ok >= 1 and pin_front_bad == 0,
        "shot_window_key_keynote_inactive": shot_key_ok >= 1 and shot_key_bad == 0,
        "pause_lifecycle": pause_ok >= 1,
        "pin_ok_while_recording": pin_ok >= 1,
        "no_hotkey_activated_app": hotkey_activated_app == 0,
        "start_without_overlay": start_without_overlay,
        "overlay_sequence_ok": start_without_overlay == 0,
        "counts": {
            "hotkey_shot": hotkey_shot,
            "hotkey_pin": hotkey_pin,
            "hotkey_pause": hotkey_pause,
            "shot_front_ok": shot_front_ok,
            "pin_front_ok": pin_front_ok,
            "pause_ok": pause_ok,
            "pin_ok": pin_ok,
            "menu_start": menu_start,
            "picker_open": picker_open,
            "picker_confirm": picker_confirm,
            "picker_cancel": picker_cancel,
            "start_requested": start_requested,
        },
    }
    required = [
        "hotkey_shot",
        "hotkey_pin",
        "hotkey_pause",
        "shot_front_keynote_inactive",
        "pin_front_keynote_inactive",
        "shot_window_key_keynote_inactive",
        "pause_lifecycle",
        "pin_ok_while_recording",
        "no_hotkey_activated_app",
        "overlay_sequence_ok",
    ]
    report["checks"] = checks
    report["required"] = required
    # Preserve legacy numeric field used by older tests/readers.
    report["start_without_overlay"] = start_without_overlay
    report["shot_became_key_while_app_active"] = shot_key_bad
    report["hotkey_activated_app"] = hotkey_activated_app
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
