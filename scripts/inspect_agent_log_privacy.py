#!/usr/bin/env python3
"""Structural privacy check for ScrumTrace agent JSONL logs.

Rejects forbidden content keys and user-supplied marker values.
Permits documented technical keys such as has_url.
Never prints a rejected secret value — only line number and key.

Usage:
  python3 scripts/inspect_agent_log_privacy.py --log PATH \\
    --forbidden-value 'ST-G1-PAUSE-TOKEN-9F3C' \\
    --forbidden-value 'orchid lantern seven'
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

FORBIDDEN_KEYS = {
    "title",
    "window_title",
    "url",
    "note",
    "transcript",
    "api_key",
    "token",
    "passphrase",
    "secret",
}
ALLOWED_TECHNICAL_KEYS = {"has_url"}


def walk(obj: object, prefix: str = "") -> list[tuple[str, object]]:
    found: list[tuple[str, object]] = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            found.append((path, value))
            found.extend(walk(value, path))
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            path = f"{prefix}[{index}]"
            found.extend(walk(value, path))
    return found


def leaf_key(path: str) -> str:
    if "[" in path:
        path = path.split("[", 1)[0]
    if "." in path:
        return path.rsplit(".", 1)[-1]
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument(
        "--forbidden-value",
        action="append",
        default=[],
        help="Marker string that must not appear as any JSONL string value",
    )
    args = parser.parse_args()

    log_path = args.log.expanduser()
    markers = [value for value in args.forbidden_value if value]
    findings: list[dict[str, object]] = []

    if not log_path.is_file():
        report = {
            "status": "blocked",
            "blocked_reasons": ["missing_log"],
            "failed": [],
            "manual_checks": [],
            "findings": [],
        }
        print(json.dumps(report, indent=2))
        return 2

    for line_no, raw in enumerate(
        log_path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
    ):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError:
            findings.append(
                {
                    "line": line_no,
                    "key": "<json>",
                    "reason": "malformed_json",
                }
            )
            continue
        if not isinstance(row, dict):
            findings.append(
                {
                    "line": line_no,
                    "key": "<root>",
                    "reason": "non_object_row",
                }
            )
            continue
        for path, value in walk(row):
            key = leaf_key(path)
            if key in ALLOWED_TECHNICAL_KEYS:
                continue
            if key in FORBIDDEN_KEYS:
                findings.append(
                    {
                        "line": line_no,
                        "key": key,
                        "reason": "forbidden_key",
                    }
                )
                continue
            if markers and isinstance(value, str):
                for marker in markers:
                    if marker and marker in value:
                        findings.append(
                            {
                                "line": line_no,
                                "key": key,
                                "reason": "forbidden_value",
                            }
                        )
                        break

    # Never include marker/secret text in the report.
    if findings:
        report = {
            "status": "fail",
            "failed": [
                f"line={item['line']} key={item['key']} reason={item['reason']}"
                for item in findings
            ],
            "blocked_reasons": [],
            "manual_checks": [],
            "findings": findings,
        }
        print(json.dumps(report, indent=2))
        return 1

    report = {
        "status": "pass",
        "failed": [],
        "blocked_reasons": [],
        "manual_checks": [],
        "findings": [],
    }
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
