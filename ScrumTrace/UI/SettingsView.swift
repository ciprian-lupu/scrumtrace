import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: SessionController
    @State private var keyStatus = ""
    @State private var selectedTab = SettingsTab.speech
    @State private var licenseDraft = ""
    @State private var licenseLine = LicenseStore.status().settingsLine
    @State private var updateLine = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            speechTab.tabItem { Label("Speech", systemImage: "waveform") }.tag(SettingsTab.speech)
            logsTab.tabItem { Label("Logs", systemImage: "text.alignleft") }.tag(SettingsTab.logs)
            permissionsTab.tabItem { Label("This process", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            aiTab.tabItem { Label("AI", systemImage: "cpu") }.tag(SettingsTab.ai)
            generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .frame(minWidth: 560, minHeight: 520)
        .padding()
    }

    private var speechTab: some View {
        Form {
            Section("Speech") {
                Picker("WhisperKit model", selection: $settings.whisperModel) {
                    Text("Compressed turbo (632 MB, recommended)")
                        .tag(WhisperTranscriber.defaultStoredModel)
                    Text("Uncompressed large-v3_turbo (multi-GB)")
                        .tag("large-v3_turbo_uncompressed")
                    Text("base (faster, less accurate)").tag("base")
                    Text("tiny (debug)").tag("tiny")
                }
                TextField("WhisperKit model", text: $settings.whisperModel)
                Text("Pinned default is large-v3-v20240930_turbo_632MB (openai_whisper-large-v3-v20240930_turbo_632MB). First run downloads the CoreML model. The old large-v3_turbo name is remapped so a stored UserDefaults value recovers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Resolved folder", value: WhisperTranscriber.whisperKitModelName(settings.whisperModel))
                LabeledContent("Model ready", value: controller.transcriber.isReady ? "yes" : "not loaded yet")
                Button("Preload Whisper model") {
                    let model = settings.whisperModel
                    AgentLog.event("settings_action", ["action": "preload_whisper"])
                    Task.detached {
                        try? await controller.transcriber.prepare(model: model)
                    }
                }
            }
            Section("Capture") {
                Text("Shot  ⌥⌘S    Pin  ⌥⌘Space    Pause  ⌥⌘P")
                    .font(.system(.body, design: .monospaced))
                Text("HUD shows t_media. Pause discards screen frames, system audio, microphone PCM, metadata, Shot, and Hold-to-Talk. After Stop, WhisperKit transcribes the room mic and the movie’s system-audio track, then merges on t_media. Archive is 3840×2160 at 4 fps, 16 Mbps H.264 High (keyframe every second).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var logsTab: some View {
        AgentLogPane(controller: controller)
    }

    private var permissionsTab: some View {
        Form {
            Section("This process") {
                LabeledContent("Screen Recording", value: screenRecordingLabel)
                LabeledContent("Microphone", value: CapturePermissions.microphoneStatus())
                LabeledContent("App path", value: CapturePermissions.runningAppPath())
                Text(CapturePermissions.readiness().userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Ask for Screen Recording") {
                    AgentLog.event("settings_action", ["action": "ask_screen"])
                    Task.detached {
                        _ = CapturePermissions.requestScreenAccess()
                    }
                }
                Button("Open Screen Recording settings") {
                    AgentLog.event("settings_action", ["action": "screen_settings"])
                    SystemPrivacySettings.openScreenRecording()
                }
                Button("Open Microphone settings") {
                    AgentLog.event("settings_action", ["action": "mic_settings"])
                    SystemPrivacySettings.openMicrophone()
                }
                Button("Relaunch ScrumTrace") {
                    AgentLog.event("settings_action", ["action": "relaunch"])
                    CapturePermissions.relaunchRunningApp()
                }
                Button("Reveal agent log") {
                    AgentLog.event("settings_action", ["action": "reveal_log"])
                    AgentLog.reveal()
                }
                Button("Log permission probe") {
                    AgentLog.event("settings_action", ["action": "probe"])
                    CapturePermissions.probeAndLog()
                }
                Text("macOS lists every Debug copy as “ScrumTrace”. A toggle that is already on is often a different binary. After mac_gate01.sh, open ~/Applications/ScrumTrace.app only. Enabling Screen Recording never applies until this app quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Capture") {
                Button("Enable browser URL metadata (Accessibility)") {
                    AgentLog.event("settings_action", ["action": "ax_prompt"])
                    MetadataSampler.requestTrust(prompt: true)
                }
                Text("Optional. Accessibility is not required to Record. It only adds window titles and browser URLs. The looping system sheet on Record is Screen Recording, not this list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aiTab: some View {
        Form {
            Section("AI provider") {
                Picker("Backend", selection: $settings.provider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: settings.provider) { _, _ in
                    settings.applyProviderDefaults()
                }
                TextField("Endpoint", text: $settings.baseURL)
                TextField("Model", text: $settings.model)
                if settings.provider == .anthropic {
                    Text("Documented Messages models: claude-sonnet-5, claude-opus-5, claude-haiku-4-5. Retired claude-3-5 and claude-3-7 ids are refused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.model.isEmpty {
                        Text("Anthropic stays off until you set a currently documented Messages model.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if AIProviderConfiguration.isRetiredAnthropic(settings.model) {
                        Text("This model id is retired (2025–2026). Anthropic calls are refused.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                SecureField("API key (Keychain)", text: $settings.apiKeyDraft)
                Text("Keys stay on this Mac. ScrumTrace never proxies them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save key") {
                    do {
                        try settings.saveAPIKey()
                        let empty = settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        keyStatus = empty ? "Key removed from Keychain." : "Key saved on this Mac."
                        AgentLog.event("settings_action", [
                            "action": "save_key",
                            "empty": empty ? "1" : "0"
                        ])
                    } catch {
                        keyStatus = error.localizedDescription
                        AgentLog.event("settings_action", [
                            "action": "save_key_fail",
                            "error": AgentLog.sanitize(error.localizedDescription)
                        ])
                    }
                }
                if !keyStatus.isEmpty {
                    Text(keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Provider capabilities") {
                Text("MVP backend: OpenAI-compatible. Adapters send only what these flags allow. Google may upload a clip (inline MP4, size-capped) when Video is yes. OpenAI-compatible and Anthropic send stills and transcript only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Text", value: capabilities.acceptsText ? "yes" : "no")
                LabeledContent("Images", value: capabilities.acceptsImages ? "yes" : "no")
                LabeledContent("Video", value: ProviderWireMedia.willUploadClip(configuration: capabilities) ? "yes" : "no")
                if settings.provider == .google {
                    Toggle("Allow Gemini to upload clip video", isOn: $settings.allowGoogleClipUpload)
                    Text("Off by default. When on, Approve upload may send the 720p clip (video and audio). Local export only still sends nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Export") {
                Toggle("Include full transcript in session-pack.zip", isOn: $settings.includeFullTranscriptInZip)
                Text("Off by default. The local archive always keeps full_transcript.json. Agents receive export/ only. The first provider call still asks for upload consent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section("Product context") {
                TextField("App name", text: $settings.appName)
                TextField("Repo URL", text: $settings.repoURL)
                TextField("Tech stack", text: $settings.techStack)
            }
            Section("Retention") {
                Picker("Keep sessions", selection: $settings.retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Archive stays on this Mac until you delete it or this setting prunes completed sessions. export/ is not uploaded by ScrumTrace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Meeting notice") {
                Toggle("I will tell participants this Mac is recording", isOn: $settings.meetingNoticeAccepted)
                Text("ScrumTrace captures other people’s voices and shared screens. You are the controller. See docs/PRIVACY.md and docs/PARTICIPANT_NOTICE.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("License") {
                Text(licenseLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Signed license (label|expires.signature)", text: $licenseDraft)
                Button("Save license") {
                    licenseLine = LicenseStore.applyLicenseKey(licenseDraft).settingsLine
                    AgentLog.event("settings_action", ["action": "license_save"])
                }
                Text("A 14-day local trial is display-only. Record is never gated by this row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Text(updateLine.isEmpty ? "This build is \(UpdateChecker.currentVersion)." : updateLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check GitHub releases") {
                    AgentLog.event("settings_action", ["action": "updates"])
                    Task {
                        let result = await UpdateChecker.check()
                        updateLine = result.settingsLine
                    }
                }
                Button("Open releases page") {
                    NSWorkspace.shared.open(UpdateChecker.releasesURL)
                }
            }
            Button("Show first-run permissions") {
                AgentLog.event("settings_action", ["action": "onboarding"])
                OnboardingWindow.present()
            }
        }
        .formStyle(.grouped)
    }

    private var capabilities: AIProviderConfiguration {
        settings.providerConfiguration()
    }

    private var screenRecordingLabel: String {
        if CapturePermissions.screenGrantedAtLaunch {
            return "allowed for this process"
        }
        if CapturePermissions.currentScreenGranted() {
            return "on — relaunch required"
        }
        return "not this process"
    }
}

private enum SettingsTab: Hashable {
    case speech
    case logs
    case permissions
    case ai
    case general
}

struct AgentLogPane: View {
    @ObservedObject var controller: SessionController
    @State private var logText = ""
    @State private var status = ""
    @State private var crashNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent log").font(.headline)
                Spacer()
                Button("Refresh") {
                    AgentLog.event("settings_action", ["action": "log_refresh"])
                    reload()
                }
                Button("Copy") {
                    AgentLog.event("settings_action", ["action": "log_copy"])
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                    status = "Copied"
                }
                Button("Reveal in Finder") {
                    AgentLog.event("settings_action", ["action": "reveal_log"])
                    AgentLog.reveal()
                }
                Button("Export diagnostic bundle") {
                    AgentLog.event("settings_action", ["action": "diagnostics"])
                    do {
                        let url = try AgentLog.exportDiagnosticBundle()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        status = "Wrote \(url.lastPathComponent)"
                    } catch {
                        status = error.localizedDescription
                    }
                }
                Button("Reveal crash reports") {
                    AgentLog.event("settings_action", ["action": "crash_reports"])
                    CapturePermissions.revealCrashReports()
                    reloadCrashes()
                }
            }
            if crashNames.isEmpty {
                Text("No ScrumTrace-*.ips reports in ~/Library/Logs/DiagnosticReports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Crash reports: \(crashNames.joined(separator: ", "))")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let error = controller.lastError, !error.isEmpty {
                Text("Last error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Text(controller.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(logText.isEmpty ? "No agent log yet. Record or tap Log permission probe." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Button("Log permission probe") {
                    AgentLog.event("settings_action", ["action": "probe"])
                    CapturePermissions.probeAndLog()
                    reload()
                }
                Button("Reveal sessions folder") {
                    AgentLog.event("settings_action", ["action": "reveal_sessions"])
                    controller.vault.revealRootInFinder()
                }
                Button("Check for updates") {
                    AgentLog.event("settings_action", ["action": "updates"])
                    Task {
                        _ = await UpdateChecker.check()
                        NSWorkspace.shared.open(UpdateChecker.releasesURL)
                    }
                }
            }
        }
        .onAppear {
            reload()
            reloadCrashes()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            reload()
        }
    }

    private func reload() {
        logText = AgentLog.readTail(maxLines: 250)
    }

    private func reloadCrashes() {
        crashNames = CapturePermissions.crashReportURLs().map(\.lastPathComponent)
    }
}
