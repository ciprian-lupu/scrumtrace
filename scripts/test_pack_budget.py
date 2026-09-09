#!/usr/bin/env python3
"""PackBudget: 35 MB cap is measured on the zip, not assumed from clip count."""
from __future__ import annotations

import os
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

MAX_ZIP = 35 * 1024 * 1024


def zip_export(src: Path, dest: Path) -> int:
    dest.unlink(missing_ok=True)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(src.rglob("*")):
            if p.is_file():
                zf.write(p, p.relative_to(src).as_posix())
    return dest.stat().st_size


def omission_order(rel_paths: list[str]) -> list[str]:
    extras = []
    extra_clips = []
    extra_stills = []
    keyword = []
    for rel in rel_paths:
        if rel.startswith("media-work/"):
            extras.append(rel)
        elif rel.endswith(".mp4") and rel.startswith("media/") and "keyword" not in rel:
            extra_clips.append(rel)
        elif rel.endswith(".png") and rel.startswith("shots/") and "001" not in rel:
            extra_stills.append(rel)
        elif rel.endswith(".mp4") and rel.startswith("media/"):
            keyword.append(rel)
    extra_clips.sort()
    extra_stills.sort()
    extras.sort()
    keyword.sort()
    # Spec drop order: keyword-only, extra stills, extra clips, then leftover.
    return extras + extra_stills + extra_clips + keyword


def omit_until_under(src: Path, dest: Path) -> list[str]:
    omitted: list[str] = []
    size = zip_export(src, dest)
    rels = [p.relative_to(src).as_posix() for p in src.rglob("*") if p.is_file()]
    order = omission_order(rels)
    i = 0
    while size > MAX_ZIP and i < len(order):
        rel = order[i]
        i += 1
        path = src / rel
        if path.exists():
            path.unlink()
            omitted.append(rel)
            size = zip_export(src, dest)
    return omitted


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "export"
        src.mkdir()
        (src / "AGENT_CONTEXT.md").write_text("# ctx\n", encoding="utf-8")
        (src / "media").mkdir()
        (src / "media-work").mkdir()
        (src / "shots").mkdir()
        # Incompressible blobs so DEFLATED zip stays above the 35 MB cap.
        (src / "media" / "keyword.mp4").write_bytes(os.urandom(36 * 1024 * 1024))
        (src / "media-work" / "scratch.mp4").write_bytes(os.urandom(8 * 1024 * 1024))
        (src / "shots" / "001.png").write_bytes(os.urandom(200_000))
        dest = Path(tmp) / "pack.zip"
        omitted = omit_until_under(src, dest)
        size = dest.stat().st_size
        assert size <= MAX_ZIP, f"zip still {size}"
        assert "media/keyword.mp4" in omitted, omitted
        assert "media-work/scratch.mp4" in omitted, omitted
        assert omitted[0] == "media-work/scratch.mp4", omitted
        assert not (src / "media" / "keyword.mp4").exists()
        print("pack budget: ok", size, omitted)

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "export"
        src.mkdir()
        (src / "AGENT_CONTEXT.md").write_text("# ctx\n![](shots/001.jpg)\n", encoding="utf-8")
        (src / "SESSION_BRIEF.html").write_text("<html></html>", encoding="utf-8")
        (src / "session.manifest.json").write_text("{}", encoding="utf-8")
        (src / "media").mkdir()
        (src / "shots").mkdir()
        for i in range(1, 9):
            folder = src / "media" / f"task-{i:02d}"
            folder.mkdir()
            (folder / "clip.mp4").write_bytes(os.urandom(6 * 1024 * 1024))
        for i in range(1, 21):
            (src / "shots" / f"{i:03d}.jpg").write_bytes(os.urandom(80_000))
        dest = Path(tmp) / "pack.zip"
        omitted = omit_until_under(src, dest)
        size = dest.stat().st_size
        assert size <= MAX_ZIP, f"8-clip zip still {size}"
        assert omitted, "expected named omissions for 8×6 MB clips"
        (src / "OMITTED.md").write_text(
            "# Omitted from export\n\n" + "\n".join(f"- `{path}`" for path in omitted),
            encoding="utf-8",
        )
        assert (src / "shots" / "001.jpg").exists(), "evidence shot 001 must survive omit"
        assert (src / "AGENT_CONTEXT.md").exists()
        remaining_ctx = "shots/001.jpg"
        assert (src / remaining_ctx).is_file()
        print("pack budget 8 clips / 20 shots: ok", size, "omitted", len(omitted))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
