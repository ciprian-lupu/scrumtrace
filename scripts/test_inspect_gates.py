#!/usr/bin/env python3
"""Deterministic aggregate runner for split gate inspector tests."""

from __future__ import annotations

import ast
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE_TESTS = ROOT / "scripts" / "gate_tests"

# Fixed sorted module list (lexicographic). Must match AST discovery.
FIXED_MODULES = [
    "test_all_gates",
    "test_gate0",
    "test_gate1",
    "test_gate2",
    "test_gate3",
    "test_gate4",
    "test_gate5",
    "test_gate6",
    "test_gate_minus0",
    "test_gate_minus1",
]


def ast_test_function_count(path: Path) -> int:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    return sum(
        1
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    )


def discover_test_modules() -> list[str]:
    found: list[str] = []
    for path in sorted(GATE_TESTS.glob("test_*.py")):
        if ast_test_function_count(path) > 0:
            found.append(path.stem)
    return found


def main() -> int:
    discovered = discover_test_modules()
    if discovered != FIXED_MODULES:
        print(
            f"module list mismatch fixed={FIXED_MODULES} discovered={discovered}",
            file=sys.stderr,
        )
        return 1

    failures = 0
    for name in FIXED_MODULES:
        path = GATE_TESTS / f"{name}.py"
        result = subprocess.run(
            [sys.executable, str(path)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(GATE_TESTS),
        )
        status = "ok" if result.returncode == 0 else "FAIL"
        if result.returncode != 0:
            failures += 1
            err = (result.stderr.strip().splitlines() or [""])[-1]
            print(f"{name}: {status} exit={result.returncode} {err}")
        else:
            detail = (result.stdout.strip().splitlines() or [""])[-1]
            print(f"{name}: {status} {detail}")
    if failures:
        print(f"inspect gate helpers FAILED ({failures} modules)")
        return 1
    print("inspect gate helpers ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
