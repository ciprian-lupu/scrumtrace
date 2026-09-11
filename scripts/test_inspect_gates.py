from __future__ import annotations

import json
import subprocess
import sys
import zipfile
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


def test_inspect_gate1_fails_when_pause_count_or_duration_short() -> None:
    session = Path("/tmp/scrumtrace-inspect-gate1-short")
    _write_gate1_fake_session(
        session,
        layout={
            "microphone_wav": True,
            "system_audio_in_movie": True,
            "wav_start_media_seconds": 0.0,
        },
    )
    result = _run_gate1(session)
    report = json.loads(result.stdout)
    assert result.returncode == 1
    assert report["checks"]["manifest_pause_count_ge_3"] is False
    assert report["checks"]["manifest_media_ge_1200"] is False
    assert "manifest_pause_count_ge_3" in report["required"]
    assert "manifest_media_ge_1200" in report["required"]
    assert "manifest_pause_count_ge_3" in report["failed"]
    assert "manifest_media_ge_1200" in report["failed"]


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


def _run(script: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts" / script), *args],
        check=False,
        capture_output=True,
        text=True,
    )


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


def test_inspect_minus0_fails_without_movie() -> None:
    session = Path("/tmp/scrumtrace-minus0-empty")
    (session / "archive").mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(parents=True, exist_ok=True)
    result = _run("inspect_gate_minus0.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["session_mp4_exists"] is False


def test_inspect_minus0_requires_first_samples_when_log_given() -> None:
    session = Path("/tmp/scrumtrace-minus0-samples")
    archive = session / "archive"
    archive.mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(parents=True, exist_ok=True)
    (archive / "session.mp4").write_bytes(b"ftyp")
    (archive / "audio.wav").write_bytes(b"RIFF")
    (archive / "capture-layout.json").write_text(
        json.dumps({"wav_start_media_seconds": 0.0}),
        encoding="utf-8",
    )
    log = Path("/tmp/scrumtrace-minus0.jsonl")
    log.write_text(json.dumps({"event": "launch"}) + "\n", encoding="utf-8")
    result = _run(
        "inspect_gate_minus0.py",
        ["--session", str(session), "--log", str(log)],
    )
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["first_sample_screen"] is False
    assert "first_sample_screen" in report["failed"]


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


def test_inspect_gate3_blocked_without_transcript() -> None:
    session = Path("/tmp/scrumtrace-gate3-empty")
    (session / "archive").mkdir(parents=True, exist_ok=True)
    result = _run("inspect_gate3_whisper.py", ["--session", str(session)])
    assert result.returncode == 2


def test_inspect_gate3_fails_when_dual_pass_missing() -> None:
    session = Path("/tmp/scrumtrace-gate3-dual")
    archive = session / "archive"
    archive.mkdir(parents=True, exist_ok=True)
    (session / "export").mkdir(parents=True, exist_ok=True)
    (archive / "full_transcript.json").write_text(
        json.dumps({"segments": [{"start": 0, "end": 1, "text": "hi"}], "sources": ["room"]}),
        encoding="utf-8",
    )
    (archive / "pipeline-timing.json").write_text(
        json.dumps({"whisper_wall_seconds": 12.0, "whisper_sources": ["room"], "whisper_incomplete": False}),
        encoding="utf-8",
    )
    (archive / "capture-layout.json").write_text(
        json.dumps({"microphone_wav": True, "system_audio_in_movie": True}),
        encoding="utf-8",
    )
    result = _run("inspect_gate3_whisper.py", ["--session", str(session)])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["dual_pass_when_both_captured"] is False


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


def test_inspect_all_gates_mock_only() -> None:
    result = _run("inspect_all_gates.py", ["--mock-only"])
    assert result.returncode == 0, result.stdout + result.stderr
    summary = json.loads(result.stdout)
    assert summary["gates"]["minus1"]["status"] == "pass"
    assert "Do not invent GATE_LOG.md cells" in summary["note"]


def main() -> None:
    test_inspect_gate1_fails_when_token_is_in_movie()
    test_inspect_gate1_fails_when_wav_exists_without_layout()
    test_inspect_gate1_reports_wav_start_when_layout_present()
    test_inspect_gate1_fails_when_pause_count_or_duration_short()
    test_inspect_gate0_fails_when_shot_steals_focus()
    test_inspect_gate0_fails_when_start_skips_overlay()
    test_inspect_gate0_fails_when_open_omits_record_mode()
    test_inspect_gate0_fails_when_start_uses_choose_mode()
    test_inspect_gate0_passes_when_overlay_cancelled()
    test_inspect_gate0_passes_when_record_follows_overlay()
    test_inspect_minus1_passes_repo_mock()
    test_inspect_minus1_fails_when_token_leaks()
    test_inspect_minus0_fails_without_movie()
    test_inspect_minus0_requires_first_samples_when_log_given()
    test_inspect_gate2_fails_when_shot_saves_during_pause()
    test_inspect_gate2_passes_when_shot_refused()
    test_inspect_gate2_blocked_without_pause()
    test_inspect_gate3_blocked_without_transcript()
    test_inspect_gate3_fails_when_dual_pass_missing()
    test_inspect_gate4_fails_when_too_many_slices()
    test_inspect_gate5_fails_when_confirmed_lacks_files()
    test_inspect_gate5_fails_when_eval_follows_denied_consent()
    test_inspect_gate6_fails_when_zip_lists_archive()
    test_inspect_all_gates_mock_only()
    print("inspect gate helpers ok")


if __name__ == "__main__":
    main()
