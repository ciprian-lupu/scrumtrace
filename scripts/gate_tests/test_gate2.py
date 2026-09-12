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

def test_inspect_gate2_fails_when_shot_saves_during_pause() -> None:
    log = Path("/tmp/scrumtrace-gate2-shot.jsonl")
    log.write_text(
        json.dumps({"event": "pause_ok"})
        + "\n"
        + json.dumps({"event": "shot_save"})
        + "\n"
        + json.dumps({"event": "resume_ok"})
        + "\n",
        encoding="utf-8",
    )
    result = _run("inspect_gate2_shot.py", ["--log", str(log)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["shot_persisted_while_paused"] == 1


def test_inspect_gate2_passes_when_shot_refused() -> None:
    log = Path("/tmp/scrumtrace-gate2-ok.jsonl")
    log.write_text(
        json.dumps({"event": "pause_ok"})
        + "\n"
        + json.dumps({"event": "shot_ignored", "reason": "paused"})
        + "\n"
        + json.dumps({"event": "talk_start_fail", "reason": "paused"})
        + "\n"
        + json.dumps({"event": "pin_ignored", "reason": "paused"})
        + "\n"
        + json.dumps({"event": "resume_ok"})
        + "\n",
        encoding="utf-8",
    )
    result = _run("inspect_gate2_shot.py", ["--log", str(log)])
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["exercised"] is True


def test_inspect_gate2_blocked_without_pause() -> None:
    log = Path("/tmp/scrumtrace-gate2-nopause.jsonl")
    log.write_text(json.dumps({"event": "launch"}) + "\n", encoding="utf-8")
    result = _run("inspect_gate2_shot.py", ["--log", str(log)])
    assert result.returncode == 2
    report = json.loads(result.stdout)
    assert report["blocked"] is True



def main() -> None:
    test_inspect_gate2_fails_when_shot_saves_during_pause()
    test_inspect_gate2_passes_when_shot_refused()
    test_inspect_gate2_blocked_without_pause()
    print("test_gate2 ok")


if __name__ == "__main__":
    main()
