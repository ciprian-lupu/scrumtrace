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


def _write_gate1_fake_session(session: Path, *, layout: object | None) -> None:
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
    layout_path = archive / "capture-layout.json"
    if layout is None:
        layout_path.unlink(missing_ok=True)
    else:
        payload = layout if isinstance(layout, str) else json.dumps(layout)
        layout_path.write_text(payload, encoding="utf-8")


def _run_gate1(session: Path) -> subprocess.CompletedProcess[str]:
    script = ROOT / "scripts" / "inspect_gate1_session.py"
    return subprocess.run(
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


def test_inspect_gate1_fails_when_wav_exists_without_layout() -> None:
    session = Path("/tmp/scrumtrace-inspect-gate1-no-layout")
    _write_gate1_fake_session(session, layout=None)
    result = _run_gate1(session)
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["checks"]["capture_layout_exists"] is False
    assert report["checks"]["wav_start_media_seconds"] is None
    assert report["checks"]["wav_start_present"] is False
    assert "capture_layout_exists" in report["required"]
    assert "wav_start_present" in report["required"]
    assert "capture_layout_exists" in report["failed"]
    assert "wav_start_present" in report["failed"]


def test_inspect_gate1_reports_wav_start_when_layout_present() -> None:
    session = Path("/tmp/scrumtrace-inspect-gate1-with-layout")
    _write_gate1_fake_session(
        session,
        layout={
            "microphone_wav": True,
            "system_audio_in_movie": True,
            "wav_start_media_seconds": 0.12,
        },
    )
    result = _run_gate1(session)
    report = json.loads(result.stdout)
    assert report["checks"]["capture_layout_exists"] is True
    assert report["checks"]["wav_start_media_seconds"] == 0.12
    assert report["checks"]["wav_start_present"] is True
    assert "capture_layout_exists" in report["required"]
    assert "wav_start_present" in report["required"]
    assert "capture_layout_exists" not in report["failed"]
    assert "wav_start_present" not in report["failed"]


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


def test_inspect_gate0_fails_when_open_omits_record_mode() -> None:
    script = ROOT / "scripts" / "inspect_gate0_log.py"
    log = Path("/tmp/scrumtrace-inspect-gate0-open-mode.jsonl")
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
    log = Path("/tmp/scrumtrace-inspect-gate0-choose.jsonl")
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
    log = Path("/tmp/scrumtrace-inspect-gate0-cancel.jsonl")
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
    test_inspect_gate1_fails_when_wav_exists_without_layout()
    test_inspect_gate1_reports_wav_start_when_layout_present()
    test_inspect_gate0_fails_when_shot_steals_focus()
    test_inspect_gate0_fails_when_start_skips_overlay()
    test_inspect_gate0_fails_when_open_omits_record_mode()
    test_inspect_gate0_fails_when_start_uses_choose_mode()
    test_inspect_gate0_passes_when_overlay_cancelled()
    test_inspect_gate0_passes_when_record_follows_overlay()
    print("inspect gate helpers ok")


if __name__ == "__main__":
    main()
