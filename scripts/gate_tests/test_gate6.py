#!/usr/bin/env python3
"""Gate 6 tests: ZIP inventory, allow-list, omissions, and HTML escaping."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "inspect_gate6_pack.py"
sys.path.insert(0, str(ROOT / "scripts"))
from gate_inspect_lib import zip_inventory, zip_names


def _session(tmp: Path) -> Path:
    session = tmp / "s"
    (session / "archive").mkdir(parents=True)
    (session / "export").mkdir(parents=True)
    return session


def _write_base(
    session: Path,
    *,
    omitted: list[dict[str, object]] | None = None,
    zip_bytes: int | None = None,
    special: str = "plain",
    members: dict[str, bytes] | None = None,
    export_manifest_omitted: list[dict[str, object]] | None = None,
    context_extra: str = "",
    brief_extra: str = "",
    export_manifest_extra: dict[str, object] | None = None,
) -> None:
    export = session / "export"
    omitted = list(omitted or [])
    title = special
    observed = special
    stated = special
    inferred = special
    note = special
    manifest = {
        "omitted": omitted,
        "tasks": [
            {
                "title": title,
                "observed": observed,
                "stated": stated,
                "inferred": inferred,
                "agent_instructions": special,
            }
        ],
        "shots": [{"note": note}],
    }
    (session / "session.manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    export_manifest = {"omitted": list(export_manifest_omitted if export_manifest_omitted is not None else omitted)}
    if export_manifest_extra:
        export_manifest.update(export_manifest_extra)
    (export / "session.manifest.json").write_text(json.dumps(export_manifest), encoding="utf-8")

    escaped_brief = (
        brief_extra
        or (
            f"<p>{title.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('\"','&quot;')}</p>"
            if any(ch in special for ch in '&<>"')
            else f"<p>{special}</p>"
        )
    )
    (export / "AGENT_CONTEXT.md").write_text(
        "# context\n" + context_extra, encoding="utf-8"
    )
    (export / "SESSION_BRIEF.html").write_text(escaped_brief, encoding="utf-8")
    (export / "AGENT_PROMPT.txt").write_text("prompt", encoding="utf-8")
    if omitted:
        lines = ["# Omitted from export", ""]
        for item in omitted:
            path = str(item.get("path") or "").removeprefix("export/")
            reason = str(item.get("reason") or "")
            lines.append(f"- `{path}` — {reason}")
        (export / "OMITTED.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    else:
        omitted_path = export / "OMITTED.md"
        if omitted_path.exists():
            omitted_path.unlink()

    default_members = {
        "AGENT_CONTEXT.md": b"# context\n",
        "SESSION_BRIEF.html": escaped_brief.encode(),
        "AGENT_PROMPT.txt": b"prompt",
        "session.manifest.json": json.dumps(export_manifest).encode(),
    }
    if omitted:
        default_members["OMITTED.md"] = (export / "OMITTED.md").read_bytes()
    payload = members if members is not None else default_members
    zip_path = export / "session-pack.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        for name, data in payload.items():
            zf.writestr(name, data)
    size = zip_path.stat().st_size
    (session / "archive" / "pipeline-timing.json").write_text(
        json.dumps(
            {
                "zip_bytes": size if zip_bytes is None else zip_bytes,
                "omitted_count": len(omitted),
            }
        ),
        encoding="utf-8",
    )


def _run(session: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--session", str(session)],
        check=False,
        capture_output=True,
        text=True,
    )


def test_zip_inventory_states() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        missing = zip_inventory(root / "no.zip")
        assert missing.state == "missing"
        assert zip_names(root / "no.zip") == []
        good = root / "ok.zip"
        with zipfile.ZipFile(good, "w") as zf:
            zf.writestr("a.txt", "hi")
        inv = zip_inventory(good)
        assert inv.state == "valid"
        assert zip_names(good) == ["a.txt"]
        bad = root / "bad.zip"
        bad.write_bytes(b"not-a-zip")
        assert zip_inventory(bad).state == "corrupt"
        assert zip_names(bad) == []


def test_missing_zip_blocks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        _write_base(session, special='A & B <C> "D"')
        (session / "export" / "session-pack.zip").unlink()
        result = _run(session)
        assert result.returncode == 2
        assert json.loads(result.stdout)["status"] == "blocked"


def test_corrupt_zip_blocks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        _write_base(session, special='A & B <C> "D"')
        (session / "export" / "session-pack.zip").write_bytes(b"nope")
        result = _run(session)
        assert result.returncode == 2
        assert "zip_corrupt" in json.loads(result.stdout)["blocked_reasons"]


def test_archive_member_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        _write_base(
            session,
            special='A & B <C> "D"',
            members={
                "AGENT_CONTEXT.md": b"#",
                "SESSION_BRIEF.html": b"<p>A &amp; B &lt;C&gt; &quot;D&quot;</p>",
                "AGENT_PROMPT.txt": b"p",
                "session.manifest.json": b"{}",
                "archive/session.mp4": b"nope",
            },
        )
        result = _run(session)
        assert result.returncode == 1
        report = json.loads(result.stdout)
        assert "zip_members_allowed" in report["failed"]


def test_missing_required_doc_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        _write_base(
            session,
            special='A & B <C> "D"',
            members={
                "AGENT_CONTEXT.md": b"#",
                "SESSION_BRIEF.html": b"<p>A &amp; B &lt;C&gt; &quot;D&quot;</p>",
                "session.manifest.json": b"{}",
            },
        )
        result = _run(session)
        assert result.returncode == 1
        assert "required_docs_present" in json.loads(result.stdout)["failed"]


def test_timing_mismatch_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        _write_base(session, special='A & B <C> "D"', zip_bytes=1)
        result = _run(session)
        assert result.returncode == 1
        assert "timing_zip_bytes_match" in json.loads(result.stdout)["failed"]


def test_omitted_count_mismatch_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        omitted = [{"path": "export/media/big.mp4", "reason": "oversize"}]
        _write_base(session, special='A & B <C> "D"', omitted=omitted)
        timing = json.loads((session / "archive" / "pipeline-timing.json").read_text())
        timing["omitted_count"] = 99
        (session / "archive" / "pipeline-timing.json").write_text(json.dumps(timing))
        result = _run(session)
        assert result.returncode == 1
        assert "timing_omitted_count_match" in json.loads(result.stdout)["failed"]


def test_html_specials_must_be_escaped() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        _write_base(
            session,
            special='A & B <C> "D"',
            brief_extra="<p>A & B <C> \"D\"</p>",  # raw specials, not escaped
        )
        result = _run(session)
        assert result.returncode == 1
        assert "html_specials_escaped" in json.loads(result.stdout)["failed"]


def test_good_pack_passes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        session = _session(Path(tmp))
        export = session / "export"
        (export / "shots").mkdir()
        (export / "shots" / "a.png").write_bytes(b"png")
        _write_base(
            session,
            special='A & B <C> "D"',
            context_extra="![](shots/a.png)\n",
            omitted=[{"path": "export/media/huge.mp4", "reason": "oversize"}],
        )
        # Rebuild zip including shot is not required inside zip for context path check;
        # context links resolve against export/.
        result = _run(session)
        assert result.returncode == 0, result.stdout + result.stderr
        report = json.loads(result.stdout)
        assert report["status"] == "pass"


def main() -> None:
    test_zip_inventory_states()
    test_missing_zip_blocks()
    test_corrupt_zip_blocks()
    test_archive_member_fails()
    test_missing_required_doc_fails()
    test_timing_mismatch_fails()
    test_omitted_count_mismatch_fails()
    test_html_specials_must_be_escaped()
    test_good_pack_passes()
    print("test_gate6 ok")


if __name__ == "__main__":
    main()
