#!/usr/bin/env python3
"""EvidenceValidator + export-relative path contracts (Linux)."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def normalize(text: str) -> str:
    return " ".join(text.lower().split())


def quote_matches(quote: str, start: float, end: float, segments: list[tuple[float, float, str]]) -> bool:
    needle = normalize(quote)
    if not needle:
        return False
    return any(seg_end >= start and seg_start <= end and needle in normalize(text) for seg_start, seg_end, text in segments)


def test_quote_window() -> None:
    segments = [(10.0, 14.0, "this does nothing it should store the athlete")]
    assert quote_matches("this does nothing", 10.5, 13.0, segments)
    assert not quote_matches("invented passphrase", 10.5, 13.0, segments)
    validator = (ROOT / "ScrumTrace" / "AI" / "EvidenceValidator.swift").read_text()
    confirm = validator.split("static func canConfirm")[1].split("static func applyExportEvidence")[0]
    assert "quote outside slice window" in confirm
    assert "quote times are inverted" in confirm
    assert "quote not found in transcript window" in confirm
    assert "frame_references outside this slice window" in confirm
    assert "shots: [ShotRecord]" in confirm
    assert "framesOverlapSlice" in confirm
    overlap = validator.split("static func framesOverlapSlice")[1].split("static func applyExportEvidence")[0]
    assert "tMedia" in overlap
    assert "startMedia" in overlap
    assert "endMedia" in overlap
    assert "shotOwning" in overlap
    assert "allowed = slice.stills" not in overlap
    assert "!shots.isEmpty" in overlap
    assert 'contains("shots/")' in overlap
    assert "isSameSessionPath" in overlap
    assert "stillCandidates" in overlap
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    capture = controller.split("private func captureShot")[1].split("private func finishShot")[0]
    assert "writeContainedData(png, relative: rawPath" in capture
    assert "try? png.write(to: rawURL)" not in capture
    snap = capture.index("ScreenSnap.capture")
    assert capture.find("allowsNewCapture", snap) != -1
    sampler = (ROOT / "ScrumTrace" / "Capture" / "MetadataSampler.swift").read_text()
    sample_fn = sampler.split("func sample(")[1].split("private func readFrontmost")[0]
    assert sample_fn.count("isSuspended") >= 3
    finish = controller.split("private func finishShot")[1].split("private func privacyPause")[0]
    assert "Could not write the annotated Shot" in finish
    assert "try? png.write" not in finish
    assert "writeContainedData(png, relative: annotatedPath" in finish


def test_export_rel_in_swift() -> None:
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func toExportRoot" in models
    assert "func isUnderExport" in models
    zipper = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    assert "allowList" in zipper
    assert '"-@"' in zipper
    assert "containedExportMember" in zipper
    assert '"-y"' in zipper
    assert "removeEscapingExportLinks" in zipper
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func containedExportMember" in models
    assert "isSymbolicLink" in models
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func handoffPath" in models
    assert "func omittedHandoffPath" in models
    assert "func handoffFileIfPresent" in models
    assert "func writeExportText" in models
    assert "func isVisualEvidence" in models
    assert 'rest[0] == "shots"' in models or '"shots", "media", "media-work"' in models
    clip = (ROOT / "ScrumTrace" / "Slicing" / "ClipExporter.swift").read_text()
    assert "tightenExportClips" in clip
    assert "containedExportMember" in clip
    assert "existingSessionFile" in clip
    assert "copyContainedToTemporaryFile" in clip
    assert "extractStill(source: movieCopy" in clip
    assert "extractStill(source: source" not in clip
    assert "AVAssetExportPreset640x480" in clip
    assert "AVVideoProfileLevelH264MainAutoLevel" in clip
    assert "writeMainProfileClip" in clip
    shot = (ROOT / "ScrumTrace" / "UI" / "ShotNoteWindow.swift").read_text()
    assert "lockFocus" not in shot
    assert "bitmapImageRepForCachingDisplay" in shot
    jpeg = (ROOT / "ScrumTrace" / "AI" / "AIProviderProtocol.swift").read_text()
    assert "lockFocus" not in jpeg
    projector = (ROOT / "ScrumTrace" / "Export" / "ExportProjector.swift").read_text()
    assert "lockFocus" not in projector
    assert "omittedHandoffPath" in projector
    assert "JPEG transcode failed" in projector
    rewrite = projector.split("func rewriteEvidence")[1].split("func copyStill")[0]
    assert "ExportRel.handoffPath" in rewrite
    assert 'path.hasPrefix("export/")' not in rewrite
    transcode = projector.split("func transcodeJPEG")[1]
    assert "isReadableSessionFile" in transcode
    assert "readContainedData" in transcode
    assert "NSImage(contentsOf:" not in transcode


def test_frame_ref_basename_resolves() -> None:
    from tempfile import TemporaryDirectory

    def candidates(path: str) -> list[str]:
        name = Path(path).name
        stem = Path(name).stem
        return [
            path,
            f"archive/shots/{name}",
            f"archive/shots/{stem}.png",
            f"archive/shots/{stem}.annotated.png",
            f"export/shots/{stem}.jpg",
            f"export/shots/{stem}.annotated.jpg",
        ]

    def resolve(path: str, root: Path) -> str | None:
        seen: set[str] = set()
        for rel in candidates(path):
            if rel in seen:
                continue
            seen.add(rel)
            if (root / rel).is_file():
                return rel
        return None

    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        shot = root / "archive" / "shots" / "001.png"
        shot.parent.mkdir(parents=True)
        shot.write_bytes(b"png")
        assert resolve("001.png", root) == "archive/shots/001.png"
        assert resolve("missing.png", root) is None

    validator = (ROOT / "ScrumTrace" / "AI" / "EvidenceValidator.swift").read_text()
    first_match = validator.split("static func firstMatch")[1]
    assert "isSymbolicLink" in first_match
    assert "skipDescendants" in first_match
    assert "unfollowedRelative" in first_match
    assert "containsSymlinkComponent" in first_match
    assert "existingSessionFile" in first_match
    assert "sessionRoot: sessionURL" in first_match
    assert "replacingOccurrences(of: prefix" not in first_match
    resolve = validator.split("static func resolvePath")[1].split("static func existingPaths")[0]
    assert "containsSymlinkComponent" in resolve
    assert "isVisualEvidence" in resolve
    assert "func resolvePath" in validator
    assert "func applyExportEvidence" in validator
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    eval_slice = processor.split("private func evaluateSlice")[1].split("private func tasks(")[0]
    assert "existingSessionFile" in eval_slice
    assert "fileExists(atPath: url.path), seenImage" not in eval_slice
    assert "sessionURL: sessionURL" in eval_slice.split("SliceEvaluationRequest")[1]
    assert eval_slice.count("abortedForAuth") >= 3
    assert eval_slice.rfind("abortedForAuth") < eval_slice.find("provider.evaluate")
    assert "jpegPayload(url: url, sessionRoot: sessionURL)" in eval_slice
    assert "skippedNoSendableMedia" in eval_slice
    assert "AIProviderError.emptyResponse" not in eval_slice
    assert "reviewTasks(" in eval_slice
    assert "shots: linked" in eval_slice
    assert "for shot in linked" in eval_slice
    assert "let shot = linked.first" not in eval_slice
    eval_loop = processor.split("let toRun =")[1].split("manifest.slices = updatedSlices.sorted")[0]
    assert "withTaskGroup" not in eval_loop
    assert "try vault.write(manifest: &manifest)" in eval_loop
    assert "let remaining = toRun.filter" in eval_loop
    assert "rankedTasks" not in eval_loop
    assert "manifest.tasks = tasks" in eval_loop
    assert "uniquedTaskIds(tasks)" in eval_loop
    after_eval = processor.split("manifest.slices = updatedSlices.sorted")[1].split("try requireUsableSession")[0]
    assert "mergeUncoveredReview(manifest: &manifest, kept: tasks)" in after_eval
    assert "unknown task kind" in validator
    assert "decision is not keep" in validator
    assert "existingSessionFile" in validator
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func existingSessionFile" in models
    assert "func isContainedRegularFile" in models
    assert "isSymbolicLink" in models
    assert "resolvingSymlinksInPath" in models
    assert "archive/shots/" in validator
    assert "sourceSliceId.isEmpty" in validator
    apply_fn = validator.split("static func applyExportEvidence")[1].split("static func exportFileExists")[0]
    assert "quoteMatchesTranscript" in apply_fn
    assert "packMediaHandoff" in apply_fn
    assert "omitted: [OmittedAsset]" in apply_fn
    assert "omitted: omitted" in apply_fn
    assert "exportFileExists(path" not in apply_fn
    assert "transcript: FullTranscript?" in apply_fn
    assert "slices: [SliceRecord]" in apply_fn
    assert "shots: [ShotRecord]" in apply_fn
    assert "framesOverlapSlice" in apply_fn
    assert "shotOwning" in apply_fn
    assert "citesSliceWindow" in apply_fn
    assert "quote times are inverted" in apply_fn or "tMediaStart > quote.tMediaEnd" in apply_fn
    assert "quote outside slice window" in apply_fn or "slice.startMedia" in apply_fn
    assert "sourceSliceId.isEmpty" in apply_fn
    assert "keepConfidenceFloor" in apply_fn
    assert "normalize(copy.inferred)" in apply_fn
    assert "normalize(copy.observed)" in apply_fn
    assert "guard let transcript else" in apply_fn
    assert "!copy.quotes.isEmpty" in apply_fn
    assert "sliceById[copy.sourceSliceId] == nil" in apply_fn
    assert "func mergeCanonicalStatuses" in validator
    merge_fn = validator.split("static func mergeCanonicalStatuses")[1].split("static func exportFileExists")[0]
    assert "copy.status = projected.status" in merge_fn
    assert "copy.evidenceMedia" not in merge_fn
    slicer = (ROOT / "ScrumTrace" / "Slicing" / "MeetingSlicer.swift").read_text()
    assert "clipMaxDuration" in slicer
    plist = (ROOT / "ScrumTrace" / "App" / "Info.plist").read_text()
    assert "NSAccessibilityUsageDescription" in plist


def test_brief_shell_tokens_are_filled() -> None:
    shell = (ROOT / "ScrumTrace" / "Export" / "Resources" / "brief.shell.html").read_text()
    tokens = set(re.findall(r"\{\{[A-Z0-9_]+\}\}", shell))
    gen = (ROOT / "scripts" / "generate_mock_session.py").read_text()
    for token in tokens:
        assert token in gen, f"generate_mock_session.py missing {token}"
    html = (ROOT / "samples" / "mock-session" / "export" / "SESSION_BRIEF.html").read_text()
    assert "{{" not in html
    assert "1 pause" in html
    assert "1 pauses" not in html
    assert "fonts.googleapis" not in html
    assert "@import" not in html
    preview = (ROOT / "scripts" / "serve_preview.py").read_text()
    assert "def do_HEAD" in preview
    assert "def map_index" in preview
    head_fn = preview.split("def do_HEAD")[1].split("def log_message")[0]
    assert "map_index" in head_fn
    get_fn = preview.split("def do_GET")[1].split("def do_HEAD")[0]
    assert "map_index" in get_fn


def test_mock_clip_ffprobe() -> None:
    import subprocess

    clip = ROOT / "samples" / "mock-session" / "export" / "media" / "task-02" / "clip.mp4"
    assert clip.is_file()
    probe = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,width,height",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(clip),
        ],
        text=True,
    )
    data = json.loads(probe)
    stream = data["streams"][0]
    assert stream["codec_name"] == "h264"
    assert int(stream["width"]) == 1280
    assert int(stream["height"]) == 720
    duration = float(data["format"]["duration"])
    assert 15.0 <= duration <= 17.0, duration
    audio = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "json",
            str(clip),
        ],
        text=True,
    )
    audio_data = json.loads(audio)
    assert audio_data["streams"], "clip is missing an AAC track"
    assert audio_data["streams"][0]["codec_name"] == "aac"


def test_mock_agent_context_paths_exist() -> None:
    export = ROOT / "samples" / "mock-session" / "export"
    ctx = (export / "AGENT_CONTEXT.md").read_text()
    for rel in re.findall(r"!\[\]\(([^)]+)\)", ctx):
        assert (export / rel).is_file(), f"missing {rel}"
    for rel in re.findall(r"`(media/[^`]+)`", ctx):
        assert (export / rel).is_file(), f"missing {rel}"
    html = (export / "SESSION_BRIEF.html").read_text()
    assert 'class="conf">0.91</span>' in html
    assert 'class="conf">0.88</span>' in html
    for rel in re.findall(r'(?:src|href)="([^"]+)"', html):
        if rel.startswith("http://") or rel.startswith("https://") or rel.startswith("#"):
            continue
        assert (export / rel).is_file(), f"SESSION_BRIEF missing {rel}"
    manifest = json.loads((export / "session.manifest.json").read_text())
    for task in manifest.get("tasks", []):
        for rel in task.get("evidence_media", []):
            assert (export / rel).is_file(), f"manifest missing {rel}"
        if task.get("status") == "confirmed":
            assert float(task.get("confidence", 0)) >= 0.55, task.get("task_id")
    ctx = (export / "AGENT_CONTEXT.md").read_text()
    assert "confidence: 0.91" in ctx
    assert "confidence: 0.88" in ctx


def test_mock_pack_zip_is_export_only() -> None:
    import zipfile

    export = ROOT / "samples" / "mock-session" / "export"
    zip_path = export / "session-pack.zip"
    assert zip_path.is_file()
    assert zip_path.stat().st_size <= 35 * 1024 * 1024
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
    assert names, "session-pack.zip is empty"
    for name in names:
        assert "archive/" not in name, name
        assert not name.startswith("..")
        assert not name.startswith("media/task-01"), name
        assert (export / name).is_file(), name
    assert not (export / "media" / "task-01").exists()


def main() -> None:
    test_quote_window()
    test_export_rel_in_swift()
    test_frame_ref_basename_resolves()
    test_brief_shell_tokens_are_filled()
    test_mock_clip_ffprobe()
    test_mock_agent_context_paths_exist()
    test_mock_pack_zip_is_export_only()
    print("evidence contracts ok")


if __name__ == "__main__":
    main()
