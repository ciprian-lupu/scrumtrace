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

def test_inspect_gate6_fails_when_zip_lists_archive() -> None:
    session = Path("/tmp/scrumtrace-gate6-leak")
    export = session / "export"
    export.mkdir(parents=True, exist_ok=True)
    (session / "archive").mkdir(exist_ok=True)
    (export / "AGENT_CONTEXT.md").write_text("# ctx\n", encoding="utf-8")
    (export / "SESSION_BRIEF.html").write_text("<html></html>", encoding="utf-8")
    (session / "session.manifest.json").write_text(json.dumps({"omitted": []}), encoding="utf-8")
    zip_path = export / "session-pack.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("archive/session.mp4", b"nope")
        zf.writestr("AGENT_CONTEXT.md", "# ctx\n")
    result = _run("inspect_gate6_pack.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["zip_has_no_archive"] is False



def main() -> None:
    test_inspect_gate6_fails_when_zip_lists_archive()
    print("test_gate6 ok")


if __name__ == "__main__":
    main()
