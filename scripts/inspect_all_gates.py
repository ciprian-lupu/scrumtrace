#!/usr/bin/env python3
"""Run every ScrumTrace gate inspector that has artifacts.

Exit 0 means runnable inspectors did not fail. Blocked gates (no session yet,
Whisper not finished, …) are listed, not invented as GATE_LOG.md PASS rows.
Never writes samples/GATE_LOG.md.

Usage:
  python3 scripts/inspect_all_gates.py --mock-only
  python3 scripts/inspect_all_gates.py --session PATH --log PATH \\
    --token ST-G1-PAUSE-TOKEN-9F3C --passphrase 'orchid lantern seven'
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
NOTE = "Inspector pass is not a GATE_LOG.md PASS. Do not invent GATE_LOG.md cells."


def run_script(script: str, extra: list[str]) -> dict[str, object]:
    cmd = [sys.executable, str(SCRIPTS / script), *extra]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    payload: dict[str, object] | None = None
    stdout = result.stdout.strip()
    if stdout:
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError:
            payload = None
    status = "pass"
    if result.returncode == 2:
        status = "blocked"
    elif result.returncode != 0:
        status = "fail"
    return {
        "script": script,
        "exit": result.returncode,
        "status": status,
        "failed": (payload or {}).get("failed", []),
        "blocked": (payload or {}).get("blocked", result.returncode == 2),
        "report": payload,
        "stderr": result.stderr.strip(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=Path, default=None)
    parser.add_argument("--log", type=Path, default=None)
    parser.add_argument("--log-start-line", type=int, default=None)
    parser.add_argument("--token", default="")
    parser.add_argument("--passphrase", default="")
    parser.add_argument("--shot-before-pause", default="")
    parser.add_argument("--mock-only", action="store_true")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat blocked gates as failure (use after a complete Mac run).",
    )
    args = parser.parse_args()

    if args.log is not None and args.log_start_line is None:
        print(
            '{"status":"blocked","blocked_reasons":["log_requires_log_start_line"],"failed":[],"manual_checks":[]}'
        )
        return 2
    if args.log_start_line is not None and args.log_start_line < 1:
        print(
            '{"status":"blocked","blocked_reasons":["log_start_line_must_be_positive"],"failed":[],"manual_checks":[]}'
        )
        return 2

    gates: dict[str, dict[str, object]] = {}
    gates["minus1"] = run_script("inspect_gate_minus1.py", [])

    if args.mock_only:
        summary = {
            "gates": {
                name: {
                    "script": row["script"],
                    "exit": row["exit"],
                    "status": row["status"],
                    "failed": row["failed"],
                }
                for name, row in gates.items()
            },
            "failed": [name for name, row in gates.items() if row["status"] == "fail"],
            "blocked": [],
            "note": NOTE,
        }
        print(json.dumps(summary, indent=2))
        return 1 if summary["failed"] else 0

    session = args.session.expanduser().resolve() if args.session else None
    log = args.log.expanduser() if args.log else None
    session_args = ["--session", str(session)] if session else None
    log_args = ["--log", str(log)] if log else None
    if log_args is not None and args.log_start_line is not None:
        log_args.extend(["--log-start-line", str(args.log_start_line)])

    if session_args:
        minus0 = ["--session", str(session)]
        if log_args:
            minus0.extend(log_args)
        gates["minus0"] = run_script("inspect_gate_minus0.py", minus0)
        gates["3"] = run_script("inspect_gate3_whisper.py", session_args)
        gates["4"] = run_script("inspect_gate4_slicer.py", session_args)
        gate5 = list(session_args)
        if log_args:
            gate5.extend(log_args)
        gates["5"] = run_script("inspect_gate5_provider.py", gate5)
        gates["6"] = run_script("inspect_gate6_pack.py", session_args)
    else:
        for name in ("minus0", "3", "4", "5", "6"):
            gates[name] = {
                "script": None,
                "exit": 2,
                "status": "blocked",
                "failed": [],
                "blocked": True,
                "report": None,
                "stderr": "no --session",
            }

    if log_args:
        gates["0"] = run_script("inspect_gate0_log.py", log_args)
        gates["2"] = run_script("inspect_gate2_shot.py", log_args)
    else:
        for name in ("0", "2"):
            gates[name] = {
                "script": None,
                "exit": 2,
                "status": "blocked",
                "failed": [],
                "blocked": True,
                "report": None,
                "stderr": "no --log",
            }

    if session_args and args.token.strip() and args.passphrase.strip():
        gate1 = [
            "--session",
            str(session),
            "--token",
            args.token,
            "--passphrase",
            args.passphrase,
            "--shot-before-pause",
            args.shot_before_pause,
        ]
        gates["1"] = run_script("inspect_gate1_session.py", gate1)
    else:
        gates["1"] = {
            "script": "inspect_gate1_session.py",
            "exit": 2,
            "status": "blocked",
            "failed": [],
            "blocked": True,
            "report": None,
            "stderr": "need --session --token --passphrase",
        }

    failed = [name for name, row in gates.items() if row["status"] == "fail"]
    blocked = [name for name, row in gates.items() if row["status"] == "blocked"]
    summary = {
        "session": str(session) if session else None,
        "log": str(log) if log else None,
        "gates": {
            name: {
                "script": row["script"],
                "exit": row["exit"],
                "status": row["status"],
                "failed": row["failed"],
            }
            for name, row in gates.items()
        },
        "failed": failed,
        "blocked": blocked,
        "note": NOTE,
    }
    print(json.dumps(summary, indent=2))
    if failed:
        return 1
    if args.strict and blocked:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
