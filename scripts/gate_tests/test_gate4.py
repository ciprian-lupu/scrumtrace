#!/usr/bin/env python3
"""Gate 4 tests: real clip measurements, ZIP size parity, Chrome flag."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_gate4_slicer.py"


def _ffprobe_stub_env(
    *,
    width: int = 1280,
    height: int = 720,
    codec: str = "h264",
    profile: str = "high",
    audio: str = "aac",
) -> dict[str, str]:
    bindir = Path(tempfile.mkdtemp(prefix="scrumtrace-ffprobe4-"))
    stub = bindir / "ffprobe"
    # Return video JSON when -select_streams v:0, audio codec otherwise.
    stub.write_text(
        f"""#!/bin/sh
if echo "$*" | grep -q 'v:0'; then
  cat <<'EOF'
{{"streams":[{{"codec_name":"{codec}","profile":"{profile}","width":{width},"height":{height}}}]}}
EOF
else
  cat <<'EOF'
{{"streams":[{{"codec_name":"{audio}"}}]}}
EOF
fi
""",
        encoding="utf-8",
    )
    stub.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{bindir}:{env.get('PATH', '')}"
    return env


def _write_session(
    session: Path,
    *,
    slices: list[dict[str, object]] | None,
    zip_bytes: object = None,
    clip_bytes: bytes = b"not-empty-clip",
    corrupt_zip: bool = False,
) -> None:
    archive = session / "archive"
    export = session / "export" / "media" / "task-01"
    archive.mkdir(parents=True, exist_ok=True)
    export.mkdir(parents=True, exist_ok=True)
    if slices is None:
        (session / "session.manifest.json").write_text(
            json.dumps({"slices": []}), encoding="utf-8"
        )
    else:
        for item in slices:
            rel = str(item.get("export_clip_path") or "media/task-01/clip.mp4")
            cleaned = rel[len("export/") :] if rel.startswith("export/") else rel
            path = session / "export" / cleaned
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(clip_bytes)
        (session / "session.manifest.json").write_text(
            json.dumps({"slices": slices}), encoding="utf-8"
        )
    zip_path = session / "export" / "session-pack.zip"
    if corrupt_zip:
        zip_path.write_bytes(b"not-a-zip")
        size = zip_path.stat().st_size
    else:
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("SESSION_BRIEF.html", "<html></html>")
        size = zip_path.stat().st_size
    if zip_bytes is None:
        zip_bytes = size
    (archive / "pipeline-timing.json").write_text(
        json.dumps({"zip_bytes": zip_bytes}), encoding="utf-8"
    )


def _good_slices(n: int = 1, duration: float = 25.0) -> list[dict[str, object]]:
    return [
        {
            "slice_id": f"s{i}",
            "start_media": float(i) * 30.0,
            "end_media": float(i) * 30.0 + duration,
            "export_clip_path": "media/task-01/clip.mp4",
        }
        for i in range(n)
    ]


def _run(
    session: Path, *, chrome: bool = False, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    args = [sys.executable, str(SCRIPT), "--session", str(session)]
    if chrome:
        args.append("--chrome-playback-ok")
    return subprocess.run(args, check=False, capture_output=True, text=True, env=env)


def test_thirteen_slices_fail() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    _write_session(session, slices=_good_slices(13))
    result = _run(session, chrome=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["checks"]["candidate_windows_le_12"] is False
    assert "slice_count_1_to_12" in report["failed"]


def test_empty_slices_block() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    _write_session(session, slices=None)
    result = _run(session, chrome=True, env=_ffprobe_stub_env())
    assert result.returncode == 2
    report = json.loads(result.stdout)
    assert report["status"] == "blocked"


def test_duration_25_passes_25001_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    env = _ffprobe_stub_env()
    _write_session(session, slices=_good_slices(1, duration=25.0))
    ok = _run(session, chrome=True, env=env)
    assert ok.returncode == 0, ok.stdout + ok.stderr
    _write_session(session, slices=_good_slices(1, duration=25.001))
    bad = _run(session, chrome=True, env=env)
    assert bad.returncode == 1
    assert "slice_ranges_ok" in json.loads(bad.stdout)["failed"]


def test_negative_and_nan_times_fail() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    env = _ffprobe_stub_env()
    for start, end in ((-1.0, 1.0), (0.0, float("nan")), (5.0, 4.0)):
        slices = [
            {
                "slice_id": "s0",
                "start_media": start,
                "end_media": end,
                "export_clip_path": "media/task-01/clip.mp4",
            }
        ]
        _write_session(session, slices=slices)
        result = _run(session, chrome=True, env=env)
        assert result.returncode == 1, (start, end, result.stdout)
        assert "slice_ranges_ok" in json.loads(result.stdout)["failed"]


def test_zip_bytes_mismatch_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    _write_session(session, slices=_good_slices(1), zip_bytes=1)
    result = _run(session, chrome=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "zip_bytes_match_file" in report["failed"]


def test_missing_or_empty_clip_fails() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    _write_session(session, slices=_good_slices(1), clip_bytes=b"")
    result = _run(session, chrome=True, env=_ffprobe_stub_env())
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "clip_exists" in report["failed"]


def test_missing_chrome_flag_returns_manual_required() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    _write_session(session, slices=_good_slices(1))
    result = _run(session, chrome=False, env=_ffprobe_stub_env())
    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "manual_required"


def test_valid_artifacts_with_chrome_pass() -> None:
    session = Path(tempfile.mkdtemp(prefix="scrumtrace-gate4-")) / "s"
    _write_session(session, slices=_good_slices(2, duration=10.0))
    result = _run(session, chrome=True, env=_ffprobe_stub_env())
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    assert report["status"] == "pass"
    assert report["checks"]["clip_profile"] == "high"
    assert report["checks"]["clip_audio_codec"] == "aac"


def main() -> None:
    test_thirteen_slices_fail()
    test_empty_slices_block()
    test_duration_25_passes_25001_fails()
    test_negative_and_nan_times_fail()
    test_zip_bytes_mismatch_fails()
    test_missing_or_empty_clip_fails()
    test_missing_chrome_flag_returns_manual_required()
    test_valid_artifacts_with_chrome_pass()
    print("test_gate4 ok")


if __name__ == "__main__":
    main()
