#!/usr/bin/env python3
"""Inspect ScrumTrace agent.jsonl for Gate 0 focus-steal signals.

This cannot prove Keynote kept focus. It fails when the log shows the Shot
panel became key and activated the app, which is the steal we can see.

Usage:
  python3 scripts/inspect_gate0_log.py --log ~/Library/Logs/ScrumTrace/agent.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


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
        "events": [],
    }
    if not path.is_file():
        print(json.dumps(report, indent=2))
        return 2

    events: list[dict[str, object]] = []
    shot_key_active = 0
    hotkeys = 0
    shot_shown = 0
    shot_key = 0
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        row = parse_line(raw)
        if row is None:
            continue
        name = str(row.get("event") or row.get("name") or "")
        if name.startswith("hotkey_"):
            hotkeys += 1
        if name == "shot_window_shown":
            shot_shown += 1
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
    report["events"] = events
    print(json.dumps(report, indent=2))
    if shot_key_active:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
