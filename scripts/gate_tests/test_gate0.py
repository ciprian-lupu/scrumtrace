from __future__ import annotations

import tempfile

import json
import subprocess
import sys
import zipfile
from pathlib import Path

_GATE_DIR = Path(__file__).resolve().parent
if str(_GATE_DIR) not in sys.path:
    sys.path.insert(0, str(_GATE_DIR))

from support import ROOT

def test_inspect_gate0_fails_when_shot_steals_focus() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "inspect-gate0.jsonl")
    log.write_text(
        json.dumps({"event": "hotkey_shot"})
        + "\n"
        + json.dumps({"event": "hotkey_front", "action": "shot", "app_active": "1", "front": "com.str8minds.ScrumTrace"})
        + "\n"
        + json.dumps({"event": "shot_window_key", "app_active": "1", "front": "com.apple.iWork.Keynote"})
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(script), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["shot_became_key_while_app_active"] == 1
    assert report["hotkey_activated_app"] == 1


def test_inspect_gate0_fails_when_start_skips_overlay() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "inspect-gate0-overlay.jsonl")
    log.write_text(
        json.dumps({"event": "menu_start"})
        + "\n"
        + json.dumps({"event": "start_requested"})
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(script), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["start_without_overlay"] == 1


def test_inspect_gate0_fails_when_open_omits_record_mode() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "inspect-gate0-open-mode.jsonl")
    log.write_text(
        json.dumps({"event": "menu_start"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "open"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "confirm", "mode": "record"})
        + "\n"
        + json.dumps({"event": "start_requested"})
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(script), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["start_without_overlay"] == 1


def test_inspect_gate0_fails_when_start_uses_choose_mode() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "inspect-gate0-choose.jsonl")
    log.write_text(
        json.dumps({"event": "menu_start"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "open", "mode": "choose"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "confirm", "mode": "choose"})
        + "\n"
        + json.dumps({"event": "start_requested"})
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(script), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["start_without_overlay"] == 1


def test_inspect_gate0_passes_when_overlay_cancelled() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "inspect-gate0-cancel.jsonl")
    log.write_text(
        json.dumps({"event": "menu_start"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "open", "mode": "record"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "cancel"})
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(script), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["picker_cancel"] == 1
    assert report["start_requested"] == 0
    assert report["start_without_overlay"] == 0


def test_inspect_gate0_passes_when_record_follows_overlay() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = (Path(tempfile.mkdtemp(prefix="scrumtrace-")) / "inspect-gate0-overlay-ok.jsonl")
    log.write_text(
        json.dumps({"event": "menu_start"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "open", "mode": "record"})
        + "\n"
        + json.dumps({"event": "capture_area_picker", "action": "confirm", "full": "0", "mode": "record"})
        + "\n"
        + json.dumps({"event": "start_requested"})
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(script), "--log", str(log)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["picker_open"] == 1
    assert report["picker_confirm"] == 1
    assert report["start_without_overlay"] == 0



def main() -> None:
    test_inspect_gate0_fails_when_shot_steals_focus()
    test_inspect_gate0_fails_when_start_skips_overlay()
    test_inspect_gate0_fails_when_open_omits_record_mode()
    test_inspect_gate0_fails_when_start_uses_choose_mode()
    test_inspect_gate0_passes_when_overlay_cancelled()
    test_inspect_gate0_passes_when_record_follows_overlay()
    print("test_gate0 ok")


if __name__ == "__main__":
    main()
