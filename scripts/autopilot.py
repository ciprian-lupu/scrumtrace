#!/usr/bin/env python3
"""ScrumTrace autonomous completion ledger."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
GRAPH_PATH = ROOT / "automation" / "task-graph.json"
_STATE_OVERRIDE = os.environ.get("SCRUMTRACE_AUTOPILOT_HOME", "").strip()
STATE_DIR = Path(_STATE_OVERRIDE) if _STATE_OVERRIDE else (ROOT / ".scrumtrace-autopilot")
STATE_PATH = STATE_DIR / "state.json"

CLASSIFICATIONS = frozenset({
    "automatable",
    "needs_mac_worker_capable",
    "human_evidence",
    "operator_no_commit",
})
MODEL_FAMILIES = frozenset({"composer", "grok"})
BLOCKER_CODES = frozenset({
    "tcc",
    "manual_visual_audio",
    "signing_material",
    "provider_credential",
    "destructive_confirm",
    "authz_denied",
    "product_decision",
    "needs_mac_worker",
})
SECRET_KEY_RE = re.compile(
    r"(passphrase|password|token|api[_-]?key|secret|transcript|title|url|note|content)",
    re.I,
)
FORBIDDEN_ARGV_RE = re.compile(
    r"(passphrase|password|token|api[_-]?key|secret|--key=)",
    re.I,
)
SPAWN_REGEX = {
    "A06b": re.compile(r"^A06b$"),
    "B01a-NNN": re.compile(r"^B01a-\d+$"),
    "E02-NNN": re.compile(r"^E02-\d+$"),
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class AutopilotError(Exception):
    pass


def die(message: str, code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=".state-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AutopilotError(f"invalid JSON at {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise AutopilotError(f"expected object JSON at {path}")
    return data


def reject_secret_fields(payload: Any, path: str = "") -> None:
    if isinstance(payload, dict):
        for key, value in payload.items():
            key_path = f"{path}.{key}" if path else str(key)
            if SECRET_KEY_RE.search(str(key)):
                raise AutopilotError(f"forbidden content field rejected: {key_path}")
            reject_secret_fields(value, key_path)
    elif isinstance(payload, list):
        for index, item in enumerate(payload):
            reject_secret_fields(item, f"{path}[{index}]")


def redact_argv(argv: list[str]) -> list[str]:
    out: list[str] = []
    hide_next = False
    for item in argv:
        if hide_next:
            out.append("[REDACTED]")
            hide_next = False
            continue
        if FORBIDDEN_ARGV_RE.search(item):
            if item.startswith("--") and "=" not in item:
                out.append(item)
                hide_next = True
            else:
                out.append("[REDACTED]")
            continue
        out.append(item)
    return out


def release_evidence_errors(
    task_id: str, evidence: object, source_sha: str
) -> list[str]:
    """Validate release-only proof required before APP_DONE can be true."""
    if task_id not in {"F04", "G01", "G02", "G03"}:
        return []
    if not isinstance(evidence, dict):
        return [f"{task_id} release_evidence must be an object"]

    errors: list[str] = []
    if task_id == "F04":
        if evidence.get("gate_log_source_sha") != source_sha:
            errors.append("F04 Gate-log source SHA must equal HEAD")
        artifact_map_sha = evidence.get("artifact_map_sha256")
        if not isinstance(artifact_map_sha, str) or not SHA256_RE.fullmatch(
            artifact_map_sha
        ):
            errors.append("F04 artifact-map digest missing or invalid")
        if evidence.get("blocked_rows") != 0:
            errors.append("F04 blocked_rows must be zero")
        if evidence.get("manual_rows") != 0:
            errors.append("F04 manual_rows must be zero")
    elif task_id == "G01":
        for field in (
            "codesign_verified",
            "notarization_verified",
            "stapler_verified",
        ):
            if evidence.get(field) is not True:
                errors.append(f"G01 {field} must be true")
    elif task_id == "G02":
        if evidence.get("published_update_verified") is not True:
            errors.append("G02 published_update_verified must be true")
    elif task_id == "G03":
        if evidence.get("installed_release_verified") is not True:
            errors.append("G03 installed_release_verified must be true")
    return errors


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=check,
        capture_output=True,
        text=True,
    )


def git_head() -> str:
    return git("rev-parse", "HEAD").stdout.strip()


def git_status_short() -> str:
    return git("status", "--short").stdout


def git_commit_exists(sha: str) -> bool:
    return git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0


def git_changed_paths(base: str, commit: str) -> list[str]:
    result = git("diff", "--name-only", f"{base}...{commit}")
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def path_matches(path: str, patterns: list[str]) -> bool:
    normalized = path.replace("\\", "/").lstrip("./")
    for pattern in patterns:
        pat = pattern.replace("\\", "/").rstrip("/")
        if not pat:
            continue
        if normalized == pat or normalized.startswith(pat + "/"):
            return True
    return False


def load_graph() -> dict[str, Any]:
    graph = load_json(GRAPH_PATH)
    validate_graph(graph)
    return graph


def validate_graph(graph: dict[str, Any]) -> None:
    fixed = graph.get("fixed_inventory")
    tasks = graph.get("tasks")
    if not isinstance(fixed, list) or not isinstance(tasks, list):
        raise AutopilotError("task graph missing fixed_inventory or tasks")
    ids = [t.get("id") for t in tasks if isinstance(t, dict)]
    if ids != fixed:
        missing = [item for item in fixed if item not in ids]
        extra = [item for item in ids if item not in fixed]
        raise AutopilotError(
            f"fixed inventory mismatch missing={missing} extra={extra}"
        )
    by_id: dict[str, dict[str, Any]] = {}
    for task in tasks:
        if not isinstance(task, dict):
            raise AutopilotError("task entry must be object")
        tid = task.get("id")
        if not isinstance(tid, str) or not tid:
            raise AutopilotError("task missing id")
        if tid in by_id:
            raise AutopilotError(f"duplicate task id {tid}")
        for field in (
            "title",
            "dependencies",
            "wave",
            "builder_model",
            "reviewer_model",
            "owned_paths",
            "forbidden_paths",
            "focused_tests",
            "environment",
            "classification",
            "allowed_blockers",
            "expected_commit_subject",
            "acceptance_artifacts",
        ):
            if field not in task:
                raise AutopilotError(f"task {tid} missing {field}")
        if task["classification"] not in CLASSIFICATIONS:
            raise AutopilotError(f"task {tid} bad classification")
        if task["builder_model"] not in MODEL_FAMILIES:
            raise AutopilotError(f"task {tid} bad builder_model")
        if task["reviewer_model"] not in MODEL_FAMILIES:
            raise AutopilotError(f"task {tid} bad reviewer_model")
        if task["builder_model"] == task["reviewer_model"]:
            raise AutopilotError(f"task {tid} builder/reviewer must differ")
        if task["environment"] not in {"linux", "mac", "either"}:
            raise AutopilotError(f"task {tid} bad environment")
        if not isinstance(task["wave"], int) or task["wave"] < 0:
            raise AutopilotError(f"task {tid} bad wave")
        for code in task["allowed_blockers"]:
            if code not in BLOCKER_CODES:
                raise AutopilotError(f"task {tid} unknown blocker {code}")
        by_id[tid] = task

    visiting: set[str] = set()
    visited: set[str] = set()

    def dfs(node: str) -> None:
        if node in visited:
            return
        if node in visiting:
            raise AutopilotError(f"dependency cycle involving {node}")
        visiting.add(node)
        for dep in by_id[node]["dependencies"]:
            if dep not in by_id:
                raise AutopilotError(f"task {node} depends on unknown {dep}")
            dfs(dep)
        visiting.remove(node)
        visited.add(node)

    for tid in by_id:
        dfs(tid)


def default_state(base: str) -> dict[str, Any]:
    return {
        "version": 1,
        "base_sha": base,
        "created_at": int(time.time()),
        "tasks": {},
        "spawned": {},
        "passes": {},
        "confirmations": {},
        "artifact_claims": {},
        "pass_reset_reason": None,
        "pass_lock_sha": None,
        "last_error": None,
    }


def load_state(*, required: bool = True) -> dict[str, Any]:
    if not STATE_PATH.exists():
        if required:
            raise AutopilotError("state missing; run init first")
        return default_state("")
    try:
        raw = STATE_PATH.read_bytes()
        if not raw.strip():
            raise AutopilotError("truncated state rejected")
        data = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AutopilotError(f"corrupt state preserved as evidence: {exc}") from exc
    if not isinstance(data, dict) or "tasks" not in data:
        raise AutopilotError("corrupt state preserved as evidence: schema")
    return data


def save_state(state: dict[str, Any]) -> None:
    atomic_write_json(STATE_PATH, state)


def task_map(graph: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {t["id"]: t for t in graph["tasks"]}


def all_task_ids(graph: dict[str, Any], state: dict[str, Any]) -> list[str]:
    ids = list(graph["fixed_inventory"])
    for child in state.get("spawned", {}):
        if child not in ids:
            ids.append(child)
    return ids


def resolve_task(
    graph: dict[str, Any], state: dict[str, Any], tid: str
) -> dict[str, Any]:
    tasks = task_map(graph)
    if tid in tasks:
        return tasks[tid]
    spawned = state.get("spawned", {})
    if tid in spawned:
        return spawned[tid]
    raise AutopilotError(f"unknown task {tid}")


def task_entry(state: dict[str, Any], tid: str) -> dict[str, Any]:
    tasks = state.setdefault("tasks", {})
    entry = tasks.get(tid)
    if entry is None:
        entry = {"id": tid, "status": "ready"}
        tasks[tid] = entry
    return entry


def deps_satisfied(graph: dict[str, Any], state: dict[str, Any], tid: str) -> bool:
    task = resolve_task(graph, state, tid)
    for dep in task["dependencies"]:
        if task_entry(state, dep).get("status") != "integrated":
            return False
    return True


def deps_legally_blocked(
    graph: dict[str, Any], state: dict[str, Any], tid: str
) -> bool:
    task = resolve_task(graph, state, tid)
    unmet = False
    for dep in task["dependencies"]:
        status = task_entry(state, dep).get("status")
        if status == "integrated":
            continue
        unmet = True
        if status not in {"needs_mac_worker", "human_required"}:
            return False
    return unmet


def owned_overlap(a: list[str], b: list[str]) -> bool:
    for left in a:
        for right in b:
            l = left.rstrip("/")
            r = right.rstrip("/")
            if not l or not r:
                continue
            if l == r or l.startswith(r + "/") or r.startswith(l + "/"):
                return True
    return False


def ready_tasks(graph: dict[str, Any], state: dict[str, Any]) -> list[str]:
    candidates: list[tuple[int, str]] = []
    for tid in all_task_ids(graph, state):
        entry = task_entry(state, tid)
        if entry.get("status") not in {"ready", "failed"}:
            continue
        if not deps_satisfied(graph, state, tid):
            continue
        task = resolve_task(graph, state, tid)
        candidates.append((int(task["wave"]), tid))
    if not candidates:
        return []
    lowest = min(wave for wave, _ in candidates)
    wave_tasks = [tid for wave, tid in candidates if wave == lowest]
    selected: list[str] = []
    for tid in wave_tasks:
        owned = list(resolve_task(graph, state, tid).get("owned_paths") or [])
        conflict = False
        for prev in selected:
            prev_owned = list(
                resolve_task(graph, state, prev).get("owned_paths") or []
            )
            if owned and prev_owned and owned_overlap(owned, prev_owned):
                conflict = True
                break
        if not conflict:
            selected.append(tid)
    return selected


def clear_passes(state: dict[str, Any], reason: str) -> None:
    state["passes"] = {}
    state["confirmations"] = {}
    state["pass_reset_reason"] = reason
    state["pass_lock_sha"] = None


def ensure_clean_tree() -> None:
    if git_status_short().strip():
        raise AutopilotError("working tree is dirty (including untracked)")


def maybe_reset_passes_for_tree(state: dict[str, Any]) -> None:
    head = git_head()
    locked = state.get("pass_lock_sha")
    if locked and locked != head:
        clear_passes(state, "HEAD changed")
        return
    status = git_status_short()
    dirty = False
    for line in status.splitlines():
        path = line[3:] if len(line) > 3 else line
        path = path.strip().strip('"')
        if path.startswith(".scrumtrace-autopilot/"):
            continue
        dirty = True
        break
    if dirty and state.get("passes"):
        clear_passes(state, "dirty source tree")


def remote_sha(name: str) -> str | None:
    result = git("rev-parse", f"{name}/develop", check=False)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def run_commands(commands: list[str]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for command in commands:
        argv = ["bash", "-lc", command]
        proc = subprocess.run(
            argv,
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        results.append(
            {
                "command": command,
                "argv": redact_argv(argv),
                "exit_code": proc.returncode,
            }
        )
        if proc.returncode != 0:
            break
    return results


def cmd_init(args: argparse.Namespace) -> int:
    base = args.base
    if not git_commit_exists(base):
        die(f"unknown base commit {base}")
    graph = load_graph()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state = default_state(base)
    for tid in graph["fixed_inventory"]:
        task_entry(state, tid)
    save_state(state)
    print(json.dumps({"ok": True, "base_sha": base, "tasks": len(graph["tasks"])}))
    return 0


def cmd_ready(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    maybe_reset_passes_for_tree(state)
    ready = ready_tasks(graph, state)
    payload = {
        "ready": ready,
        "wave": resolve_task(graph, state, ready[0])["wave"] if ready else None,
        "tasks": [
            {
                "id": tid,
                "classification": resolve_task(graph, state, tid)["classification"],
                "builder_model": resolve_task(graph, state, tid)["builder_model"],
                "owned_paths": resolve_task(graph, state, tid)["owned_paths"],
            }
            for tid in ready
        ],
    }
    print(json.dumps(payload, indent=None if args.json else 2))
    return 0


def cmd_start(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    tid = args.task
    resolve_task(graph, state, tid)
    entry = task_entry(state, tid)
    if entry.get("status") not in {"ready", "failed"}:
        die(f"task {tid} not startable from status {entry.get('status')}")
    if not deps_satisfied(graph, state, tid):
        die(f"task {tid} dependencies not satisfied")
    branch = args.branch
    if branch != branch.lower() or not branch.endswith("-0397"):
        die("branch must be lowercase and end with -0397")
    if not branch.startswith("cursor/"):
        die("branch must start with cursor/")
    entry.update(
        {
            "status": "in_progress",
            "branch": branch,
            "base_sha": args.base,
            "started_at": int(time.time()),
        }
    )
    save_state(state)
    print(json.dumps({"ok": True, "task": tid, "status": "in_progress"}))
    return 0


def cmd_spawn_task(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    parent = resolve_task(graph, state, args.parent)
    allowed = list(parent.get("spawn_allowed") or [])
    child_id = args.id
    matched = False
    for token in allowed:
        if token in SPAWN_REGEX and SPAWN_REGEX[token].match(child_id):
            matched = True
            break
        if token == child_id:
            matched = True
            break
        if token.endswith("-NNN") and re.match(
            "^" + re.escape(token[:-4]) + r"-\d+$", child_id
        ):
            matched = True
            break
    if not matched:
        die(f"spawn id {child_id} not allowed by parent {args.parent}")
    ownership = load_json(Path(args.ownership).resolve())
    reject_secret_fields(ownership)
    owned = ownership.get("owned_paths")
    if not isinstance(owned, list) or not owned:
        die("ownership.json must include owned_paths")
    child = {
        "id": child_id,
        "title": ownership.get("title", child_id),
        "dependencies": list(parent["dependencies"]) + [args.parent],
        "wave": parent["wave"],
        "builder_model": ownership.get("builder_model", parent["builder_model"]),
        "reviewer_model": ownership.get(
            "reviewer_model", parent["reviewer_model"]
        ),
        "owned_paths": owned,
        "forbidden_paths": ownership.get(
            "forbidden_paths", parent["forbidden_paths"]
        ),
        "focused_tests": ownership.get("focused_tests", []),
        "environment": ownership.get("environment", parent["environment"]),
        "classification": ownership.get("classification", "automatable"),
        "human_evidence_allowed": False,
        "allowed_blockers": ownership.get("allowed_blockers", []),
        "expected_commit_subject": ownership.get("expected_commit_subject", ""),
        "acceptance_artifacts": ownership.get("acceptance_artifacts", []),
        "integration_commands": ownership.get(
            "integration_commands", parent.get("integration_commands", [])
        ),
        "spawn_allowed": [],
        "parent": args.parent,
    }
    if child["builder_model"] == child["reviewer_model"]:
        die("spawned child builder/reviewer must differ")
    state.setdefault("spawned", {})[child_id] = child
    parent_entry = task_entry(state, args.parent)
    children = list(parent_entry.get("children") or [])
    if child_id not in children:
        children.append(child_id)
    parent_entry["children"] = children
    task_entry(state, child_id)
    save_state(state)
    print(json.dumps({"ok": True, "spawned": child_id, "parent": args.parent}))
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    tid = args.task
    task = resolve_task(graph, state, tid)
    entry = task_entry(state, tid)
    if entry.get("status") not in {"in_progress", "recorded", "failed"}:
        die(f"task {tid} not recordable from {entry.get('status')}")
    commit = args.commit
    if not git_commit_exists(commit):
        die(f"unreachable commit {commit}")
    base = entry.get("base_sha") or state.get("base_sha")
    if not base:
        die("missing base sha")
    changed = git_changed_paths(str(base), commit)
    owned = list(task.get("owned_paths") or [])
    forbidden = list(task.get("forbidden_paths") or [])
    for path in changed:
        if forbidden and path_matches(path, forbidden) and not path_matches(path, owned):
            die(f"unowned/forbidden changed file: {path}")
        if owned and not path_matches(path, owned):
            die(f"unowned changed file: {path}")
    results_path = Path(args.results).resolve()
    if not results_path.is_file():
        die(f"missing results file {results_path}")
    results = load_json(results_path)
    reject_secret_fields(results)
    focused = list(task.get("focused_tests") or [])
    command_results = results.get("commands")
    if focused:
        if not isinstance(command_results, list):
            die("results.commands required for focused tests")
        by_cmd = {
            str(item.get("command")): item
            for item in command_results
            if isinstance(item, dict)
        }
        for cmd in focused:
            item = by_cmd.get(cmd)
            if item is None:
                die(f"missing focused test result for {cmd}")
            if int(item.get("exit_code", 1)) != 0:
                die(f"focused test failed: {cmd}")
    entry.update(
        {
            "status": "recorded",
            "commit": commit,
            "changed_paths": changed,
            "results_sha256": sha256_file(results_path),
            "recorded_at": int(time.time()),
        }
    )
    clear_passes(state, f"task {tid} recorded")
    save_state(state)
    print(json.dumps({"ok": True, "task": tid, "status": "recorded", "commit": commit}))
    return 0


def cmd_block(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    tid = args.task
    task = resolve_task(graph, state, tid)
    code = args.reason_code
    if code not in BLOCKER_CODES:
        die(f"unknown blocker reason code {code}")
    if code not in set(task.get("allowed_blockers") or []):
        die(f"blocker {code} not declared for task {tid}")
    if task["classification"] == "automatable":
        if code not in {"needs_mac_worker", "authz_denied"}:
            die(
                f"automatable task {tid} cannot be relabelled human_required via {code}"
            )
    evidence = Path(args.evidence).resolve()
    if not evidence.is_file():
        die(f"missing evidence file {evidence}")
    digest = sha256_file(evidence)
    length = evidence.stat().st_size
    status = "needs_mac_worker" if code == "needs_mac_worker" else "human_required"
    entry = task_entry(state, tid)
    entry.update(
        {
            "status": status,
            "blocker": {
                "reason_code": code,
                "evidence_path": str(evidence),
                "evidence_sha256": digest,
                "evidence_bytes": length,
            },
            "blocked_at": int(time.time()),
        }
    )
    clear_passes(state, f"task {tid} blocked")
    save_state(state)
    print(json.dumps({"ok": True, "task": tid, "status": status, "reason_code": code}))
    return 0


def cmd_review(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    tid = args.task
    task = resolve_task(graph, state, tid)
    entry = task_entry(state, tid)
    if entry.get("status") not in {"recorded", "reviewed"}:
        die(f"task {tid} must be recorded before review")
    model = args.model.lower()
    if model not in MODEL_FAMILIES:
        die(f"unknown model family {model}")
    if model == task["builder_model"]:
        die("review model must differ from builder")
    if model != task["reviewer_model"]:
        die(f"expected reviewer {task['reviewer_model']}, got {model}")
    result_path = Path(args.result).resolve()
    result = load_json(result_path)
    reject_secret_fields(result)
    findings = result.get("findings")
    if findings is None:
        die("review result must include findings")
    if isinstance(findings, list):
        severe = [
            f
            for f in findings
            if isinstance(f, dict)
            and str(f.get("severity", "")).lower() in {"critical", "high"}
        ]
        if severe:
            die("review has unresolved critical/high findings")
    elif findings not in ("NO FINDINGS", "none", ""):
        die("review findings format invalid")
    entry.update(
        {
            "status": "reviewed",
            "review": {
                "model": model,
                "result_sha256": sha256_file(result_path),
            },
            "reviewed_at": int(time.time()),
        }
    )
    save_state(state)
    print(json.dumps({"ok": True, "task": tid, "status": "reviewed"}))
    return 0


def cmd_integrate(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    tid = args.task
    task = resolve_task(graph, state, tid)
    entry = task_entry(state, tid)
    if entry.get("status") != "reviewed":
        die(f"task {tid} must be reviewed before integrate")
    for child in entry.get("children") or []:
        child_status = task_entry(state, child).get("status")
        if child_status not in {"integrated", "needs_mac_worker", "human_required"}:
            die(f"spawned child {child} not complete ({child_status})")
    develop_sha = args.develop_sha
    if develop_sha != git_head():
        die(f"develop-sha {develop_sha} != HEAD {git_head()}")
    wave_results_path = Path(args.wave_results).resolve()
    claimed = load_json(wave_results_path)
    reject_secret_fields(claimed)
    commands = list(task.get("integration_commands") or [])
    executed = run_commands(commands) if commands else []
    for item in executed:
        if int(item["exit_code"]) != 0:
            entry["status"] = "failed"
            entry["integration_failure"] = item
            save_state(state)
            die(f"integration command failed: {item['command']}")
    entry.update(
        {
            "status": "integrated",
            "integrated_sha": develop_sha,
            "integration_commands": executed,
            "wave_results_sha256": sha256_file(wave_results_path),
            "integrated_at": int(time.time()),
        }
    )
    clear_passes(state, f"task {tid} integrated")
    save_state(state)
    print(
        json.dumps(
            {
                "ok": True,
                "task": tid,
                "status": "integrated",
                "develop_sha": develop_sha,
            }
        )
    )
    return 0


def cmd_record_operator(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    tid = args.task
    task = resolve_task(graph, state, tid)
    if task["classification"] not in {"operator_no_commit", "human_evidence"}:
        die(f"task {tid} is not an operator/no-commit task")
    results_path = Path(args.results).resolve()
    results = load_json(results_path)
    reject_secret_fields(results)
    required = [
        "command_digest",
        "exit_code",
        "source_sha",
        "artifact_path",
        "artifact_sha256",
        "artifact_bytes",
        "machine",
        "environment",
        "manual_state",
    ]
    for field in required:
        if field not in results:
            die(f"operator results missing {field}")
    if results["source_sha"] != git_head():
        die("operator result source_sha must equal HEAD")
    if not isinstance(results["exit_code"], int) or isinstance(
        results["exit_code"], bool
    ):
        die("operator exit_code must be an integer")
    if results["exit_code"] != 0:
        die("operator command did not succeed")
    if results["manual_state"] != "pass":
        die("operator manual_state must be pass")
    if not isinstance(results["command_digest"], str) or not SHA256_RE.fullmatch(
        results["command_digest"]
    ):
        die("operator command_digest must be a SHA-256 digest")
    release_evidence = results.get("release_evidence")
    evidence_errors = release_evidence_errors(
        tid, release_evidence, results["source_sha"]
    )
    if evidence_errors:
        die("; ".join(evidence_errors))
    artifact = Path(str(results["artifact_path"]))
    if not artifact.is_absolute():
        artifact = (ROOT / artifact).resolve()
    if not artifact.is_file():
        die(f"missing operator artifact {artifact}")
    digest = sha256_file(artifact)
    if digest != results["artifact_sha256"]:
        die("artifact sha256 mismatch")
    if int(results["artifact_bytes"]) != artifact.stat().st_size:
        die("artifact byte length mismatch")
    claims = state.setdefault("artifact_claims", {})
    prior = claims.get(digest)
    if prior and prior != tid:
        die(f"artifact already assigned to {prior}")
    claims[digest] = tid
    entry = task_entry(state, tid)
    operator = {
        "results_sha256": sha256_file(results_path),
        "artifact_sha256": digest,
        "artifact_bytes": int(results["artifact_bytes"]),
        "artifact_path": str(artifact),
        "command_digest": results["command_digest"],
        "exit_code": int(results["exit_code"]),
        "source_sha": results["source_sha"],
        "machine": results["machine"],
        "environment": results["environment"],
        "manual_state": results["manual_state"],
    }
    if release_evidence is not None:
        operator["release_evidence"] = release_evidence
    entry.update(
        {
            "status": "integrated",
            "operator": operator,
            "integrated_sha": results["source_sha"],
            "integrated_at": int(time.time()),
        }
    )
    clear_passes(state, f"operator {tid} recorded")
    save_state(state)
    print(json.dumps({"ok": True, "task": tid, "status": "integrated"}))
    return 0


def reachable_pass_commands(
    graph: dict[str, Any], state: dict[str, Any]
) -> list[str]:
    commands: list[str] = []
    for tid in all_task_ids(graph, state):
        task = resolve_task(graph, state, tid)
        entry = task_entry(state, tid)
        if task["classification"] in {"human_evidence", "operator_no_commit"}:
            continue
        if entry.get("status") == "needs_mac_worker":
            continue
        if (
            task["classification"] == "needs_mac_worker_capable"
            and entry.get("status") != "integrated"
        ):
            continue
        if entry.get("status") == "integrated":
            commands.extend(task.get("focused_tests") or [])
            commands.extend(task.get("integration_commands") or [])
    commands.append("bash scripts/run_linux_tests.sh")
    seen: set[str] = set()
    ordered: list[str] = []
    for cmd in commands:
        if cmd not in seen:
            seen.add(cmd)
            ordered.append(cmd)
    return ordered


def cmd_pass_start(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    number = int(args.number)
    if number not in {1, 2, 3}:
        die("pass number must be 1, 2, or 3")
    ensure_clean_tree()
    head = git_head()
    if head != args.sha:
        die(f"HEAD {head} != pass sha {args.sha}")
    model = args.model.lower()
    if model not in MODEL_FAMILIES:
        die(f"unknown model {model}")
    expected = {1: "composer", 2: "grok", 3: None}[number]
    if expected and model != expected:
        die(f"pass {number} expects model {expected}")
    passes = state.setdefault("passes", {})
    if number > 1:
        prev = passes.get(str(number - 1))
        if not prev or prev.get("status") != "finished" or prev.get("sha") != head:
            die(f"pass {number - 1} must be finished at same sha")
    passes[str(number)] = {
        "status": "started",
        "sha": head,
        "model": model,
        "started_at": int(time.time()),
    }
    state["pass_lock_sha"] = head
    save_state(state)
    print(json.dumps({"ok": True, "pass": number, "sha": head, "model": model}))
    return 0


def cmd_pass_finish(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    number = int(args.number)
    ensure_clean_tree()
    head = git_head()
    if head != args.sha:
        die(f"HEAD {head} != pass sha {args.sha}")
    model = args.model.lower()
    passes = state.setdefault("passes", {})
    current = passes.get(str(number))
    if not current or current.get("status") != "started":
        die(f"pass {number} was not started")
    if current.get("sha") != head or current.get("model") != model:
        die("pass finish sha/model mismatch")
    results = load_json(Path(args.results).resolve())
    reject_secret_fields(results)
    required_cmds = set(reachable_pass_commands(graph, state))
    reported = results.get("commands")
    if not isinstance(reported, list):
        die("pass results.commands required")
    by_cmd = {
        str(item.get("command")): item
        for item in reported
        if isinstance(item, dict)
    }
    for cmd in required_cmds:
        item = by_cmd.get(cmd)
        if item is None:
            die(f"pass missing required command {cmd}")
        if int(item.get("exit_code", 1)) != 0:
            clear_passes(state, f"pass {number} command failed")
            save_state(state)
            die(f"pass command failed: {cmd}")
    current.update(
        {
            "status": "finished",
            "finished_at": int(time.time()),
            "results_sha256": sha256_file(Path(args.results).resolve()),
        }
    )
    save_state(state)
    print(json.dumps({"ok": True, "pass": number, "status": "finished"}))
    return 0


def cmd_confirm(args: argparse.Namespace) -> int:
    state = load_state()
    head = git_head()
    if head != args.sha:
        die("confirmation sha mismatch")
    model = args.model.lower()
    if model not in MODEL_FAMILIES:
        die(f"unknown model {model}")
    result = args.result
    if result != "AUTOMATABLE_SCOPE_CONFIRMED" and not result.startswith(
        "NOT_CONFIRMED"
    ):
        die("invalid confirmation result")
    passes = state.get("passes") or {}
    p3 = passes.get("3")
    if not p3 or p3.get("status") != "finished" or p3.get("sha") != head:
        die("pass 3 must be finished at confirmation sha")
    confirmations = state.setdefault("confirmations", {})
    if result.startswith("NOT_CONFIRMED"):
        confirmations[model] = {
            "result": result,
            "sha": head,
            "at": int(time.time()),
        }
        save_state(state)
        die(f"confirmation not confirmed: {result}")
    confirmations[model] = {
        "result": "AUTOMATABLE_SCOPE_CONFIRMED",
        "sha": head,
        "at": int(time.time()),
    }
    save_state(state)
    print(json.dumps({"ok": True, "model": model, "sha": head}))
    return 0


def automatable_verify(
    graph: dict[str, Any], state: dict[str, Any]
) -> tuple[bool, list[str]]:
    errors: list[str] = []
    head = git_head()
    for tid in all_task_ids(graph, state):
        task = resolve_task(graph, state, tid)
        entry = task_entry(state, tid)
        status = entry.get("status")
        classification = task["classification"]
        if classification == "automatable":
            if status == "integrated":
                continue
            if deps_legally_blocked(graph, state, tid):
                continue
            if not deps_satisfied(graph, state, tid):
                continue
            errors.append(f"automatable task {tid} not integrated ({status})")
        elif classification == "needs_mac_worker_capable":
            if status in {"integrated", "needs_mac_worker", "human_required"}:
                continue
            if not deps_satisfied(graph, state, tid):
                continue
            if deps_legally_blocked(graph, state, tid):
                continue
            errors.append(
                f"mac-capable task {tid} reachable but not integrated/blocked ({status})"
            )
    passes = state.get("passes") or {}
    for number in ("1", "2", "3"):
        item = passes.get(number)
        if not item or item.get("status") != "finished" or item.get("sha") != head:
            errors.append(f"pass {number} missing at HEAD")
    confirmations = state.get("confirmations") or {}
    for model in ("composer", "grok"):
        item = confirmations.get(model)
        if (
            not item
            or item.get("result") != "AUTOMATABLE_SCOPE_CONFIRMED"
            or item.get("sha") != head
        ):
            errors.append(f"confirmation missing for {model}")
    origin = remote_sha("origin")
    github = remote_sha("github")
    if origin != head:
        errors.append(f"origin/develop mismatch ({origin} != {head})")
    if github is None:
        errors.append("github/develop missing")
    elif github != head:
        errors.append(f"github/develop mismatch ({github} != {head})")
    return (not errors, errors)


def release_verify(
    graph: dict[str, Any], state: dict[str, Any]
) -> tuple[bool, list[str]]:
    _ok, errors = automatable_verify(graph, state)
    head = git_head()
    for tid in [
        "F01-linux",
        "F01-mac",
        "F02",
        "F03",
        "F04",
        "G01",
        "G02",
        "G03",
    ]:
        entry = task_entry(state, tid)
        if entry.get("status") != "integrated":
            errors.append(f"release task {tid} not integrated")
            continue
        op = entry.get("operator") or {}
        if op.get("source_sha") != head:
            errors.append(f"release task {tid} artifact sha stale")
        if op.get("exit_code") != 0:
            errors.append(f"release task {tid} command did not succeed")
        if op.get("manual_state") != "pass":
            errors.append(f"release task {tid} manual state is not pass")
        artifact_path = op.get("artifact_path")
        if not isinstance(artifact_path, str):
            errors.append(f"release task {tid} artifact path missing")
        else:
            artifact = Path(artifact_path)
            if not artifact.is_absolute():
                artifact = (ROOT / artifact).resolve()
            if not artifact.is_file():
                errors.append(f"release task {tid} artifact missing")
            else:
                if sha256_file(artifact) != op.get("artifact_sha256"):
                    errors.append(f"release task {tid} artifact digest changed")
                if artifact.stat().st_size != op.get("artifact_bytes"):
                    errors.append(f"release task {tid} artifact size changed")
        errors.extend(
            release_evidence_errors(tid, op.get("release_evidence"), head)
        )
    for tid in all_task_ids(graph, state):
        status = task_entry(state, tid).get("status")
        if status in {"needs_mac_worker", "human_required", "failed"}:
            errors.append(f"release blocked by {tid}={status}")
    return (not errors, errors)


def cmd_verify(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    maybe_reset_passes_for_tree(state)
    if args.mode == "automatable":
        ok, errors = automatable_verify(graph, state)
        app_done = False
    else:
        ok, errors = release_verify(graph, state)
        app_done = ok
    payload = {
        "mode": args.mode,
        "ok": ok,
        "errors": errors,
        "APP_DONE": app_done,
        "sha": git_head(),
    }
    print(json.dumps(payload, indent=2))
    return 0 if ok else 1


def sanitize_handoff_text(text: str) -> str:
    return re.sub(
        r"(?i)(api[_-]?key|token|passphrase|password)\s*[:=]\s*\S+",
        r"\1=[REDACTED]",
        text,
    )


def cmd_handoff(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    output = Path(args.output).resolve()
    try:
        output.relative_to(STATE_DIR.resolve())
    except ValueError:
        die("handoff output must stay under .scrumtrace-autopilot/")
    if args.mode == "automatable":
        ok, errors = automatable_verify(graph, state)
        app_done = False
    else:
        ok, errors = release_verify(graph, state)
        app_done = ok
    if not ok:
        die("verify failed; handoff refused: " + "; ".join(errors))
    actions: list[str] = []
    seen_mac_attach = False
    for tid in all_task_ids(graph, state):
        task = resolve_task(graph, state, tid)
        entry = task_entry(state, tid)
        status = entry.get("status")
        if status == "needs_mac_worker":
            if not seen_mac_attach:
                actions.append("enable/attach the Mac worker")
                seen_mac_attach = True
            continue
        if status != "human_required":
            continue
        deps_ok = True
        for dep in task["dependencies"]:
            dep_task = resolve_task(graph, state, dep)
            dep_status = task_entry(state, dep).get("status")
            if (
                dep_task["classification"] == "automatable"
                and dep_status != "integrated"
            ):
                deps_ok = False
                break
            if dep_status not in {
                "integrated",
                "needs_mac_worker",
                "human_required",
            }:
                deps_ok = False
                break
        if not deps_ok:
            continue
        if tid == "E03" and task_entry(state, "E02").get("status") != "integrated":
            continue
        blocker = (entry.get("blocker") or {}).get("reason_code", "human_required")
        actions.append(f"{tid}: resolve {blocker}")
    lines = [
        "# ScrumTrace automation completion report",
        "",
        f"APP_DONE: {'true' if app_done else 'false'}",
        f"mode: {args.mode}",
        f"sha: {git_head()}",
        "",
        "## Human actions (dependency order)",
        "",
    ]
    if not actions:
        lines.append("- none")
    else:
        for action in actions:
            lines.append(f"- {action}")
    lines.append("")
    text = sanitize_handoff_text("\n".join(lines))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "output": str(output), "APP_DONE": app_done}))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    graph = load_graph()
    state = load_state()
    maybe_reset_passes_for_tree(state)
    summary = {
        "base_sha": state.get("base_sha"),
        "head": git_head(),
        "ready": ready_tasks(graph, state),
        "tasks": {
            tid: task_entry(state, tid).get("status")
            for tid in all_task_ids(graph, state)
        },
        "passes": state.get("passes"),
        "confirmations": state.get("confirmations"),
    }
    print(json.dumps(summary, indent=2 if not args.json else None))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="autopilot.py")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init")
    p.add_argument("--base", required=True)
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("ready")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_ready)

    p = sub.add_parser("start")
    p.add_argument("task")
    p.add_argument("--branch", required=True)
    p.add_argument("--base", required=True)
    p.set_defaults(func=cmd_start)

    p = sub.add_parser("spawn-task")
    p.add_argument("--parent", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--ownership", required=True)
    p.set_defaults(func=cmd_spawn_task)

    p = sub.add_parser("record")
    p.add_argument("task")
    p.add_argument("--commit", required=True)
    p.add_argument("--results", required=True)
    p.set_defaults(func=cmd_record)

    p = sub.add_parser("block")
    p.add_argument("task")
    p.add_argument("--reason-code", required=True)
    p.add_argument("--evidence", required=True)
    p.set_defaults(func=cmd_block)

    p = sub.add_parser("review")
    p.add_argument("task")
    p.add_argument("--model", required=True)
    p.add_argument("--result", required=True)
    p.set_defaults(func=cmd_review)

    p = sub.add_parser("integrate")
    p.add_argument("task")
    p.add_argument("--develop-sha", required=True)
    p.add_argument("--wave-results", required=True)
    p.set_defaults(func=cmd_integrate)

    p = sub.add_parser("record-operator")
    p.add_argument("task")
    p.add_argument("--results", required=True)
    p.set_defaults(func=cmd_record_operator)

    p = sub.add_parser("pass-start")
    p.add_argument("--number", required=True, type=int)
    p.add_argument("--sha", required=True)
    p.add_argument("--model", required=True)
    p.set_defaults(func=cmd_pass_start)

    p = sub.add_parser("pass-finish")
    p.add_argument("--number", required=True, type=int)
    p.add_argument("--sha", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--results", required=True)
    p.set_defaults(func=cmd_pass_finish)

    p = sub.add_parser("confirm")
    p.add_argument("--model", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--result", required=True)
    p.set_defaults(func=cmd_confirm)

    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("verify")
    p.add_argument("--mode", choices=["automatable", "release"], required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("handoff")
    p.add_argument("--mode", choices=["automatable", "release"], required=True)
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_handoff)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except AutopilotError as exc:
        die(str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
