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

def test_inspect_gate4_fails_when_too_many_slices() -> None:
    session = Path("/tmp/scrumtrace-gate4-slices")
    session.mkdir(parents=True, exist_ok=True)
    (session / "archive").mkdir(exist_ok=True)
    (session / "export" / "media" / "task-01").mkdir(parents=True, exist_ok=True)
    (session / "export" / "media" / "task-01" / "clip.mp4").write_bytes(b"ftyp")
    slices = [{"slice_id": f"s{i}", "export_clip_path": "export/media/task-01/clip.mp4"} for i in range(13)]
    (session / "session.manifest.json").write_text(json.dumps({"slices": slices}), encoding="utf-8")
    (session / "archive" / "pipeline-timing.json").write_text(
        json.dumps({"zip_bytes": 12}),
        encoding="utf-8",
    )
    result = _run("inspect_gate4_slicer.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["candidate_windows_le_12"] is False



def main() -> None:
    test_inspect_gate4_fails_when_too_many_slices()
    print("test_gate4 ok")


if __name__ == "__main__":
    main()
