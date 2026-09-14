#!/usr/bin/env python3
"""Print failing XCTest cases and their assertion messages from an .xcresult bundle.

Parallel xcodebuild runs list failing test names in the console but not the messages,
so CI calls this on failure. Usage: print_xcresult_failures.py <DerivedData path or .xcresult>.
Always exits 0: it only adds diagnostics to a job that has already failed.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys


def newest_bundle(target: pathlib.Path) -> pathlib.Path | None:
    if target.suffix == ".xcresult":
        return target if target.exists() else None
    bundles = sorted((target / "Logs" / "Test").glob("*.xcresult"), key=lambda p: p.stat().st_mtime)
    return bundles[-1] if bundles else None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: print_xcresult_failures.py <DerivedData path or .xcresult>")
        return 0
    bundle = newest_bundle(pathlib.Path(sys.argv[1]))
    if bundle is None:
        print("No .xcresult bundle found; the build probably failed before tests ran.")
        return 0
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
            capture_output=True, text=True, check=True,
        ).stdout
        tree = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Could not read {bundle.name}: {error}")
        return 0

    failures: list[tuple[str, str, list[str]]] = []

    def walk(node: dict, suite: str) -> None:
        kind = node.get("nodeType", "")
        name = node.get("name", "")
        if kind == "Test Suite":
            suite = name
        if kind == "Test Case" and node.get("result") == "Failed":
            messages = [
                child.get("name", "")
                for child in node.get("children", []) or []
                if child.get("nodeType") == "Failure Message"
            ]
            failures.append((suite, name, messages))
        for child in node.get("children", []) or []:
            walk(child, suite)

    for top in tree.get("testNodes", []):
        walk(top, "")

    print(f"Result bundle: {bundle.name}")
    if not failures:
        print("No failing test cases recorded.")
        return 0
    for suite, name, messages in failures:
        print(f"FAILED {suite}/{name}")
        for message in messages or ["(no message recorded)"]:
            print(f"    {message}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
