#!/usr/bin/env python3
"""Run every ScrumTrace gate inspector that has artifacts.

Exit 0 means runnable inspectors did not fail. Blocked / manual_required gates
are listed, never invented as GATE_LOG.md PASS rows.
Never writes samples/GATE_LOG.md.

Usage:
  python3 scripts/inspect_all_gates.py --mock-only
  python3 scripts/inspect_all_gates.py --artifact-map path/to/map.json --strict
  python3 scripts/inspect_all_gates.py --session PATH --log PATH \\
    --log-start-line N --token TOKEN --passphrase '…' \\
    --manual-video-scrub-ok --manual-audio-scrub-ok \\
    --av-offset-ms 12 --ptt-temp-deleted-ok
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path(os.environ.get("SCRUMTRACE_GATE_SCRIPTS", str(ROOT / "scripts")))
NOTE = "Inspector pass is not a GATE_LOG.md PASS. Do not invent GATE_LOG.md cells."

GATE_ORDER = ["minus1", "minus0", "0", "1", "2", "3", "4", "5", "6"]
ARTIFACT_MAP_KEYS = ("minus0", "0", "1/2", "3", "4", "5", "6")
GATE5_KEYS = ("denied", "invalid_key", "retired_model", "evidence")
GATE5_SUBCOMMANDS = {
    "denied": "denied",
    "invalid_key": "invalid-key",
    "retired_model": "retired-model",
    "evidence": "evidence",
}
ARTIFACT_ENTRY_KEYS = {
    "minus0": {"session", "log", "log_start_line"},
    "0": {"log", "log_start_line"},
    "1/2": {
        "session",
        "log",
        "log_start_line",
        "token",
        "passphrase",
        "manual_video_scrub_ok",
        "manual_audio_scrub_ok",
        "av_offset_ms",
        "ptt_temp_deleted_ok",
    },
    "3": {"session", "target_media_seconds", "target_wall_seconds"},
    "4": {"session", "chrome_playback_ok"},
    "6": {"session"},
}
GATE5_ENTRY_KEYS = {
    "denied": {"session", "log", "log_start_line"},
    "invalid_key": {"session", "log", "log_start_line"},
    "retired_model": {"session", "log", "log_start_line"},
    "evidence": {"session"},
}
REQUIRED_REPORT_FIELDS = ("status", "blocked_reasons", "manual_checks")
ALLOWED_STATUSES = {"pass", "fail", "blocked", "manual_required"}


def blocked_row(script: str | None, reason: str, *, next_action: str) -> dict[str, Any]:
    return {
        "script": script,
        "exit": 2,
        "status": "blocked",
        "failed": [],
        "blocked_reasons": [reason],
        "manual_checks": [],
        "next_action": next_action,
        "report": None,
        "stderr": reason,
    }


def fail_row(
    script: str | None,
    reason: str,
    *,
    exit_code: int = 1,
    stderr: str = "",
    report: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "script": script,
        "exit": exit_code,
        "status": "fail",
        "failed": [reason],
        "blocked_reasons": [],
        "manual_checks": [],
        "next_action": f"Fix inspector contract failure: {reason}",
        "report": report,
        "stderr": stderr,
    }


def next_action_for(
    script: str | None,
    status: str,
    blocked_reasons: list[Any],
    manual_checks: list[Any],
) -> str:
    if status == "pass":
        return ""
    if status == "manual_required":
        checks = ", ".join(str(item) for item in manual_checks) or "manual checks"
        return f"Supply human assertions for {script}: {checks}"
    if status == "blocked":
        reasons = ", ".join(str(item) for item in blocked_reasons) or "missing artifacts"
        return f"Provide artifacts for {script}: {reasons}"
    return f"Repair {script}: see failed checks"


def run_script(script: str, extra: list[str]) -> dict[str, Any]:
    cmd = [sys.executable, str(SCRIPTS / script), *extra]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    stdout = result.stdout.strip()
    stderr = result.stderr.strip()
    if not stdout:
        return fail_row(script, "malformed_inspector_output", stderr=stderr)
    try:
        loaded = json.loads(stdout)
    except json.JSONDecodeError:
        return fail_row(script, "malformed_inspector_output", stderr=stderr)
    if not isinstance(loaded, dict):
        return fail_row(script, "malformed_inspector_output", stderr=stderr)

    missing = [field for field in REQUIRED_REPORT_FIELDS if field not in loaded]
    if missing:
        return fail_row(
            script,
            f"missing_report_fields:{','.join(missing)}",
            stderr=stderr,
            report=loaded,
        )

    status = loaded.get("status")
    if status not in ALLOWED_STATUSES:
        return fail_row(script, "invalid_status", stderr=stderr, report=loaded)

    if result.returncode not in (0, 1, 2):
        return fail_row(
            script,
            f"unexpected_exit:{result.returncode}",
            exit_code=result.returncode,
            stderr=stderr,
            report=loaded,
        )
    if result.returncode == 0 and status != "pass":
        return fail_row(script, "exit_status_mismatch", stderr=stderr, report=loaded)
    if result.returncode == 1 and status != "fail":
        return fail_row(script, "exit_status_mismatch", stderr=stderr, report=loaded)
    if result.returncode == 2 and status not in {"blocked", "manual_required"}:
        return fail_row(script, "exit_status_mismatch", stderr=stderr, report=loaded)

    blocked_reasons = loaded.get("blocked_reasons")
    manual_checks = loaded.get("manual_checks")
    if not isinstance(blocked_reasons, list) or not isinstance(manual_checks, list):
        return fail_row(script, "malformed_report_lists", stderr=stderr, report=loaded)

    return {
        "script": script,
        "exit": result.returncode,
        "status": status,
        "failed": list(loaded.get("failed") or []),
        "blocked_reasons": list(blocked_reasons),
        "manual_checks": list(manual_checks),
        "next_action": next_action_for(script, str(status), blocked_reasons, manual_checks),
        "report": loaded,
        "stderr": stderr,
    }


def load_artifact_map(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"artifact_map_invalid:{exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("artifact_map_must_be_object")
    return data


def validate_artifact_map(data: dict[str, Any], *, strict: bool) -> list[str]:
    errors: list[str] = []
    unknown = sorted(set(data) - set(ARTIFACT_MAP_KEYS))
    if unknown:
        errors.append(f"unknown_artifact_map_keys:{','.join(unknown)}")
    if strict:
        missing = [key for key in ARTIFACT_MAP_KEYS if key not in data]
        if missing:
            errors.append(f"missing_artifact_map_keys:{','.join(missing)}")

    def require_session(entry: dict[str, Any], label: str) -> None:
        if "session" not in entry or not str(entry.get("session") or "").strip():
            errors.append(f"{label}_missing_session")

    def require_log(entry: dict[str, Any], label: str) -> None:
        if "log" not in entry or not str(entry.get("log") or "").strip():
            errors.append(f"{label}_missing_log")
        if "log_start_line" not in entry:
            errors.append(f"{label}_missing_log_start_line")
        else:
            try:
                line = int(entry["log_start_line"])
            except (TypeError, ValueError):
                errors.append(f"{label}_log_start_line_invalid")
            else:
                if line < 1:
                    errors.append(f"{label}_log_start_line_must_be_positive")

    def reject_unknown(
        entry: dict[str, Any], allowed: set[str], label: str
    ) -> None:
        if not strict:
            return
        extra = sorted(set(entry) - allowed)
        if extra:
            errors.append(f"{label}_unknown_keys:{','.join(extra)}")

    for key, entry in data.items():
        if key not in ARTIFACT_MAP_KEYS:
            continue
        if not isinstance(entry, dict):
            errors.append(f"{key}_entry_must_be_object")
            continue
        if key == "minus0":
            reject_unknown(entry, ARTIFACT_ENTRY_KEYS[key], key)
            require_session(entry, key)
            require_log(entry, key)
        elif key == "0":
            reject_unknown(entry, ARTIFACT_ENTRY_KEYS[key], key)
            require_log(entry, key)
        elif key == "1/2":
            reject_unknown(entry, ARTIFACT_ENTRY_KEYS[key], key)
            require_session(entry, key)
            require_log(entry, key)
        elif key in {"3", "4", "6"}:
            reject_unknown(entry, ARTIFACT_ENTRY_KEYS[key], key)
            require_session(entry, key)
        elif key == "5":
            unknown5 = sorted(set(entry) - set(GATE5_KEYS))
            if unknown5:
                errors.append(f"gate5_unknown_keys:{','.join(unknown5)}")
            if strict:
                missing5 = [name for name in GATE5_KEYS if name not in entry]
                if missing5:
                    errors.append(f"gate5_missing_keys:{','.join(missing5)}")
            for name, nested in entry.items():
                if name not in GATE5_KEYS:
                    continue
                if not isinstance(nested, dict):
                    errors.append(f"gate5_{name}_must_be_object")
                    continue
                reject_unknown(
                    nested, GATE5_ENTRY_KEYS[name], f"gate5_{name}"
                )
                require_session(nested, f"gate5_{name}")
                if name != "evidence":
                    require_log(nested, f"gate5_{name}")

    if strict:
        session_uses: dict[str, list[str]] = {}
        log_window_uses: dict[tuple[str, int], list[str]] = {}

        def record_artifacts(entry: dict[str, Any], label: str) -> None:
            session = entry.get("session")
            if isinstance(session, str) and session.strip():
                identity = str(Path(session).expanduser().resolve())
                session_uses.setdefault(identity, []).append(label)
            log = entry.get("log")
            line = entry.get("log_start_line")
            if isinstance(log, str) and log.strip():
                try:
                    line_number = int(line)
                except (TypeError, ValueError):
                    pass
                else:
                    identity = (
                        str(Path(log).expanduser().resolve()),
                        line_number,
                    )
                    log_window_uses.setdefault(identity, []).append(label)

        for key in ("minus0", "0", "1/2", "3", "4", "6"):
            value = data.get(key)
            if isinstance(value, dict):
                record_artifacts(value, key)
        gate5 = data.get("5")
        if isinstance(gate5, dict):
            for name in GATE5_KEYS:
                value = gate5.get(name)
                if isinstance(value, dict):
                    record_artifacts(value, f"5.{name}")

        related_pipeline = {"3", "4", "6"}
        for labels in session_uses.values():
            if len(labels) < 2:
                continue
            if set(labels).issubset(related_pipeline):
                continue
            errors.append(f"session_reused:{','.join(sorted(labels))}")
        for labels in log_window_uses.values():
            if len(labels) > 1:
                errors.append(f"log_window_reused:{','.join(sorted(labels))}")
    return errors


def path_from(entry: dict[str, Any], key: str) -> Path | None:
    raw = entry.get(key)
    if raw is None or str(raw).strip() == "":
        return None
    return Path(str(raw)).expanduser()


def summarize_gate5(rows: dict[str, dict[str, Any]]) -> dict[str, Any]:
    statuses = [row["status"] for row in rows.values()]
    if any(status == "fail" for status in statuses):
        status = "fail"
        exit_code = 1
    elif any(status == "manual_required" for status in statuses):
        status = "manual_required"
        exit_code = 2
    elif any(status == "blocked" for status in statuses):
        status = "blocked"
        exit_code = 2
    else:
        status = "pass"
        exit_code = 0
    blocked_reasons: list[str] = []
    manual_checks: list[str] = []
    failed: list[str] = []
    for name, row in rows.items():
        for item in row.get("blocked_reasons") or []:
            blocked_reasons.append(f"{name}:{item}")
        for item in row.get("manual_checks") or []:
            manual_checks.append(f"{name}:{item}")
        for item in row.get("failed") or []:
            failed.append(f"{name}:{item}")
    return {
        "script": "inspect_gate5_provider.py",
        "exit": exit_code,
        "status": status,
        "failed": failed,
        "blocked_reasons": blocked_reasons,
        "manual_checks": manual_checks,
        "next_action": next_action_for(
            "inspect_gate5_provider.py", status, blocked_reasons, manual_checks
        ),
        "report": {"scenarios": {name: row.get("report") for name, row in rows.items()}},
        "stderr": "",
        "scenarios": {
            name: {
                "status": row["status"],
                "exit": row["exit"],
                "failed": row["failed"],
                "blocked_reasons": row["blocked_reasons"],
                "manual_checks": row["manual_checks"],
                "next_action": row["next_action"],
            }
            for name, row in rows.items()
        },
    }


def gate1_args_from_entry(
    entry: dict[str, Any],
    *,
    token: str,
    passphrase: str,
    manual_video: bool,
    manual_audio: bool,
    av_offset_ms: float | None,
    ptt_ok: bool,
) -> list[str] | None:
    session = path_from(entry, "session")
    tok = str(entry.get("token") or token).strip()
    phrase = str(entry.get("passphrase") or passphrase).strip()
    if session is None or not tok or not phrase:
        return None
    args = [
        "--session",
        str(session.resolve()),
        "--token",
        tok,
        "--passphrase",
        phrase,
    ]
    video_ok = bool(entry.get("manual_video_scrub_ok", manual_video))
    audio_ok = bool(entry.get("manual_audio_scrub_ok", manual_audio))
    ptt = bool(entry.get("ptt_temp_deleted_ok", ptt_ok))
    offset = entry.get("av_offset_ms", av_offset_ms)
    if video_ok:
        args.append("--manual-video-scrub-ok")
    if audio_ok:
        args.append("--manual-audio-scrub-ok")
    if ptt:
        args.append("--ptt-temp-deleted-ok")
    if offset is not None and str(offset).strip() != "":
        args.extend(["--av-offset-ms", str(offset)])
    return args


def public_gate_summary(row: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {
        "script": row.get("script"),
        "exit": row.get("exit"),
        "status": row.get("status"),
        "failed": row.get("failed") or [],
        "blocked_reasons": row.get("blocked_reasons") or [],
        "manual_checks": row.get("manual_checks") or [],
        "next_action": row.get("next_action") or "",
    }
    if "scenarios" in row:
        out["scenarios"] = row["scenarios"]
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=Path, default=None)
    parser.add_argument("--log", type=Path, default=None)
    parser.add_argument("--log-start-line", type=int, default=None)
    parser.add_argument("--token", default="")
    parser.add_argument("--passphrase", default="")
    parser.add_argument("--manual-video-scrub-ok", action="store_true")
    parser.add_argument("--manual-audio-scrub-ok", action="store_true")
    parser.add_argument("--av-offset-ms", type=float, default=None)
    parser.add_argument("--ptt-temp-deleted-ok", action="store_true")
    parser.add_argument("--target-media-seconds", type=float, default=None)
    parser.add_argument("--target-wall-seconds", type=float, default=None)
    parser.add_argument("--chrome-playback-ok", action="store_true")
    parser.add_argument("--artifact-map", type=Path, default=None)
    parser.add_argument("--mock-only", action="store_true")
    parser.add_argument(
        "--guided",
        action="store_true",
        help="Stop after Gate -0 failure (mac_all_gates guided workflow).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Succeed only when every requested gate status is pass.",
    )
    args = parser.parse_args()

    if args.log is not None and args.log_start_line is None and args.artifact_map is None:
        print(
            json.dumps(
                {
                    "status": "blocked",
                    "blocked_reasons": ["log_requires_log_start_line"],
                    "failed": [],
                    "manual_checks": [],
                }
            )
        )
        return 2
    if args.log_start_line is not None and args.log_start_line < 1:
        print(
            json.dumps(
                {
                    "status": "blocked",
                    "blocked_reasons": ["log_start_line_must_be_positive"],
                    "failed": [],
                    "manual_checks": [],
                }
            )
        )
        return 2

    artifact_map: dict[str, Any] | None = None
    if args.artifact_map is not None:
        try:
            artifact_map = load_artifact_map(args.artifact_map.expanduser())
        except ValueError as exc:
            print(
                json.dumps(
                    {
                        "status": "fail",
                        "failed": [str(exc)],
                        "blocked_reasons": [],
                        "manual_checks": [],
                        "note": NOTE,
                    },
                    indent=2,
                )
            )
            return 1
        map_errors = validate_artifact_map(artifact_map, strict=args.strict)
        if map_errors:
            print(
                json.dumps(
                    {
                        "status": "fail",
                        "failed": map_errors,
                        "blocked_reasons": [],
                        "manual_checks": [],
                        "note": NOTE,
                    },
                    indent=2,
                )
            )
            return 1
    elif args.strict and not args.mock_only:
        print(
            json.dumps(
                {
                    "status": "fail",
                    "failed": ["strict_requires_artifact_map"],
                    "blocked_reasons": [],
                    "manual_checks": [],
                    "note": NOTE,
                },
                indent=2,
            )
        )
        return 1

    gates: dict[str, dict[str, Any]] = {}
    gates["minus1"] = run_script("inspect_gate_minus1.py", [])

    if args.mock_only:
        summary = {
            "gates": {name: public_gate_summary(row) for name, row in gates.items()},
            "failed": [name for name, row in gates.items() if row["status"] == "fail"],
            "blocked": [
                name
                for name, row in gates.items()
                if row["status"] in {"blocked", "manual_required"}
            ],
            "manual_required": [
                name for name, row in gates.items() if row["status"] == "manual_required"
            ],
            "next_actions": {
                name: row["next_action"]
                for name, row in gates.items()
                if row.get("next_action")
            },
            "note": NOTE,
        }
        print(json.dumps(summary, indent=2))
        if summary["failed"]:
            return 1
        if args.strict and (summary["blocked"] or summary["manual_required"]):
            return 1
        return 0

    session = args.session.expanduser().resolve() if args.session else None
    log = args.log.expanduser() if args.log else None

    def entry(key: str) -> dict[str, Any] | None:
        if artifact_map is None:
            return None
        value = artifact_map.get(key)
        return value if isinstance(value, dict) else None

    minus0_entry = entry("minus0")
    if minus0_entry is not None:
        minus0_session = path_from(minus0_entry, "session")
        minus0_log = path_from(minus0_entry, "log")
        minus0_line = int(minus0_entry["log_start_line"])
        assert minus0_session is not None and minus0_log is not None
        gates["minus0"] = run_script(
            "inspect_gate_minus0.py",
            [
                "--session",
                str(minus0_session.resolve()),
                "--log",
                str(minus0_log),
                "--log-start-line",
                str(minus0_line),
            ],
        )
    elif session is not None and log is not None and args.log_start_line is not None:
        gates["minus0"] = run_script(
            "inspect_gate_minus0.py",
            [
                "--session",
                str(session),
                "--log",
                str(log),
                "--log-start-line",
                str(args.log_start_line),
            ],
        )
    else:
        gates["minus0"] = blocked_row(
            "inspect_gate_minus0.py",
            "missing_minus0_artifacts",
            next_action=(
                "Provide --artifact-map minus0.session/log/log_start_line "
                "or --session --log --log-start-line"
            ),
        )

    skip_rest_after_minus0 = args.guided and gates["minus0"]["status"] != "pass"

    if skip_rest_after_minus0:
        gates["0"] = blocked_row(
            "inspect_gate0_log.py",
            "skipped_after_minus0_failure",
            next_action="Repair Gate -0 before continuing the guided Mac workflow",
        )
    else:
        zero_entry = entry("0")
        if zero_entry is not None:
            zero_log = path_from(zero_entry, "log")
            assert zero_log is not None
            gates["0"] = run_script(
                "inspect_gate0_log.py",
                [
                    "--log",
                    str(zero_log),
                    "--log-start-line",
                    str(int(zero_entry["log_start_line"])),
                ],
            )
        elif log is not None and args.log_start_line is not None:
            gates["0"] = run_script(
                "inspect_gate0_log.py",
                ["--log", str(log), "--log-start-line", str(args.log_start_line)],
            )
        else:
            gates["0"] = blocked_row(
                "inspect_gate0_log.py",
                "missing_log",
                next_action=(
                    "Provide artifact-map 0.log/log_start_line or --log --log-start-line"
                ),
            )

    one_two = entry("1/2")
    if skip_rest_after_minus0:
        gates["1"] = blocked_row(
            "inspect_gate1_session.py",
            "skipped_after_minus0_failure",
            next_action="Repair Gate -0 before continuing the guided Mac workflow",
        )
        gates["2"] = blocked_row(
            "inspect_gate2_shot.py",
            "skipped_after_minus0_failure",
            next_action="Repair Gate -0 before continuing the guided Mac workflow",
        )
    else:
        if one_two is not None:
            g1_args = gate1_args_from_entry(
                one_two,
                token=args.token,
                passphrase=args.passphrase,
                manual_video=args.manual_video_scrub_ok,
                manual_audio=args.manual_audio_scrub_ok,
                av_offset_ms=args.av_offset_ms,
                ptt_ok=args.ptt_temp_deleted_ok,
            )
            if g1_args is None:
                gates["1"] = blocked_row(
                    "inspect_gate1_session.py",
                    "missing_gate1_credentials",
                    next_action="Provide 1/2.session plus token and passphrase",
                )
            else:
                gates["1"] = run_script("inspect_gate1_session.py", g1_args)
            two_log = path_from(one_two, "log")
            if two_log is None:
                gates["2"] = blocked_row(
                    "inspect_gate2_shot.py",
                    "missing_log",
                    next_action="Provide 1/2.log and log_start_line",
                )
            else:
                gates["2"] = run_script(
                    "inspect_gate2_shot.py",
                    [
                        "--log",
                        str(two_log),
                        "--log-start-line",
                        str(int(one_two["log_start_line"])),
                    ],
                )
        else:
            if session is not None and args.token.strip() and args.passphrase.strip():
                g1_args = gate1_args_from_entry(
                    {"session": str(session)},
                    token=args.token,
                    passphrase=args.passphrase,
                    manual_video=args.manual_video_scrub_ok,
                    manual_audio=args.manual_audio_scrub_ok,
                    av_offset_ms=args.av_offset_ms,
                    ptt_ok=args.ptt_temp_deleted_ok,
                )
                assert g1_args is not None
                gates["1"] = run_script("inspect_gate1_session.py", g1_args)
            else:
                gates["1"] = blocked_row(
                    "inspect_gate1_session.py",
                    "need_session_token_passphrase",
                    next_action=(
                        "Provide --artifact-map 1/2 or --session --token --passphrase"
                    ),
                )
            if log is not None and args.log_start_line is not None:
                gates["2"] = run_script(
                    "inspect_gate2_shot.py",
                    ["--log", str(log), "--log-start-line", str(args.log_start_line)],
                )
            else:
                gates["2"] = blocked_row(
                    "inspect_gate2_shot.py",
                    "missing_log",
                    next_action=(
                        "Provide --artifact-map 1/2.log or --log --log-start-line"
                    ),
                )

    gate1_passed = gates["1"]["status"] == "pass"

    def skip_or_run(name: str, script: str, runner: Callable[[], dict[str, Any]]) -> None:
        if skip_rest_after_minus0:
            gates[name] = blocked_row(
                script,
                "skipped_after_minus0_failure",
                next_action="Repair Gate -0 before continuing the guided Mac workflow",
            )
        elif not gate1_passed:
            gates[name] = blocked_row(
                script,
                "blocked_until_gate1_pass",
                next_action="Pass Gate 1 from a named artifact before running Gates 3-6",
            )
        else:
            gates[name] = runner()

    def run_gate3() -> dict[str, Any]:
        three = entry("3")
        if three is not None:
            sess = path_from(three, "session")
            assert sess is not None
            cmd = ["--session", str(sess.resolve())]
            if three.get("target_media_seconds") is not None:
                cmd.extend(
                    ["--target-media-seconds", str(three["target_media_seconds"])]
                )
            if three.get("target_wall_seconds") is not None:
                cmd.extend(
                    ["--target-wall-seconds", str(three["target_wall_seconds"])]
                )
            return run_script("inspect_gate3_whisper.py", cmd)
        if session is None:
            return blocked_row(
                "inspect_gate3_whisper.py",
                "missing_session",
                next_action="Provide artifact-map 3.session or --session",
            )
        cmd = ["--session", str(session)]
        if args.target_media_seconds is not None:
            cmd.extend(["--target-media-seconds", str(args.target_media_seconds)])
        if args.target_wall_seconds is not None:
            cmd.extend(["--target-wall-seconds", str(args.target_wall_seconds)])
        return run_script("inspect_gate3_whisper.py", cmd)

    skip_or_run("3", "inspect_gate3_whisper.py", run_gate3)

    def run_gate4() -> dict[str, Any]:
        four = entry("4")
        if four is not None:
            sess = path_from(four, "session")
            assert sess is not None
            cmd = ["--session", str(sess.resolve())]
            if four.get("chrome_playback_ok"):
                cmd.append("--chrome-playback-ok")
            return run_script("inspect_gate4_slicer.py", cmd)
        if session is None:
            return blocked_row(
                "inspect_gate4_slicer.py",
                "missing_session",
                next_action="Provide artifact-map 4.session or --session",
            )
        cmd = ["--session", str(session)]
        if args.chrome_playback_ok:
            cmd.append("--chrome-playback-ok")
        return run_script("inspect_gate4_slicer.py", cmd)

    skip_or_run("4", "inspect_gate4_slicer.py", run_gate4)

    def run_gate5() -> dict[str, Any]:
        five = entry("5")
        if five is None:
            return blocked_row(
                "inspect_gate5_provider.py",
                "gate5_requires_artifact_map_scenarios",
                next_action=(
                    "Provide artifact-map 5.denied/invalid_key/retired_model/evidence"
                ),
            )
        scenario_rows: dict[str, dict[str, Any]] = {}
        for key in GATE5_KEYS:
            nested = five.get(key)
            if not isinstance(nested, dict):
                scenario_rows[key] = blocked_row(
                    "inspect_gate5_provider.py",
                    f"missing_scenario:{key}",
                    next_action=f"Add artifact-map 5.{key}",
                )
                continue
            sess = path_from(nested, "session")
            assert sess is not None
            sub = GATE5_SUBCOMMANDS[key]
            if key == "evidence":
                scenario_rows[key] = run_script(
                    "inspect_gate5_provider.py",
                    [sub, "--session", str(sess.resolve())],
                )
            else:
                scen_log = path_from(nested, "log")
                assert scen_log is not None
                scenario_rows[key] = run_script(
                    "inspect_gate5_provider.py",
                    [
                        sub,
                        "--session",
                        str(sess.resolve()),
                        "--log",
                        str(scen_log),
                        "--log-start-line",
                        str(int(nested["log_start_line"])),
                    ],
                )
        return summarize_gate5(scenario_rows)

    skip_or_run("5", "inspect_gate5_provider.py", run_gate5)

    def run_gate6() -> dict[str, Any]:
        six = entry("6")
        if six is not None:
            sess = path_from(six, "session")
            assert sess is not None
            return run_script(
                "inspect_gate6_pack.py", ["--session", str(sess.resolve())]
            )
        if session is None:
            return blocked_row(
                "inspect_gate6_pack.py",
                "missing_session",
                next_action="Provide artifact-map 6.session or --session",
            )
        return run_script("inspect_gate6_pack.py", ["--session", str(session)])

    skip_or_run("6", "inspect_gate6_pack.py", run_gate6)

    ordered = {name: gates[name] for name in GATE_ORDER if name in gates}
    failed = [name for name, row in ordered.items() if row["status"] == "fail"]
    blocked = [
        name
        for name, row in ordered.items()
        if row["status"] in {"blocked", "manual_required"}
    ]
    manual_required = [
        name for name, row in ordered.items() if row["status"] == "manual_required"
    ]
    next_actions = {
        name: row["next_action"]
        for name, row in ordered.items()
        if row.get("next_action")
    }

    summary = {
        "session": str(session) if session else None,
        "log": str(log) if log else None,
        "artifact_map": str(args.artifact_map) if args.artifact_map else None,
        "guided": bool(args.guided),
        "gates": {name: public_gate_summary(row) for name, row in ordered.items()},
        "failed": failed,
        "blocked": blocked,
        "manual_required": manual_required,
        "next_actions": next_actions,
        "note": NOTE,
    }
    print(json.dumps(summary, indent=2))
    if failed:
        return 1
    if args.strict and (blocked or manual_required):
        return 1
    if args.guided and gates["minus0"]["status"] == "fail":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
