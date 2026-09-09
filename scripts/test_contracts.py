#!/usr/bin/env python3
"""Contract tests that do not need a Mac."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_export_has_no_archive_and_no_tokens() -> None:
    export = ROOT / "samples" / "mock-session" / "export"
    assert export.exists()
    assert not (export / "archive").exists()
    assert not (export / "session.mp4").exists()
    assert not (export / "audio.wav").exists()
    assert not (export / "full_transcript.json").exists()
    forbidden = ["ATH-SAVE-DISABLED-0x9F", "STENCIL-4419"]
    for path in export.rglob("*"):
        if not path.is_file() or path.suffix.lower() in {".png", ".jpg", ".jpeg", ".mp4", ".zip"}:
            continue
        text = path.read_text(errors="ignore")
        for token in forbidden:
            assert token not in text, f"{token} leaked into {path}"
        assert "archive/" not in text, f"archive path leaked into {path}"


def test_agent_context_uses_export_relative_paths() -> None:
    ctx = (ROOT / "samples" / "mock-session" / "export" / "AGENT_CONTEXT.md").read_text()
    assert "![](shots/001.annotated.png)" in ctx
    assert "`media/task-02/clip.mp4`" in ctx
    assert "archive/" not in ctx
    assert "export/shots" not in ctx


def test_retired_anthropic_ids() -> None:
    settings = (ROOT / "ScrumTrace" / "App" / "AppSettings.swift").read_text()
    assert "claude-3-5" in settings
    assert "claude-3-7" in settings
    assert "claude-sonnet-5" in settings
    ui = (ROOT / "ScrumTrace" / "UI" / "SettingsView.swift").read_text()
    assert "claude-sonnet-5" in ui
    assert "claude-opus-5" in ui
    assert "claude-haiku-4-5" in ui
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "isRetiredAnthropic" in processor


def test_json_schema_uses_standard_types() -> None:
    schema = (ROOT / "ScrumTrace" / "AI" / "EvaluationJSONSchema.swift").read_text()
    assert '"type": "object"' in schema
    assert '"type": "string"' in schema
    assert '"type": "number"' in schema
    assert '"type": "array"' in schema
    assert '"OBJECT"' not in schema
    assert '"STRING"' not in schema
    assert "agent_instructions_draft" in schema
    client = (ROOT / "ScrumTrace" / "AI" / "OpenAICompatibleClient.swift").read_text()
    assert "json_schema" in client
    assert "EvaluationJSONSchema.openaiStructured" in client
    openai_schema = schema.split("static let openaiStructured")[1].split("private static let quote")[0]
    assert "$schema" not in openai_schema
    canonical = schema.split("static let canonical")[1].split("static let openaiStructured")[0]
    assert "$schema" in canonical


def test_html_escaper_order() -> None:
    renderer = (ROOT / "ScrumTrace" / "Export" / "SessionBriefRenderer.swift").read_text()
    amp = renderer.find('replacingOccurrences(of: "&"')
    lt = renderer.find('replacingOccurrences(of: "<"')
    assert 0 <= amp < lt, "escape & before <"


def test_zipper_never_deletes_archive() -> None:
    zipper = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    assert "ExportRel.isUnderExport" in zipper
    assert "allowList" in zipper
    assert '"-@"' in zipper
    assert "archive/session.mp4" not in zipper
    omit_md = zipper.split("func writeOmittedMarkdown")[1].split("private func uniquedOmitted")[0]
    assert "omittedHandoffPath" in omit_md


def test_clip_exporter_macos14() -> None:
    clip = (ROOT / "ScrumTrace" / "Slicing" / "ClipExporter.swift").read_text()
    assert "exportAsynchronously" in clip
    assert "export(to:" not in clip
    assert "AVAssetExportPreset1280x720" in clip
    assert "tightenExportClips" in clip
    assert "AVAssetExportPreset640x480" in clip
    assert "fileLengthLimit" in clip
    assert "clipVideoBitrate" in clip
    assert "AVVideoProfileLevelH264MainAutoLevel" in clip
    assert "writeMainProfileClip" in clip
    assert "loadTracks(withMediaType:" in clip
    assert "asset.tracks(withMediaType:" not in clip
    assert "ClipResumeOnce" in clip
    assert "ClipCopyState" in clip
    assert "Do not cancelWriting" in clip
    assert "shouldOptimizeForNetworkUse = true" in clip
    writer = clip.split("func writeMainProfileClip")[1].split("func exportPresetClip")[0]
    assert "AVVideoProfileLevelH264MainAutoLevel" in writer
    assert "clipWidth" in writer
    assert "clipHeight" in writer
    assert "clipAudioBitrate" in clip
    assert "image(at:" in clip
    assert "generateCGImagesAsynchronously" not in clip
    assert "copyCGImage" not in clip


def test_handoff_log_names_mp4_tools() -> None:
    log = (ROOT / "samples" / "mock-session" / "HANDOFF_LOG.md").read_text()
    assert "ffprobe" in log or "ffmpeg" in log
    assert "clip.mp4" in log
    assert "PNG" in log or "png" in log


def test_pause_gate_hold_to_talk() -> None:
    shot = (ROOT / "ScrumTrace" / "UI" / "ShotNoteWindow.swift").read_text()
    assert "abortTalk" in shot
    assert "scrumTraceCaptureGate" in shot
    hud = (ROOT / "ScrumTrace" / "UI" / "RecordingHUDWindow.swift").read_text()
    assert "allowsNewCapture" in hud


def test_retry_failed_slices_and_pins() -> None:
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "needsEvaluate" in processor
    assert "offlineFailed" in processor
    assert "API key missing" in processor
    vault = (ROOT / "ScrumTrace" / "Storage" / "SessionVault.swift").read_text()
    assert "loadPinTimes" in vault
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    assert "mergePins" in controller


def test_audio_split_and_brief_loader() -> None:
    recorder = (ROOT / "ScrumTrace" / "Capture" / "SessionRecorder.swift").read_text()
    assert "appendAudioToMovie" in recorder
    assert "case .microphone:" in recorder
    assert "writeWav(from: sampleBuffer)" in recorder
    assert "microphoneWav" in recorder
    assert "CaptureAudioLayout" in recorder
    assert "guard !paused, started else { return }" in recorder
    brief = (ROOT / "ScrumTrace" / "Export" / "SessionBriefRenderer.swift").read_text()
    assert "Export/Resources" in brief
    menu = (ROOT / "ScrumTrace" / "UI" / "MenuBarController.swift").read_text()
    assert "retryRecent" in menu
    assert "lastMenuSignature" in menu
    assert "isEnabled = !controller.isBusy" in menu
    assert "hudShouldShow" in menu
    assert "scrumTraceHUDSuppress" in menu
    hud = (ROOT / "ScrumTrace" / "UI" / "RecordingHUDWindow.swift").read_text()
    assert "controller.isBusy" in hud
    shot = (ROOT / "ScrumTrace" / "UI" / "ShotNoteWindow.swift").read_text()
    assert "abortTalk" in shot
    # ShotNoteView.body must close before startTalk (compile error if the brace is missing).
    body = shot.index("var body: some View")
    start_talk = shot.index("private func startTalk()")
    assert shot[body:start_talk].count("{") == shot[body:start_talk].count("}")


def test_dual_transcript_merge_wired() -> None:
    speech = (ROOT / "ScrumTrace" / "Speech" / "WhisperTranscriber.swift").read_text()
    assert "func merge" in speech
    assert "func transcribeMovieAudio" in speech
    assert "AVAssetExportPresetAppleM4A" in speech
    assert "wordTimestamps: true" in speech
    assert "whisperKitModelName" in speech
    assert "openai_whisper-large-v3-turbo" in speech
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "shouldTranscribeMovie" in processor
    assert "transcribeMovieAudio" in processor
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "capture-layout.json" in models
    assert "microphone_wav" in models
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    assert "guard !isBusy, !isRecording" in controller
    assert 'phase = .transcribing' in controller
    vault = (ROOT / "ScrumTrace" / "Storage" / "SessionVault.swift").read_text()
    assert "func windowContext" in vault


def test_pipeline_timing_stays_in_archive() -> None:
    zipper = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "pipeline-timing.json" in models
    assert "whisper_wall_seconds" in models
    assert "PipelineTiming" in processor
    assert "pipeline-timing.json" not in zipper
    allow = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    assert "AGENT_CONTEXT.md" in allow
    assert "try? runZip" in zipper
    recorder = (ROOT / "ScrumTrace" / "Capture" / "SessionRecorder.swift").read_text()
    assert "writerQueue.sync" in recorder
    pause_fn = recorder.split("func setPaused")[1].split("func stop")[0]
    assert "writerQueue.sync" in pause_fn
    assert "writerQueue.async" not in pause_fn
    speech = (ROOT / "ScrumTrace" / "Speech" / "WhisperTranscriber.swift").read_text()
    assert "temporaryDirectory" in speech
    assert "private var ready = false" in speech
    recorder = (ROOT / "ScrumTrace" / "Capture" / "SessionRecorder.swift").read_text()
    assert "AVCaptureDevice.requestAccess(for: .audio)" in recorder
    sampler = (ROOT / "ScrumTrace" / "Capture" / "MetadataSampler.swift").read_text()
    assert "ResumeOnce" in sampler
    assert "requestTrust" in sampler
    assert "private var suspended = false" in sampler
    icons = ROOT / "ScrumTrace" / "Assets.xcassets" / "AppIcon.appiconset"
    for name in ("icon_16.png", "icon_32.png", "icon_64.png", "icon_128.png", "icon_256.png", "icon_512.png", "icon_1024.png"):
        assert (icons / name).is_file(), name
    app = (ROOT / "ScrumTrace" / "App" / "AppDelegate.swift").read_text()
    assert "MetadataSampler.requestTrust" in app
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    assert "transcriber.prepare" in controller
    hud = (ROOT / "ScrumTrace" / "UI" / "RecordingHUDWindow.swift").read_text()
    assert "wallElapsed" in hud


def test_pause_privacy_and_metadata_gate() -> None:
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    assert "pausedByPrivacy" in controller
    assert "isCurrentlyTripped" in controller
    assert "sampleMetadataTick" in controller
    assert "Re-check after the 200 ms" in controller
    assert "haltCaptureForTermination" in controller
    halt = controller.split("func haltCaptureForTermination")[1].split("private func startRecordingAsync")[0]
    assert "stopRecording()" not in halt
    assert "Task.detached" in halt
    assert "persistInterruptedCapture" in halt
    app = (ROOT / "ScrumTrace" / "App" / "AppDelegate.swift").read_text()
    assert "haltCaptureForTermination" in app
    assert "height: 780" in app
    menu = (ROOT / "ScrumTrace" / "UI" / "MenuBarController.swift").read_text()
    quit_fn = menu.split("func quit()")[1].split("func openRecent")[0]
    assert "stopRecording()" not in quit_fn
    assert "terminate" in quit_fn
    log_fn = controller.split("private func log(")[1].split("private func flashStatus")[0]
    assert "case .pin, .url, .window" in log_fn
    agent = (ROOT / "ScrumTrace" / "Export" / "AgentContextRenderer.swift").read_text()
    assert "this export folder" in agent
    assert "Never open the private capture folder" in agent
    assert "handoffPath" in agent
    assert "Still auto-paused for a password manager" in controller
    assert "Stills and transcript excerpts" in controller
    assert "includesClipAudio: approved && uploadsClip" in controller
    assert "willUploadClip" in controller
    assert "Clip video and the master movie are not uploaded" in controller
    assert "NSApp.activate" in controller.split("func requestUploadConsent")[1].split("private func captureShot")[0]
    capture = controller.split("private func captureShot")[1].split("private func finishShot")[0]
    assert "shots.append(record)" in capture
    finish = controller.split("private func finishShot")[1].split("private func privacyPause")[0]
    assert "firstIndex(where: { $0.id == stored.id })" in finish
    clock = (ROOT / "ScrumTrace" / "Capture" / "ClockSynchronizer.swift").read_text()
    assert "CMSyncConvertTime" in clock
    privacy = (ROOT / "ScrumTrace" / "Capture" / "PrivacyGuard.swift").read_text()
    hud = (ROOT / "ScrumTrace" / "UI" / "RecordingHUDWindow.swift").read_text()
    assert "canResumeFromPause" in controller
    assert "canResumeFromPause" in hud
    assert "canResumeFromPause" in menu
    assert "org.keepassxc.KeePassXC" in privacy
    assert 'contains("proton")' in privacy
    assert 'contains("strongbox")' in privacy
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    decision = models.split("enum CandidateDecision")[1].split("enum ShotSource")[0]
    assert "?? .needsReview" in decision
    status = models.split("enum TaskStatus")[1].split("enum CandidateDecision")[0]
    assert "?? .needsReview" in status
    kind = models.split("enum TaskKind")[1].split("enum TaskStatus")[0]
    assert "?? .unknown" in kind
    extractor = (ROOT / "ScrumTrace" / "AI" / "AIProviderProtocol.swift").read_text()
    assert "func decodeLossy" in extractor
    validator = (ROOT / "ScrumTrace" / "AI" / "EvidenceValidator.swift").read_text()
    assert "unknown task kind" in validator
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "kind: candidate.kind == .unknown ? .bug" not in processor
    assert "phase == .paused" in controller.split("private func privacyPause")[1].split("private func privacyResume")[0]


def test_phase45_clip_consent_and_budget() -> None:
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "clipURL" in processor
    assert "forceReview" in processor
    assert "withExistingMedia" in processor
    assert "One bad" in processor or "must not abort the session" in processor
    projector = (ROOT / "ScrumTrace" / "Export" / "ExportProjector.swift").read_text()
    assert "MediaBudget.maxStills" in projector
    assert "Over extra-still budget" in projector
    zipper = (ROOT / "ScrumTrace" / "Export" / "SessionPackZipper.swift").read_text()
    assert "!reservedClipSet.contains($0)" in zipper
    keyword_block = zipper.split("Keyword-only clips")[1].split("let evidenceShotsNewestFirst")[0]
    assert "reservedClipSet" in keyword_block
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "for pass in 0..<3" in processor
    prompts = (ROOT / "ScrumTrace" / "AI" / "PromptTemplates.swift").read_text()
    assert "wrapUntrusted(\"Window metadata" in prompts
    settings = (ROOT / "ScrumTrace" / "UI" / "SettingsView.swift").read_text()
    assert "capabilities.acceptsText" in settings
    assert "willUploadClip" in settings
    assert "Save key" in settings
    assert "Key saved on this Mac" in settings
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    assert "func needsReprompt" in models
    assert "func handoffPath" in models
    assert "func omittedHandoffPath" in models
    assert "enum TaskRanking" in models
    assert "selectForPack" in processor
    local = processor.split("func localReviewTasks")[1].split("func excerptMap")[0]
    assert "selectForPack" in local
    assert "Inspect the linked evidence only" in processor
    assert "remain in archive/" not in processor
    assert "applyExportEvidence" in processor
    assert "manifest.tasks = projection.manifest.tasks" in processor
    assert "includesClipAudio != acceptsVideo" in models
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    assert "needsReprompt" in controller
    assert "!local.uploadConsent.approved || destinationChanged" not in controller
    assert "askedBefore" in controller
    assert "analysisStatus = .pending" in controller
    openai = (ROOT / "ScrumTrace" / "AI" / "OpenAICompatibleClient.swift").read_text()
    anthropic = (ROOT / "ScrumTrace" / "AI" / "AnthropicClient.swift").read_text()
    google = (ROOT / "ScrumTrace" / "AI" / "GoogleClient.swift").read_text()
    protocol_src = (ROOT / "ScrumTrace" / "AI" / "AIProviderProtocol.swift").read_text()
    assert "mp4BodyURL" in openai
    assert "mp4BodyURL" in anthropic
    assert "mp4BodyURL" in google
    assert "func mp4BodyURL" in protocol_src
    assert "willUploadClip" in protocol_src
    assert "adaptersUploadVideo" in protocol_src
    assert 'mediaSent.append("video")' not in processor
    assert "Data(contentsOf: request.clipURL" not in openai
    assert "Data(contentsOf: request.clipURL" not in anthropic
    assert "Data(contentsOf: request.clipURL" not in google
    clip = (ROOT / "ScrumTrace" / "Slicing" / "ClipExporter.swift").read_text()
    assert "updated.stills = [stillRelative]" not in clip
    slicer = (ROOT / "ScrumTrace" / "Slicing" / "MeetingSlicer.swift").read_text()
    assert 'copy.stills = ["\\(folder)/shot-1.jpg"]' not in slicer
    assert "unionStills" in slicer
    assert "if last.stills.isEmpty" not in slicer
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "shotsLinked" in processor
    shot = (ROOT / "ScrumTrace" / "UI" / "ShotNoteWindow.swift").read_text()
    assert "let hadText = !note.isEmpty" in shot
    processor = (ROOT / "ScrumTrace" / "Processing" / "SessionProcessor.swift").read_text()
    assert "transcriber.isReady || !hadAudio" in processor
    assert "async -> FullTranscript" in processor
    assert "justFinishedTranscribing" in processor
    retry_block = processor.split("if justFinishedTranscribing")[1].split("if !manifest.hasCompleted(.slicing)")[0]
    assert "completedStages.removeAll" in retry_block
    assert "tasks = []" in retry_block
    assert "vault.write" in retry_block
    assert "zip failed" in processor
    assert "writeExportDocuments" in processor.split("Docs first")[1].split("var zipResult")[0]
    zipper_over = zipper.split("if size > MediaBudget.maxZipBytes")[1].split("func writeZip")[0]
    assert "throw" not in zipper_over
    assert "Pack still" in zipper_over
    brief = (ROOT / "ScrumTrace" / "Export" / "SessionBriefRenderer.swift").read_text()
    fallback = brief.split("let fallbackShell")[1].split("let fallbackCSS")[0]
    assert "{{TIMELINE_HTML}}" in fallback
    assert "{{SHOTS_HTML}}" in fallback
    assert "data-lightbox" in brief.split("let fallbackJS")[1]
    js = (ROOT / "ScrumTrace" / "Export" / "Resources" / "brief.js").read_text()
    assert 'box.setAttribute("aria-label", img.alt)' in js
    assert "box.focus()" in js
    assert "event.target === box" in js
    assert "lastOpener" in js
    fallback_js = brief.split("let fallbackJS")[1]
    assert "event.target === box" in fallback_js
    assert "lastOpener" in fallback_js
    assert 'box.addEventListener("click", close)' not in js
    assert 'box.addEventListener("click", close)' not in fallback_js
    prompts = (ROOT / "ScrumTrace" / "AI" / "PromptTemplates.swift").read_text()
    assert 'wrapUntrusted("Human shot note' in prompts
    pbx = (ROOT / "ScrumTrace.xcodeproj" / "project.pbxproj").read_text()
    assert "ENABLE_TESTABILITY = YES" in pbx
    assert "!configuration.acceptsText" in processor
    controller = (ROOT / "ScrumTrace" / "Processing" / "SessionController.swift").read_text()
    assert "suppressHUD" in controller
    recorder = (ROOT / "ScrumTrace" / "Capture" / "SessionRecorder.swift").read_text()
    assert "withCheckedContinuation" in recorder
    assert "100_000_000" in controller
    assert "scrumtrace-note-" in shot
    brief_src = (ROOT / "ScrumTrace" / "Export" / "SessionBriefRenderer.swift").read_text()
    assert "t_media" in brief_src.split("task.quotes.map")[1].split("return \"\"\"")[0]
    models = (ROOT / "ScrumTrace" / "Storage" / "SessionModels.swift").read_text()
    task_decode = models.split("struct TaskRecord")[1].split("struct CandidateRecord")[0]
    assert "decodeIfPresent([QuoteRecord]" in task_decode
    recorder = (ROOT / "ScrumTrace" / "Capture" / "SessionRecorder.swift").read_text()
    start_fn = recorder.split("func start()")[1].split("func setPaused")[0]
    assert "self.started = true" in start_fn
    assert "startCapture" in start_fn
    assert start_fn.index("self.started = true") < start_fn.index("startCapture")
    assert "try await writerQueue.sync" not in recorder
    assert "evenCaptureSize" in start_fn
    assert "prepareWriters(width:" in start_fn
    assert "config.width = size.width" in start_fn
    assert "config.height = size.height" in start_fn
    assert "AVVideoWidthKey: w" in recorder
    assert "AVVideoHeightKey: h" in recorder
    stop_fn = controller.split("private func stopRecordingAsync")[1].split("private func runProcessor")[0]
    assert "setPaused(false)" not in stop_fn
    assert "freezeWriters" in stop_fn
    assert "markRecordingStopped" in recorder
    assert "func freezeWriters" in recorder
    clock = (ROOT / "ScrumTrace" / "Capture" / "ClockSynchronizer.swift").read_text()
    assert "stoppedWall" in clock
    assert "func markRecordingStopped" in clock
    shots_fn = brief_src.split("private func shots")[1].split("private func omittedHTML")[0]
    assert "handoffPath" in shots_fn
    google = (ROOT / "ScrumTrace" / "AI" / "GoogleClient.swift").read_text()
    assert "var candidates: [Candidate]?" in google
    assert "var content: Content?" in google
    assert "var parts: [Part]?" in google
    recorder_engine = recorder.split("func writeEngineBuffer")[1].split("func requestPermission")[0]
    assert "buffer.frameLength" in recorder_engine
    agent = (ROOT / "ScrumTrace" / "Export" / "AgentContextRenderer.swift").read_text()
    assert "omittedHandoffPath" in agent
    brief_omit = brief_src.split("private func omittedHTML")[1].split("private static func clock")[0]
    assert "omittedHandoffPath" in brief_omit
    assert "isAuthFailure" in protocol_src
    assert "markEvalAuthFailed" in processor
    assert "Skipped remaining slices after provider authentication failed." in processor
    assert "willUploadClip(configuration: configuration)" in processor
    google = (ROOT / "ScrumTrace" / "AI" / "GoogleClient.swift").read_text()
    assert "x-goog-api-key" in google
    assert "?key=" not in google
    assert "AgentInstructionTemplate.render(kind: .unknown, product: product)" in processor


def main() -> None:
    test_export_has_no_archive_and_no_tokens()
    test_agent_context_uses_export_relative_paths()
    test_retired_anthropic_ids()
    test_json_schema_uses_standard_types()
    test_html_escaper_order()
    test_zipper_never_deletes_archive()
    test_clip_exporter_macos14()
    test_handoff_log_names_mp4_tools()
    test_pause_gate_hold_to_talk()
    test_retry_failed_slices_and_pins()
    test_audio_split_and_brief_loader()
    test_dual_transcript_merge_wired()
    test_pipeline_timing_stays_in_archive()
    test_pause_privacy_and_metadata_gate()
    test_phase45_clip_consent_and_budget()
    print("contract tests ok")


if __name__ == "__main__":
    main()
