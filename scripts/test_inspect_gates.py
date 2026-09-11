from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_inspect_gate1_fails_when_token_is_in_movie() -> None:
    script = ROOT / "scripts" / "inspect_gate1_session.py"
    session = Path("/tmp/scrumtrace-inspect-gate1")
    archive = session / "archive"
    export = session / "export"
    shots = archive / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    (archive / "session.mp4").write_bytes(b"xxxx ST-G1-PAUSE-TOKEN-9F3C yyyy")
    (archive / "audio.wav").write_bytes(b"RIFF....orchid lantern seven")
    (archive / "full_transcript.json").write_text("{}", encoding="utf-8")
    (archive / "events.jsonl").write_text("{}\n", encoding="utf-8")
    (session / "session.manifest.json").write_text(
        json.dumps({"duration": {"media_seconds": 1}, "pauses": []}),
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "--session",
            str(session),
            "--token",
            "ST-G1-PAUSE-TOKEN-9F3C",
            "--passphrase",
            "orchid lantern seven",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["session_mp4_no_ascii_token"] is False
    assert report["checks"]["audio_wav_no_ascii_passphrase"] is False


def test_inspect_gate0_fails_when_shot_steals_focus() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = Path("/tmp/scrumtrace-inspect-gate0.jsonl")
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
    log = Path("/tmp/scrumtrace-inspect-gate0-overlay.jsonl")
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


def test_inspect_gate0_passes_when_record_follows_overlay() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = Path("/tmp/scrumtrace-inspect-gate0-overlay-ok.jsonl")
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
    test_inspect_gate1_fails_when_token_is_in_movie()
    test_inspect_gate0_fails_when_shot_steals_focus()
    test_inspect_gate0_fails_when_start_skips_overlay()
    test_inspect_gate0_passes_when_record_follows_overlay()
    print("inspect gate helpers ok")


if __name__ == "__main__":
    main()
