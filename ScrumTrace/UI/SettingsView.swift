import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: SessionController
    @State private var keyStatus = ""
    @State private var testingConnection = false
    @State private var connectionLine = ""
    @ObservedObject var navigation: SettingsNavigation
    @State private var licenseDraft = ""
    @State private var licenseLine = LicenseStore.status().settingsLine
    @State private var updateLine = ""
    @State private var checkingUpdates = false
    @State private var preloadingWhisper = false
    @State private var preloadLine = ""
    @State private var removingKey = false
    @State private var showAdvancedSpeech = false
    @State private var showSpeakerReview = false
    /// True once a manifest in the vault decodes, so the speaker review has a session to list. The answer is kept on
    /// `navigation`, which outlives this view, so it stays while the next check runs and a test can wait for it.
    private var hasReviewableSession: Bool { navigation.hasReviewableSession == true }
    @State private var preloadingSpeakers = false
    @State private var speakerModelLine = ""

    var body: some View {
        VStack(spacing: 8) {
        TabView(selection: $navigation.selectedTab) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in speechTab }
                .tabItem { Label("Speech", systemImage: "waveform") }.tag(SettingsTab.speech)
            captureTab.tabItem { Label("Capture", systemImage: "record.circle") }.tag(SettingsTab.capture)
            logsTab.tabItem { Label("Logs", systemImage: "text.alignleft") }.tag(SettingsTab.logs)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                permissionsTab
            }
            .tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            aiTab.tabItem { Label("AI", systemImage: "cpu") }.tag(SettingsTab.ai)
            generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        Text(controller.canChangeCaptureSettings
             ? "Preferences save automatically. Contexts, keys and licenses use their Save button."
             : "Recording or analysis is active. Configuration can be changed when it finishes.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 620, minHeight: 560)
        .padding()
        // Whether Review and name speakers… has a session to list. The vault is read off the main actor when Settings
        // appears and when recording or analysis starts or ends, never in the Speech tab, which is redrawn every second.
        .task(id: controller.canChangeCaptureSettings ? (controller.lastSessionId ?? "") : nil) {
            let vault = controller.vault
            let reviewable = await Task.detached(priority: .userInitiated) { SpeakerReviewLoader.hasReviewableSession(in: vault) }.value
            guard !Task.isCancelled else { return }
            navigation.hasReviewableSession = reviewable
        }
        .sheet(isPresented: $showSpeakerReview) {
            SpeakerReviewView(controller: controller)
        }
        .onChange(of: settings.whisperModel) { _, _ in preloadLine = "" }
        .onChange(of: settings.provider) { _, _ in
            keyStatus = ""
            connectionLine = ""
        }
        .onChange(of: settings.baseURL) { _, _ in
            keyStatus = ""
            connectionLine = ""
        }
        .onChange(of: settings.model) { _, _ in
            keyStatus = ""
            connectionLine = ""
        }
        .onChange(of: settings.connectionLibrary.selectedID) { _, _ in
            keyStatus = ""
            connectionLine = ""
        }
        .alert("Remove saved key?", isPresented: $removingKey) {
            Button("Remove key", role: .destructive) {
                do {
                    try settings.removeSavedAPIKey()
                    keyStatus = "Key removed. Recording and local export are still available."
                } catch { keyStatus = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the key for the selected service from this Mac. You will need to enter it again to use AI analysis.")
        }
    }

    private var speechTab: some View {
        Form {
            Section("Local transcription") {
                Picker("Meeting language", selection: $settings.speechLanguage) {
                    ForEach(SpeechLanguage.allCases) { language in Text(language.title).tag(language) }
                }
                .disabled(!controller.canChangeCaptureSettings)
                Text("Choose Romanian for meetings mainly in Romanian. Automatic detects the spoken language. This applies to the next recording or analysis and to voice notes; existing transcripts are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Speech model", selection: $settings.whisperModel) {
                    Text("Compressed turbo (632 MB, recommended)").tag(WhisperTranscriber.defaultStoredModel)
                    Text("Uncompressed turbo (multi-GB)").tag("large-v3_turbo_uncompressed")
                    Text("Base (faster, less accurate)").tag("base")
                    Text("Tiny (quick checks)").tag("tiny")
                    if ![WhisperTranscriber.defaultStoredModel, "large-v3_turbo_uncompressed", "base", "tiny"].contains(settings.whisperModel) {
                        Text("Custom model").tag(settings.whisperModel)
                    }
                }
                .disabled(speechControlsDisabled)
                LabeledContent("Selected model", value: controller.transcriber.isReady(for: settings.whisperModel)
                               ? "Ready" : controller.transcriber.isPreparing ? "Loading…" : "Not loaded")
                if let loaded = controller.transcriber.loadedModelName,
                   !controller.transcriber.isReady(for: settings.whisperModel) {
                    Text("Previously loaded: \(loaded). Load the selected model to switch.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(preloadingWhisper || controller.transcriber.isPreparing ? "Loading Whisper model…" : "Preload Whisper model") {
                    guard !speechControlsDisabled else { return }
                    let model = settings.whisperModel
                    preloadingWhisper = true
                    preloadLine = "Loading the local model. The first download can take several minutes."
                    AgentLog.event("settings_action", ["action": "preload_whisper"])
                    Task {
                        defer { preloadingWhisper = false }
                        do {
                            try await controller.transcriber.prepare(model: model)
                            preloadLine = "The selected model is ready. No relaunch is needed."
                        } catch { preloadLine = "Could not load Whisper: \(error.localizedDescription)" }
                    }
                }
                .disabled(speechControlsDisabled || settings.whisperModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !preloadLine.isEmpty { Text(preloadLine).font(.caption).textSelection(.enabled) }
                Text("Speech is processed on this Mac. Preload before a meeting to finish the model download and preparation in advance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TranscriptionConnectionViews(settings: settings, controller: controller)
            Section("Speakers in the room and in calls") {
                Toggle("Identify speakers locally after recording", isOn: $settings.identifySpeakers)
                    .disabled(!controller.canChangeCaptureSettings)
                Text("Separate anonymous speakers for the room microphone and call audio. Names are entered manually for each session. Estimates and overlapping voices need review; use headphones to reduce call audio leaking into the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(preloadingSpeakers ? "Loading speaker models…" : "Preload speaker models") {
                        preloadingSpeakers = true
                        speakerModelLine = "Downloading and preparing local speaker models…"
                        Task {
                            defer { preloadingSpeakers = false }
                            do {
                                try await SpeakerDiarizer.shared.prepare()
                                speakerModelLine = "Speaker models are ready on this Mac."
                            } catch { speakerModelLine = "Could not load speaker models. Check the connection and try again (macOS 15+ required)." }
                        }
                    }
                    .disabled(preloadingSpeakers || !controller.canChangeCaptureSettings)
                    Button("Review and name speakers…") { showSpeakerReview = true }
                        .disabled(!controller.canChangeCaptureSettings || !hasReviewableSession)
                        .help(reviewSpeakersHelp)
                }
                if !speakerModelLine.isEmpty { Text(speakerModelLine).font(.caption).textSelection(.enabled) }
                Text("Requires macOS 15+. First use downloads FluidAudio's public models. Meeting audio stays on this Mac; no voice profile is saved for future meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced model settings", isExpanded: $showAdvancedSpeech) {
                    TextField("WhisperKit model ID", text: $settings.whisperModel)
                        .disabled(speechControlsDisabled)
                    Text("Resolved model: \(WhisperTranscriber.whisperKitModelName(settings.whisperModel))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Reveal downloaded models") {
                        NSWorkspace.shared.open(WhisperTranscriber.modelDownloadBase)
                    }
                    .disabled(!FileManager.default.fileExists(atPath: WhisperTranscriber.modelDownloadBase.path))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var speechControlsDisabled: Bool {
        preloadingWhisper || controller.transcriber.isPreparing || !controller.canChangeCaptureSettings
    }

    private var reviewSpeakersHelp: String {
        if !controller.canChangeCaptureSettings { return RecordingsModel.busyReason }
        if !hasReviewableSession { return "No saved recording to review yet." }
        return "Name the speakers of a saved recording and correct passages."
    }

    private var captureTab: some View {
        Form {
            Section("Sources") {
                Toggle("Show pointer in the archive", isOn: $settings.showCursor)
                    .disabled(!controller.canChangeCaptureSettings)
                Toggle("Record microphone", isOn: $settings.includeMicrophone)
                    .disabled(!controller.canChangeCaptureSettings)
                Text("System audio is always captured. These choices apply to the next recording. Turn the microphone off to exclude the room audio. The pointer toggle only affects the archive movie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Capture area") {
                LabeledContent("Current", value: settings.captureSummary)
                Button("Select area on screen…") {
                    AgentLog.event("settings_action", ["action": "select_area"])
                    guard controller.canChangeCaptureSettings else { return }
                    CaptureAreaPicker.present(current: settings.captureArea) { area in
                        guard controller.canChangeCaptureSettings else { return }
                        settings.captureArea = area
                        settings.recordSingleWindow = false
                    }
                }
                .disabled(!controller.canChangeCaptureSettings)
                Button("Use entire display") {
                    AgentLog.event("settings_action", ["action": "area_full"])
                    settings.captureArea = .entireDisplay
                    settings.recordSingleWindow = false
                }
                .disabled(!controller.canChangeCaptureSettings
                    || (settings.captureArea.isEntireDisplay && !settings.recordSingleWindow))
                Toggle("Record a single window", isOn: $settings.recordSingleWindow)
                    .disabled(!controller.canChangeCaptureSettings)
                Text("Default is the whole display. Start recording opens a macOS-style overlay: drag a rectangle, move or resize it, then Record or Return on that display. A saved region here is the starting box. With Record a single window on, Start lists the open windows instead: only the one you pick is recorded, Shots show only that window, and window titles and URLs are noted only while its app is in front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Hotkeys") {
                LabeledContent("Shot", value: HotkeyManager.shotLabel)
                LabeledContent("Pin", value: HotkeyManager.pinLabel)
                LabeledContent("Pause", value: HotkeyManager.pauseLabel)
                Text("HUD shows t_media. Pause discards screen frames, system audio, microphone PCM, metadata, Shot, and Hold-to-Talk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Archive movie") {
                LabeledContent("Resolution", value: "\(MediaBudget.archiveMaxWidth)×\(MediaBudget.archiveMaxHeight)")
                LabeledContent("Frame rate", value: "\(MediaBudget.archiveExpectedFrameRate) fps")
                LabeledContent("Video bitrate", value: "\(MediaBudget.archiveVideoBitrate / 1_000_000) Mbps H.264 High")
                LabeledContent("Peak bitrate", value: "\(MediaBudget.archiveVideoMaxBitrate / 1_000_000) Mbps cap")
                LabeledContent("Keyframe", value: "every \(MediaBudget.archiveKeyFrameInterval) frames")
                LabeledContent("Export clips", value: "\(MediaBudget.clipWidth)×\(MediaBudget.clipHeight) @ \(MediaBudget.clipVideoBitrate / 1000) kbps")
                Text("Archive is private (session.mp4). Export clips are the 720p handoff. These values are the shipped capture budget, not a live encoder slider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recordings") {
                LabeledContent("Folder", value: CapturePermissions.scrubHome(controller.vault.rootURL.path))
                Button("Reveal recordings folder") {
                    AgentLog.event("settings_action", ["action": "reveal_sessions"])
                    controller.vault.revealRootInFinder()
                }
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
                // The words Overview's readiness card uses, lower case like the Screen Recording value above.
                LabeledContent("Microphone", value: OverviewReadiness.microphoneStatus(CapturePermissions.microphoneStatus()).lowercased())
                LabeledContent("App path", value: CapturePermissions.runningAppPath())
                Text(CapturePermissions.readiness(requireMicrophone: settings.includeMicrophone).userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Ask for Screen Recording") {
                    AgentLog.event("settings_action", ["action": "ask_screen"])
                    Task.detached {
                        _ = CapturePermissions.requestScreenAccess()
                    }
                }
                .disabled(CapturePermissions.currentScreenGranted() || !controller.canChangeCaptureSettings)
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
                    controller.relaunchForPermissions()
                }
                .disabled(!controller.canChangeCaptureSettings)
                Button("Reveal agent log") {
                    AgentLog.event("settings_action", ["action": "reveal_log"])
                    AgentLog.reveal()
                }
                Button("Log permission probe") {
                    AgentLog.event("settings_action", ["action": "probe"])
                    CapturePermissions.probeAndLog()
                }
                Text("If you change Screen Recording access in System Settings, relaunch this copy of ScrumTrace before recording. The app path above identifies the copy currently running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Accessibility") {
                LabeledContent(
                    "Window titles / URLs",
                    value: OverviewReadiness.accessibilityStatus(trusted: MetadataSampler.requestTrust(prompt: false)).lowercased()
                )
                Button("Enable browser URL metadata (Accessibility)") {
                    AgentLog.event("settings_action", ["action": "ax_prompt"])
                    MetadataSampler.requestTrust(prompt: true)
                }
                Text("Optional. Accessibility adds window titles and scrubbed browser URLs to help explain the recording. Screen and microphone recording work without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aiTab: some View {
        Form {
            Section("Local coding agents") {
                Picker("Open export in Codex", selection: $settings.codexHandoffDestination) {
                    ForEach(CodexHandoffDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .accessibilityIdentifier("settings.codexDestination")
                Text(settings.codexHandoffDestination == .app
                     ? "Choose a project name on first open. Export and archive analyses reuse that recording's project, with separate task prompts. You send the prompt yourself."
                     : "Starts Codex CLI in Terminal using your existing login. Install the codex command and allow ScrumTrace to control Terminal when macOS asks.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Open archive in Codex always uses the desktop app and adds the original source to the shared project. Claude and the Terminal option use only export/. These handoffs do not use the API key below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AIConnectionsSettingsView(settings: settings, controller: controller)
            Section("Selected service") {
                Picker("Backend", selection: $settings.provider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                TextField("Endpoint", text: $settings.baseURL)
                TextField("Model", text: $settings.model)
                Text("These fields belong to the selected service. Enter an API root; OpenAI-compatible and Anthropic endpoints may end in /v1. Hive: https://api.thehive.ai and a Playground / Service V3 secret key (not a V2 project token).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Validate configuration") {
                        settings.refreshKeyStatus()
                        keyStatus = settings.configurationSummary
                    }
                    Button("Use provider defaults") { settings.applyProviderDefaults() }
                }
                if let issue = settings.configurationIssue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
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
                LabeledContent("Saved key", value: settings.hasSavedAPIKey ? "Stored for this service" : "Not saved for this service")
                SecureField(settings.hasSavedAPIKey ? "Replacement API key" : "API key (Keychain)", text: $settings.apiKeyDraft)
                Text("Saved in this Mac’s Keychain for the selected service. A saved key is never displayed here. Switching services uses that service’s key only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save key") {
                    do {
                        try settings.saveAPIKey()
                        keyStatus = "Key saved on this Mac. Online validity has not been checked."
                        AgentLog.event("settings_action", ["action": "save_key"])
                    } catch {
                        keyStatus = error.localizedDescription
                        AgentLog.event("settings_action", [
                            "action": "save_key_fail",
                            "error": AgentLog.sanitize(error.localizedDescription)
                        ])
                    }
                }
                .disabled(
                    settings.connectionLibrary.selected == nil
                        || settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || settings.configurationIssue != nil
                )
                if settings.hasSavedAPIKey {
                    Button("Remove saved key…", role: .destructive) { removingKey = true }
                }
                if settings.connectionLibrary.selected == nil {
                    Text("Select or add a service to save a key. You can still record and produce a local export.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !settings.hasSavedAPIKey {
                    Text("AI is not configured for this service. You can still record and produce a local export.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !keyStatus.isEmpty {
                    Text(keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(settings.connectionLibrary.selected == nil)
            Section("Test connection") {
                Text("Sends a one-word ping with the selected service’s endpoint, model, and key. Nothing from a meeting is uploaded. A typed key that is not saved yet is used for this test only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(testingConnection ? "Testing…" : "Test current settings") {
                    testCurrentSettings()
                }
                .disabled(!canTestConnection)
                if !connectionLine.isEmpty {
                    Text(connectionLine)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(connectionLine.hasPrefix("Key accepted") ? Color.secondary : Color.red)
                }
            }
            Section("Comparison input") {
                Text("All selected services receive the same transcript excerpts, notes, product context and up to four JPEG stills per slice. Video is excluded so models can be compared on identical evidence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Text", value: "yes")
                LabeledContent("Images", value: "yes")
                LabeledContent("Video", value: "no — identical input comparison")
            }
            Section("Export") {
                Toggle("Include full transcript in session-pack.zip", isOn: $settings.includeFullTranscriptInZip)
                Text("Off by default. The local archive always keeps full_transcript.json. Agents receive export/ only. Stop asks for upload consent before transcription and any upload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!controller.canChangeCaptureSettings)
    }

    private var generalTab: some View {
        Form {
            ProductContextsSettingsView(settings: settings, controller: controller)
            Section("Retention") {
                Picker("Keep recordings", selection: $settings.retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("On the next app launch, completed recordings older than this limit are permanently removed, including their archive and export. Unfinished recordings are kept. Choose Forever to manage deletion yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!controller.canChangeCaptureSettings)
            Section("Meeting notice") {
                Toggle("I will tell participants this Mac is recording", isOn: $settings.meetingNoticeAccepted)
                Text("ScrumTrace captures other people’s voices and shared screens. You are the controller. See docs/PRIVACY.md and docs/PARTICIPANT_NOTICE.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!controller.canChangeCaptureSettings)
            Section("License") {
                Text(licenseLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Signed license (label|expires.signature)", text: $licenseDraft)
                Button("Save license") {
                    licenseLine = LicenseStore.applyLicenseKey(licenseDraft).settingsLine
                    AgentLog.event("settings_action", ["action": "license_save"])
                }
                .disabled(licenseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("A 14-day local trial is display-only. Record is never gated by this row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Text(updateLine.isEmpty ? "This build is \(UpdateChecker.currentVersion)." : updateLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(checkingUpdates ? "Checking GitHub releases…" : "Check GitHub releases") {
                    guard !checkingUpdates else { return }
                    checkingUpdates = true
                    updateLine = "Checking GitHub releases…"
                    AgentLog.event("settings_action", ["action": "updates"])
                    Task {
                        defer { checkingUpdates = false }
                        let result = await UpdateChecker.check()
                        updateLine = result.settingsLine
                    }
                }
                .disabled(checkingUpdates)
                Button("Open releases page") {
                    NSWorkspace.shared.open(UpdateChecker.releasesURL)
                }
            }
            Section("About") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                LabeledContent(
                    "Build",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                )
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "com.str8minds.ScrumTrace")
                Toggle("Show ScrumTrace in the Dock while its window is open", isOn: $settings.showInDockWhileWindowOpen)
                    .accessibilityIdentifier("main.settings.showInDock")
                Text("Adds a Dock icon and a Command-Tab entry while the ScrumTrace window is open. Closing the window returns ScrumTrace to the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show first-run permissions") {
                    AgentLog.event("settings_action", ["action": "onboarding"])
                    OnboardingWindow.present()
                }
                Button("Open privacy notes") {
                    AgentLog.event("settings_action", ["action": "privacy_doc"])
                    openRepoDoc("docs/PRIVACY.md")
                }
                Button("Open participant notice") {
                    AgentLog.event("settings_action", ["action": "notice_doc"])
                    openRepoDoc("docs/PARTICIPANT_NOTICE.md")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openRepoDoc(_ relative: String) {
        let bundled = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: bundled.path) {
            NSWorkspace.shared.open(bundled)
            return
        }
        if let url = URL(string: "https://github.com/ciprian-lupu/scrumtrace/blob/develop/\(relative)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var canTestConnection: Bool {
        !testingConnection
            && settings.connectionLibrary.selected != nil
            && settings.configurationIssue == nil
            && (settings.hasSavedAPIKey
                || !settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func configurationForConnectionTest() -> AIProviderConfiguration {
        var configuration = settings.providerConfiguration()
        let draft = settings.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            configuration.apiKey = draft
        }
        return configuration
    }

    private func testCurrentSettings() {
        guard canTestConnection else { return }
        testingConnection = true
        connectionLine = "Sending a one-word ping…"
        let configuration = configurationForConnectionTest()
        AgentLog.event("settings_action", ["action": "test_llm"])
        Task {
            defer { testingConnection = false }
            do {
                let result = try await AIConnectionTest.run(configuration: configuration)
                connectionLine = AIConnectionTest.successLine(result: result, model: configuration.model)
                AgentLog.event("settings_action", [
                    "action": "test_llm_ok",
                    "ms": String(result.elapsedMs)
                ])
            } catch {
                connectionLine = AIConnectionTest.userMessage(for: error)
                AgentLog.event("settings_action", [
                    "action": "test_llm_fail",
                    "error": AIProviderError.diagnosticCode(error)
                ])
            }
        }
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

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab = SettingsTab.speech
    /// Whether Settings found a saved recording that Review and name speakers… can list, or nil until its first check
    /// landed. Settings reads the vault off the main actor when it appears and when recording or analysis starts or
    /// ends; the presenter keeps this object, so the last answer survives Settings being rebuilt.
    @Published var hasReviewableSession: Bool?
}

enum SettingsTab: Hashable, CaseIterable {
    case speech
    case capture
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
    @State private var currentRunOnly = true
    @State private var liveUpdates = true
    @State private var search = ""
    @State private var checkingUpdates = false

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
            }
            HStack {
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
            HStack {
                Toggle("Current run only", isOn: $currentRunOnly)
                Toggle("Live updates", isOn: $liveUpdates)
                Spacer()
                Text("Newest first · up to 250 entries").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Filter log entries", text: $search)
                .textFieldStyle(.roundedBorder)
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
                Text(logText.isEmpty ? "No matching entries. Clear the filter, include earlier runs, or tap Log permission probe." : logText)
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
                Button("Reveal recordings folder") {
                    AgentLog.event("settings_action", ["action": "reveal_sessions"])
                    controller.vault.revealRootInFinder()
                }
                Button(checkingUpdates ? "Checking updates…" : "Check for updates") {
                    guard !checkingUpdates else { return }
                    checkingUpdates = true
                    status = "Checking GitHub releases…"
                    AgentLog.event("settings_action", ["action": "updates"])
                    Task {
                        defer { checkingUpdates = false }
                        status = await UpdateChecker.check().settingsLine
                    }
                }
                .disabled(checkingUpdates)
            }
        }
        .onAppear {
            reload()
            reloadCrashes()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if liveUpdates { reload() }
        }
        .onChange(of: currentRunOnly) { _, _ in reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: liveUpdates) { _, enabled in if enabled { reload() } }
    }

    private func reload() {
        logText = AgentLog.readTail(maxLines: 250, runID: currentRunOnly ? AgentLog.currentRunID : nil,
                                    query: search, newestFirst: true)
    }

    private func reloadCrashes() {
        crashNames = CapturePermissions.crashReportURLs().map(\.lastPathComponent)
    }
}
