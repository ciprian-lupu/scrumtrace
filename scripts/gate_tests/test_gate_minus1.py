from __future__ import annotations

import json
import subprocess
import sys
import zipfile
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from support import ROOT, _run

def test_inspect_minus1_passes_repo_mock() -> None:
    result = _run("inspect_gate_minus1.py", [])
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["tokens_absent_from_text"] is True
    assert report["checks"]["clip_evidence"] is True


def test_inspect_minus1_fails_when_token_leaks() -> None:
    export = Path("/tmp/scrumtrace-minus1-leak/export")
    export.mkdir(parents=True, exist_ok=True)
    (export / "AGENT_CONTEXT.md").write_text("ATH-SAVE-DISABLED-0x9F\n", encoding="utf-8")
    (export / "SESSION_BRIEF.html").write_text("<html></html>", encoding="utf-8")
    (export / "AGENT_PROMPT.txt").write_text("x", encoding="utf-8")
    (export / "session.manifest.json").write_text("{}", encoding="utf-8")
    result = _run("inspect_gate_minus1.py", ["--export", str(export)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["tokens_absent_from_text"] is False



def main() -> None:
    test_inspect_minus1_passes_repo_mock()
    test_inspect_minus1_fails_when_token_leaks()
    print("test_gate_minus1 ok")


if __name__ == "__main__":
    main()
