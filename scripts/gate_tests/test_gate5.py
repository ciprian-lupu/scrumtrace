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

def test_inspect_gate5_fails_when_confirmed_lacks_files() -> None:
    session = Path("/tmp/scrumtrace-gate5-evidence")
    session.mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(exist_ok=True)
    (session / "session.manifest.json").write_text(
        json.dumps(
            {
                "upload_consent": {
                    "approved": True,
                    "provider": "openai_compatible",
                    "endpoint": "https://api.openai.com",
                    "model": "gpt-4o",
                    "includes_clip_audio": False,
                    "includes_clip_video": False,
                    "includes_stills": True,
                },
                "tasks": [
                    {
                        "task_id": "TASK-01",
                        "status": "confirmed",
                        "evidence_media": ["shots/missing.png"],
                        "inferred": "x",
                        "observed": "y",
                        "stated": "z",
                        "quotes": [],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    result = _run("inspect_gate5_provider.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["confirmed_evidence_on_disk"] is False


def test_inspect_gate5_fails_when_eval_follows_denied_consent() -> None:
    session = Path("/tmp/scrumtrace-gate5-deny")
    session.mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(exist_ok=True)
    (session / "session.manifest.json").write_text(
        json.dumps(
            {
                "upload_consent": {
                    "approved": False,
                    "approved_at": "2026-09-11T00:00:00Z",
                    "provider": "openai_compatible",
                    "endpoint": "https://api.openai.com",
                    "model": "gpt-4o",
                    "includes_clip_audio": False,
                    "includes_clip_video": False,
                    "includes_stills": False,
                },
                "tasks": [],
            }
        ),
        encoding="utf-8",
    )
    log = Path("/tmp/scrumtrace-gate5-deny.jsonl")
    log.write_text(
        json.dumps({"event": "consent_result", "approved": "0", "provider": "openai_compatible"})
        + "\n"
        + json.dumps({"event": "eval_slice"})
        + "\n",
        encoding="utf-8",
    )
    result = _run(
        "inspect_gate5_provider.py",
        ["--session", str(session), "--log", str(log)],
    )
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["no_eval_after_denied_consent"] is False



def main() -> None:
    test_inspect_gate5_fails_when_confirmed_lacks_files()
    test_inspect_gate5_fails_when_eval_follows_denied_consent()
    print("test_gate5 ok")


if __name__ == "__main__":
    main()
