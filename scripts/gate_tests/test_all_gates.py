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

def test_inspect_all_gates_mock_only() -> None:
    result = _run("inspect_all_gates.py", ["--mock-only"])
    assert result.returncode == 0, result.stdout + result.stderr
    summary = json.loads(result.stdout)
    assert summary["gates"]["minus1"]["status"] == "pass"
    assert "Do not invent GATE_LOG.md cells" in summary["note"]



def main() -> None:
    test_inspect_all_gates_mock_only()
    print("test_all_gates ok")


if __name__ == "__main__":
    main()
