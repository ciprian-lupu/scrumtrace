#!/usr/bin/env python3
"""Inspect ScrumTrace agent.jsonl for Gate 0 focus-steal and overlay signals.

This cannot prove Keynote kept focus. It fails when the log shows the Shot
panel became key and activated the app, which is the steal we can see.

It also fails when menu Start requested capture without opening and confirming
the capture-area overlay in record mode (Record after the lasting dashed rectangle).

Usage:
  python3 scripts/inspect_gate0_log.py --log ~/Library/Logs/ScrumTrace/agent.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def record_overlay_step(mode: str, awaiting_start: bool) -> bool:
    if not awaiting_start:
        return False
    return mode == "record"


def parse_line(raw: str) -> dict[str, object] | None:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args()
    path: Path = args.log.expanduser()
    report: dict[str, object] = {
        "log": str(path),
        "exists": path.is_file(),
        "hotkeys": 0,
        "shot_shown": 0,
        "shot_became_key": 0,
        "shot_became_key_while_app_active": 0,
        "hotkey_activated_app": 0,
        "picker_open": 0,
        "picker_confirm": 0,
        "picker_cancel": 0,
        "menu_start": 0,
        "start_requested": 0,
        "start_without_overlay": 0,
        "events": [],
    }
    if not path.is_file():
        print(json.dumps(report, indent=2))
        return 2

    events: list[dict[str, object]] = []
    shot_key_active = 0
    hotkey_activated = 0
    hotkeys = 0
    shot_shown = 0
    shot_key = 0
    picker_open = 0
    picker_confirm = 0
    picker_cancel = 0
    menu_start = 0
    start_requested = 0
    start_without_overlay = 0
    awaiting_overlay = False
    saw_open = False
    saw_confirm = False
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        row = parse_line(raw)
        if row is None:
            continue
        name = str(row.get("event") or row.get("name") or "")
        action = str(row.get("action") or "")
        picker_mode = str(row.get("mode") or "")
        if name.startswith("hotkey_"):
            hotkeys += 1
        if name == "shot_window_shown":
            shot_shown += 1
        if name == "menu_start":
            menu_start += 1
            awaiting_overlay = True
            saw_open = False
            saw_confirm = False
        if name == "capture_area_picker":
            if action == "open":
                picker_open += 1
                if record_overlay_step(picker_mode, awaiting_overlay):
                    saw_open = True
            elif action == "confirm":
                picker_confirm += 1
                if record_overlay_step(picker_mode, awaiting_overlay):
                    saw_confirm = True
            elif action == "cancel":
                picker_cancel += 1
                awaiting_overlay = False
            events.append({"event": name, "action": action, "mode": row.get("mode")})
        if name == "start_requested":
            start_requested += 1
            if awaiting_overlay and not (saw_open and saw_confirm):
                start_without_overlay += 1
            awaiting_overlay = False
        if name == "hotkey_front":
            active = str(row.get("app_active") or "") == "1"
            if active:
                hotkey_activated += 1
            events.append(
                {
                    "event": name,
                    "action": row.get("action"),
                    "app_active": row.get("app_active"),
                    "front": row.get("front"),
                }
            )
        if name == "shot_window_key":
            shot_key += 1
            active = str(row.get("app_active") or "") == "1"
            if active:
                shot_key_active += 1
            events.append(
                {
                    "event": name,
                    "app_active": row.get("app_active"),
                    "front": row.get("front"),
                }
            )
    report["hotkeys"] = hotkeys
    report["shot_shown"] = shot_shown
    report["shot_became_key"] = shot_key
    report["shot_became_key_while_app_active"] = shot_key_active
    report["hotkey_activated_app"] = hotkey_activated
    report["picker_open"] = picker_open
    report["picker_confirm"] = picker_confirm
    report["picker_cancel"] = picker_cancel
    report["menu_start"] = menu_start
    report["start_requested"] = start_requested
    report["start_without_overlay"] = start_without_overlay
    report["events"] = events
    print(json.dumps(report, indent=2))
    if shot_key_active or hotkey_activated or start_without_overlay:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
