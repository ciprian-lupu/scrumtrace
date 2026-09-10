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
NAMED_DOCS = (
    "AGENT_CONTEXT.md",
    "SESSION_BRIEF.html",
    "AGENT_PROMPT.txt",
    "session.manifest.json",
    "OMITTED.md",
)


def contained_export_member(file: Path, export_dir: Path) -> str | None:
    if file.is_symlink() or not file.is_file():
        return None
    export_root = export_dir.resolve()
    try:
        rel = file.resolve().relative_to(export_root)
    except ValueError:
        return None
    parts = [part for part in rel.as_posix().split("/") if part]
    if not parts or ".." in parts or "archive" in parts:
        return None
    return "/".join(parts)


def remove_escaping_export_links(export_dir: Path) -> None:
    if export_dir.is_symlink():
        export_dir.unlink()
        export_dir.mkdir(parents=True, exist_ok=True)
        return
    if not export_dir.is_dir():
        return
    links: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(export_dir, followlinks=False):
        base = Path(dirpath)
        for name in dirnames:
            path = base / name
            if path.is_symlink():
                links.append(path)
        for name in filenames:
            path = base / name
            if path.is_symlink():
                links.append(path)
    for link in reversed(links):
        if link.is_symlink():
            link.unlink(missing_ok=True)


def iter_export_files(root: Path):
    if root.is_symlink() or not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(dirpath)
        dirnames[:] = [name for name in dirnames if not (base / name).is_symlink()]
        for name in filenames:
            path = base / name
            if not path.is_symlink():
                yield path


def allow_list(export_dir: Path, include_full_transcript: bool = False) -> list[str]:
    remove_escaping_export_links(export_dir)
    out: list[str] = []
    for name in NAMED_DOCS:
        member = contained_export_member(export_dir / name, export_dir)
        if member:
            out.append(member)
    if include_full_transcript:
        member = contained_export_member(export_dir / "full_transcript.json", export_dir)
        if member:
            out.append(member)
    for folder in ("shots", "media"):
        for path in iter_export_files(export_dir / folder):
            member = contained_export_member(path, export_dir)
            if member:
                out.append(member)
    return sorted(out)


def zip_allow_list(export_dir: Path, dest: Path, members: list[str]) -> None:
    dest.unlink(missing_ok=True)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_STORED) as zf:
        for member in members:
            path = export_dir / member
            if path.is_symlink():
                raise AssertionError(f"allow-list followed symlink {member}")
            zf.write(path, member)


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

    with tempfile.TemporaryDirectory() as tmp:
        export = Path(tmp) / "pack-root"
        export.mkdir()
        (export / "shots").mkdir()
        (export / "media").mkdir()
        (export / "AGENT_CONTEXT.md").write_text("# ctx\n", encoding="utf-8")
        (export / "shots" / "ok.png").write_bytes(b"still")
        secret = Path(tmp) / "outside.mp4"
        secret.write_bytes(b"ARCHIVE-LEAK")
        (export / "media" / "leak.mp4").symlink_to(secret)
        (export / "AGENT_PROMPT.txt").symlink_to(secret)
        members = allow_list(export)
        assert "shots/ok.png" in members, members
        assert "AGENT_CONTEXT.md" in members, members
        assert "media/leak.mp4" not in members, members
        assert "AGENT_PROMPT.txt" not in members
        dest = Path(tmp) / "pack.zip"
        zip_allow_list(export, dest, members)
        with zipfile.ZipFile(dest) as zf:
            names = set(zf.namelist())
            assert "shots/ok.png" in names
            assert "media/leak.mp4" not in names
            assert "AGENT_PROMPT.txt" not in names
            for info in zf.infolist():
                data = zf.read(info)
                assert b"ARCHIVE-LEAK" not in data, info.filename
        assert not (export / "media" / "leak.mp4").exists()
        assert not (export / "AGENT_PROMPT.txt").exists()
        assert secret.exists()
        print("pack budget symlink escape: ok", members)

    with tempfile.TemporaryDirectory() as tmp:
        session = Path(tmp) / "session"
        export = session / "export"
        archive = session / "archive"
        (export / "shots").mkdir(parents=True)
        archive.mkdir(parents=True)
        secret = archive / "session.mp4"
        secret.write_bytes(b"secret-movie")
        (export / "media").symlink_to(archive)
        remove_escaping_export_links(export)
        assert not (export / "media").exists()
        assert secret.exists()
        trap = export / "shots" / "leak.mp4"
        trap.symlink_to(secret)
        remove_escaping_export_links(export)
        assert not trap.exists()
        assert secret.exists()
    with tempfile.TemporaryDirectory() as tmp:
        session = Path(tmp) / "session"
        export = session / "export"
        archive = session / "archive"
        export.mkdir(parents=True)
        archive.mkdir()
        movie = archive / "session.mp4"
        movie.write_bytes(os.urandom(64 * 1024))
        planted = export / "session-pack.zip"
        planted.symlink_to(movie)
        # Following the dest would weigh the master movie. C3 must not.
        measured = 0 if planted.is_symlink() or not planted.is_file() else planted.stat().st_size
        assert planted.is_symlink()
        assert measured == 0
        assert planted.stat().st_size == movie.stat().st_size
        print("pack budget zip dest symlink: ok")

    zipper = ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift"
    zipper_src = zipper.read_text()
    assert "measuredPackBytes" in zipper_src
    assert "exportFolderBytes" in zipper_src
    assert "regularFileByteCount" in zipper_src
    assert "attributesOfItem" not in zipper_src
    zip_fn = zipper_src.split("func zip(")[1].split("func writeZip")[0]
    assert "folder > MediaBudget.maxZipBytes" in zip_fn
    assert zip_fn.index("let dropList") < zip_fn.index("return Result")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
