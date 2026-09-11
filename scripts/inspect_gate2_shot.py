#!/usr/bin/env python3
"""Inspect agent.jsonl for Phase 2 / Gate 1 Shot-pause violations.

Fails only when a Shot, Pin, or Hold-to-Talk persisted during an open pause.
Missing pause attempts are reported, not invented as GATE_LOG PASS rows.

Usage:
  python3 scripts/inspect_gate2_shot.py --log ~/Library/Logs/ScrumTrace/agent.jsonl
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from gate_inspect_lib import (
    die_missing,
    emit,
    event_name,
    in_pause_window,
    pause_windows,
    read_jsonl,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args()
    path: Path = args.log.expanduser()
    rows = read_jsonl(path)
    report: dict[str, object] = {
        "gate": "2",
        "log": str(path),
        "exists": path.is_file(),
        "checks": {},
    }
    if not path.is_file():
        return die_missing(report)

    windows = pause_windows(rows)
    shot_ok = 0
    shot_violations = 0
    talk_ok = 0
    talk_press_during = 0
    talk_abort_during = 0
    pin_ok = 0
    pin_violations = 0
    for index, row in enumerate(rows):
        if not in_pause_window(index, windows):
            continue
        name = event_name(row)
        reason = str(row.get("reason") or "")
        if name in {"shot_ignored", "shot_fail"} and reason == "paused":
            shot_ok += 1
        elif name in {"shot_begin", "shot_save"}:
            shot_violations += 1
        elif name in {"talk_start_fail", "talk_abort"}:
            talk_ok += 1
            if name == "talk_abort":
                talk_abort_during += 1
        elif name == "talk_press":
            talk_press_during += 1
        elif name == "pin_ignored" and reason == "paused":
            pin_ok += 1
        elif name == "pin_ok":
            pin_violations += 1
    talk_violations = max(0, talk_press_during - talk_abort_during)

    checks = {
        "pause_windows": len(windows),
        "shot_refused_while_paused": shot_ok,
        "shot_persisted_while_paused": shot_violations,
        "talk_refused_while_paused": talk_ok,
        "talk_persisted_while_paused": talk_violations,
        "pin_ignored_while_paused": pin_ok,
        "pin_ok_while_paused": pin_violations,
        "no_shot_persist_during_pause": shot_violations == 0,
        "no_talk_persist_during_pause": talk_violations == 0,
        "no_pin_during_pause": pin_violations == 0,
        "exercised": (shot_ok + talk_ok + pin_ok) > 0,
    }
    if not windows:
        report["checks"] = checks
        report["required"] = []
        return emit(report, [], blocked=True)

    required = [
        "no_shot_persist_during_pause",
        "no_talk_persist_during_pause",
        "no_pin_during_pause",
    ]
    report["checks"] = checks
    report["required"] = required
    failed = [key for key in required if checks.get(key) is not True]
    return emit(report, failed)


if __name__ == "__main__":
    sys.exit(main())
